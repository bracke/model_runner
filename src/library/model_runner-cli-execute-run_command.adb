with Ada.Calendar;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Real_Time;
with Ada.Text_IO;
with Interfaces;
with Model_Runner.Drafts;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Permissions;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Grammar;
with Model_Runner.Schema;
with Model_Runner.Limits;
with Model_Runner.Numerics;
with Hostkit.Process;

with Model_Runner.Cancellation;
with Model_Runner.Platform;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Platform.Signals;
with Model_Runner.Progress;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Vision;
with Model_Runner.Tools;
with Model_Runner.Tokenizer;
with Model_Runner.UTF8;
with Model_Runner.CLI.Pictures;
with Model_Runner.Agent;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Runner;
with GNAT.OS_Lib;
with Model_Runner.CLI.Interactive;
with Model_Runner.CLI.Checkpoint;
with Model_Runner.CLI.Execute.Acquisition;

package body Model_Runner.CLI.Execute.Run_Command is

   use Model_Runner.CLI.Execute.Acquisition;
   use type Model_Runner.CLI.Options.Prompt_Source;
   use type Model_Runner.CLI.Options.Text_Access;
   use type Model_Runner.CLI.Options.Verbosity;
   use type Model_Runner.Generation.Completion_Reason;
   use type Model_Runner.Conversation.Role;
   use type Model_Runner.Agent.Stop_Reason;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type L.Repack_Mode;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;

   --  Prints the agent loop's calls and tool results to the console as they
   --  happen, so `run --agent` shows the loop unfolding rather than only its
   --  end. The console goes to standard error, so standard output stays the
   --  model's own text. When Trace is on it also records each call and result,
   --  with the milliseconds since it started, as JSON objects, which the run
   --  writes out as a trace when it ends. When a checkpoint file is set it
   --  saves the conversation at the close of each step, so a run interrupted
   --  partway is still resumable, not only one that stops on its own.
   type Agent_Watch
     (Screen : access Pres.Console;
      Trace  : Boolean;
      Log    : access Conv.History) is
     limited new Model_Runner.Agent.Observer with record
        Started    : Ada.Calendar.Time := Ada.Calendar.Clock;
        Events     : US.Unbounded_String;
        Count      : Natural := 0;
        Checkpoint : US.Unbounded_String;   --  path, or empty for none
     end record;

   overriding procedure On_Call
     (Self      : in out Agent_Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String);
   overriding procedure On_Result
     (Self      : in out Agent_Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Model_Runner.Tools.Runner.Call_Outcome);

   overriding procedure On_Step (Self : in out Agent_Watch);
   overriding procedure On_Turn
     (Self  : in out Agent_Watch;
      Step  : Positive;
      Calls : Positive);

   --  A call's number in the run, as the trace writes it.
   function Number (Call : Model_Runner.Agent.Invocation) return String is
      Raw : constant String := Positive'Image (Call.Id);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Number;

   overriding procedure On_Step (Self : in out Agent_Watch) is
   begin
      if Self.Log /= null and then US.Length (Self.Checkpoint) > 0 then
         Model_Runner.CLI.Checkpoint.Save
           (US.To_String (Self.Checkpoint), Self.Log.all);
      end if;
   end On_Step;

   --  Milliseconds from the watch's start to now, as a decimal with no sign.
   function Elapsed_Ms (Self : Agent_Watch) return String is
      use type Ada.Calendar.Time;
      Ms : constant Long_Long_Integer :=
        Long_Long_Integer (1000.0 * (Ada.Calendar.Clock - Self.Started));
      Raw : constant String := Long_Long_Integer'Image (Ms);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Elapsed_Ms;

   --  Add one event object to the trace, comma-separated from the last.
   procedure Record_Event (Self : in out Agent_Watch; Body_Text : String) is
   begin
      if Self.Count > 0 then
         US.Append (Self.Events, ",");
      end if;
      US.Append (Self.Events, "{""t_ms"":" & Elapsed_Ms (Self) & ","
                 & Body_Text & "}");
      Self.Count := Self.Count + 1;
   end Record_Event;

   --  A turn's calls, counted, before they run: in the trace as an event
   --  of its own, so a reader sees which calls came together.
   overriding procedure On_Turn
     (Self  : in out Agent_Watch;
      Step  : Positive;
      Calls : Positive)
   is
      function Bare (Value : Positive) return String is
         Raw : constant String := Positive'Image (Value);
      begin
         return Raw (Raw'First + 1 .. Raw'Last);
      end Bare;
   begin
      if Self.Trace then
         Record_Event
           (Self, """event"":""turn"",""step"":" & Bare (Step) & ",""calls"":" & Bare (Calls));
      end if;
   end On_Turn;

   overriding procedure On_Call
     (Self      : in out Agent_Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String) is
   begin
      Pres.Put_Tool_Call (Self.Screen.all, Named, Arguments);
      if Self.Trace then
         Record_Event
           (Self,
            """event"":""call"",""invocation"":" & Number (Call)
            & ",""name"":""" & JSON_Escape (Named)
            & """,""arguments"":""" & JSON_Escape (Arguments) & """");
      end if;
   end On_Call;

   overriding procedure On_Result
     (Self      : in out Agent_Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Model_Runner.Tools.Runner.Call_Outcome)
   is
      pragma Unreferenced (Arguments);
      package Tr renames Model_Runner.Tools.Runner;

      --  How it ended, as the trace names it: answered, failed, or the
      --  refusal by what refused it.
      Said : constant String :=
        (case Ended.Answer is
           when Tr.Answered  => "answered",
           when Tr.Failed    => "failed",
           when Tr.Timed_Out => "timed_out",
           when Tr.Cancelled => "cancelled",
           when Tr.Refused  =>
             (case Ended.Refusal is
                when Tr.Outside_Project => "refused_outside_project",
                when Tr.Harness_Owned   => "refused_harness_owned",
                when Tr.Policy          => "refused_by_policy",
                when Tr.Not_Permitted | Tr.Not_Refused => "refused"));
   begin
      Pres.Put_Tool_Result (Self.Screen.all, Result);
      if Self.Trace then
         Record_Event
           (Self,
            """event"":""result"",""invocation"":" & Number (Call)
            & ",""name"":""" & JSON_Escape (Named)
            & """,""outcome"":""" & Said
            & """,""changed"":" & (if Ended.Changed then "true" else "false")
            & ",""result"":""" & JSON_Escape (Result) & """");
      end if;
   end On_Result;

   --  Whether Whole contains Part.
   function Contains (Whole, Part : String) return Boolean is
   begin
      if Part'Length = 0 then
         return False;
      elsif Whole'Length < Part'Length then
         return False;
      end if;
      for P in Whole'First .. Whole'Last - Part'Length + 1 loop
         if Whole (P .. P + Part'Length - 1) = Part then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   --  The gate on each tool call the agent would run. It fences an unattended
   --  run first: a tool named in --deny-tool, or a call whose arguments hold a
   --  --deny-arg string, is refused before it runs and with no one asked --
   --  the model is told and may take another way, so the run goes on within
   --  the fence. Then, with --confirm-tools, it asks the operator: the prompt
   --  goes to the console (standard error) and the answer is read from
   --  standard input -- a line beginning y allows the call, one beginning q
   --  stops the loop, anything else (n, a blank line, an end of input)
   --  declines the one call. With neither a matching rule nor --confirm-tools,
   --  the call runs.
   type Policy_Approver
     (Screen : access Pres.Console;
      Rules  : access constant Opt.Command) is
     limited new Model_Runner.Agent.Approver with null record;

   overriding function Consider
     (Self : in out Policy_Approver; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict;

   overriding function Consider
     (Self : in out Policy_Approver; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict
   is
      Line : String (1 .. 256);
      Last : Natural := 0;
   begin
      --  The fence: a denied tool, or a denied argument string, is refused.
      for I in 1 .. Self.Rules.Deny_Tool_Count loop
         if Named = T.To_String (Self.Rules.Deny_Tools (I)) then
            Pres.Put_Note
              (Self.Screen.all, "cli.agent.denied",
               [Loc.Named ("name", Named)]);
            return Model_Runner.Agent.Deny;
         end if;
      end loop;
      for I in 1 .. Self.Rules.Deny_Arg_Count loop
         if Contains (Arguments, T.To_String (Self.Rules.Deny_Args (I))) then
            Pres.Put_Note
              (Self.Screen.all, "cli.agent.denied",
               [Loc.Named ("name", Named)]);
            return Model_Runner.Agent.Deny;
         end if;
      end loop;

      --  Past the fence: run it, unless the operator is asked and says not to.
      if not Self.Rules.Confirm_Tools then
         return Model_Runner.Agent.Allow;
      end if;

      Pres.Put_Note
        (Self.Screen.all, "cli.agent.confirm",
         [Loc.Named ("name", Named), Loc.Named ("arguments", Arguments)]);
      begin
         Ada.Text_IO.Get_Line (Line, Last);
      exception
         when Ada.Text_IO.End_Error =>
            return Model_Runner.Agent.Halt;
      end;
      if Last >= 1 and then (Line (1) = 'y' or else Line (1) = 'Y') then
         return Model_Runner.Agent.Allow;
      elsif Last >= 1 and then (Line (1) = 'q' or else Line (1) = 'Q') then
         return Model_Runner.Agent.Halt;
      else
         return Model_Runner.Agent.Deny;
      end if;
   end Consider;

   --  Puts the model's question to the user on the console and reads their
   --  answer from standard input, for the ask_user tool. An end of input --
   --  a closed or piped-dry stdin -- is no answer rather than an error, so
   --  the loop goes on rather than blocking on input no one will give.
   type Console_Inquirer (Screen : access Pres.Console) is
     limited new Model_Runner.Tools.Builtin.Inquirer with null record;

   overriding procedure Ask
     (Self     : in out Console_Inquirer;
      Question : String;
      Answer   : out String;
      Last     : out Natural;
      Status   : out E.Error_Info);

   overriding procedure Ask
     (Self     : in out Console_Inquirer;
      Question : String;
      Answer   : out String;
      Last     : out Natural;
      Status   : out E.Error_Info)
   is
      --  The whole line, however long: read into a fixed buffer, a longer
      --  answer left its tail in the input for the next line read to take.
      function Typed return String is
      begin
         return Ada.Text_IO.Get_Line;
      exception
         when Ada.Text_IO.End_Error =>
            return "";
      end Typed;
   begin
      Last   := 0;
      Status := E.Success;
      Pres.Put_Note
        (Self.Screen.all, "cli.agent.ask", [Loc.Named ("detail", Question)]);
      declare
         Line : constant String := Typed;
         Cut  : constant String :=
           " (the answer was cut here: it was" & Natural'Image (Line'Length)
           & " bytes, and a tool's answer holds" & Natural'Image (Answer'Length) & ")";
      begin
         if Line'Length <= Answer'Length then
            Answer (Answer'First .. Answer'First + Line'Length - 1) := Line;
            Last := Answer'First + Line'Length - 1;
         elsif Answer'Length > Cut'Length then
            --  Too long for the answer: what fits, and said to be cut.
            declare
               Keep : constant Natural := Answer'Length - Cut'Length;
            begin
               Answer (Answer'First .. Answer'First + Keep - 1) :=
                 Line (Line'First .. Line'First + Keep - 1);
               Answer (Answer'First + Keep .. Answer'Last) := Cut;
               Last := Answer'Last;
            end;
         else
            Status := E.Make (E.Tools_Too_Large);
         end if;
      end;
   end Ask;

   --  Embeds text for the agent's retrieve tool, using the loaded model on a
   --  session of its own. What the model has made of a text lives in its
   --  hidden state; this reduces that to one mean-pooled, unit-length vector,
   --  the way `embed` does, resetting the session first so each text is
   --  embedded on its own.
   type Model_Embedder
     (Src  : access constant L.Model'Class;
      Sess : access L.Session) is
     limited new Model_Runner.Tools.Builtin.Embedder with null record;

   overriding procedure Embed
     (Self   : in out Model_Embedder;
      Text   : String;
      Vector : out N.Real_Array;
      Last   : out Natural;
      Status : out E.Error_Info);

   overriding procedure Embed
     (Self   : in out Model_Embedder;
      Text   : String;
      Vector : out N.Real_Array;
      Last   : out Natural;
      Status : out E.Error_Info)
   is
      Settings : constant L.Configuration := L.Config (Self.Src.all);
      Width    : constant N.Element_Count := N.Element_Count (Settings.Embedding);
      Words    : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Self.Src.all);

      Tokens : Vocab.Token_Array
        (1 .. Model_Runner.Limits.Default_Session_Limits.Max_Batch);
      Count  : Natural;

      Logits : N.Real_Array
        (0 .. (if Settings.Has_Head
               then N.Element_Count (Settings.Vocabulary) - 1
               else -1));
      Room   : Model_Runner.Tensors.Real_Array_Access := null;
   begin
      Last := 0;
      Status := E.Success;

      if Width = 0 or else N.Element_Count (Vector'Length) < Width then
         Status := E.Make (E.Internal_Unexpected_Exception);
         return;
      end if;

      --  Each text stands alone: the session's positions are cleared so one
      --  passage's state never leaks into the next.
      L.Reset (Self.Sess.all);

      Vocab.Encode
        (Words.all, Text, Vocab.Adds_Beginning (Words.all),
         not Settings.Causal and then Vocab.Adds_End (Words.all),
         Tokens, Count, Status);
      if E.Is_Error (Status) then
         return;
      elsif Count = 0 then
         Status := E.Make (E.CLI_No_Prompt_Available);
         return;
      end if;

      --  Embed at most this many tokens. An embedding model that attends
      --  both ways -- a BERT sentence model -- has a fixed position limit
      --  (512 for all-MiniLM), and a passage longer than that would fail the
      --  whole batch; the leading tokens carry the meaning a search needs.
      Count := Natural'Min (Count, 480);

      Room := new N.Real_Array (0 .. N.Element_Count (Count) * Width - 1);
      L.Evaluate_Batch
        (Self.Sess.all, Self.Src.all, Tokens (1 .. Count), Logits,
         States => Room, Status => Status);
      if E.Is_Error (Status) then
         Free_Reals (Room);
         return;
      end if;

      declare
         Acc   : N.Real_Array (0 .. Width - 1) := [others => 0.0];
         Total : N.Wide_Real := 0.0;
      begin
         for Pos in 0 .. N.Element_Count (Count) - 1 loop
            for Elem in 0 .. Width - 1 loop
               Acc (Elem) := Acc (Elem) + Room.all (Pos * Width + Elem);
            end loop;
         end loop;
         Free_Reals (Room);

         for Elem in 0 .. Width - 1 loop
            Acc (Elem) := Acc (Elem) / N.Real (Count);
            Total := Total + N.Wide_Real (Acc (Elem)) * N.Wide_Real (Acc (Elem));
         end loop;

         if Total > 0.0 then
            declare
               Scale : constant N.Real := N.Real (1.0 / N.Sqrt (Total));
            begin
               for Elem in 0 .. Width - 1 loop
                  Vector (Elem) := Acc (Elem) * Scale;
               end loop;
            end;
         else
            for Elem in 0 .. Width - 1 loop
               Vector (Elem) := Acc (Elem);
            end loop;
         end if;
      end;

      Last := Natural (Width) - 1;
   end Embed;

   --  A lease over a pool of sub-agent sessions, so several delegated
   --  subtasks run at once, each on a session of its own. Acquire waits when
   --  every session is busy; Open makes the sessions that opened leasable.
   type Availability is array (Positive range <>) of Boolean;

   protected type Session_Leaser (Count : Positive) is
      procedure Open (Ready : Natural);
      entry Acquire (Slot : out Positive);
      procedure Release (Slot : Positive);
   private
      Available  : Availability (1 .. Count) := [others => False];
      Free_Count : Natural := 0;
   end Session_Leaser;

   protected body Session_Leaser is
      procedure Open (Ready : Natural) is
      begin
         for I in 1 .. Ready loop
            Available (I) := True;
         end loop;
         Free_Count := Ready;
      end Open;

      entry Acquire (Slot : out Positive) when Free_Count > 0 is
      begin
         Slot := 1;
         for I in Available'Range loop
            if Available (I) then
               Available (I) := False;
               Free_Count    := Free_Count - 1;
               Slot          := I;
               exit;
            end if;
         end loop;
      end Acquire;

      procedure Release (Slot : Positive) is
      begin
         Available (Slot) := True;
         Free_Count       := Free_Count + 1;
      end Release;
   end Session_Leaser;

   type Session_Pool is array (Positive range <>) of L.Session;

   --  Runs a delegated subtask for the agent's delegate tool, on a fresh
   --  agent loop of its own. It leases a session from a pool kept apart from
   --  the caller's, so the caller's loop -- suspended on this very call -- is
   --  undisturbed, and several subtasks may run at once, each on a session of
   --  its own; it gives the sub-agent no delegator, so a sub-agent's own
   --  delegate call is declined and delegation cannot recurse without bound.
   --  The sub-agent starts a conversation of its own, seeded with the task,
   --  runs to an answer under its own step and token budget, and hands back
   --  only that answer -- the caller never sees the sub-agent's steps.
   type Model_Delegator
     (Src    : access constant L.Model'Class;
      Req    : access constant Gen.Request;
      Stops  : access Model_Runner.Stops.Set;
      Time   : Model_Runner.Clocks.Clock_Reference;
      Seed   : Model_Runner.Entropy.Source_Reference;
      Steps  : Positive;
      Budget : Natural;
      Count  : Positive) is
     limited new Model_Runner.Tools.Builtin.Delegator with record
        Sessions : Session_Pool (1 .. Count);
        Leases   : Session_Leaser (Count);
        Ready    : Natural := 0;   --  sessions that opened; 0 until Open

        --  The system prompt each sub-agent is opened with, read from a file
        --  where the caller gave one; null for the built-in one below.
        System_Text : Opt.Text_Access := null;
     end record;

   --  Two subtasks may overlap when the pool holds more than one open
   --  session (which the CLI opens only on a backend that evaluates two at
   --  once, so this need not check the backend again).
   overriding function Parallel_Delegates
     (Self : Model_Delegator) return Boolean is (Self.Ready > 1);

   overriding procedure Run_Sub
     (Self        : in out Model_Delegator;
      Instruction : String;
      Context     : Model_Runner.Tools.Runner.Tool_Context;
      Result      : out String;
      Last        : out Natural;
      Ended       : out Model_Runner.Tools.Builtin.Sub_Outcome;
      Status      : out E.Error_Info);

   overriding procedure Run_Sub
     (Self        : in out Model_Delegator;
      Instruction : String;
      Context     : Model_Runner.Tools.Runner.Tool_Context;
      Result      : out String;
      Last        : out Natural;
      Ended       : out Model_Runner.Tools.Builtin.Sub_Outcome;
      Status      : out E.Error_Info)
   is
      package Bi renames Model_Runner.Tools.Builtin;
      package Tr renames Model_Runner.Tools.Runner;
      use type Ada.Real_Time.Time;

      Slot : Positive;

      --  The child's budget is the least of its own and what its parent
      --  has left: a child does not get a fresh allowance of the time or
      --  the tokens its parent is spending.
      Tokens : constant Natural :=
        (if Context.Tokens_Left = Natural'Last then Self.Budget
         elsif Self.Budget = 0 then Context.Tokens_Left
         else Natural'Min (Self.Budget, Context.Tokens_Left));
      Timed   : constant Boolean := Context.Deadline /= Ada.Real_Time.Time_Last;
      Seconds : constant Duration :=
        (if Timed then Tr.Time_Left (Context, Duration (86_400)) else 0.0);

      System_Prompt : constant String :=
        (if Self.System_Text /= null then Self.System_Text.all
         else "You are a sub-agent handed one self-contained task. Use the "
         & "tools to complete it, then reply with a direct, complete answer "
         & "that stands on its own -- the caller sees only your final answer, "
         & "not your steps, and you keep no memory of it once you answer.");
   begin
      Last   := Result'First - 1;
      Status := E.Success;
      Ended  := (State => Bi.Failed, others => <>);

      --  Nothing left to run it with: said, not started.
      if Tr.Stopped (Context) or else (Context.Tokens_Left = 0) then
         Ended :=
           (State  => (if Model_Runner.Cancellation.Is_Cancelled (Context.Cancel) then Bi.Cancelled
                       else Bi.Exhausted),
            Reason => Ada.Strings.Unbounded.To_Unbounded_String
                        (if Context.Tokens_Left = 0 then "token limit" else "timed out"),
            Timed  => Context.Tokens_Left /= 0,
            others => <>);
         return;
      end if;

      --  Take a session of our own; wait if every one is busy.
      Self.Leases.Acquire (Slot);

      declare
         Sub_Msgs   : Conv.History;
         Sub_Tools  : Model_Runner.Tools.Definitions;
         Sub_Runner : aliased Model_Runner.Tools.Builtin.Instance;
         Loop_Out   : Model_Runner.Agent.Outcome;
         Cond       : E.Error_Info;
      begin
         --  Offered what its runner can run: it has no delegator and no one
         --  to ask, so neither delegate nor ask_user is put to it.
         Model_Runner.Tools.Read (Sub_Tools, Sub_Runner.Offered_Text, Cond);
         if E.Is_Error (Cond) then
            Status := Cond;
         else
            Conv.Open (Sub_Msgs, Status => Cond);
            if E.Is_Error (Cond) then
               Status := Cond;
            else
               Conv.Set_System (Sub_Msgs, System_Prompt, Cond);
               Conv.Append (Sub_Msgs, Conv.User_Role, Instruction, Cond);
               if E.Is_Error (Cond) then
                  Status := Cond;
               else
                  --  Clear the session so the task starts from nothing, no
                  --  earlier subtask's state leaking in. Sub_Runner is left
                  --  with no delegator, so it declines a delegate call:
                  --  delegation goes one level deep and no further.
                  L.Reset (Self.Sessions (Slot));
                  Model_Runner.Agent.Run
                    (Source           => Self.Src.all,
                     Session          => Self.Sessions (Slot),
                     Messages         => Sub_Msgs,
                     Offered          => Sub_Tools,
                     Executor         => Sub_Runner,
                     Generation       => Self.Req.all,
                     Stop_Set         => Self.Stops.all,
                     Sink             => null,
                     Time             => Self.Time,
                     Seeds            => Self.Seed,
                     Cancel           => Context.Cancel,
                     Max_Steps        => Self.Steps,
                     Max_Seconds      => Seconds,
                     Max_Total_Tokens => Tokens,
                     Compact          => True,
                     Result           => Loop_Out);

                  --  How it ended, by what its stop asks: only an answer is
                  --  a result.
                  declare
                     Traits : constant Model_Runner.Agent.Stop_Traits :=
                       Model_Runner.Agent.Traits_Of (Loop_Out.Reason);
                  begin
                     Ended :=
                       (State  => (if Traits.Finished then Bi.Completed
                                   elsif Loop_Out.Reason = Model_Runner.Agent.Cancelled then Bi.Cancelled
                                   elsif Traits.Exhausted then Bi.Exhausted
                                   else Bi.Failed),
                        Reason => Ada.Strings.Unbounded.To_Unbounded_String
                                    (Model_Runner.Agent.Reason_Words (Loop_Out.Reason)),
                        Timed  => Loop_Out.Reason = Model_Runner.Agent.Timed_Out,
                        Steps  => Loop_Out.Steps,
                        Calls  => Loop_Out.Calls,
                        Tokens => Loop_Out.Generated_Tokens + Loop_Out.Delegated_Tokens);
                  end;

                  --  The answer is the last assistant turn's text, and only
                  --  where the child answered.
                  for I in reverse 1 .. Conv.Length (Sub_Msgs) loop
                     exit when Bi."/=" (Ended.State, Bi.Completed);
                     if Conv.Sender_At (Sub_Msgs, I) = Conv.Assistant_Role then
                        declare
                           Answer : constant String :=
                             Conv.Content_At (Sub_Msgs, I);
                           Take   : constant Natural :=
                             Natural'Min (Answer'Length, Result'Length);
                        begin
                           if Take > 0 then
                              Result (Result'First .. Result'First + Take - 1)
                                := Answer (Answer'First .. Answer'First
                                           + Take - 1);
                              Last := Result'First + Take - 1;
                           end if;
                        end;
                        exit;
                     end if;
                  end loop;
               end if;
               Conv.Close (Sub_Msgs);
            end if;
         end if;
      exception
         when Failure : others =>
            Status := E.Unexpected (Failure, "delegated run");
      end;

      --  Always give the session back, whatever happened.
      Self.Leases.Release (Slot);
   end Run_Sub;

   --  Runs a tool call by handing it to an external program: the program is
   --  invoked with the function name and the arguments (as JSON) as its two
   --  arguments, and what it prints to standard output is the tool's answer.
   --  The library starts no process; this is the command, which may. The
   --  program's own standard error is left alone, so it can log while it
   --  works.
   type Command_Runner (Command : access constant String) is
     limited new Model_Runner.Tools.Runner.Instance with null record;

   overriding procedure Run
     (Self      : in out Command_Runner;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

   overriding procedure Run
     (Self      : in out Command_Runner;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      use type GNAT.OS_Lib.String_Access;
      Program : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path (Self.Command.all);
      Args    : GNAT.OS_Lib.Argument_List :=
        [1 => new String'(Named), 2 => new String'(Arguments)];
      Handle  : GNAT.OS_Lib.File_Descriptor;
      Path    : GNAT.OS_Lib.String_Access;
      Ran     : Boolean := False;
      Code    : Integer := -1;

      --  Put a short text into the result, in place of an answer.
      procedure Note (Text : String) is
      begin
         Last := 0;
         if Text'Length <= Result'Length then
            Result (Result'First .. Result'First + Text'Length - 1) := Text;
            Last := Result'First + Text'Length - 1;
         end if;
      end Note;
   begin
      Status := Model_Runner.Errors.Success;
      Outcome := Model_Runner.Tools.Runner.Done;
      Last := 0;

      if Program = null then
         Outcome.Answer := Model_Runner.Tools.Runner.Failed;
         Note ("error: tool command not found on the path: "
               & Self.Command.all);
         for A of Args loop
            GNAT.OS_Lib.Free (A);
         end loop;
         return;
      end if;

      GNAT.OS_Lib.Create_Temp_File (Handle, Path);
      GNAT.OS_Lib.Close (Handle);

      --  Within the run's limits: its cancellation, and its deadline where
      --  it has one. A program that hangs is stopped with its group then,
      --  where it used to hang the run with it.
      declare
         package Tr renames Model_Runner.Tools.Runner;
         use type Ada.Real_Time.Time;
         Context : constant Tr.Tool_Context := Tr.Context_Of (Self);
         Words   : Hostkit.String_Vectors.Vector;
         Happened : Hostkit.Process.Process_Outcome;
      begin
         Words.Append (Ada.Strings.Unbounded.To_Unbounded_String (Named));
         Words.Append (Ada.Strings.Unbounded.To_Unbounded_String (Arguments));
         Tr.Enter (Context);
         Happened := Hostkit.Process.Run_Captured
           (Program     => Program.all,
            Arguments   => Words,
            Stdout_Path => Path.all,
            Timeout_Ms  =>
              (if Context.Deadline = Ada.Real_Time.Time_Last then 0
               else Natural'Max (1, Natural (Tr.Time_Left (Context, Duration (86_400)) * 1000))),
            Cancelled   => Tr.Stop_Now'Access,
            Whole_Group => True);
         Ran := Happened.Started and then not Happened.Timed_Out;
         Code := Happened.Exit_Status;
         if Happened.Timed_Out then
            Outcome.Answer :=
              (if Model_Runner.Cancellation.Is_Cancelled (Context.Cancel)
               then Tr.Cancelled else Tr.Timed_Out);
            Note ("error: the tool command was stopped: "
                  & (if Model_Runner.Cancellation.Is_Cancelled (Context.Cancel)
                     then "the run was cancelled" else "the run's time ran out"));
         end if;
      end;

      if Ran and then Code = 0 then
         declare
            File  : Ada.Text_IO.File_Type;
            --  Room kept at the end for saying the output was cut.
            Cut   : constant String := ASCII.LF & "(the tool command's output was cut here: it printed more"
              & " than a tool's answer holds)";
            Room  : constant Natural := Result'Last - Cut'Length;
            Fill  : Natural := Result'First - 1;
            First : Boolean := True;
         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path.all);
            while not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Line : constant String := Ada.Text_IO.Get_Line (File);
                  Gap  : constant Natural := (if First then 0 else 1);
               begin
                  --  Past what fits: said, not dropped without a word.
                  if Fill + Gap + Line'Length > Room then
                     Result (Fill + 1 .. Fill + Cut'Length) := Cut;
                     Fill := Fill + Cut'Length;
                     Outcome.Truncated := True;
                     exit;
                  end if;
                  if not First then
                     Fill := Fill + 1;
                     Result (Fill) := ASCII.LF;
                  end if;
                  Result (Fill + 1 .. Fill + Line'Length) := Line;
                  Fill := Fill + Line'Length;
                  First := False;
               end;
            end loop;
            Ada.Text_IO.Close (File);

            if Fill >= Result'First then
               Last := Fill;
            else
               --  The program said nothing. The model still needs a turn,
               --  and an empty one is not a valid message.
               Note ("(the tool command produced no output)");
            end if;
         exception
            when others =>
               Outcome.Answer := Model_Runner.Tools.Runner.Failed;
               Note ("error: could not read the tool command's output");
         end;
      elsif Model_Runner.Tools.Runner."=" (Outcome.Answer, Model_Runner.Tools.Runner.Answered) then
         Outcome.Answer := Model_Runner.Tools.Runner.Failed;
         Note ("error: the tool command failed");
      end if;

      declare
         Gone : Boolean;
      begin
         GNAT.OS_Lib.Delete_File (Path.all, Gone);
      end;
      GNAT.OS_Lib.Free (Path);
      GNAT.OS_Lib.Free (Program);
      for A of Args loop
         GNAT.OS_Lib.Free (A);
      end loop;
   end Run;

   ---------------------------------------------------------------------------
   --  run
   ---------------------------------------------------------------------------

   --  The most of a token a draft from the block past the stack may cost
   --  and still be taken without being asked for, and how many proposals a
   --  round it makes then. See where a run's request is made.
   Next_Draft_Share  : constant Float := 0.25;
   Next_Draft_Bytes  : constant Float := 2.0 * 1024.0 ** 3;
   Next_Draft_Tokens : constant := 3;
   Split_Next_Draft_Tokens : constant := 4;

   --  Proposals a round for a draft the run found in the model store:
   --  three read best for Steelman-14B with Qwen2.5-Coder-0.5B, 12.75
   --  tokens a second against 12.0, 11.8 and 11.3 for four, five and six.
   Store_Draft_Tokens : constant := 3;

   procedure Do_Run
     (Item    : Opt.Command;
      Screen  : in out Pres.Console;
      Catalog : Loc.Catalog;
      Status  : out Natural)
   is separate;

end Model_Runner.CLI.Execute.Run_Command;
