with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Model_Runner.Grammar;
with Model_Runner.Tokenizer;
with Model_Runner.Tools.Constraint;

package body Model_Runner.Agent is

   package Conv renames Model_Runner.Conversation;
   package U renames Ada.Strings.Unbounded;
   package E renames Model_Runner.Errors;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package Vocab renames Model_Runner.Tokenizer;

   use type Gen.Completion_Reason;
   use type Interfaces.Unsigned_64;
   use type E.Error_Code;
   use type Model_Runner.Clocks.Clock_Reference;

   --  How many distinct calls one loop remembers, to notice a repeat. A
   --  model asks for a handful of tools; a table this size costs a couple
   --  of kilobytes and holds far more calls than a well-behaved loop makes.
   Seen_Max : constant := 256;

   type Text_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   ---------
   -- Run --
   ---------

   procedure Run
     (Source     : Model_Runner.Llama.Model'Class;
      Session    : in out Model_Runner.Llama.Session;
      Messages   : in out Model_Runner.Conversation.History;
      Offered    : Model_Runner.Tools.Definitions;
      Executor   : in out Model_Runner.Tools.Runner.Instance'Class;
      Generation : Model_Runner.Generation.Request;
      Stop_Set   : Model_Runner.Stops.Set;
      Sink       : Model_Runner.Output.Sink_Reference;
      Time       : Model_Runner.Clocks.Clock_Reference;
      Seeds      : Model_Runner.Entropy.Source_Reference;
      Cancel     : Model_Runner.Cancellation.Token_Reference := null;
      Max_Steps  : Positive := 8;
      Max_Seconds : Duration := 0.0;
      Max_Total_Tokens : Natural := 0;
      Max_Parallel : Positive := 1;
      Tool_Syntax : Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Tools.Tool_Call_JSON;
      Thinking   : Model_Runner.Templates.Thinking_Choice :=
        Model_Runner.Templates.Thinking_Unstated;
      Watch      : Observer_Reference := null;
      Approve    : Approver_Reference := null;
      Max_Retries : Natural := 0;
      Compact     : Boolean := False;
      Keep_Recent : Positive := 6;
      Answer_Schema : String := "";
      Pictures    : Model_Runner.Generation.Picture_Set :=
        Model_Runner.Generation.No_Pictures;
      Bounds     : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Result     : out Outcome)
   is
      Words : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Source);

      Have_Tools : constant Boolean :=
        Model_Runner.Tools.Count (Offered) > 0;

      --  Whether generation is grammar-constrained at all: whenever there
      --  are tools to call, and also when a final answer must take a shape,
      --  even with no tools.
      use type Model_Runner.Tools.Call_Syntax;

      --  The call grammar shapes the <tool_call> envelope and both tag
      --  forms -- Qwen3-Coder's <function=..> and MiniCPM's <function
      --  name="..">, each with a <think> block admitted ahead of the
      --  reply, since those families reason in one. Left free before,
      --  because that block's '<' was one the grammar's prose refused, a
      --  0.8B wrote <parameter/op> and lost the argument; shaped, it
      --  cannot. Open_JSON alone is left free where tools are offered --
      --  its point is to read the object a model writes without any
      --  envelope, and the grammar's prose would admit that object and
      --  shape nothing -- and shaped by the answer schema where none are,
      --  since an answer is the same JSON whichever syntax the calls take.
      Constrain : constant Boolean :=
        (Have_Tools or else Answer_Schema /= "")
        and then (Tool_Syntax /= Model_Runner.Tools.Open_JSON
                  or else not Have_Tools);

      --  The grammar, compiled once: the tools do not change between steps,
      --  so neither does what a call may look like.
      Rules_Grammar : aliased Model_Runner.Grammar.Compiled;
      Rules         : Gen.Grammar_Reference := null;

      --  A generation request the loop owns the discipline of. The caller's
      --  sampling and budget are kept; the three fields the loop must decide
      --  are set here, over whatever the caller left in them.
      Request : Gen.Request := Generation;

      Last_Result : Gen.Result;

      --  A wall-clock budget for the loop, checked between steps. Read once
      --  at the start; a monotonic clock never goes back, so the elapsed
      --  time below is never negative.
      Timing    : constant Boolean := Time /= null and then Max_Seconds > 0.0;
      Started   : constant Model_Runner.Clocks.Nanoseconds :=
        (if Timing then Model_Runner.Clocks.Read (Time) else 0);
      Budget_Ns : constant Model_Runner.Clocks.Nanoseconds :=
        Model_Runner.Clocks.Nanoseconds (Long_Float (Max_Seconds) * 1.0e9);

      --  The calls made so far, by a hash of name-and-arguments, so a call
      --  the model has already made is noticed rather than run again -- a
      --  real tool may not be idempotent, and a model that repeats itself
      --  is not making progress.
      Seen      : array (1 .. Seen_Max) of Interfaces.Unsigned_64;
      Seen_Used : Natural := 0;

      --  Retries left for a generation that ends in a runtime error. Spent
      --  down as they are used; when none are left, such an error stops the
      --  loop as it always did.
      Retries_Left : Natural := Max_Retries;

      --  FNV-1a over the name, a separator, and the arguments.
      function Digest (Named : String; Args : String)
        return Interfaces.Unsigned_64
      is
         Hash : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
         procedure Mix (Text : String) is
         begin
            for C of Text loop
               Hash :=
                 (Hash xor Interfaces.Unsigned_64 (Character'Pos (C)))
                 * 16#0000_0100_0000_01B3#;
            end loop;
         end Mix;
      begin
         Mix (Named);
         Mix ([1 => ASCII.NUL]);
         Mix (Args);
         return Hash;
      end Digest;

      function Already_Seen (Key : Interfaces.Unsigned_64) return Boolean is
      begin
         for Index in 1 .. Seen_Used loop
            if Seen (Index) = Key then
               return True;
            end if;
         end loop;
         return False;
      end Already_Seen;

      procedure Remember (Key : Interfaces.Unsigned_64) is
      begin
         if Seen_Used < Seen_Max then
            Seen_Used := Seen_Used + 1;
            Seen (Seen_Used) := Key;
         end if;
      end Remember;

      --  Render the committed conversation, with the tools in it, ready for
      --  the model to continue.
      procedure Render
        (Rendered : out Text_Access;
         Status   : out E.Error_Info)
      is
         Buffer : Text_Access := new String (1 .. Bounds.Max_Rendered_Bytes);
         Last   : Natural;
      begin
         Rendered := null;
         Model_Runner.Templates.Render
           (L.Template (Source).all, Messages,
            Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
            Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
            True, Buffer.all, Last, Status,
            Thinking => Thinking,
            Tools    => (if Have_Tools then Offered'Unrestricted_Access
                         else null));
         if E.Is_Ok (Status) then
            Rendered := new String'(Buffer.all (1 .. Last));
         end if;
         Free (Buffer);
      end Render;

   begin
      Result := (Reason => Answered, others => <>);

      Request.Add_Beginning := False;
      Request.Retain_Text := True;
      Request.Reuse_Committed_Prefix := True;
      if not L.Capability (Source).Supports_Batched then
         Request.Batch_Size := 1;
      end if;

      if Constrain then
         Model_Runner.Tools.Constraint.Compile_Call_Grammar
           (Offered, Rules_Grammar, Result.Error,
            Answer_Schema => Answer_Schema,
            Syntax        => Tool_Syntax);
         if E.Is_Error (Result.Error) then
            Result.Reason := Grammar_Failed;
            return;
         end if;
         Rules := Rules_Grammar'Unchecked_Access;
      end if;

      Step_Loop :
      loop
         --  The wall-clock budget, between steps. A generation in flight is
         --  bounded by its token budget, so this is checked here rather than
         --  inside one.
         if Timing
           and then Model_Runner.Clocks.Read (Time) - Started > Budget_Ns
         then
            Result.Reason := Timed_Out;
            exit Step_Loop;
         end if;

         declare
            Rendered : Text_Access := null;
            Status   : E.Error_Info;
         begin
            Render (Rendered, Status);

            --  A conversation too large to render is made to fit by dropping
            --  its oldest turns, rather than ending the loop -- when the
            --  caller asked for that. Each compaction that drops something
            --  invalidates the committed positions, so the session is reset
            --  before rendering again.
            while Compact
              and then E.Is_Error (Status)
              and then Status.Code = E.Template_Output_Too_Large
            loop
               declare
                  Gone : Natural;
               begin
                  Conv.Compact (Messages, Keep_Recent, Gone);
                  exit when Gone = 0;
                  L.Reset (Session);
                  Result.Compactions := Result.Compactions + 1;
                  Free (Rendered);
                  Render (Rendered, Status);
               end;
            end loop;

            if E.Is_Error (Status) then
               Result.Reason := Render_Failed;
               Result.Error := Status;
               exit Step_Loop;
            end if;

            Gen.Release (Last_Result);
            Gen.Generate
              (Source   => Source,
               Session  => Session,
               Prompt   => Rendered.all,
               Item     => Request,
               Stop_Set => Stop_Set,
               Rules    => Rules,
               Sink     => Sink,
               Observer => null,
               Time     => Time,
               Seeds    => Seeds,
               Cancel   => Cancel,
               Bounds   => Bounds,
               Pictures => Pictures,
               Outcome  => Last_Result);
            Free (Rendered);
         end;

         if Last_Result.Reason = Gen.Runtime_Error then
            --  An unfinished turn is not committed, and the session is reset
            --  so the next attempt re-evaluates the committed conversation.
            L.Reset (Session);
            if Retries_Left > 0 then
               --  A retry: the committed conversation is unchanged, so the
               --  loop renders it again and generates again. The step is not
               --  counted, only the retry.
               Retries_Left := Retries_Left - 1;
               Result.Retries := Result.Retries + 1;
               goto Next_Iteration;
            end if;
            Result.Reason := Generation_Failed;
            Result.Error := Last_Result.Error;
            exit Step_Loop;
         end if;

         if Last_Result.Reason = Gen.Cancelled then
            L.Reset (Session);
            Result.Reason := Cancelled;
            exit Step_Loop;
         end if;

         --  Commit the reply as the turn it is: the text becomes the
         --  content, and each call is attached so the next render writes it
         --  in the template's own spelling.
         declare
            Status  : E.Error_Info;
            Reading : E.Error_Info;
         begin
            if Have_Tools then
               Conv.Append_Reply
                 (Messages, Gen.Generated_Text (Last_Result), Status, Reading,
                  Syntax => Tool_Syntax);
            else
               Conv.Append
                 (Messages, Conv.Assistant_Role,
                  Gen.Generated_Text (Last_Result), Status);
            end if;

            --  An empty reply -- no words and no call -- is not a failure of
            --  the history; it is a model with nothing more to say. Take the
            --  loop as answered rather than erroring on the empty turn, which
            --  a model does reach when a tool's result was all it needed and
            --  it adds nothing to it.
            if Status.Code = E.Conversation_Empty then
               Result.Reason := Answered;
               exit Step_Loop;
            end if;

            if E.Is_Error (Status) then
               L.Reset (Session);
               Result.Reason := History_Failed;
               Result.Error := Status;
               exit Step_Loop;
            end if;
         end;

         Result.Steps := Result.Steps + 1;
         Result.Generated_Tokens :=
           Result.Generated_Tokens + Last_Result.Generated_Tokens;
         Result.Prompt_Tokens := Last_Result.Prompt_Tokens;

         declare
            Turn  : constant Positive := Conv.Length (Messages);
            Asked : constant Natural := Conv.Call_Count (Messages, Turn);

            --  Whether this turn made a call it had not made before. A turn
            --  whose calls are all repeats got nowhere, and the loop stops
            --  rather than circle.
            Progressed : Boolean := False;
         begin
            --  Nothing left to run: the model has answered.
            exit Step_Loop when Asked = 0;

            --  Calls to run, but no room to run them and read the answer.
            if Result.Steps >= Max_Steps then
               Result.Reason := Step_Limit;
               exit Step_Loop;
            end if;

            --  Calls to run, but the cumulative token budget is spent.
            if Max_Total_Tokens > 0
              and then Result.Generated_Tokens >= Max_Total_Tokens
            then
               Result.Reason := Token_Limit;
               exit Step_Loop;
            end if;

            --  Decide, run and report the turn's calls. The decisions --
            --  dedup and approval -- and every result appended stay on this
            --  task and in call order; the runs of calls the Executor marks
            --  parallel-safe may overlap on worker tasks in between. A real
            --  tool need not be safe to run twice, so a call the model already
            --  made is not run again: the model is told it repeated itself and
            --  pointed back at the answer it has.
            declare
               type Plan_Kind is (As_Note, As_Serial, As_Parallel);
               type Item_Rec is record
                  Named  : U.Unbounded_String;
                  Args   : U.Unbounded_String;
                  Kind   : Plan_Kind := As_Note;
                  Text   : U.Unbounded_String;  --  a note, or a run's answer
                  Failed : Boolean := False;     --  the answer would not fit
                  Done   : Boolean := False;     --  the run has happened
               end record;

               Items   : array (1 .. Asked) of Item_Rec;
               Planned : Natural := 0;  --  calls decided before an approval halt
               Halted  : Boolean := False;

               Repeat_Note : constant String :=
                 "error: this exact call was already made in this "
                 & "conversation; use its earlier result rather than "
                 & "repeating the call";
            begin
               --  Decide each call in order: dedup, then approval.
               Plan_Calls :
               for Call in 1 .. Asked loop
                  declare
                     Named : constant String :=
                       Conv.Call_Name (Messages, Turn, Call);
                     Args  : constant String :=
                       Conv.Call_Arguments (Messages, Turn, Call);
                     Key   : constant Interfaces.Unsigned_64 :=
                       Digest (Named, Args);
                  begin
                     Items (Call).Named := U.To_Unbounded_String (Named);
                     Items (Call).Args  := U.To_Unbounded_String (Args);
                     if Watch /= null then
                        Watch.On_Call (Named, Args);
                     end if;

                     if Already_Seen (Key) then
                        Items (Call).Text :=
                          U.To_Unbounded_String (Repeat_Note);
                     else
                        Progressed := True;
                        Remember (Key);
                        if not Model_Runner.Tools.Offers (Offered, Named) then
                           --  The grammar should have made this impossible;
                           --  if it happens anyway, the model hears the truth
                           --  and may correct itself.
                           Items (Call).Text := U.To_Unbounded_String
                             ("error: no tool named """ & Named & """");
                        else
                           case (if Approve = null then Allow
                                 else Approve.Consider (Named, Args))
                           is
                              when Halt =>
                                 --  The gate stopped the run: the calls so far
                                 --  stand and the loop ends after they report.
                                 Halted := True;
                                 exit Plan_Calls;

                              when Deny =>
                                 --  The gate declined this one call. The model
                                 --  is told and may take another way.
                                 Items (Call).Text := U.To_Unbounded_String
                                   ("error: running """ & Named
                                    & """ was not approved; do not repeat it "
                                    & "-- take a different approach or answer "
                                    & "without it");

                              when Allow =>
                                 if Executor.Parallel_Safe (Named) then
                                    Items (Call).Kind := As_Parallel;
                                 else
                                    Items (Call).Kind := As_Serial;
                                 end if;
                           end case;
                        end if;
                     end if;
                     Planned := Call;
                  end;
               end loop Plan_Calls;

               --  Overlap the parallel-safe runs when there is more than one
               --  and room to. Each worker takes the next such call, runs it
               --  into its own buffer, and leaves the answer in its slot; the
               --  block's end waits for them all.
               declare
                  P_Index : array (1 .. Planned) of Positive;
                  P_Count : Natural := 0;
               begin
                  for I in 1 .. Planned loop
                     if Items (I).Kind = As_Parallel then
                        P_Count := P_Count + 1;
                        P_Index (P_Count) := I;
                     end if;
                  end loop;

                  if Max_Parallel > 1 and then P_Count > 1 then
                     declare
                        protected Dispatch is
                           procedure Next (Slot : out Natural);
                        private
                           Cursor : Natural := 0;
                        end Dispatch;

                        protected body Dispatch is
                           procedure Next (Slot : out Natural) is
                           begin
                              if Cursor < P_Count then
                                 Cursor := Cursor + 1;
                                 Slot   := Cursor;
                              else
                                 Slot := 0;
                              end if;
                           end Next;
                        end Dispatch;

                        task type Worker;
                        task body Worker is
                           Slot : Natural;
                        begin
                           loop
                              Dispatch.Next (Slot);
                              exit when Slot = 0;
                              declare
                                 Idx  : constant Positive := P_Index (Slot);
                                 Buf  : String
                                   (1 .. Model_Runner.Tools.Max_Call_Bytes);
                                 Fill : Natural;
                                 Ran  : E.Error_Info;
                              begin
                                 Executor.Run
                                   (U.To_String (Items (Idx).Named),
                                    U.To_String (Items (Idx).Args),
                                    Buf, Fill, Ran);
                                 if E.Is_Error (Ran) then
                                    Items (Idx).Failed := True;
                                 else
                                    Items (Idx).Text :=
                                      U.To_Unbounded_String (Buf (1 .. Fill));
                                 end if;
                                 Items (Idx).Done := True;
                              exception
                                 when others =>
                                    Items (Idx).Failed := True;
                                    Items (Idx).Done   := True;
                              end;
                           end loop;
                        end Worker;

                        Crew : array
                          (1 .. Positive'Min (Max_Parallel, P_Count))
                          of Worker;
                     begin
                        null;  --  the block's end waits for every Worker
                     end;
                  end if;
               end;

               --  Report every decided call, in order. A parallel run's answer
               --  is already in hand; a serial run -- and a parallel one no
               --  worker took (Max_Parallel one, or the turn's only such call)
               --  -- happens here on this task.
               Report_Calls :
               for Call in 1 .. Planned loop
                  declare
                     Named  : constant String :=
                       U.To_String (Items (Call).Named);
                     Status : E.Error_Info;
                  begin
                     if Items (Call).Kind = As_Serial
                       or else (Items (Call).Kind = As_Parallel
                                and then not Items (Call).Done)
                     then
                        declare
                           Buf  : String
                             (1 .. Model_Runner.Tools.Max_Call_Bytes);
                           Fill : Natural;
                           Ran  : E.Error_Info;
                        begin
                           Executor.Run
                             (Named, U.To_String (Items (Call).Args),
                              Buf, Fill, Ran);
                           if E.Is_Error (Ran) then
                              Items (Call).Failed := True;
                           else
                              Items (Call).Text :=
                                U.To_Unbounded_String (Buf (1 .. Fill));
                           end if;
                        end;
                     end if;

                     declare
                        Reply : constant String :=
                          (if Items (Call).Failed
                           then "error: the tool's answer was too large to "
                                & "return"
                           else U.To_String (Items (Call).Text));
                     begin
                        Conv.Append (Messages, Conv.Tool_Role, Reply, Status);
                        if Watch /= null then
                           Watch.On_Result (Named, Reply);
                        end if;
                     end;

                     Result.Calls := Result.Calls + 1;
                     if E.Is_Error (Status) then
                        L.Reset (Session);
                        Result.Reason := History_Failed;
                        Result.Error := Status;
                        exit Step_Loop;
                     end if;
                  end;
               end loop Report_Calls;

               if Halted then
                  Result.Reason := Declined;
                  exit Step_Loop;
               end if;
            end;

            --  A turn that only repeated calls it had already made is going
            --  in circles. Stop rather than let it spend the step budget on
            --  the same calls over and over.
            if not Progressed then
               Result.Reason := Repeating;
               exit Step_Loop;
            end if;
         end;

         --  The step's turn and its tool results are in the history now; a
         --  watcher may persist the run's progress before the next step.
         if Watch /= null then
            Watch.On_Step;
         end if;

         --  Where a retried generation rejoins the loop, having reset the
         --  session and left the committed conversation as it was.
         <<Next_Iteration>>
         null;
      end loop Step_Loop;

      Gen.Release (Last_Result);
      Model_Runner.Grammar.Close (Rules_Grammar);
   exception
      when others =>
         Gen.Release (Last_Result);
         Model_Runner.Grammar.Close (Rules_Grammar);
         Result.Reason := Generation_Failed;
         Result.Error := E.Make (E.Internal_Unexpected_Exception);
   end Run;

end Model_Runner.Agent;
