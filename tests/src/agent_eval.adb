with Ada.Calendar; use type Ada.Calendar.Time;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Text_IO;
with Ada.Strings.Unbounded;

with Host_Load;

with Model_Runner.Agent;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Shards;
with Model_Runner.Generation;
with Model_Runner.Grammar;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Sampling;
with Model_Runner.Schema;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Tools;
with Model_Runner.Tools.Builtin;

package body Agent_Eval is

   package Conv renames Model_Runner.Conversation;
   package CPU renames Model_Runner.Backend.CPU;
   package E renames Model_Runner.Errors;
   package Containers renames Model_Runner.GGUF.Containers;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package Shards renames Model_Runner.GGUF.Shards;
   package G renames Model_Runner.Grammar;
   package Schema renames Model_Runner.Schema;

   use type Model_Runner.Backend.Backend_Kind;
   use type Conv.Role;
   use type Model_Runner.Agent.Stop_Reason;

   ---------------------------------------------------------------------------
   --  The task table
   --
   --  Each task poses a question a tool answers, names the tool the model
   --  ought to reach for, and gives the text its final turn has to carry.
   --  The wanted text is what the built-in tool makes true -- 47 times 89
   --  is 4183, "stressed" reversed is "desserts" -- so a machine anywhere
   --  scores the same pass.
   ---------------------------------------------------------------------------

   Sys_Tools : aliased constant String :=
     "You are a helpful assistant with tools. When a question needs "
     & "arithmetic, string work, or a fact you are unsure of, call the tool "
     & "for it rather than guessing. After a tool answers, reply to the user "
     & "with the answer.";
   Sys_Plain : aliased constant String :=
     "You are a helpful assistant. Follow the user's instruction exactly.";

   Empty : aliased constant String := "";

   P1 : aliased constant String :=
     "What is 47 times 89? Use the calculator, then tell me the number.";
   T1 : aliased constant String := "calculator";
   W1 : aliased constant String := "4183";

   P2 : aliased constant String :=
     "How many characters are in the word ""stressed""? "
     & "Use the string_length tool.";
   T2 : aliased constant String := "string_length";
   W2 : aliased constant String := "8";

   P3 : aliased constant String :=
     "Reverse the word ""stressed"" using the reverse_text tool and tell me "
     & "the result.";
   T3 : aliased constant String := "reverse_text";
   W3 : aliased constant String := "desserts";

   P4 : aliased constant String :=
     "Look up the fact with key capital_of_france and tell me what it is.";
   T4 : aliased constant String := "lookup";
   W4 : aliased constant String := "Paris";

   P5 : aliased constant String :=
     "Reply with exactly the single word BLUE and nothing else.";
   W5 : aliased constant String := "BLUE";

   --  Multi-step tasks: each needs more than one tool call, either the same
   --  tool twice or two different tools, and the answer depends on the whole
   --  chain. A single call cannot pass them, which is what Min_Calls holds.

   --  A chain through one tool: the second call reads the first's result.
   P6 : aliased constant String :=
     "Add 5 and 7 with the calculator, then multiply that result by 3 with "
     & "the calculator. Tell me the final number.";
   W6 : aliased constant String := "36";

   --  A chain through two tools: reverse, then count the reversed word.
   P7 : aliased constant String :=
     "Reverse the word ""stressed"" with reverse_text, then count the "
     & "characters of the reversed word with string_length. Tell me the "
     & "count.";
   T7B : aliased constant String := "string_length";
   W7 : aliased constant String := "8";

   --  Two facts from one tool, both wanted in the answer.
   P8 : aliased constant String :=
     "Look up the fact for capital_of_france and the fact for ada_year, and "
     & "tell me both.";
   W8A : aliased constant String := "Paris";
   W8B : aliased constant String := "1983";

   --  Two calculations, both wanted in the answer.
   P9 : aliased constant String :=
     "What is 6 times 7, and what is 12 plus 9? Give me both numbers.";
   W9A : aliased constant String := "42";
   W9B : aliased constant String := "21";

   --  A structured-answer task: no tool is needed, but the final answer must
   --  come back in a shape -- an object with an integer "days" -- which the
   --  answer schema constrains the reply to. It scores whether the model
   --  reaches the right answer while held to that shape.
   P10 : aliased constant String :=
     "How many days are in a week? Give me the final answer.";
   W10 : aliased constant String := "7";
   S10 : aliased constant String :=
     "{""type"":""object"",""properties"":"
     & "{""days"":{""type"":""integer""}},""required"":[""days""]}";

   type Task_Spec is record
      System    : access constant String;
      Prompt    : access constant String;
      Tool      : access constant String;   --  a tool that must be called
      Tool_Two  : access constant String;   --  a second tool, or Empty
      Wants     : access constant String;   --  a substring the answer needs
      Also      : access constant String;   --  a second one, or Empty
      Min_Calls : Natural;                   --  fewest tool calls the task
                                             --  must make
      Answer    : access constant String;   --  a JSON schema the answer must
                                             --  match, or Empty for free text
   end record;

   Tasks : constant array (Positive range <>) of Task_Spec :=
     [(Sys_Tools'Access, P1'Access, T1'Access, Empty'Access,
       W1'Access, Empty'Access, 1, Empty'Access),
      (Sys_Tools'Access, P2'Access, T2'Access, Empty'Access,
       W2'Access, Empty'Access, 1, Empty'Access),
      (Sys_Tools'Access, P3'Access, T3'Access, Empty'Access,
       W3'Access, Empty'Access, 1, Empty'Access),
      (Sys_Tools'Access, P4'Access, T4'Access, Empty'Access,
       W4'Access, Empty'Access, 1, Empty'Access),
      (Sys_Plain'Access, P5'Access, Empty'Access, Empty'Access,
       W5'Access, Empty'Access, 0, Empty'Access),
      (Sys_Tools'Access, P6'Access, T1'Access, Empty'Access,
       W6'Access, Empty'Access, 2, Empty'Access),
      (Sys_Tools'Access, P7'Access, T3'Access, T7B'Access,
       W7'Access, Empty'Access, 2, Empty'Access),
      (Sys_Tools'Access, P8'Access, T4'Access, Empty'Access,
       W8A'Access, W8B'Access, 2, Empty'Access),
      (Sys_Tools'Access, P9'Access, T1'Access, Empty'Access,
       W9A'Access, W9B'Access, 2, Empty'Access),
      (Sys_Plain'Access, P10'Access, Empty'Access, Empty'Access,
       W10'Access, Empty'Access, 0, S10'Access)];

   ---------------------------------------------------------------------------
   --  Checking a transcript
   ---------------------------------------------------------------------------

   function Lower (Text : String) return String
     renames Ada.Characters.Handling.To_Lower;

   --  Whether Needle occurs in Haystack, letters compared without case.
   function Contains (Haystack, Needle : String) return Boolean is
      H : constant String := Lower (Haystack);
      N : constant String := Lower (Needle);
   begin
      if N'Length = 0 then
         return True;
      end if;
      if N'Length > H'Length then
         return False;
      end if;
      for Start in H'First .. H'Last - N'Length + 1 loop
         if H (Start .. Start + N'Length - 1) = N then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   --  The content of the last assistant turn, which is the model's answer.
   function Final_Answer (Messages : Conv.History) return String is
   begin
      for Index in reverse 1 .. Conv.Length (Messages) loop
         if Conv.Sender_At (Messages, Index) = Conv.Assistant_Role then
            return Conv.Content_At (Messages, Index);
         end if;
      end loop;
      return "";
   end Final_Answer;

   --  Whether the answer matches the schema it was asked to take. Compiles
   --  the schema to a grammar and matches the whole answer against it: what
   --  the loop's own answer grammar guarantees, checked here independently.
   --  An empty schema constrains nothing, so anything fits it.
   function Answer_Fits_Schema (Text, Schema_Text : String) return Boolean is
      Buffer : String (1 .. Schema.Max_Grammar_Bytes);
      Last   : Natural;
      Rules  : G.Compiled;
      State  : G.Matcher;
      St     : E.Error_Info;
      Held   : Boolean;
   begin
      if Schema_Text = "" then
         return True;
      end if;
      Schema.To_Grammar (Schema_Text, Buffer, Last, St);
      if E.Is_Error (St) or else Last = 0 then
         return False;
      end if;
      G.Compile (Rules, Buffer (1 .. Last), St);
      if E.Is_Error (St) then
         return False;
      end if;
      G.Start (Rules, State, St);
      G.Advance (Rules, State, Text, St);
      Held := E.Is_Ok (St) and then G.Is_Complete (Rules, State);
      G.Close (Rules);
      return Held;
   end Answer_Fits_Schema;

   --  Whether any assistant turn asked for the named tool.
   function Called_Tool (Messages : Conv.History; Named : String)
     return Boolean is
   begin
      for Index in 1 .. Conv.Length (Messages) loop
         for Call in 1 .. Conv.Call_Count (Messages, Index) loop
            if Conv.Call_Name (Messages, Index, Call) = Named then
               return True;
            end if;
         end loop;
      end loop;
      return False;
   end Called_Tool;

   ----------
   -- Dump --
   ----------

   --  The whole of one task's transcript, to standard error: every turn with
   --  its role and text, each call it made beneath the turn that made it, and
   --  the verdict. This is what turns "4 of 5 passed" into "task 3 called
   --  reverse_text with these arguments and answered this", which is the
   --  difference between a number and something a reader can act on.
   procedure Dump
     (Index    : Positive;
      Spec     : Task_Spec;
      Messages : Conv.History;
      Outcome  : Model_Runner.Agent.Outcome;
      Passed   : Boolean;
      Seconds  : Duration)
   is
      procedure Line (Text : String) is
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Text);
      end Line;
   begin
      Line ("--- task" & Positive'Image (Index)
            & (if Passed then "  PASS" else "  FAIL")
            & "  reason=" & Model_Runner.Agent.Stop_Reason'Image
                              (Outcome.Reason)
            & "  calls=" & Natural'Image (Outcome.Calls)
            & "  tokens=" & Natural'Image (Outcome.Generated_Tokens)
            & "  prompt=" & Natural'Image (Outcome.Prompt_Tokens)
            & "  seconds=" & Natural'Image (Natural (Seconds))
            & "  wants=""" & Spec.Wants.all & """"
            & (if Spec.Also.all /= "" then " +""" & Spec.Also.all & """"
               else "")
            & (if Spec.Tool.all /= "" then "  needs=" & Spec.Tool.all else "")
            & (if Spec.Tool_Two.all /= "" then "+" & Spec.Tool_Two.all
               else "")
            & (if Spec.Min_Calls > 1
               then " min-calls=" & Natural'Image (Spec.Min_Calls) else "")
            & " ---");
      for I in 1 .. Conv.Length (Messages) loop
         Line ("  " & Conv.Role_Name (Conv.Sender_At (Messages, I)) & ": "
               & Conv.Content_At (Messages, I));
         for K in 1 .. Conv.Call_Count (Messages, I) loop
            Line ("    -> " & Conv.Call_Name (Messages, I, K) & " "
                  & Conv.Call_Arguments (Messages, I, K));
         end loop;
      end loop;
   end Dump;

   --  A non-negative number with no leading space.
   function Num (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Num;

   --  A string as a JSON string literal's contents: the escapes JSON
   --  requires, and the control characters it forbids raw written as \uXXXX.
   function JSON_Escape (Text : String) return String is
      use Ada.Strings.Unbounded;
      Out_S : Unbounded_String;
      Hex   : constant String := "0123456789abcdef";
   begin
      for C of Text loop
         case C is
            when '"'      => Append (Out_S, "\""");
            when '\'      => Append (Out_S, "\\");
            when ASCII.LF => Append (Out_S, "\n");
            when ASCII.CR => Append (Out_S, "\r");
            when ASCII.HT => Append (Out_S, "\t");
            when ASCII.BS => Append (Out_S, "\b");
            when ASCII.FF => Append (Out_S, "\f");
            when others =>
               if Character'Pos (C) < 16#20# then
                  Append (Out_S, "\u00");
                  Append (Out_S, Hex (Hex'First + Character'Pos (C) / 16));
                  Append (Out_S, Hex (Hex'First + Character'Pos (C) mod 16));
               else
                  Append (Out_S, C);
               end if;
         end case;
      end loop;
      return To_String (Out_S);
   end JSON_Escape;

   --  Append one task's result -- its expectations, verdict and whole
   --  transcript -- to the report as a JSON object.
   procedure Emit_Task
     (Into     : in out Ada.Strings.Unbounded.Unbounded_String;
      Index    : Positive;
      Spec     : Task_Spec;
      Messages : Conv.History;
      Outcome  : Model_Runner.Agent.Outcome;
      Passed   : Boolean)
   is
      use Ada.Strings.Unbounded;
      procedure A (Text : String) is
      begin
         Append (Into, Text);
      end A;
      function Q (Text : String) return String
      is ("""" & JSON_Escape (Text) & """");

      Needs_Written : Boolean := False;
      procedure Need (Name : String) is
      begin
         if Name /= "" then
            if Needs_Written then
               A (",");
            end if;
            A (Q (Name));
            Needs_Written := True;
         end if;
      end Need;
   begin
      if Length (Into) > 0 then
         A (",");
      end if;
      A ("{""index"":" & Num (Index));
      A (",""prompt"":" & Q (Spec.Prompt.all));
      A (",""wants"":" & Q (Spec.Wants.all));
      if Spec.Also.all /= "" then
         A (",""also"":" & Q (Spec.Also.all));
      end if;
      A (",""needs"":[");
      Need (Spec.Tool.all);
      Need (Spec.Tool_Two.all);
      A ("]");
      A (",""min_calls"":" & Num (Spec.Min_Calls));
      if Spec.Answer.all /= "" then
         A (",""answer_schema"":" & Q (Spec.Answer.all));
      end if;
      A (",""passed"":" & (if Passed then "true" else "false"));
      A (",""reason"":"
         & Q (Model_Runner.Agent.Stop_Reason'Image (Outcome.Reason)));
      A (",""steps"":" & Num (Outcome.Steps));
      A (",""calls"":" & Num (Outcome.Calls));
      A (",""retries"":" & Num (Outcome.Retries));
      A (",""generated_tokens"":" & Num (Outcome.Generated_Tokens));
      A (",""prompt_tokens"":" & Num (Outcome.Prompt_Tokens));
      A (",""final"":" & Q (Final_Answer (Messages)));
      A (",""transcript"":[");
      for I in 1 .. Conv.Length (Messages) loop
         if I > 1 then
            A (",");
         end if;
         A ("{""role"":" & Q (Conv.Role_Name (Conv.Sender_At (Messages, I))));
         A (",""content"":" & Q (Conv.Content_At (Messages, I)));
         if Conv.Call_Count (Messages, I) > 0 then
            A (",""calls"":[");
            for K in 1 .. Conv.Call_Count (Messages, I) loop
               if K > 1 then
                  A (",");
               end if;
               A ("{""name"":" & Q (Conv.Call_Name (Messages, I, K)));
               A (",""arguments"":"
                  & Q (Conv.Call_Arguments (Messages, I, K)) & "}");
            end loop;
            A ("]");
         end if;
         A ("}");
      end loop;
      A ("]}");
   end Emit_Task;

   ---------
   -- Say --
   ---------

   procedure Say (Result : in out Report; Text : String) is
      Room : constant Natural := Natural'Min (Text'Length, Result.Detail'Length);
   begin
      Result.Detail (1 .. Room) := Text (Text'First .. Text'First + Room - 1);
      Result.Detail_Up := Room;
   end Say;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path    : String;
      Threads : Positive;
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Anyway      : Boolean := False;
      Waiting     : Natural := 0;
      Trace       : Boolean := False;
      Report_Path : String := "";
      Format      : String := "";
      Context     : Natural := 8_192;
      Arithmetic  : String := "";
      Result      : out Report)
   is
      Source    : Shards.Shard_Set;
      Container : Containers.Container;
      Engine    : L.Model;
      Status    : E.Error_Info;

      --  The task objects of the JSON report, accumulated while each task's
      --  history is still open, and wrapped and written out at the end.
      Report_Buf : Ada.Strings.Unbounded.Unbounded_String;

      Bounds : constant Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
   begin
      Result := (others => <>);
      Result.Load_Before := Host_Load.Now;

      if Path = "" or else not Ada.Directories.Exists (Path) then
         Result.Missing := True;
         Say (Result, "no model at that path; nothing scored");
         return;
      end if;

      --  The same gate every model campaign here comes through.
      if not Host_Load.Settle (Waiting, Anyway) then
         Result.Missing := True;
         Say (Result, "the machine is too busy to score on");
         return;
      end if;

      if Backend = Model_Runner.Backend.Backend_Device then
         declare
            Awake : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Awake);
            if not Awake then
               Result.Missing := True;
               Say (Result, "no device answered");
               return;
            end if;
         end;
      end if;

      Shards.Open_Model (Source, Container, Path, Status => Status);
      if E.Is_Error (Status) then
         Shards.Close (Source);
         Say (Result, "the model would not open: "
              & E.Error_Code'Image (Status.Code));
         return;
      end if;

      L.Prepare
        (Engine, Container, Source, Backend => Backend,
         Threads => Threads, Status => Status);
      if E.Is_Error (Status) then
         Containers.Close (Container);
         Shards.Close (Source);
         Say (Result, "the model would not prepare: "
              & E.Error_Code'Image (Status.Code));
         return;
      end if;

      --  The arithmetic, told to the backend once the model is known and
      --  before anything is dispatched: the one named, or the one run
      --  would choose for this model unasked. A campaign that scored on
      --  the f32 path measured a path nobody runs, and on a four-billion
      --  parameter hybrid took ten times as long.
      declare
         use type L.Arithmetic_Mode;
         use type L.Architecture;
         Mode  : L.Arithmetic_Mode := L.Integer_Activations;
         Found : Boolean := Arithmetic = "";
      begin
         for Each in L.Arithmetic_Mode loop
            if L.Arithmetic_Name (Each) = Arithmetic then
               Mode := Each;
               Found := True;
            end if;
         end loop;
         if not Found then
            Say (Result, "no arithmetic is named '" & Arithmetic & "'");
            L.Close (Engine, Status);
            Containers.Close (Container);
            Shards.Close (Source);
            return;
         end if;
         if Arithmetic = "" and then L.Config (Engine).Kind = L.Gemma2 then
            Mode := L.Mixed_Activations;
         end if;
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (L.Quantized_Roles (Mode));
      end;

      --  A named format replaces the model's own template with one this
      --  build carries, and whatever Prepare chose: for a model whose
      --  embedded template will not compile, Prepare has already put the
      --  carried format that template is written in, when there is one,
      --  and the summary says so.
      if Format /= "" then
         if Model_Runner.Templates.Built_In (Format) = "" then
            Say (Result, "no built-in chat format is named '" & Format & "'");
            L.Close (Engine, Status);
            Containers.Close (Container);
            Shards.Close (Source);
            return;
         end if;
         L.Use_Template
           (Engine, Model_Runner.Templates.Built_In (Format),
            Model_Runner.Limits.Default_Model_Limits, Status, Name => Format);
         if E.Is_Error (Status) then
            Say (Result, "the '" & Format & "' format would not compile: "
                 & E.Error_Code'Image (Status.Code));
            L.Close (Engine, Status);
            Containers.Close (Container);
            Shards.Close (Source);
            return;
         end if;
      end if;

      if not L.Template_Ready (Engine) then
         Say (Result, "the model has no usable chat template to score with");
         L.Close (Engine, Status);
         Containers.Close (Container);
         Shards.Close (Source);
         return;
      end if;

      if L.Template_Stood_In (Engine) then
         Say (Result, "the model's own template would not compile; "
              & "rendering with the built-in " & L.Template_Format (Engine)
              & " format");
      end if;

      declare
         --  The shape a task offering tools reads its calls in: the one the
         --  format the model renders with writes them. A task with no tools
         --  -- the answer-schema one -- stays on the JSON envelope
         --  regardless, because that is the syntax its answer grammar
         --  constrains.
         Tool_Syntax : constant Model_Runner.Tools.Call_Syntax :=
           Model_Runner.Templates.Syntax_Of (L.Template_Format (Engine));

         Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
         Where : constant CPU.Pool_Reference :=
           (if Threads = 1 then null else Team'Unchecked_Access);
         Seeds : aliased Model_Runner.Entropy.Host_Source;
         Clock : aliased Model_Runner.Clocks.System_Clock;
      begin
         for Index in Tasks'Range loop
            declare
               Spec     : Task_Spec renames Tasks (Index);
               Session  : L.Session;
               Messages : Conv.History;
               Offered  : Model_Runner.Tools.Definitions;
               Runner   : Model_Runner.Tools.Builtin.Instance;
               Stop     : Model_Runner.Stops.Set;
               Request  : Gen.Request;
               Loop_Out : Model_Runner.Agent.Outcome;
               Local    : E.Error_Info;

               Wanted_Tool : constant Boolean := Spec.Tool.all /= "";
               Passed      : Boolean;
               Began       : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            begin
               Result.Tasks := Result.Tasks + 1;

               L.Open (Session, Engine, Context => Context,
                       Workers => Where, Status => Local);
               exit when E.Is_Error (Local);

               Conv.Open (Messages, Bounds, Local);
               exit when E.Is_Error (Local);
               Conv.Set_System (Messages, Spec.System.all, Local);
               Conv.Append (Messages, Conv.User_Role, Spec.Prompt.all, Local);

               if Wanted_Tool then
                  Model_Runner.Tools.Read
                    (Offered, Model_Runner.Tools.Builtin.Definitions_Text,
                     Local);
               end if;

               Model_Runner.Stops.Open (Stop, Bounds);

               Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
               --  Short: a tool task ends in a call and a sentence, and a
               --  grammar filters every one of a large model's tokens on
               --  every step, so a generous cap here is time spent for
               --  nothing. A model that has not answered in this many has
               --  not understood the task.
               Request.Max_Tokens := 128;
               Request.Seed := 1;
               Request.Has_Seed := True;

               Model_Runner.Agent.Run
                 (Source     => Engine,
                  Session    => Session,
                  Messages   => Messages,
                  Offered    => Offered,
                  Executor   => Runner,
                  Generation => Request,
                  Stop_Set   => Stop,
                  Sink       => null,
                  Time       => Clock'Unchecked_Access,
                  Seeds      => Seeds'Unchecked_Access,
                  --  A task offering tools reads its calls in the format's
                  --  shape; one with only an answer schema stays on the JSON
                  --  envelope, which is what its answer grammar constrains.
                  Tool_Syntax =>
                    (if Wanted_Tool then Tool_Syntax
                     else Model_Runner.Tools.Tool_Call_JSON),
                  --  Room for a chain: several tool calls and the answer.
                  Max_Steps  => 10,
                  --  A ceiling so one task cannot hang the run. Generous:
                  --  the step budget and the duplicate guard stop it first
                  --  in the ordinary case; this is the backstop.
                  Max_Seconds => 300.0,
                  --  Thinking off: the tool-call grammar reserves the '<'
                  --  that begins a call, and a <think> block would open with
                  --  the same character and be refused. A reasoning model
                  --  scored here answers without the block.
                  Thinking   => Model_Runner.Templates.Thinking_Off,
                  Answer_Schema => Spec.Answer.all,
                  Bounds     => Bounds,
                  Result     => Loop_Out);

               Result.Steps := Result.Steps + Loop_Out.Steps;
               Result.Calls := Result.Calls + Loop_Out.Calls;
               Result.Tokens := Result.Tokens + Loop_Out.Generated_Tokens;

               --  A pass is the answer the task's tools make true, the tools
               --  it needs having been the ones that answered it, and -- for
               --  a chain -- enough calls to have gone through the steps
               --  rather than guessed the end.
               Passed :=
                 Loop_Out.Reason = Model_Runner.Agent.Answered
                 and then Contains (Final_Answer (Messages), Spec.Wants.all)
                 and then (Spec.Also.all = ""
                           or else Contains (Final_Answer (Messages),
                                             Spec.Also.all))
                 and then (not Wanted_Tool
                           or else Called_Tool (Messages, Spec.Tool.all))
                 and then (Spec.Tool_Two.all = ""
                           or else Called_Tool (Messages, Spec.Tool_Two.all))
                 and then Loop_Out.Calls >= Spec.Min_Calls
                 and then Answer_Fits_Schema
                            (Final_Answer (Messages), Spec.Answer.all);

               if Passed then
                  Result.Passed := Result.Passed + 1;
               end if;

               if Trace then
                  Dump (Index, Spec, Messages, Loop_Out, Passed,
                        Ada.Calendar.Clock - Began);
               end if;

               if Report_Path /= "" then
                  Emit_Task (Report_Buf, Index, Spec, Messages, Loop_Out,
                             Passed);
               end if;

               Model_Runner.Stops.Close (Stop);
               Model_Runner.Tools.Close (Offered);
               Conv.Close (Messages);
               L.Close (Session);
            end;
         end loop;

         --  Close the pool before its scope ends. The workers are Ada tasks
         --  that leave their loop only when Close sets the shutdown flag, and
         --  a master awaits its dependent tasks before it finalizes the
         --  object they belong to -- so leaving this to the pool's own
         --  Finalize would wait on workers that were never told to stop, with
         --  every task of the pool asleep. Every other caller of the pool
         --  closes it here for the same reason; this one did not, and the
         --  agent loop hung at teardown until it did.
         CPU.Close (Team);
      end;

      --  Detail is left as it stands: empty for a plain run, or the note
      --  that a carried format stood in, which the summary carries along.
      Result.Ran := Result.Tasks > 0;
      Result.Load_After := Host_Load.Now;

      if Report_Path /= "" then
         declare
            File : Ada.Text_IO.File_Type;
         begin
            Ada.Text_IO.Create
              (File, Ada.Text_IO.Out_File, Report_Path);
            Ada.Text_IO.Put
              (File, "{""model"":""" & JSON_Escape (Path) & """");
            Ada.Text_IO.Put
              (File, ",""backend"":"""
               & Model_Runner.Backend.Backend_Name (Backend) & """");
            Ada.Text_IO.Put (File, ",""threads"":" & Num (Threads));
            --  The carried format rendered with, when one was; a reader
            --  comparing runs wants to know the model was not rendered
            --  with its own template.
            if L.Template_Format (Engine) /= "" then
               Ada.Text_IO.Put
                 (File, ",""format"":""" & L.Template_Format (Engine) & """");
            end if;
            Ada.Text_IO.Put (File, ",""tasks"":" & Num (Result.Tasks));
            Ada.Text_IO.Put (File, ",""passed"":" & Num (Result.Passed));
            Ada.Text_IO.Put (File, ",""steps"":" & Num (Result.Steps));
            Ada.Text_IO.Put (File, ",""calls"":" & Num (Result.Calls));
            Ada.Text_IO.Put (File, ",""tokens"":" & Num (Result.Tokens));
            Ada.Text_IO.Put
              (File, ",""results"":["
               & Ada.Strings.Unbounded.To_String (Report_Buf) & "]}");
            Ada.Text_IO.New_Line (File);
            Ada.Text_IO.Close (File);
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
         end;
      end if;

      L.Close (Engine, Status);
      Containers.Close (Container);
      Shards.Close (Source);
   end Run;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
      function Count (Value : Natural) return String is
         Raw : constant String := Natural'Image (Value);
      begin
         return Raw (Raw'First + 1 .. Raw'Last);
      end Count;
   begin
      if Item.Missing or else not Item.Ran then
         return "agent-eval: " & Item.Detail (1 .. Item.Detail_Up);
      end if;
      return "agent-eval: tasks " & Count (Item.Tasks)
        & ", passed " & Count (Item.Passed)
        & ", steps " & Count (Item.Steps)
        & ", calls " & Count (Item.Calls)
        & ", tokens " & Count (Item.Tokens)
        --  What a run that scored still had to say: a format standing in.
        & (if Item.Detail_Up > 0
           then "; " & Item.Detail (1 .. Item.Detail_Up)
           else "");
   end Summary;

end Agent_Eval;
