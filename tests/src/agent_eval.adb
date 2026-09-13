with Ada.Characters.Handling;
with Ada.Directories;

with Host_Load;

with Model_Runner.Agent;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Shards;
with Model_Runner.Generation;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Sampling;
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

   type Task_Spec is record
      System : access constant String;
      Prompt : access constant String;
      Tool   : access constant String;
      Wants  : access constant String;
   end record;

   Tasks : constant array (Positive range <>) of Task_Spec :=
     [(Sys_Tools'Access, P1'Access, T1'Access, W1'Access),
      (Sys_Tools'Access, P2'Access, T2'Access, W2'Access),
      (Sys_Tools'Access, P3'Access, T3'Access, W3'Access),
      (Sys_Tools'Access, P4'Access, T4'Access, W4'Access),
      (Sys_Plain'Access, P5'Access, Empty'Access, W5'Access)];

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
      Anyway  : Boolean := False;
      Waiting : Natural := 0;
      Result  : out Report)
   is
      Source    : Shards.Shard_Set;
      Container : Containers.Container;
      Engine    : L.Model;
      Status    : E.Error_Info;

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

      if not L.Template_Ready (Engine) then
         Say (Result, "the model has no usable chat template to score with");
         L.Close (Engine, Status);
         Containers.Close (Container);
         Shards.Close (Source);
         return;
      end if;

      declare
         Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
         Where : constant CPU.Pool_Reference :=
           (if Threads = 1 then null else Team'Unchecked_Access);
         Seeds : aliased Model_Runner.Entropy.Host_Source;
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
            begin
               Result.Tasks := Result.Tasks + 1;

               L.Open (Session, Engine, Workers => Where, Status => Local);
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
                  Time       => null,
                  Seeds      => Seeds'Unchecked_Access,
                  Max_Steps  => 6,
                  --  Thinking off: the tool-call grammar reserves the '<'
                  --  that begins a call, and a <think> block would open with
                  --  the same character and be refused. A reasoning model
                  --  scored here answers without the block.
                  Thinking   => Model_Runner.Templates.Thinking_Off,
                  Bounds     => Bounds,
                  Result     => Loop_Out);

               Result.Steps := Result.Steps + Loop_Out.Steps;
               Result.Calls := Result.Calls + Loop_Out.Calls;

               --  A pass is the answer the tool makes true, and -- where the
               --  task is one only a tool can answer -- the tool having been
               --  the thing that answered it.
               Passed :=
                 Loop_Out.Reason = Model_Runner.Agent.Answered
                 and then Contains (Final_Answer (Messages), Spec.Wants.all)
                 and then (not Wanted_Tool
                           or else Called_Tool (Messages, Spec.Tool.all));

               if Passed then
                  Result.Passed := Result.Passed + 1;
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

      Result.Ran := Result.Tasks > 0;
      Result.Load_After := Host_Load.Now;
      Say (Result, "scored");

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
        & ", calls " & Count (Item.Calls);
   end Summary;

end Agent_Eval;
