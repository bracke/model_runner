with Ada.Strings.Fixed;
with Ada.Real_Time;
with Ada.Characters.Handling;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Model_Runner.Agent.Recall;
with Model_Runner.Grammar;
with Model_Runner.Tokenizer;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Constraint;

package body Model_Runner.Agent is

   use type Model_Runner.Tools.Runner.Call_Kind;
   use type Model_Runner.Tools.Runner.Answer_Kind;

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

   type Text_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   ---------------
   -- Answer_Of --
   ---------------

   function Answer_Of (Reply : String) return String is
      Close : constant Natural :=
        Ada.Strings.Fixed.Index (Reply, "</think>", Ada.Strings.Backward);
      First : Positive := (if Close = 0 then Reply'First else Close + 8);
   begin
      if Close = 0 then
         return Reply;
      end if;
      while First <= Reply'Last and then Reply (First) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
         First := First + 1;
      end loop;
      return Reply (First .. Reply'Last);
   end Answer_Of;

   ------------------
   -- Reason_Words --
   ------------------

   function Reason_Words (Reason : Stop_Reason) return String is
      Said : String := Ada.Characters.Handling.To_Lower (Stop_Reason'Image (Reason));
   begin
      for C of Said loop
         if C = '_' then
            C := ' ';
         end if;
      end loop;
      return Said;
   end Reason_Words;

   ---------
   -- Run --
   ---------

   --------------
   -- Class_Of --
   --------------

   function Class_Of (Status : Model_Runner.Errors.Error_Info) return Failure_Class
   is (case Status.Code is
         when E.Template_Output_Too_Large => Too_Large_To_Render,
         when E.Generation_Context_Exhausted | E.Generation_Prompt_Too_Long => Context_Exhausted,
         when E.Generation_Cancelled => Interrupted,
         when E.Tools_Call_Malformed => Unreadable_Call,
         when others =>
           (if E.Is_Error (Status) then Backend_Error else Other_Failure));

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

      --  The same budget as the deadline the run's calls run within.
      Deadline : constant Ada.Real_Time.Time :=
        (if Timing then Ada.Real_Time."+" (Ada.Real_Time.Clock, Ada.Real_Time.To_Time_Span (Max_Seconds))
         else Ada.Real_Time.Time_Last);

      --  Tokens the run has spent, its own and its children's.
      function Spent return Natural is (Result.Generated_Tokens + Result.Delegated_Tokens);

      --  The calls made since the state they read last changed, by their
      --  identity -- name and canonical arguments -- so a call the model has already made is
      --  noticed rather than run again -- a real tool may not be
      --  idempotent, and a model that repeats itself is not making
      --  progress -- with what each answered and how it ended. See Recall.
      Made : Model_Runner.Agent.Recall.Memory;

      --  And the work as it went, for a compacted conversation to carry.
      Work : Model_Runner.Agent.Recall.Work_Log;

      --  What calls answered and what was written where, across every
      --  change; and how many answered calls in a row have changed
      --  nothing. A run going nowhere is told so -- the harness says what
      --  it sees rather than waiting for the step budget to run out.
      Sighted : Model_Runner.Agent.Recall.Sightings;
      Quiet   : Natural := 0;

      --  Whether any call has changed state yet: before one, an answer
      --  the same as before is no news.
      Made_Change : Boolean := False;

      --  Calls made in the turns before this one: a call's number in the
      --  run is this and its place in its turn.
      Invocations : Natural := 0;

      --  Calls in a row that change nothing before the run is told so, and
      --  told again at every as many more.
      Quiet_Note : constant := 8;

      --  Turns in a row that only repeated calls: going round is the
      --  second such turn, not the first.
      Stalled : Natural := 0;

      --  Retries left for a generation that ends in a runtime error. Spent
      --  down as they are used; when none are left, such an error stops the
      --  loop as it always did.
      Retries_Left : Natural := Max_Retries;

      --  Times a reply whose call would not read is given back to the
      --  model, and what the last reply's reading said.
      Chances_Left : Natural := 2;
      Reading      : E.Error_Info;

      --  Whether a reply's text closes the call it ends in, in the syntax the
      --  calls are read in: a marked call by its closing tag, an open one by
      --  its object's brace or its fence.
      function Closes_Call (Text : String) return Boolean is
         Last : Natural := Text'Last;
      begin
         while Last >= Text'First and then Text (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
            Last := Last - 1;
         end loop;
         declare
            Trimmed : constant String := Text (Text'First .. Last);
            function Ends (Mark : String) return Boolean is
              (Trimmed'Length >= Mark'Length
               and then Trimmed (Trimmed'Last - Mark'Length + 1 .. Trimmed'Last) = Mark);
         begin
            case Tool_Syntax is
               when Model_Runner.Tools.Function_XML => return Ends ("</function>");
               when Model_Runner.Tools.Tool_Call_JSON | Model_Runner.Tools.Qwen_XML =>
                  return Ends ("</tool_call>");
               when others => return Ends ("}") or else Ends ("```");
            end case;
         end;
      end Closes_Call;

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
      Request.Deadline := Deadline;
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
            while E.Is_Error (Status)
              and then Recovery_For (Class_Of (Status), Compact, Retries_Left, 0)
                       = Compact_And_Retry
            loop
               declare
                  Gone : Natural;
               begin
                  Conv.Compact (Messages, Keep_Recent, Gone, Work.Record_Text);
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

            Request.Hold_Back :=
              Model_Runner.Templates.Opening
                (L.Template (Source).all, Messages,
                 Vocab.Token_Text
                   (Words.all, Vocab.Beginning_Token (Words.all)),
                 Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
                 Rendered.all,
                 Thinking => Thinking,
                 Tools    => (if Have_Tools then Offered'Unrestricted_Access
                              else null));

            --  No more asked of a generation than the run has left.
            if Max_Total_Tokens > 0 then
               if Spent >= Max_Total_Tokens then
                  Free (Rendered);
                  Result.Reason := Token_Limit;
                  exit Step_Loop;
               end if;
               Request.Max_Tokens :=
                 Natural'Min (Generation.Max_Tokens, Max_Total_Tokens - Spent);
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
            case Recovery_For (Class_Of (Last_Result.Error), Compact, Retries_Left, 0) is
               when Retry_Same =>
                  --  A retry: the committed conversation is unchanged, so
                  --  the loop renders it again and generates again. The step
                  --  is not counted, only the retry.
                  Retries_Left := Retries_Left - 1;
                  Result.Retries := Result.Retries + 1;
                  goto Next_Iteration;
               when Compact_And_Retry =>
                  --  Out of context: room made by dropping the oldest turns,
                  --  and the step tried again -- where it was tried again as
                  --  it was, and ran out the same way.
                  declare
                     Gone : Natural;
                  begin
                     Conv.Compact (Messages, Keep_Recent, Gone, Work.Record_Text);
                     if Gone > 0 then
                        Result.Compactions := Result.Compactions + 1;
                        goto Next_Iteration;
                     end if;
                  end;
               when Return_To_Model | Stop =>
                  null;
            end case;
            Result.Reason := Generation_Failed;
            Result.Error := Last_Result.Error;
            exit Step_Loop;
         end if;

         if Last_Result.Reason = Gen.Cancelled then
            L.Reset (Session);
            Result.Reason := Cancelled;
            exit Step_Loop;
         end if;

         --  The run's time ran out inside the reply: stopped there, not
         --  after it, and the turn cut short is not committed.
         if Last_Result.Reason = Gen.Time_Limit then
            L.Reset (Session);
            Result.Reason := Timed_Out;
            exit Step_Loop;
         end if;

         --  Commit the reply as the turn it is: the text becomes the
         --  content, and each call is attached so the next render writes it
         --  in the template's own spelling.
         declare
            Status  : E.Error_Info;
         begin
            Reading := E.Success;
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

         --  A call written so that it could not be read: the model is told,
         --  and tries again, twice at most -- where the reply was taken as
         --  an answer with no call in it and the run ended.
         --  Only where a call is marked as one: the open syntax reads a bare
         --  or fenced object as a call, and an answer showing a sample of
         --  JSON is no broken call.
         if E.Is_Error (Reading)
           and then Model_Runner.Tools."/=" (Tool_Syntax, Model_Runner.Tools.Open_JSON)
           and then Conv.Call_Count (Messages, Conv.Length (Messages)) = 0
           and then Result.Steps < Max_Steps
           and then Recovery_For (Class_Of (Reading), Compact, Retries_Left, Chances_Left)
                    = Return_To_Model
         then
            declare
               Told : E.Error_Info;
            begin
               Chances_Left := Chances_Left - 1;
               Conv.Append
                 (Messages, Conv.User_Role,
                  "Your tool call could not be read: " & E.Error_Code'Image (Reading.Code)
                  & ". Write the call again, exactly in the format the tools were offered"
                  & " in, or answer without a call.", Told);
               if E.Is_Ok (Told) then
                  goto Next_Iteration;
               end if;
            end;
         end if;

         declare
            Turn  : constant Positive := Conv.Length (Messages);
            Asked : constant Natural := Conv.Call_Count (Messages, Turn);

            --  Whether this turn made a call it had not made before. A turn
            --  whose calls are all repeats got nowhere, and the loop stops
            --  rather than circle.
            Progressed : Boolean := False;

            --  Whether the reply stopped at its token limit inside its last
            --  call: the text does not close it. Such a call is read from
            --  what was written before the cut -- a file's content stopping
            --  mid-line -- and is not run: a write of it would leave the
            --  file cut short.
            Cut_Last : constant Boolean :=
              Last_Result.Reason in Gen.Maximum_Tokens | Gen.Context_Full
              and then not Closes_Call (Gen.Generated_Text (Last_Result));
         begin
            --  Nothing left to run: the model has answered.
            exit Step_Loop when Asked = 0;

            if Watch /= null then
               Watch.On_Turn (Result.Steps, Asked);
            end if;

            --  Calls to run, but no room to run them and read the answer.
            if Result.Steps >= Max_Steps then
               Result.Reason := Step_Limit;
               exit Step_Loop;
            end if;

            --  Calls to run, but the cumulative token budget is spent.
            if Max_Total_Tokens > 0 and then Spent >= Max_Total_Tokens then
               Result.Reason := Token_Limit;
               exit Step_Loop;
            end if;

            --  The run's limits, for every call of the turn to run within.
            Model_Runner.Tools.Runner.Set_Context
              (Executor,
               (Cancel      => Cancel,
                Deadline    => Deadline,
                Tokens_Left => (if Max_Total_Tokens = 0 then Natural'Last
                                else Max_Total_Tokens - Spent),
                --  As deep as the runner was made for: a helper's runner
                --  is handed its depth before its loop starts.
                Depth       => Model_Runner.Tools.Runner.Context_Of (Executor).Depth));

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
                  Copy_Of : Natural := 0;        --  the same call earlier this turn
                  --  How the run, or the note in its place, ended.
                  Ended  : Model_Runner.Tools.Runner.Call_Outcome :=
                    Model_Runner.Tools.Runner.Done;
               end record;

               Items   : array (1 .. Asked) of Item_Rec;
               Planned : Natural := 0;  --  calls decided before an approval halt
               Halted  : Boolean := False;

               --  Whether a call that Changes is planned this turn: a call
               --  after it waits for it, not run ahead of it with the
               --  parallel-safe ones, whose runs come before the serial.
               Changing : Boolean := False;

               --  A note in a call's place: refused by what, or failed.
               Failed_Note : constant Model_Runner.Tools.Runner.Call_Outcome :=
                 (Answer => Model_Runner.Tools.Runner.Failed, others => <>);

               Repeat_Note : constant String :=
                 "error: this exact call was already made in this "
                 & "conversation, and its result is above; where that "
                 & "was an error, the same call gives it again -- change "
                 & "the call, or do something else";
            begin
               --  Decide each call in order: dedup, then approval.
               Plan_Calls :
               for Call in 1 .. Asked loop
                  declare
                     Named : constant String :=
                       Conv.Call_Name (Messages, Turn, Call);
                     Args  : constant String :=
                       Conv.Call_Arguments (Messages, Turn, Call);
                     Key   : constant String := Model_Runner.Agent.Recall.Identity (Named, Args);
                     Effect : constant Model_Runner.Tools.Runner.Call_Kind :=
                       Executor.Kind (Named);
                  begin
                     Items (Call).Named := U.To_Unbounded_String (Named);
                     Items (Call).Args  := U.To_Unbounded_String (Args);
                     if Watch /= null then
                        Watch.On_Call
                          ((Id => Invocations + Call, In_Turn => Call, Of_Turn => Asked,
                            Changes => Effect = Model_Runner.Tools.Runner.Changes),
                           Named, Args);
                     end if;

                     if Call = Asked and then Cut_Last then
                        --  Cut off before it was whole: told, not run.
                        Items (Call).Text := U.To_Unbounded_String
                          ("error: your reply reached its length limit before this call was"
                           & " complete, so it was not run. Say less before a call; to change part"
                           & " of a file, edit_file replaces just that part.");
                        Items (Call).Ended := Failed_Note;
                        Progressed := True;
                        goto Decided;
                     end if;

                     --  The same call earlier in this very turn: its answer,
                     --  once it has one -- not run twice, not told off. A
                     --  clock is read again whatever was read before.
                     if Effect /= Model_Runner.Tools.Runner.Varies
                       and then Made.Holds (Key) and then not Made.Answered (Key)
                       and then (for some Earlier in 1 .. Call - 1 =>
                                   Model_Runner.Agent.Recall.Identity
                                     (U.To_String (Items (Earlier).Named),
                                      U.To_String (Items (Earlier).Args)) = Key)
                     then
                        for Earlier in 1 .. Call - 1 loop
                           if Model_Runner.Agent.Recall.Identity
                                (U.To_String (Items (Earlier).Named),
                                 U.To_String (Items (Earlier).Args)) = Key
                             and then Items (Call).Copy_Of = 0
                           then
                              Items (Call).Copy_Of := Earlier;
                           end if;
                        end loop;
                     elsif Effect /= Model_Runner.Tools.Runner.Varies and then Made.Holds (Key) then
                        --  Where it worked, the same answer again; where it
                        --  was an error, said that it will be again.
                        declare
                           Worked : constant Boolean :=
                             Made.Answered (Key)
                             and then Made.Ended (Key).Answer = Model_Runner.Tools.Runner.Answered;
                        begin
                           Items (Call).Text := U.To_Unbounded_String
                             (if Worked then Made.Answer (Key) else Repeat_Note);
                           Items (Call).Ended :=
                             (if Worked then Made.Ended (Key) else Failed_Note);
                        end;
                     else
                        --  Only a call not made before gets further: a
                        --  clock read again runs, and is no progress.
                        if not Made.Holds (Key) then
                           Progressed := True;
                           Made.Remember (Key);
                        end if;
                        if not Model_Runner.Tools.Offers (Offered, Named) then
                           --  The grammar should have made this impossible;
                           --  if it happens anyway, the model hears the truth
                           --  and may correct itself.
                           declare
                              Listed : U.Unbounded_String;
                           begin
                              for Index in 1 .. Model_Runner.Tools.Count (Offered) loop
                                 U.Append (Listed, (if Index = 1 then "" else ", ")
                                           & Model_Runner.Tools.Tool_Name (Offered, Index));
                              end loop;
                              Items (Call).Text := U.To_Unbounded_String
                                ("error: no tool named """ & Named & """ is offered here; the tools"
                                 & " offered are " & U.To_String (Listed));
                              Items (Call).Ended := Failed_Note;
                           end;
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
                                 Items (Call).Ended :=
                                   (Answer  => Model_Runner.Tools.Runner.Refused,
                                    Refusal => Model_Runner.Tools.Runner.Not_Permitted, others => <>);

                              when Allow =>
                                 --  After a call that changes state, in
                                 --  order: never run ahead of it.
                                 if Executor.Parallel_Safe (Named) and then not Changing then
                                    Items (Call).Kind := As_Parallel;
                                 else
                                    Items (Call).Kind := As_Serial;
                                 end if;
                                 --  And what was answered before it is
                                 --  stale once it has run.
                                 if Effect = Model_Runner.Tools.Runner.Changes then
                                    Changing := True;
                                    Made.Changed (Key);
                                 end if;
                           end case;
                        end if;
                     end if;
                     <<Decided>>
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
                                    Buf, Fill, Items (Idx).Ended, Ran);
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
                              Buf, Fill, Items (Call).Ended, Ran);
                           if E.Is_Error (Ran) then
                              Items (Call).Failed := True;
                           else
                              Items (Call).Text :=
                                U.To_Unbounded_String (Buf (1 .. Fill));
                           end if;
                        end;
                     end if;

                     declare
                        Source : constant Positive :=
                          (if Items (Call).Copy_Of > 0 then Items (Call).Copy_Of else Call);
                        Said_By_Tool : constant String :=
                          (if Items (Source).Failed
                           then "error: the tool's answer was too large to "
                                & "return"
                           else U.To_String (Items (Source).Text));
                        Ended : constant Model_Runner.Tools.Runner.Call_Outcome :=
                          (if Items (Source).Failed then Failed_Note else Items (Source).Ended);

                        Args    : constant String := U.To_String (Items (Call).Args);
                        Key     : constant String := Model_Runner.Agent.Recall.Identity (Named, Args);
                        Ran_Now : constant Boolean :=
                          Items (Call).Kind /= As_Note and then Items (Call).Copy_Of = 0;

                        --  What the harness sees in this call, said after
                        --  its answer: a check answering exactly as before
                        --  the last change, a file put back as an earlier
                        --  write left it, a run of calls changing nothing.
                        function Seen return String is
                           Has_Path, Has_Content : Boolean;
                           Path    : constant String :=
                             Model_Runner.Tools.Builtin.Text_Argument (Args, "path", Has_Path);
                           Content : constant String :=
                             Model_Runner.Tools.Builtin.Text_Argument (Args, "content", Has_Content);
                           Again   : constant Boolean :=
                             Ran_Now
                             and then Ended.Answer = Model_Runner.Tools.Runner.Answered
                             and then Executor.Kind (Named) = Model_Runner.Tools.Runner.Reads
                             and then Sighted.Seen_Again (Key, Said_By_Tool);
                           Back    : constant Boolean :=
                             Ran_Now and then Ended.Changed and then Has_Path and then Has_Content
                             and then Sighted.Seen_Again ("path" & ASCII.NUL & Path, Content);
                        begin
                           if Again and then Made_Change then
                              return ASCII.LF & "(note from the harness: this answers exactly as it"
                                & " did before your last change)";
                           elsif Back then
                              return ASCII.LF & "(note from the harness: this puts " & Path
                                & " back as an earlier write of yours left it)";
                           elsif Quiet > 0 and then Quiet mod Quiet_Note = 0 then
                              return ASCII.LF & "(note from the harness:" & Natural'Image (Quiet)
                                & " calls in a row have changed nothing; if what you need is in"
                                & " hand, act on it or give your answer)";
                           end if;
                           return "";
                        end Seen;
                     begin
                        if Ran_Now then
                           if Ended.Changed then
                              Quiet := 0;
                              Made_Change := True;
                           elsif Ended.Answer = Model_Runner.Tools.Runner.Answered then
                              Quiet := Quiet + 1;
                           end if;
                        end if;
                        declare
                           Reply : constant String := Said_By_Tool & Seen;
                        begin
                           --  Kept by the call, for a repeat of it, and in the
                           --  record of the work: by the path it named, where
                           --  it named one.
                           Made.Keep (Model_Runner.Agent.Recall.Identity (Named, Args), Reply, Ended);
                           declare
                              Named_Path : Boolean;
                              Path       : constant String :=
                                Model_Runner.Tools.Builtin.Text_Argument
                                  (U.To_String (Items (Call).Args), "path", Named_Path);
                           begin
                              Work.Note (Named, (if Named_Path then Path else ""),
                                         Executor.Kind (Named), Ended);
                           end;
                           Conv.Append (Messages, Conv.Tool_Role, Reply, Status);
                           if Watch /= null then
                              Watch.On_Result
                                ((Id => Invocations + Call, In_Turn => Call, Of_Turn => Asked,
                                  Changes => Executor.Kind (Named) = Model_Runner.Tools.Runner.Changes),
                                 Named, Args, Reply, Ended);
                           end if;
                        end;
                     end;

                     Result.Calls := Result.Calls + 1;
                     if Items (Call).Copy_Of = 0 and then Items (Call).Kind /= As_Note then
                        Result.Delegated_Tokens := Result.Delegated_Tokens + Items (Call).Ended.Tokens;
                     end if;
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

               --  A call the run's own limits stopped ends the run: its
               --  cancellation, its deadline. A tool's own time limit is
               --  the tool's failure, and the model hears it.
               if Model_Runner.Cancellation.Is_Cancelled (Cancel)
                 and then (for some Call in 1 .. Planned =>
                             Items (Call).Ended.Answer = Model_Runner.Tools.Runner.Cancelled)
               then
                  Result.Reason := Cancelled;
                  exit Step_Loop;
               elsif Timing
                 and then Model_Runner.Clocks.Read (Time) - Started > Budget_Ns
               then
                  Result.Reason := Timed_Out;
                  exit Step_Loop;
               end if;
            end;

            Invocations := Invocations + Asked;

            --  A turn that only repeated calls it had already made is going
            --  in circles. Stop rather than let it spend the step budget on
            --  the same calls over and over.
            if Progressed then
               Stalled := 0;
            else
               Stalled := Stalled + 1;
               if Stalled >= 2 then
                  Result.Reason := Repeating;
                  exit Step_Loop;
               end if;
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

      Result.Work_Record := U.To_Unbounded_String (Work.Record_Text);
      Gen.Release (Last_Result);
      Model_Runner.Grammar.Close (Rules_Grammar);
   exception
      when Failure : others =>
         Gen.Release (Last_Result);
         Model_Runner.Grammar.Close (Rules_Grammar);
         Result.Reason := Generation_Failed;
         Result.Error := E.Unexpected (Failure, "agent");
   end Run;

end Model_Runner.Agent;
