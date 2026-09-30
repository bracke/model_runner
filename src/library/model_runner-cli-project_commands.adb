with Ada.Text_IO;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Fs;

with Model_Runner.Agent;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Init;
with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Repo;
with Model_Runner.CLI.Tasks;
with Model_Runner.CLI.Work;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Framework;
with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Generation;
with Model_Runner.Localization;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tools;
with Model_Runner.Tools.Builtin;

package body Model_Runner.CLI.Project_Commands is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Agent.Stop_Reason;
   use type Model_Runner.Conversation.Role;
   use type Model_Runner.CLI.Options.Command_Kind;

   package E renames Model_Runner.Errors;
   package Conv renames Model_Runner.Conversation;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;
   package Nt renames Model_Runner.Framework.Intent;
   package Vf renames Model_Runner.Framework.Verification;
   package L renames Model_Runner.Llama;
   package Names renames Model_Runner.Framework.Name_Lists;

   --  The project is where the session was started.
   Here : constant String := ".";

   type Word_Access is access constant String;

   Words : constant array (Positive range <>) of Word_Access :=
     [new String'("/init"), new String'("/bootstrap"), new String'("/state"),
      new String'("/config"), new String'("/task"), new String'("/accept"),
      new String'("/reject"), new String'("/work"), new String'("/cancel"),
      new String'("/check"), new String'("/req"), new String'("/result"),
      new String'("/tree"), new String'("/sym"), new String'("/refs"),
      new String'("/deps"), new String'("/users"),
      new String'("/impact"), new String'("/trace"), new String'("/reconfigure"),
      new String'("/decision"), new String'("/spec"), new String'("/git"),
      new String'("/sandbox"), new String'("/instruct")];

   --  The tools the work's agents may call; each is offered only where the
   --  agent's permissions give it.
   Allowed_Tools : constant array (1 .. 5) of Word_Access :=
     [new String'("read_file"), new String'("write_file"),
      new String'("list_directory"), new String'("delegate"),
      new String'("run_checks")];

   function Image (Value : Natural) return String
   is (T.Image (Long_Long_Integer (Value)));

   --  A whole file, or nothing when it cannot be read.
   function Whole (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;
      declare
         Text : String (1 .. Natural (Ada.Directories.Size (Path)));
      begin
         Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
         return Text;
      end;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return "";
   end Whole;

   --  Every other tool refused, and said so.
   type Fence (Screen : not null access Pres.Console) is
     limited new Model_Runner.Agent.Approver with null record;

   overriding function Consider
     (Self : in out Fence; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict;

   overriding function Consider
     (Self : in out Fence; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict
   is
      pragma Unreferenced (Arguments);
   begin
      for Tool of Allowed_Tools loop
         if Tool.all = Named then
            return Model_Runner.Agent.Allow;
         end if;
      end loop;
      Pres.Put_Note (Self.Screen.all, "cli.agent.denied", [Loc.Named ("name", Named)]);
      return Model_Runner.Agent.Deny;
   end Consider;

   package Wk renames Model_Runner.Framework.Work;
   package Pm renames Model_Runner.Framework.Permissions;

   type Host_Access is access all Wk.Child_Host'Class;

   --  What the agent does, shown as it does it and recorded on its
   --  invocation.
   type Watch
     (Screen : not null access Pres.Console;
      Host   : Host_Access)
   is limited new Model_Runner.Agent.Observer with record
      --  The arguments of the calls asked for and not yet answered, oldest
      --  first: a reply may ask for several before any is answered.
      Asked : Names.Vector;

      --  The run's own stop, asked for when its work is ended elsewhere.
      Stop  : Model_Runner.Cancellation.Token_Reference := null;
   end record;

   overriding procedure On_Call
     (Self : in out Watch; Named : String; Arguments : String);

   overriding procedure On_Result
     (Self : in out Watch; Named : String; Result : String);

   overriding procedure On_Call
     (Self : in out Watch; Named : String; Arguments : String) is
      use type Model_Runner.Cancellation.Token_Reference;
   begin
      --  Its task ended elsewhere -- cancelled from another process -- the
      --  work stops rather than write on for a task that is not its.
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
      Self.Asked.Append (Arguments);
      Pres.Put_Tool_Call (Self.Screen.all, Named, Arguments);
   end On_Call;

   overriding procedure On_Result
     (Self : in out Watch; Named : String; Result : String) is
   begin
      Pres.Put_Tool_Result (Self.Screen.all, Result);
      if Self.Host /= null then
         Self.Host.Note_Call
           (Named, (if Self.Asked.Is_Empty then "" else Self.Asked.First_Element), Result);
      end if;
      if not Self.Asked.Is_Empty then
         Self.Asked.Delete_First;
      end if;
   end On_Result;

   --  Whether a path is one an agent's file tools may reach: inside the
   --  project once every link is followed, and not its state.
   function Within_Project (Path : String) return Boolean
   is (Pm.Path_Refusal (".", Path, Writing => False) = "");

   --  One tool as a model reads it.
   function Tool (Name, Description, Parameters : String) return String
   is ("{""type"": ""function"", ""function"": {""name"": """ & Name
       & """, ""description"": """ & Description
       & """, ""parameters"": " & Parameters & "}}");

   function Strings (Names : String; Required : String) return String
   is ("{""type"": ""object"", ""properties"": {" & Names & "}, ""required"": ["
       & Required & "]}");

   --  The tools an agent is offered: reading always, writing and handing
   --  work to a helper where it may.
   function Offered_Text (Host : Host_Access) return String
   is ("["
       & Tool ("read_file", "Read a text file and return its contents.",
               Strings ("""path"": {""type"": ""string""}", """path"""))
       & ", "
       & Tool ("list_directory", "List the entries of a directory.",
               Strings ("""path"": {""type"": ""string""}", """path"""))
       & (if Host /= null and then Host.May_Check (Host.Task_Profile)
          then ", "
               & Tool ("run_checks",
                       "Build and test the project as the task will be verified,"
                       & " and get back whether it passes and, if not, what the"
                       & " failing checks reported.",
                       "{""type"": ""object"", ""properties"": {}}")
          else "")
       & (if Host = null or else Host.May (Pm.Write_Source)
          then ", "
               & Tool ("write_file", "Write text to a file, replacing it.",
                       Strings ("""path"": {""type"": ""string""}, "
                                & """content"": {""type"": ""string""}",
                                """path"", ""content"""))
          else "")
       & (if Host /= null and then Host.May (Pm.Create_Children)
          then ", "
               & Tool ("delegate",
                       "Hand one part of the work -- a review, an investigation,"
                       & " a piece to write -- to a helper that starts with no"
                       & " memory of this conversation and reports back only its"
                       & " result. Say everything it needs in task. role names"
                       & " what it is for; need is required (the default),"
                       & " optional or advisory.",
                       Strings ("""task"": {""type"": ""string""}, "
                                & """role"": {""type"": ""string""}, "
                                & """need"": {""type"": ""string"", ""enum"": "
                                & "[""required"", ""optional"", ""advisory""]}",
                                """task"""))
          else "")
       & "]");

   --  The file tools, fenced by the permissions of the agent now working,
   --  and delegate, which makes a child through the harness and runs it.
   type Work_Tools
     (Agent : not null access constant Session_Agent;
      Host  : Host_Access)
   is new Model_Runner.Tools.Builtin.Instance with record
      --  The calls this agent has made, against its tool budget.
      Made : Natural := 0;
   end record;

   overriding procedure Run
     (Self      : in out Work_Tools;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Generated text written as it comes, and between its pieces the work
   --  asked after: ended elsewhere -- cancelled from another terminal --
   --  the turn stops there, not at its next call.
   type Watching_Sink is limited new Pres.Standard_Output_Sink with record
      Stop : Model_Runner.Cancellation.Token_Reference := null;
   end record;

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean);

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean)
   is
      use type Model_Runner.Cancellation.Token_Reference;
   begin
      Pres.Standard_Output_Sink (Self).Write (Item, Closed);
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
   end Write;

   --  One agent's loop, on the session: the root working on its task, or a
   --  child on what it was asked. A root that answers without calling a tool
   --  has changed nothing, whatever its answer says; it is told so and goes
   --  on, twice at most, before its answer is taken as it stands.
   procedure Run_Loop
     (Self   : Session_Agent;
      Prompt : String;
      Host   : Host_Access;
      Budget : Natural;
      Root   : Boolean;
      Answer : out Unbounded_String;
      Tokens : out Natural;
      Status : out Model_Runner.Errors.Error_Info;
      Prompt_Tokens : out Natural)
   is
      Messages : Conv.History;
      Offered  : Model_Runner.Tools.Definitions;
      Runner   : Work_Tools (Self'Unchecked_Access, Host);
      Guard    : aliased Fence (Self.Screen);
      Watcher  : aliased Watch (Self.Screen, Host);
      Sink     : aliased Watching_Sink;
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;
      Request  : Model_Runner.Generation.Request;
      Outcome  : Model_Runner.Agent.Outcome;
      Calls    : Natural := 0;

      --  The template's own shape of call, and where that is the JSON
      --  envelope, the bare or fenced object too: models asked for a call
      --  often write it without the envelope, the 14B ones as well.
      Written  : constant Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Templates.Syntax_Of (L.Template_Format (Self.Prepared.all));
      Syntax   : constant Model_Runner.Tools.Call_Syntax :=
        (if Model_Runner.Tools."=" (Written, Model_Runner.Tools.Tool_Call_JSON)
         then Model_Runner.Tools.Open_JSON else Written);
   begin
      Answer := Null_Unbounded_String;
      Tokens := 0;
      Prompt_Tokens := 0;
      Watcher.Stop := Self.Cancel;
      Sink.Stop := Self.Cancel;

      Conv.Open (Messages, Status => Status);
      if E.Is_Ok (Status) then
         Conv.Append (Messages, Conv.User_Role, Prompt, Status);
      end if;
      if E.Is_Ok (Status) then
         Model_Runner.Tools.Read (Offered, Offered_Text (Host), Status);
      end if;
      if E.Is_Error (Status) then
         Conv.Close (Messages);
         return;
      end if;

      Request.Max_Tokens := Natural'Max (Self.Item.Max_Tokens, 1024);
      Request.Sampling := Self.Item.Sampling;
      Request.Seed := Self.Item.Seed;
      Request.Has_Seed := Self.Item.Has_Seed;
      Request.Batch_Size :=
        (if L.Capability (Self.Prepared.all).Supports_Batched
         then Self.Item.Batch_Size else 1);
      Request.Add_Beginning := False;
      Request.Retain_Text := True;

      for Round in 1 .. (if Root then 3 else 1) loop
         Model_Runner.Agent.Run
           (Source      => Self.Prepared.all,
            Session     => Self.Session.all,
            Messages    => Messages,
            Offered     => Offered,
            Executor    => Runner,
            Generation  => Request,
            Stop_Set    => Self.Stop_Set.all,
            Sink        => Sink'Unchecked_Access,
            Time        => Clock'Unchecked_Access,
            Seeds       => Seeds'Unchecked_Access,
            Max_Steps   => (if Root and then Host /= null then Host.Steps
                            elsif Root then 24 else 16),
            Max_Total_Tokens => Budget,
            Max_Seconds => (if Host = null then 0.0 else Host.Time_Left),
            Cancel      => Self.Cancel,
            Tool_Syntax => Syntax,
            Thinking    => Self.Item.Thinking,
            Approve     => Guard'Unchecked_Access,
            Watch       => Watcher'Unchecked_Access,
            Result      => Outcome);
         Calls := Calls + Outcome.Calls;
         Tokens := Tokens + Outcome.Generated_Tokens;
         Prompt_Tokens := Natural'Max (Prompt_Tokens, Outcome.Prompt_Tokens);
         exit when Calls > 0 or else Round = 3
           or else Outcome.Reason /= Model_Runner.Agent.Answered;
         Conv.Append
           (Messages, Conv.User_Role,
            "You have not called a tool, so no file has changed. If the task"
            & " needs a change, make it now by calling write_file, then report"
            & " again.", Status);
         exit when E.Is_Error (Status);
      end loop;

      if Conv.Length (Messages) > 0
        and then Conv.Sender_At (Messages, Conv.Length (Messages)) = Conv.Assistant_Role
      then
         Answer := To_Unbounded_String (Conv.Content_At (Messages, Conv.Length (Messages)));
      end if;
      Conv.Close (Messages);
      Model_Runner.Tools.Close (Offered);

      if Outcome.Reason = Model_Runner.Agent.Cancelled then
         --  Stopped for work ended elsewhere, not by the person: the
         --  session's own stop is not left asked for.
         if Model_Runner.Framework.Execution.Work_Withdrawn
           and then Model_Runner.Cancellation."/=" (Self.Cancel, null)
         then
            Self.Cancel.Reset;
         end if;
         Status := E.Make (E.Generation_Cancelled);
      elsif Outcome.Reason = Model_Runner.Agent.Repeating then
         --  Going round, not a request that was wrong.
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "the model");
         E.Add_Text (Status, "detail", "it kept repeating calls it had already made, and got no"
                     & " further");
      elsif Outcome.Reason = Model_Runner.Agent.Timed_Out then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "time");
         E.Add_Text (Status, "detail", "the work ran out of the time it was given");
      elsif Outcome.Reason /= Model_Runner.Agent.Answered then
         if E.Is_Error (Outcome.Error) then
            Status := Outcome.Error;
         else
            --  Why the model stopped without answering, in words.
            Status := E.Make (E.Generation_Invalid_Request);
            E.Add_Text
              (Status, "field",
               (case Outcome.Reason is
                  when Model_Runner.Agent.Step_Limit =>
                     "the model used all its steps with a call still open (agents.max_steps)",
                  when Model_Runner.Agent.Token_Limit =>
                     "the model used all its tokens (agents.token_budget)",
                  when Model_Runner.Agent.Repeating =>
                     "the model made only calls it had made already, and got no further",
                  when Model_Runner.Agent.Render_Failed =>
                     "the conversation would not render in the model's template",
                  when Model_Runner.Agent.Grammar_Failed =>
                     "the tool grammar would not compile",
                  when Model_Runner.Agent.History_Failed =>
                     "a turn would not fit the context (a larger --context-size helps)",
                  when Model_Runner.Agent.Declined =>
                     "a call was declined before it ran",
                  when others =>
                     "the model stopped without answering"));
         end if;
      end if;
   end Run_Loop;

   --  What a refusal says, for the model to read.
   function Refusal (Status : E.Error_Info) return String is
      Found : Boolean;
      Given : E.Parameter;
   begin
      E.Find_Parameter (Status, "detail", Found, Given);
      return (if Found then T.To_String (Given.Text_Value)
              else E.Error_Code'Image (Status.Code));
   end Refusal;

   --  A child asked for, made by the harness, run on the session and
   --  answered for; run again when the harness says so.
   function Delegate (Self : Work_Tools; Arguments : String) return String is
      Found    : Boolean;
      Ignored  : Boolean;
      Brief    : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "task", Found);
      Role     : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "role", Ignored);
      Need     : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "need", Ignored);
      Retry_Of : Unbounded_String;
      Told     : Unbounded_String;
   begin
      if not Found or else Brief = "" then
         return "error: delegate needs a task string";
      elsif Self.Host = null then
         return "error: no helper can be made here; do the work with the other tools";
      end if;

      --  Nothing more is started for work already cancelled.
      if Model_Runner.Framework.Execution.Work_Withdrawn then
         return "error: the work was cancelled; no helper is made";
      end if;
      loop
         declare
            Id      : Unbounded_String;
            Context : Unbounded_String;
            Budget  : Natural;
            Status  : E.Error_Info;
            Answer  : Unbounded_String;
            Tokens  : Natural;
            Prompt  : Natural;
            Ran     : E.Error_Info;
            Now     : Unbounded_String;
            Retry   : Boolean;
         begin
            Self.Host.Open_Child
              (Role, Need, Brief, To_String (Retry_Of), Id, Context, Budget, Status);
            if E.Is_Error (Status) then
               return (if Told = Null_Unbounded_String then ""
                       else To_String (Told) & ASCII.LF)
                 & "error: no helper was made: " & Refusal (Status);
            end if;
            Run_Loop (Self.Agent.all, To_String (Context), Self.Host, Budget,
                      Root => False, Answer => Answer, Tokens => Tokens, Status => Ran,
                      Prompt_Tokens => Prompt);

            --  The work cancelled while the helper ran: it is cancelled
            --  with it, however it came to stop.
            if Model_Runner.Framework.Execution.Work_Withdrawn
              or else Model_Runner.Framework.Execution.Cancel_Requested
            then
               Ran := E.Make (E.Generation_Cancelled);
            end if;
            Self.Host.Close_Child (To_String (Answer), Tokens, Ran, Now, Retry,
                                   Prompt_Tokens => Prompt);
            Told := (if Told = Null_Unbounded_String then Now else Told & ASCII.LF & Now);
            exit when not Retry;
            Retry_Of := Id;
         end;
      end loop;
      return To_String (Told);
   end Delegate;

   overriding procedure Run
     (Self      : in out Work_Tools;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      procedure Put (Text : String) is
      begin
         Last := 0;
         Status := E.Success;
         if Text'Length > Result'Length then
            Status := E.Make (E.Tools_Too_Large);
            return;
         end if;
         Result (Result'First .. Result'First + Text'Length - 1) := Text;
         Last := Result'First + Text'Length - 1;
      end Put;

      Found : Boolean;
      Path  : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "path", Found);
      Budget : constant Natural :=
        (if Self.Host = null then 0 else Self.Host.Tool_Budget);

      --  Whether the agent now working may read or write there: inside the
      --  project, and within its source or specification grants.
      function May (Reading : Boolean) return Boolean
      is (Within_Project (Path)
          and then (Self.Host = null
                    or else Self.Host.May
                              ((if Reading then Pm.Read_Source else Pm.Write_Source), Path)
                    or else Self.Host.May
                              ((if Reading then Pm.Read_Specs else Pm.Write_Specs), Path)));
   begin
      Self.Made := Self.Made + 1;
      if Budget > 0 and then Self.Made > Budget then
         Put ("error: the budget of" & Natural'Image (Budget)
              & " tool calls is spent; give your answer now");
      elsif Named = "delegate" then
         Put (Delegate (Self, Arguments));
      elsif Named = "run_checks" then
         if Self.Host = null then
            Put ("error: no checks can be run here");
         else
            declare
               Report : Unbounded_String;
               Ran    : E.Error_Info;
            begin
               Self.Host.Run_Checks (Self.Host.Task_Profile, Report, Ran);
               Put (if E.Is_Ok (Ran) then To_String (Report)
                    else "error: the checks were not run: " & Refusal (Ran));
            end;
         end if;
      elsif Named in "read_file" | "list_directory" | "write_file"
        and then Pm.Path_Refusal (".", Path, Writing => Named = "write_file") /= ""
      then
         Put ("error: " & Pm.Path_Refusal (".", Path, Writing => Named = "write_file"));
      elsif Named in "read_file" | "list_directory" and then not May (Reading => True) then
         Put ("error: you may not read " & Path
              & (if Pm.Sandbox_Refuses (Path, False) then " (" & Pm.Sandbox_Source & " confines it)" else ""));
      elsif Named = "write_file" and then not May (Reading => False) then
         Put ("error: you may not write " & Path
              & (if Pm.Sandbox_Refuses (Path, True) then " (" & Pm.Sandbox_Source & " confines it)" else ""));
      else
         Model_Runner.Tools.Builtin.Run
           (Model_Runner.Tools.Builtin.Instance (Self), Named, Arguments, Result, Last,
            Status);
      end if;
   end Run;

   --  The root's run, with children through Host or without them.
   procedure Work_On
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Host        : Host_Access;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info)
   is
      Before : constant String := Ada.Directories.Current_Directory;
      Prompt : constant String := Whole (Prompt_Path);
      Tokens : Natural;
      Read   : Natural;
   begin
      --  The work is done where the task's files are, and its own
      --  conversation -- and each child's -- is on the session, which the
      --  screen's is read back into afterwards.
      L.Reset (Self.Session.all);
      Ada.Directories.Set_Directory (Project);
      Run_Loop (Self, Prompt, Host, (if Host = null then 0 else Host.Token_Budget), True, Answer,
                Tokens, Status, Read);
      Ada.Directories.Set_Directory (Before);
      L.Reset (Self.Session.all);
      if Host /= null then
         Host.Spend (Tokens, Prompt_Tokens => Read);
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Before);
         L.Reset (Self.Session.all);
         Answer := Null_Unbounded_String;
         Status := E.Make (E.Internal_Unexpected_Exception);
   end Work_On;

   -------------
   -- Profile --
   -------------

   overriding function Profile
     (Self : Session_Agent) return Model_Runner.Framework.Context.Model_Profile
   is
      Path : constant String := T.To_String (Self.Item.Model_Path);
   begin
      return
        (Id             => To_Unbounded_String
                             (if Path = "" then "session"
                              else Ada.Directories.Simple_Name (Path)),
         Provider       => To_Unbounded_String ("model_runner"),
         Context_Limit  => Positive'Max (1, L.Capacity (Self.Session.all)),
         Output_Reserve => Natural'Max (Self.Item.Max_Tokens, 1024),
         Tool_Overhead  =>
           Model_Runner.Framework.Context.Estimate (Offered_Text (null)) + 64,
         Tools          => True,
         Structured     => True,
         Reasoning      => Model_Runner.Templates."=" (Self.Item.Thinking,
                                                   Model_Runner.Templates.Thinking_On),
         Streaming      => True,
         Parallel_Calls => False,
         Resource_Class => To_Unbounded_String ("local"));
   end Profile;

   package Rs renames Model_Runner.Framework.Results;

   --  An issue's text with its own identifier where it says ID: it cannot
   --  hold that itself, as it is named by what it says.
   function With_Id (Id, Summary : String) return String is
      Mark : constant Natural := Ada.Strings.Fixed.Index (Summary, "result dismiss ID");
   begin
      return (if Mark = 0 then Summary
              else Summary (Summary'First .. Mark + 14) & Id
                   & With_Id (Id, Summary (Mark + 17 .. Summary'Last)));
   end With_Id;

   --  What a person dismissed: result dismiss ID.
   function Dismissed_List (Store : S.Store) return Names.Vector is
      Kept : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "dismissed");
      Result : Names.Vector;
      File   : Ada.Text_IO.File_Type;
   begin
      if Ada.Directories.Exists (Kept) then
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Kept);
         while not Ada.Text_IO.End_Of_File (File) loop
            Result.Append (Ada.Text_IO.Get_Line (File));
         end loop;
         Ada.Text_IO.Close (File);
      end if;
      return Result;
   end Dismissed_List;

   --  Whether an issue has been acted on, or no longer holds: not listed.
   function Acted_On (Store : S.Store; Issue_Id, Summary : String) return Boolean is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Summary, ": ");
      Named : constant String :=
        (if Colon > Summary'First then Summary (Summary'First .. Colon - 1) else "");
      Kind  : constant Nt.Intent_Kind :=
        (if Ada.Strings.Fixed.Index (Named, "DEC-") = Named'First then Nt.Decision
         elsif Ada.Strings.Fixed.Index (Named, "SPEC-") = Named'First then Nt.Specification
         else Nt.Requirement);
      --  An issue bootstrap raised about a line of a document
      --  -- an entry it still names, criteria before any
      --  requirement -- which the document no longer holds.
      function Document_Dropped return Boolean is
         Issue : Rs.Result;
         Got   : E.Error_Info;
      begin
         Rs.Read (Store, Issue_Id, Issue, Got);
         if E.Is_Error (Got) or else To_String (Issue.Producer) /= "bootstrap"
           or else Ada.Strings.Unbounded.Index (Issue.Provenance, "#") = 0
           or else (Ada.Strings.Fixed.Index (Summary, " still says ") = 0
                    and then Ada.Strings.Fixed.Index (Summary, ", which the project already has") = 0
                    and then Summary /= "acceptance criteria before any requirement")
         then
            return False;
         end if;
         declare
            Mark   : constant Natural := Ada.Strings.Unbounded.Index (Issue.Provenance, "#");
            Path   : constant String := Slice (Issue.Provenance, 1, Mark - 1);
            --  What it says: its identifier, or its words' first line --
            --  a SHALL line has no identifier of its own.
            Words  : constant Names.Vector :=
              Model_Runner.Framework.Lines_Of (To_String (Issue.Payload));
            Said   : constant String :=
              (if Words.Is_Empty then ""
               else Ada.Strings.Fixed.Trim (Words.First_Element, Ada.Strings.Both));
            Needle : constant String :=
              (if Ada.Strings.Fixed.Index (Summary, " still says ") > 0
                  or else Ada.Strings.Fixed.Index (Summary, ", which the project already has") > 0
               then Slice (Issue.Provenance, Mark + 1, Length (Issue.Provenance))
               else Said);
            By_Id  : constant Boolean :=
              (for some Prefix of Names.Vector'(["REQ-", "DEC-", "SPEC-"]) =>
                 Ada.Strings.Fixed.Index (Needle, Prefix) = Needle'First);
            Whole  : constant String :=
              Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), Path);
            File   : Ada.Text_IO.File_Type;
            Found  : Boolean := False;
            --  Criteria after a requirement are its own now.
            Stated : Boolean := False;
            Before : constant Boolean :=
              Summary = "acceptance criteria before any requirement";
         begin
            if Needle = "" then
               return False;
            elsif not Ada.Directories.Exists (Whole) then
               return True;
            end if;
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Whole);
            while not Found and then not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Line : constant String := Ada.Text_IO.Get_Line (File);
               begin
                  --  An entry the document names by its identifier is said
                  --  while the identifier is; one it gives by a line alone,
                  --  while that line is.
                  Found := (Ada.Strings.Fixed.Index (Line, Needle) > 0
                            or else (not Before and then Said /= "" and then not By_Id
                                     and then Ada.Strings.Fixed.Index (Line, Said) > 0))
                    and then not (Before and then Stated);
                  Stated := Stated or else Ada.Strings.Fixed.Index (Line, "REQ-") > 0;
               end;
            end loop;
            Ada.Text_IO.Close (File);
            return not Found;
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               return False;
         end;
      end Document_Dropped;
   begin
      if Ada.Strings.Fixed.Index (Summary, "output of ") = Summary'First then
         return True;
      end if;
      --  A call's failure, or what an agent reported, on work since done:
      --  the work that followed dealt with it.
      declare
         Space : constant Natural := Ada.Strings.Fixed.Index (Summary, " ");
         Call  : constant String :=
           (if Space > Summary'First then Summary (Summary'First .. Space - 1) else "");
         Held  : R.Item;
         Got   : E.Error_Info;
      begin
         if Ada.Strings.Fixed.Index (Call, "INV-") = Call'First
           and then Ada.Strings.Fixed.Index (Summary, " failed: ") = Space
         then
            S.Read (Store, Model_Runner.Framework.Invocations_Area, Call, Held, Got);
            if E.Is_Ok (Got) and then R.Get (Held, "task") /= ""
              and then Tk.State_Of (Store, R.Get (Held, "task")) = "complete"
            then
               return True;
            end if;
         end if;
      end;
      if Document_Dropped then
         return True;
      end if;
      --  A document's words a register did not hold, which it
      --  now does.
      declare
         Mark : constant Natural := Ada.Strings.Fixed.Index (Summary, " now says what ");
      begin
         if Mark > 0 then
            declare
               Rest  : constant String := Summary (Mark + 15 .. Summary'Last);
               Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
               Entry_Id : constant String :=
                 (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
               Of_Kind : constant Nt.Intent_Kind :=
                 (if Ada.Strings.Fixed.Index (Entry_Id, "DEC-") = Entry_Id'First then Nt.Decision
                  elsif Ada.Strings.Fixed.Index (Entry_Id, "SPEC-") = Entry_Id'First
                  then Nt.Specification
                  else Nt.Requirement);
               Held   : Nt.Entity;
               Got    : E.Error_Info;
               Issue  : Rs.Result;

               --  A later issue says what the document says now:
               --  this one is behind it.
               function Overtaken return Boolean is
               begin
                  for Other_Name of S.Names (Store, Model_Runner.Framework.Results_Area)
                  loop
                     declare
                        Other_Id : constant String :=
                          (if Other_Name'Length > 4
                             and then Other_Name (Other_Name'Last - 3 .. Other_Name'Last)
                                      = ".rec"
                           then Other_Name (Other_Name'First .. Other_Name'Last - 4)
                           else Other_Name);
                        Other : Rs.Result;
                        Read  : E.Error_Info;
                     begin
                        if Other_Id /= Issue_Id then
                           Rs.Read (Store, Other_Id, Other, Read, With_Payload => False);
                           if E.Is_Ok (Read)
                             and then Ada.Strings.Fixed.Index
                                        (To_String (Other.Summary),
                                         " now says what " & Entry_Id & " ") > 0
                             and then Other.Created_At > Issue.Created_At
                           then
                              return True;
                           end if;
                        end if;
                     end;
                  end loop;
                  return False;
               end Overtaken;
            begin
               Nt.Read (Store, Of_Kind, Entry_Id, Held, Got);
               Rs.Read (Store, Issue_Id, Issue, Got);
               if E.Is_Ok (Got) and then Overtaken then
                  return True;
               end if;
               return E.Is_Ok (Got)
                 and then (To_String (Held.State) in "obsolete" | "superseded" | "rejected"
                           or else Names."="
                                     (Model_Runner.Framework.Lines_Of (To_String (Held.Text)),
                                      Model_Runner.Framework.Lines_Of
                                        (To_String (Issue.Payload))));
            end;
         end if;
      end;
      return Named /= "" and then Ada.Strings.Fixed.Index (Named, " ") = 0
        and then Nt.State_Of (Store, Kind, Named)
                   in "rejected" | "obsolete" | "superseded";
   end Acted_On;

   ---------
   -- Run --
   ---------

   overriding procedure Run
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info) is
   begin
      Work_On (Self, Prompt_Path, Project, null, Answer, Status);
   end Run;

   -------------------
   -- Run_Parenting --
   -------------------

   overriding procedure Run_Parenting
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Children    : in out Model_Runner.Framework.Work.Child_Host'Class;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info) is
   begin
      Work_On (Self, Prompt_Path, Project, Children'Unchecked_Access, Answer, Status);
   end Run_Parenting;

   ------------------
   -- Recover_Here --
   ------------------

   procedure Recover_Here (Screen : in out Model_Runner.Presentation.Console) is
      Store  : S.Store;
      Report : S.Recovery_Report;
      Status : E.Error_Info;
      Said   : Names.Vector;
   begin
      if not S.Is_Initialized (Here) then
         return;
      end if;
      S.Open (Store, Here, Report, Status);
      if E.Is_Ok (Status) then
         Model_Runner.Framework.Work.Recover_On_Opening (Store, Report, Said, Status);
      end if;
      if E.Is_Error (Status) then
         Pres.Report (Screen, Status);
      end if;
      for Line of Said loop
         Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
      end loop;
      S.Close (Store);
   end Recover_Here;

   ------------------------
   -- Is_Project_Command --
   ------------------------

   function Is_Project_Command (Word : String) return Boolean
   is (for some Known of Words => Known.all = Word);

   ----------
   -- Help --
   ----------

   procedure Help (Screen : in out Model_Runner.Presentation.Console) is
   begin
      --  One key each, spelled out, so the catalog's readers can be found.
      Pres.Put_Aside (Screen, "cli.interactive.help.init");
      Pres.Put_Aside (Screen, "cli.interactive.help.bootstrap");
      Pres.Put_Aside (Screen, "cli.interactive.help.state");
      Pres.Put_Aside (Screen, "cli.interactive.help.config");
      Pres.Put_Aside (Screen, "cli.interactive.help.git");
      Pres.Put_Aside (Screen, "cli.interactive.help.sandbox");
      Pres.Put_Aside (Screen, "cli.interactive.help.instruct");
      Pres.Put_Aside (Screen, "cli.interactive.help.reconfigure");
      Pres.Put_Aside (Screen, "cli.interactive.help.task");
      Pres.Put_Aside (Screen, "cli.interactive.help.accept");
      Pres.Put_Aside (Screen, "cli.interactive.help.reject");
      Pres.Put_Aside (Screen, "cli.interactive.help.work");
      Pres.Put_Aside (Screen, "cli.interactive.help.cancel");
      Pres.Put_Aside (Screen, "cli.interactive.help.check");
      Pres.Put_Aside (Screen, "cli.interactive.help.req");
      Pres.Put_Aside (Screen, "cli.interactive.help.decision");
      Pres.Put_Aside (Screen, "cli.interactive.help.spec");
      Pres.Put_Aside (Screen, "cli.interactive.help.result");
      Pres.Put_Aside (Screen, "cli.interactive.help.tree");
      Pres.Put_Aside (Screen, "cli.interactive.help.sym");
      Pres.Put_Aside (Screen, "cli.interactive.help.refs");
      Pres.Put_Aside (Screen, "cli.interactive.help.deps");
      Pres.Put_Aside (Screen, "cli.interactive.help.users");
      Pres.Put_Aside (Screen, "cli.interactive.help.impact");
      Pres.Put_Aside (Screen, "cli.interactive.help.trace");
   end Help;

   --  Whether a line leaves a quote open: the rest of it taken as quoted.
   Left_Open : Boolean := False;

   --  The words of a line, with a quoted stretch kept whole.
   function Split (Line : String) return Names.Vector is
      Result  : Names.Vector;
      Current : Unbounded_String;
      Quoted  : Boolean := False;
      Started : Boolean := False;
      Escape  : Boolean := False;

      --  Within single quotes, which open a word or a value after =, as a
      --  shell has them: every character is itself, double quotes too. An
      --  apostrophe inside a word is only an apostrophe, and so is one
      --  inside the quotes that a letter follows: the program's name.
      Single  : Boolean := False;
   begin
      for Index in Line'Range loop
         declare
            Char : constant Character := Line (Index);
         begin
            if Single then
               if Char = ''' and then (Index = Line'Last or else Line (Index + 1) in ' ' | ASCII.HT) then
                  Single := False;
               else
                  Append (Current, Char);
               end if;
               Started := True;
            elsif Char = ''' and then not Quoted and then not Escape
              and then (not Started
                        or else (Length (Current) > 0 and then Element (Current, Length (Current)) = '='))
            then
               Single := True;
               Started := True;

            --  A quote or a backslash after a backslash is itself.
            elsif Escape then
               if Char not in '"' | '\' | ''' then
                  Append (Current, '\');
               end if;
               Append (Current, Char);
               Started := True;
               Escape := False;
            elsif Char = '\' then
               Escape := True;
            elsif Char = '"' then
               Quoted := not Quoted;
               Started := True;
            elsif Char in ' ' | ASCII.HT and then not Quoted then
               if Started then
                  Result.Append (To_String (Current));
                  Current := Null_Unbounded_String;
                  Started := False;
               end if;
            else
               Append (Current, Char);
               Started := True;
            end if;
         end;
      end loop;
      if Escape then
         Append (Current, '\');
         Started := True;
      end if;
      if Started then
         Result.Append (To_String (Current));
      end if;
      Left_Open := Quoted or else Single;
      return Result;
   end Split;

   --  Whether a word gives an input or a field, as NAME=VALUE.
   function Is_Setting (Word : String) return Boolean is
      Equal : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
   begin
      return Equal > Word'First
        and then (for all C of Word (Word'First .. Equal - 1) =>
                    C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '+' | '-');
   end Is_Setting;

   ---------
   -- Run --
   ---------

   procedure Run
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class)
   is
      All_Words  : constant Names.Vector := Split (Line);
      Open_Quote : constant Boolean := Left_Open;
      Word       : constant String := All_Words.First_Element;
      Positional : Names.Vector;
      Command    : Opt.Command;
      Status     : Natural;
      Outcome    : E.Error_Info;

      function Argument (Index : Positive) return String
      is (if Natural (Positional.Length) >= Index then Positional (Index) else "");

      --  The positional words from one on, joined: a title may have spaces.
      function Rest (From : Positive) return String is
         Text : Unbounded_String;
      begin
         for Index in From .. Natural (Positional.Length) loop
            Append (Text, (if Index = From then "" else " ") & Positional (Index));
         end loop;
         return To_String (Text);
      end Rest;

      procedure Field (Name, Value : String) is
      begin
         Pres.Put_Message
           (Screen, "cli.task.field", [Loc.Named ("name", Name), Loc.Named ("value", Value)]);
      end Field;

      --  Open the project, or say there is none.
      procedure With_Store (Act : not null access procedure (Store : in out S.Store)) is
         Store  : S.Store;
         Report : S.Recovery_Report;
      begin
         S.Open (Store, Here, Report, Outcome);

         --  Held by a run in progress, what only looks can still look.
         if E."=" (Outcome.Code, E.Framework_Locked)
           and then (Word in "/state" | "/config" | "/result"
                     or else (Word in "/req" | "/decision" | "/spec"
                              and then Argument (1) not in "new" | "accept" | "reject"
                                 | "reconsider" | "obsolete" | "block" | "unblock" | "revise"
                                 | "link" | "supersede" | "govern" | "move"))
         then
            S.Open_To_Read (Store, Here, Outcome);
            if E.Is_Ok (Outcome) then
               Pres.Put_Note (Screen, "cli.project.read_only");
            end if;
         end if;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;
         Act (Store);
         S.Close (Store);
      end With_Store;

      procedure State (Store : in out S.Store) is
         Config : R.Item;
         Read   : E.Error_Info;

         procedure Line_Of (Key : String; Value : String) is
         begin
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", Pres.Message_Value (Screen, Key)),
                Loc.Named ("value", Value)]);
         end Line_Of;

         function Count (State_Name : String) return String
         is (Image (Natural (Tk.List (Store, State_Name).Length)));

         --  The tasks in a state that needs a person, each with why.
         procedure Which (State_Name : String) is
         begin
            for Id of Tk.List (Store, State_Name) loop
               declare
                  Reasons : constant Names.Vector := Tk.Ready (Store, Id).Reasons;
               begin
                  Pres.Put_Message
                    (Screen, "cli.project.which",
                     [Loc.Named ("name", Id),
                      Loc.Named ("value", (if Reasons.Is_Empty then State_Name
                                           else Reasons.First_Element))]);
               end;
            end loop;
         end Which;

         Ready : Natural := 0;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         Line_Of ("cli.project.template", R.Get (Config, "template_id"));
         Line_Of ("cli.project.configuration", Image (R.Revision (Config)));
         --  Requirements that still stand: none rejected, retired or
         --  replaced; those waiting to be decided counted apart.
         declare
            Standing : Natural := 0;
         begin
            for Id of Nt.List (Store, Nt.Requirement) loop
               declare
                  Held : Nt.Entity;
                  Got  : E.Error_Info;
               begin
                  Nt.Read (Store, Nt.Requirement, Id, Held, Got);
                  if E.Is_Ok (Got)
                    and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                  then
                     Standing := Standing + 1;
                  end if;
               end;
            end loop;
            Line_Of ("cli.project.requirements", Image (Standing));
         end;
         Line_Of ("cli.project.candidate_requirements",
                  Image (Natural (Nt.List (Store, Nt.Requirement,
                                           Nt.First_State (Nt.Requirement)).Length)));
         Line_Of ("cli.project.verified",
                  Image (Natural (Nt.List (Store, Nt.Requirement, "verified").Length)));
         --  Done and not verified: each, and how it is.
         for Id of Nt.List (Store, Nt.Requirement, "implemented") loop
            Pres.Put_Note (Screen, "cli.project.not_verified",
                           [Loc.Named ("name", Id),
                            Loc.Named ("detail",
                                       (if Vf.Why_Not_Verified (Store, Id) = ""
                                        then "its evidence holds; check " & Id & " records it verified"
                                        else Vf.Why_Not_Verified (Store, Id)))]);
         end loop;
         --  Recorded verified, and its evidence no longer holds: said, not
         --  counted on until it is judged again.
         for Id of Nt.List (Store, Nt.Requirement, "verified") loop
            declare
               Why : constant String := Vf.Why_Not_Verified (Store, Id);
            begin
               if Why /= "" then
                  Pres.Put_Note (Screen, "cli.project.stale_verified",
                                 [Loc.Named ("name", Id), Loc.Named ("detail", Why)]);
               end if;
            end;
         end loop;
         --  Accepted, and nothing open or done serves it: no work will
         --  carry it out unless some is made.
         for Id of Nt.List (Store, Nt.Requirement, "accepted") loop
            declare
               Served : Boolean := False;
            begin
               for Task_Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Task_Id, Defined, Got);
                     Served := Served
                       or else (E.Is_Ok (Got)
                                and then Tk.State_Of (Store, Task_Id) not in "cancelled" | "rejected"
                                and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                                           .Contains (Id));
                  end;
               end loop;
               if not Served then
                  Pres.Put_Note (Screen, "cli.project.unserved", [Loc.Named ("name", Id)]);
               end if;
            end;
         end loop;
         for Id of Tk.List (Store, "accepted") loop
            if Tk.Ready (Store, Id).Ready then
               Ready := Ready + 1;
            end if;
         end loop;
         Line_Of ("cli.project.candidates", Count ("candidate"));
         Line_Of ("cli.project.accepted", Count ("accepted"));
         Line_Of ("cli.project.ready", Image (Ready));
         --  Accepted and not ready: each, with what it waits for -- a task,
         --  or a requirement since retired.
         if Natural (Tk.List (Store, "accepted").Length) > Ready then
            Line_Of ("cli.project.waiting", Image (Natural (Tk.List (Store, "accepted").Length) - Ready));
            for Id of Tk.List (Store, "accepted") loop
               declare
                  Now : constant Tk.Readiness := Tk.Ready (Store, Id);
               begin
                  if not Now.Ready then
                     Pres.Put_Message
                       (Screen, "cli.project.which",
                        [Loc.Named ("name", Id),
                         Loc.Named ("value", (if Now.Reasons.Is_Empty then "waiting"
                                              else Now.Reasons.First_Element))]);
                  end if;
               end;
            end loop;
         end if;
         --  Work a person takes in: each, with how.
         declare
            Waiting : Names.Vector;
         begin
            for Id of Tk.List (Store, "verification") loop
               if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
                  Waiting.Append (Id);
               end if;
            end loop;
            if not Waiting.Is_Empty then
               Line_Of ("cli.project.to_integrate", Image (Natural (Waiting.Length)));
               for Id of Waiting loop
                  Pres.Put_Message
                    (Screen, "cli.project.which",
                     [Loc.Named ("name", Id),
                      Loc.Named ("value", Tk.Ready (Store, Id).Reasons.First_Element)]);
               end loop;
            end if;
         end;
         Line_Of ("cli.project.blocked", Count ("blocked"));
         Which ("blocked");
         Line_Of ("cli.project.running", Count ("running"));
         Line_Of ("cli.project.complete", Count ("complete"));
         Line_Of ("cli.project.failed", Count ("failed"));
         Which ("failed");
         declare
            Last : constant Names.Vector :=
              S.Names (Store, Model_Runner.Framework.Verification_Area);
            Held : R.Item;
         begin
            if not Last.Is_Empty then
               S.Read (Store, Model_Runner.Framework.Verification_Area,
                       Last.Last_Element, Held, Read);
               Line_Of ("cli.project.last_check",
                        Last.Last_Element & " "
                        & (if R.Get (Held, "passed") = "true" then "PASS" else "FAIL"));
            end if;
         end;
         Line_Of ("cli.project.agents_active",
                  Image (Model_Runner.Framework.Agents.Active_Count (Store)));
         --  What waits on a person besides tasks: issues not yet dealt
         --  with, and what does not hold together.
         declare
            Dismissed : constant Names.Vector := Dismissed_List (Store);
            Open      : Natural := 0;
            Counted   : Names.Vector;
         begin
            for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
               declare
                  Result_Id : constant String :=
                    (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                     then Name (Name'First .. Name'Last - 4) else Name);
                  One       : Rs.Result;
                  Got       : E.Error_Info;
               begin
                  Rs.Read (Store, Result_Id, One, Got);
                  if E.Is_Ok (Got) and then Rs."=" (One.Kind, Rs.Diagnostic)
                    and then not Dismissed.Contains (Result_Id)
                    and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                    and then not Counted.Contains
                                   (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
                  then
                     Counted.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                     Open := Open + 1;
                  end if;
               end;
            end loop;
            Line_Of ("cli.project.open_issues", Image (Open));
            Line_Of ("cli.project.inconsistent",
                     Image (Model_Runner.Framework.Consistency.Length
                              (Model_Runner.Framework.Consistency.Check (Store))));
         end;
         declare
            --  The last run of every profile the full verification is made
            --  of, or of the default where it names none: all passed, or
            --  not.
            Full   : Names.Vector := Model_Runner.Framework.Lines_Of (R.Get (Config, "list.verification.full"));
            Latest : Unbounded_String;
            Result : Unbounded_String;
         begin
            --  As /check full chooses it: a profile called full first.
            if R.Has (Config, "profile.full") then
               Full.Clear;
               Full.Append ("full");
            elsif Full.Is_Empty then
               Full.Append (R.Get (Config, "scalar.verification.default"));
            end if;
            for Name of S.Names (Store, Model_Runner.Framework.Verification_Area) loop
               declare
                  Held : R.Item;
               begin
                  S.Read (Store, Model_Runner.Framework.Verification_Area, Name, Held, Read);
                  --  A test is a profile that runs tests: a build in the
                  --  full verification is not one.
                  if E.Is_Ok (Read) and then Full.Contains (R.Get (Held, "profile"))
                    and then R.Get (Config, "scalar.profile_capability." & R.Get (Held, "profile"))
                             = "run_tests"
                  then
                     Latest := To_Unbounded_String (Name);
                     Result := To_Unbounded_String
                       (if R.Get (Held, "passed") = "true" then "PASS" else "FAIL");
                  end if;
               end;
            end loop;
            if Latest /= Null_Unbounded_String then
               Line_Of ("cli.project.last_full", To_String (Latest) & " " & To_String (Result));
            end if;
         end;
      end State;

      procedure Show_Config (Store : in out S.Store) is
         Config : R.Item;
         Read   : E.Error_Info;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         for Index in 1 .. R.Field_Count (Config) loop
            declare
               Name  : constant String := R.Field_Name (Config, Index);
               Value : constant String := R.Get (Config, Name);

               --  A set's items on one line a comma apart, as the other lines
               --  name several things; a list's -- commands, in order -- a line
               --  each.
               function Shown return String is
               begin
                  --  A permission granted with nothing more: said so, not a
                  --  bare colon.
                  if Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First and then Value = "" then
                     return "(granted, no limits)";
                  elsif not (Name'Length > 4 and then Name (Name'First .. Name'First + 3) in "set." | "list")
                  then
                     return Value;
                  end if;
                  declare
                     Result : Unbounded_String;
                     Start  : Positive := Value'First;
                  begin
                     for Index in Value'First .. Value'Last + 1 loop
                        if Index > Value'Last or else Value (Index) in ASCII.LF | ASCII.HT | ',' then
                           declare
                              Item : constant String :=
                                Ada.Strings.Fixed.Trim (Value (Start .. Index - 1), Ada.Strings.Both);
                           begin
                              if Item /= "" then
                                 Append (Result, (if Result = Null_Unbounded_String then ""
                                                  elsif Name (Name'First .. Name'First + 3) = "set."
                                                  then ", "
                                                  else [1 => ASCII.LF] & "") & Item);
                              end if;
                           end;
                           Start := Index + 1;
                        end if;
                     end loop;
                     return To_String (Result);
                  end;
               end Shown;
            begin
               --  Those NAME names, when one is given.
               if (Name'Length < 5 or else Name (Name'First .. Name'First + 4) /= "file.")
                 and then (Argument (1) = "" or else Ada.Strings.Fixed.Index (Name, Argument (1)) > 0)
               then
                  Field (Name, Shown);
               end if;
            end;
         end loop;

         --  The components tasks may name, however each was declared:
         --  listed in set.components or placed with map.component.
         if Argument (1) = "" or else Ada.Strings.Fixed.Index ("components", Argument (1)) > 0 then
            declare
               Named : Unbounded_String;
            begin
               for One of Tk.Components (Store) loop
                  Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & One);
               end loop;
               Field ("components (listed or placed)", To_String (Named));
               --  Open tasks that name a component the project no longer has.
               declare
                  Stray : Unbounded_String;
               begin
                  for Id of Tk.List (Store) loop
                     declare
                        Defined : R.Item;
                        Got     : E.Error_Info;
                     begin
                        Tk.Definition (Store, Id, Defined, Got);
                        if E.Is_Ok (Got) and then R.Get (Defined, "component") /= ""
                          and then not Tk.Components (Store).Contains (R.Get (Defined, "component"))
                          and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                        then
                           Append (Stray, (if Stray = Null_Unbounded_String then "" else ", ")
                                   & Id & " in " & R.Get (Defined, "component"));
                        end if;
                     end;
                  end loop;
                  if Stray /= Null_Unbounded_String then
                     Field ("tasks in no component of the project", To_String (Stray));
                  end if;
               end;
            end;
         end if;

         --  The project's permissions where the configuration says none:
         --  what agents are given all the same.
         if (Argument (1) = "" or else Ada.Strings.Fixed.Index ("map.permission.project", Argument (1)) > 0)
           and then not (for some Index in 1 .. R.Field_Count (Config) =>
                           Ada.Strings.Fixed.Index (R.Field_Name (Config, Index),
                                                    "map.permission.project") = 1)
         then
            declare
               Given : Unbounded_String;
            begin
               for Line of Model_Runner.Framework.Lines_Of
                 (Model_Runner.Framework.Permissions.Image
                    (Model_Runner.Framework.Permissions.Effective
                       (Store, "", "", Within_Sandbox => False)))
               loop
                  Append (Given, (if Given = Null_Unbounded_String then "" else "; ") & Line);
               end loop;
               Field ("map.permission.project", "(the default) " & To_String (Given));
            end;
         end if;

         --  Settings a name picks out that are not set: said so, as they
         --  mean something unset too.
         if Argument (1) /= "" then
            for Known of Model_Runner.Framework.Configurations.Known_Names loop
               if Ada.Strings.Fixed.Index (Known, Argument (1)) > 0 and then not R.Has (Config, Known)
               then
                  --  Not set, and what that means where the harness says.
                  declare
                     Defaults : constant Model_Runner.Framework.Agents.Limits :=
                       (others => <>);
                     Default  : constant String :=
                       (if Known = "scalar.agents.max_depth" then Image (Defaults.Max_Depth)
                        elsif Known = "scalar.agents.max_children" then Image (Defaults.Max_Children)
                        elsif Known = "scalar.agents.max_active" then Image (Defaults.Max_Active)
                        elsif Known = "scalar.agents.token_budget" then Image (Defaults.Token_Budget)
                        else "");
                  begin
                     Field (Known, (if Default = "" then "(not set: the harness's default)"
                                    else "(not set: " & Default & " by default)"));
                  end;
               end if;
            end loop;
            --  A name nothing holds: said, not answered with nothing.
            if not (for some Index in 1 .. R.Field_Count (Config) =>
                      Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Argument (1)) > 0)
              and then not (for some Known of Model_Runner.Framework.Configurations.Known_Names =>
                              Ada.Strings.Fixed.Index (Known, Argument (1)) > 0)
              and then Ada.Strings.Fixed.Index ("components", Argument (1)) = 0
              and then Ada.Strings.Fixed.Index ("map.permission.project", Argument (1)) = 0
            then
               Pres.Put_Message (Screen, "cli.project.config_none", [Loc.Named ("value", Argument (1))]);
            end if;
         end if;
      end Show_Config;

      procedure Show_Result (Store : in out S.Store) is
         package Rs renames Model_Runner.Framework.Results;
         Held  : Rs.Result;
         Read  : E.Error_Info;
         Size  : constant Natural := Rs.Payload_Size (Store, Argument (1));
         --  A large payload is read only when asked for: /result ID full.
         Whole : constant Boolean := Size <= Rs.Inline_Limit or else Argument (2) = "full";
         --  As the harness writes it: ag-000001 is AG-000001, and AG-1 is
         --  AG-000001 where its kind is numbered so.
         function Normalized (Given : String) return String is
            Upper : constant String := Ada.Characters.Handling.To_Upper (Given);
            Dash  : constant Natural := Ada.Strings.Fixed.Index (Upper, "-");
         begin
            if Dash = 0 or else Upper (Upper'First .. Dash - 1) not in "AG" | "INV" | "VER" | "RES" | "CTX"
            then
               return Given;
            end if;
            declare
               Rest : constant String := Upper (Dash + 1 .. Upper'Last);
            begin
               if Upper (Upper'First .. Dash - 1) in "AG" | "INV" | "VER"
                 and then Rest'Length in 1 .. 5 and then (for all C of Rest => C in '0' .. '9')
               then
                  return Upper (Upper'First .. Dash) & (1 .. 6 - Rest'Length => '0') & Rest;
               end if;
               return Upper;
            end;
         end Normalized;
         Id    : constant String := Normalized (Argument (1));

         --  Any identifier the harness prints: an invocation, a context's
         --  manifest, evidence or an agent is shown as it is recorded.
         function Starts (Prefix : String) return Boolean
         is (Id'Length > Prefix'Length and then Id (Id'First .. Id'First + Prefix'Length - 1) = Prefix);

         procedure Show_Record (Where : Model_Runner.Framework.Area; Name : String) is
            Value : R.Item;
         begin
            S.Read (Store, Where, Name, Value, Read);
            if E.Is_Error (Read) and then not S.Exists (Store, Where, Name) then
               --  Named as it was asked for, not as it is kept.
               Read := E.Make (E.Framework_Not_Found);
               E.Add_Text (Read, "name", Id);
            end if;
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
               return;
            end if;
            for Index in 1 .. R.Field_Count (Value) loop
               declare
                  Named : constant String := R.Field_Name (Value, Index);
               begin
                  --  A check's columns by what each is; other columns a tab
                  --  apart shown as columns.
                  if Named'Length > 6 and then Named (Named'First .. Named'First + 5) = "check."
                  then
                     declare
                        function Split_Cells (Text : String) return Names.Vector is
                           Result : Names.Vector;
                           Start  : Positive := Text'First;
                        begin
                           for Index in Text'First .. Text'Last + 1 loop
                              if Index > Text'Last or else Text (Index) = ASCII.HT then
                                 Result.Append (Ada.Strings.Fixed.Trim
                                                  (Text (Start .. Index - 1), Ada.Strings.Both));
                                 Start := Index + 1;
                              end if;
                           end loop;
                           return Result;
                        end Split_Cells;
                        Cells : constant Names.Vector := Split_Cells (R.Get (Value, Named));
                        function Cell (At_Index : Positive) return String
                        is (if Natural (Cells.Length) >= At_Index then Cells (At_Index) else "");
                     begin
                        Field (Named, Cell (1) & ": " & Cell (5)
                               & " (exit " & Cell (3)
                               & ", " & Cell (4) & " s, " & Cell (6)
                               & (if Cell (8) = "warning" then ", a warning" else "")
                               & (if Cell (9) not in "" | "1" then ", tries " & Cell (9) else "")
                               & ")" & (if Cell (7) = "" then "" else "; log " & Cell (7))
                               & (if Cell (2) = "" then "" else "; ran " & Cell (2)));
                     end;
                  elsif Named = "summary" and then R.Has (Value, "depth") and then R.Get (Value, Named) = ""
                  then
                     Field (Named, "(it gave none)");
                  elsif Named = "permissions" and then R.Has (Value, "depth") then
                     --  An agent's: a line each, and create_children said
                     --  spent where its depth leaves it none.
                     declare
                        Depth : constant Natural :=
                          Natural'Value ("0" & R.Get (Value, "depth"));
                        Shown : Unbounded_String;
                     begin
                        for Line of Model_Runner.Framework.Lines_Of (R.Get (Value, Named)) loop
                           declare
                              Mark  : constant Natural := Ada.Strings.Fixed.Index (Line, "max_depth=");
                              Limit : Natural := Natural'Last;
                              Stop  : Natural;
                           begin
                              if Ada.Strings.Fixed.Index (Line, "create_children") = Line'First
                                and then Mark > 0
                              then
                                 Stop := Mark + 10;
                                 while Stop <= Line'Last and then Line (Stop) in '0' .. '9' loop
                                    Stop := Stop + 1;
                                 end loop;
                                 if Stop > Mark + 10 then
                                    Limit := Natural'Value (Line (Mark + 10 .. Stop - 1));
                                 end if;
                              end if;
                              if Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) /= "" then
                                 Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ")
                                         & Line
                                         & (if Depth >= Limit then " (none at its depth)" else ""));
                              end if;
                           end;
                        end loop;
                        Field (Named, To_String (Shown));
                     end;
                  elsif Named not in "schema_id" | "schema_version" | "entity_id" | "revision" then
                     Field (Named, Ada.Strings.Fixed.Translate
                                     (R.Get (Value, Named),
                                      Ada.Strings.Maps.To_Mapping ([1 => ASCII.HT], " ")));
                  end if;
               end;
            end loop;
            --  An agent's two ends told apart where they differ.
            if R.Has (Value, "outcome") and then R.Has (Value, "state")
              and then R.Get (Value, "outcome") /= R.Get (Value, "state")
            then
               Field ("read as", "state is how its own run ended; outcome is where that left the task");
            end if;
         end Show_Record;
      begin
         --  result dismiss ID: an issue a person has taken as read leaves the
         --  listing; the result itself is kept.
         if Id = "dismiss" then
            declare
               Named   : constant String := Argument (2);
               Kept    : constant String :=
                 Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "dismissed");
               Got     : Rs.Result;
            begin
               Rs.Read (Store, Named, Got, Read, With_Payload => False);
               if Named = "" then
                  Outcome := E.Make (E.Framework_Input_Missing);
                  E.Add_Text (Outcome, "name", "the issue to dismiss: result dismiss RES-ID, as result"
                              & " lists them");
                  Pres.Report (Screen, Outcome);
                  return;
               elsif Dismissed_List (Store).Contains (Named) then
                  Pres.Put_Note (Screen, "cli.result.dismissed_already", [Loc.Named ("name", Named)]);
                  return;
               elsif Named /= ""
                 and then (E.Is_Ok (Read) or else Ada.Strings.Fixed.Index (Named, "-") > Named'First)
                 and then (E.Is_Error (Read) or else not Rs."=" (Got.Kind, Rs.Diagnostic))
                 and then Ada.Strings.Fixed.Index (Named, "RES-") /= Named'First
               then
                  --  Something else the harness names: not an issue.
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "the issue to dismiss");
                  E.Add_Text (Outcome, "value", Named);
                  E.Add_Text (Outcome, "detail", Named & " is not an issue; result lists the issues");
                  Pres.Report (Screen, Outcome);
                  return;
               elsif Named = "" or else E.Is_Error (Read) then
                  Outcome := E.Make (E.Framework_Not_Found);
                  E.Add_Text (Outcome, "name", (if Named = "" then "the issue to dismiss" else Named));
                  Pres.Report (Screen, Outcome);
                  return;
               end if;
               declare
                  File : Ada.Text_IO.File_Type;
               begin
                  if Ada.Directories.Exists (Kept) then
                     Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Kept);
                  else
                     Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
                  end if;
                  Ada.Text_IO.Put_Line (File, Named);
                  Ada.Text_IO.Close (File);
               end;
               Pres.Put_Message (Screen, "cli.result.dismissed", [Loc.Named ("name", Named)]);
            end;
            return;
         end if;

         if Id = "" then
            --  None named: the issues kept -- what bootstrap raised, what
            --  agents reported -- each by its identifier and what it says;
            --  not a command's output, which its evidence shows, and not
            --  one about an entry since retired or replaced: acted on.
            declare
               Shown : Natural := 0;
               Said_Before : Names.Vector;

               Dismissed : constant Names.Vector := Dismissed_List (Store);
            begin
               for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
                  declare
                     Result_Id : constant String :=
                       (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                        then Name (Name'First .. Name'Last - 4) else Name);
                     One       : Rs.Result;
                     Got       : E.Error_Info;
                  begin
                     Rs.Read (Store, Result_Id, One, Got);
                     if E.Is_Ok (Got) and then Rs."=" (One.Kind, Rs.Diagnostic)
                       and then not Dismissed.Contains (Result_Id)
                       and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                       --  Said the same, in the same words, once: two attempts
                       --  that report one thing are one issue here.
                       and then not Said_Before.Contains
                                      (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
                     then
                        Said_Before.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                        Field (Result_Id, With_Id (Result_Id, To_String (One.Summary)));
                        Shown := Shown + 1;
                     end if;
                  end;
               end loop;
               if Shown = 0 then
                  Pres.Put_Message (Screen, "cli.result.none");
               end if;
            end;
            return;
         elsif (Starts ("TASK-") and then Tk.State_Of (Store, Id) = "")
           or else (Starts ("REQ-") and then Nt.State_Of (Store, Nt.Requirement, Id) = "")
           or else (Starts ("DEC-") and then Nt.State_Of (Store, Nt.Decision, Id) = "")
           or else (Starts ("SPEC-") and then Nt.State_Of (Store, Nt.Specification, Id) = "")
         then
            Read := E.Make (E.Framework_Not_Found);
            E.Add_Text (Read, "name", Id);
            Pres.Report (Screen, Read);
            return;
         elsif Starts ("TASK-") or else Starts ("REQ-") or else Starts ("DEC-") or else Starts ("SPEC-")
         then
            Pres.Put_Note
              (Screen, "cli.result.elsewhere",
               [Loc.Named ("name", Id),
                Loc.Named ("value", (if Starts ("TASK-") then "task show " & Id & " and task audit " & Id
                                     elsif Starts ("REQ-") then "req " & Id
                                     elsif Starts ("DEC-") then "decision " & Id
                                     else "spec " & Id))]);
            return;
         elsif Starts ("INV-") then
            Show_Record (Model_Runner.Framework.Invocations_Area, Id);
            return;
         elsif Starts ("CTX-") then
            Show_Record (Model_Runner.Framework.Invocations_Area, "manifest." & Id);
            return;
         elsif Starts ("VER-") then
            Show_Record (Model_Runner.Framework.Verification_Area, Id);
            return;
         elsif Starts ("AG-") then
            Show_Record (Model_Runner.Framework.Runtime_Area, "agent." & Id);
            return;
         end if;
         Rs.Read (Store, Id, Held, Read, With_Payload => Whole);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         Field ("kind", Rs.Kind_Word (Held.Kind));
         Field ("producer", To_String (Held.Producer));
         Field ("created_at", To_String (Held.Created_At));
         Field ("summary", With_Id (Id, To_String (Held.Summary)));
         Field ("provenance", To_String (Held.Provenance));
         if Dismissed_List (Store).Contains (Id) then
            Field ("dismissed", "yes: result no longer lists it");
         end if;
         for Other of Model_Runner.Framework.Lines_Of (To_String (Held.References)) loop
            Field ("references", Other);
         end loop;
         --  Whole, as it is: a line at a time, not cut to fit a message.
         if Whole and then Pres.Is_Structured (Screen) then
            Field ("payload", To_String (Held.Payload));
         elsif Whole then
            Field ("payload", "");
            for Line of Model_Runner.Framework.Lines_Of (To_String (Held.Payload)) loop
               Pres.Put_Line (Screen, "    " & Line);
            end loop;
         else
            Field ("payload", "(" & Image (Size) & " bytes; /result " & Argument (1)
                   & " full shows them)");
         end if;
      end Show_Result;

      --  The project's verification, now, for no task in particular.
      procedure Check (Store : in out S.Store) is
         Config   : R.Item;
         Read     : E.Error_Info;
         Change   : S.Transaction;
      begin
         --  A requirement: the tasks serving it verified again, the
         --  requirement itself where the project has a profile for that,
         --  and where it stands then -- with what it still lacks.
         if Argument (1)'Length > 4
           and then Argument (1) (Argument (1)'First .. Argument (1)'First + 3) = "REQ-"
         then
            declare
               package Vf renames Model_Runner.Framework.Verification;
               package Tk renames Model_Runner.Framework.Tasks;
               Requirement : constant String := Argument (1);
               Held        : Model_Runner.Framework.Intent.Entity;
               Got         : E.Error_Info;
               Evidence    : Unbounded_String;
               Passed      : Boolean;
               Changed     : Names.Vector;
               Failing     : Names.Vector;
            begin
               Model_Runner.Framework.Intent.Read
                 (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Got);
               if E.Is_Error (Got) then
                  Pres.Report (Screen, Got);
                  return;
               end if;
               --  Retired: nothing to verify, and its replacement named.
               if To_String (Held.State) in "obsolete" | "rejected" | "superseded" then
                  Got := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Got, "name", "the requirement to check");
                  E.Add_Text (Got, "value", Requirement);
                  E.Add_Text (Got, "detail", Requirement & " is " & To_String (Held.State)
                              & (if Held.Superseded_By /= Null_Unbounded_String
                                 then ", replaced by " & To_String (Held.Superseded_By) & ": check "
                                      & To_String (Held.Superseded_By) & " verifies that one"
                                 else ", and what is retired is not verified"));
                  Pres.Report (Screen, Got);
                  return;
               end if;
               for Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                  begin
                     Tk.Definition (Store, Id, Defined, Got);
                     if E.Is_Ok (Got)
                       and then Model_Runner.Framework.Lines_Of
                                  (R.Get (Defined, "requirements")).Contains (Requirement)
                       and then Tk.State_Of (Store, Id) = "complete"
                       and then Vf.Profile_Of (Store, Id) /= ""
                     then
                        Vf.Run_Profile (Store, Change, Vf.Profile_Of (Store, Id), Id, Evidence,
                                        Passed, Got);
                        if E.Is_Ok (Got) then
                           S.Commit (Store, Change, Got);
                           Field (Id, To_String (Evidence) & (if Passed then " passed" else " failed"));
                           if not Passed then
                              Failing.Append (To_String (Evidence));
                           end if;
                        end if;
                     end if;
                  end;
               end loop;
               Vf.Verify_Requirement (Store, Change, Requirement, Evidence, Passed, Got);
               if E.Is_Ok (Got) then
                  S.Commit (Store, Change, Got);
                  Field (Requirement, To_String (Evidence) & (if Passed then " passed" else " failed"));
                  if not Passed then
                     Failing.Append (To_String (Evidence));
                  end if;
               end if;
               Change := S.No_Changes;
               Vf.Reevaluate_Requirements (Store, Change, Changed, Got);
               S.Commit (Store, Change, Got);
               Model_Runner.Framework.Intent.Read
                 (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Got);
               Field ("state", To_String (Held.State));
               if To_String (Held.State) /= "verified" then
                  Field ("not verified", Vf.Why_Not_Verified (Store, Requirement));
               end if;
               --  The others the checks moved, each named as what it is: a
               --  side effect of the same evidence, not what was asked.
               for Other of Changed loop
                  if Other /= Requirement then
                     Pres.Put_Note
                       (Screen, "cli.work.requirement_also",
                        [Loc.Named ("name", Other),
                         Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Other))]);
                  end if;
               end loop;
               --  Not verified is what was asked not holding: a failure, as a
               --  check that did not pass is.
               if To_String (Held.State) /= "verified" and then Failing.Is_Empty then
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                  begin
                     E.Add_Text (Failed, "name", Requirement);
                     E.Add_Text (Failed, "detail", "it is " & To_String (Held.State) & ", not verified");
                     Pres.Report (Screen, Failed);
                  end;
               end if;

               --  Checks that did not pass: a failure, with why.
               for Evidence_Id of Failing loop
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                     Why    : Unbounded_String;
                  begin
                     for Line of Vf.Why_Failed (Store, Evidence_Id) loop
                        Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Line);
                     end loop;
                     E.Add_Text (Failed, "name", Evidence_Id);
                     E.Add_Text (Failed, "detail", To_String (Why));
                     Pres.Report (Screen, Failed);
                  end;
               end loop;
            end;
            return;
         end if;

         --  The state itself, not the project's files: what does not hold
         --  together, found without a model.
         if Argument (1) = "consistency" and then Argument (2) /= "" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "check consistency");
            E.Add_Text (Outcome, "value", Argument (2));
            E.Add_Text (Outcome, "detail", "it only lists what does not hold together; nothing"
                        & " follows it");
            Pres.Report (Screen, Outcome);
            return;
         elsif Argument (1) = "consistency" then
            declare
               package Cs renames Model_Runner.Framework.Consistency;
               Found : constant Cs.Finding_List := Cs.Check (Store);
            begin
               for Index in 1 .. Cs.Length (Found) loop
                  Pres.Put_Message
                    (Screen, "cli.task.item",
                     [Loc.Named ("name", To_String (Cs.Element (Found, Index).Subject)),
                      Loc.Named ("value", Cs.Kind_Word (Cs.Element (Found, Index).Kind)),
                      Loc.Named ("detail", To_String (Cs.Element (Found, Index).Detail))]);
               end loop;
               Pres.Put_Message
                 (Screen, "cli.project.consistency", [Loc.Named ("count", Image (Cs.Length (Found)))]);

               --  Something that does not hold together is a check that did
               --  not pass.
               if Cs.Length (Found) > 0 then
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                  begin
                     E.Add_Text (Failed, "name", "consistency");
                     E.Add_Text (Failed, "detail", "what does not hold together in the state, listed"
                                 & " above: " & Image (Cs.Length (Found)));
                     Pres.Report (Screen, Failed);
                  end;
               end if;
            end;
            return;
         end if;

         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         declare
            --  The profiles to run: the one named; for full, those the
            --  configuration's list verification.full names; otherwise the
            --  default.
            Profiles : Names.Vector;

            procedure Run_One (Profile : String) is
               Evidence : Unbounded_String;
               Passed   : Boolean;
            begin
               Vf.Run_Profile (Store, Change, Profile, "", Evidence, Passed, Outcome);
               if E.Is_Ok (Outcome) then
                  S.Commit (Store, Change, Outcome);
               end if;
               if E.Is_Error (Outcome) then
                  Pres.Report (Screen, Outcome);
                  return;
               end if;

               declare
                  Said : constant Vf.Diagnostic_List :=
                    Vf.Diagnostics_Of (Store, To_String (Evidence));
               begin
                  for Index in 1 .. Vf.Length (Said) loop
                     Pres.Put_Message
                       (Screen, "cli.task.diagnostic",
                        [Loc.Named ("path", To_String (Vf.Element (Said, Index).File) & ":"
                                    & Image (Vf.Element (Said, Index).Line)),
                         Loc.Named ("severity", To_String (Vf.Element (Said, Index).Severity)),
                         Loc.Named ("detail", To_String (Vf.Element (Said, Index).Message)
                                    & (if Length (Vf.Element (Said, Index).Code) = 0 then ""
                                       else " [" & To_String (Vf.Element (Said, Index).Code)
                                            & "]"))]);
                  end loop;
                  Pres.Put_Message
                    (Screen, "cli.task.verified",
                     [Loc.Named ("name", To_String (Evidence)),
                      Loc.Named ("value", (if Passed then "passed" else "failed")),
                      Loc.Named ("count", Image (Vf.Length
                                   (Vf.Parse_Profile (R.Get (Config, "profile." & Profile))))),
                      Loc.Named ("total", Image (Vf.Length (Said)))]);
               end;

               --  New evidence: the requirements are judged again, and said
               --  after what the checks found.
               declare
                  Changed : Names.Vector;
               begin
                  Vf.Reevaluate_Requirements (Store, Change, Changed, Outcome);
                  if E.Is_Ok (Outcome) then
                     S.Commit (Store, Change, Outcome);
                  end if;
                  for Requirement of Changed loop
                     Pres.Put_Message
                       (Screen, "cli.work.requirement",
                        [Loc.Named ("name", Requirement),
                         Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
                  end loop;
                  Outcome := E.Success;
               end;

               --  A profile that runs no tests, said so, with what does.
               --  Not when others that run them run with it.
               if R.Get (Config, "scalar.profile_capability." & Profile) /= "run_tests"
                 and then not (for some Other of Profiles =>
                                 R.Get (Config, "scalar.profile_capability." & Other) = "run_tests")
               then
                  Pres.Put_Note (Screen, "cli.check.no_tests", [Loc.Named ("name", Profile)]);
               end if;

               --  Not passed: a failure, with what failed and how it ended.
               if not Passed then
                  declare
                     Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
                     Why    : Unbounded_String;
                  begin
                     for Line of Vf.Why_Failed (Store, To_String (Evidence)) loop
                        Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Line);
                     end loop;
                     E.Add_Text (Failed, "name", To_String (Evidence));
                     E.Add_Text (Failed, "detail", To_String (Why));
                     Pres.Report (Screen, Failed);
                  end;
               end if;
            end Run_One;
         begin
            if Argument (1) = "full" and then not R.Has (Config, "profile.full") then
               for Name of Model_Runner.Framework.Lines_Of (R.Get (Config, "list.verification.full")) loop
                  if R.Has (Config, "profile." & Name) then
                     Profiles.Append (Name);
                  end if;
               end loop;
            elsif Argument (1) /= "" and then R.Has (Config, "profile." & Argument (1)) then
               Profiles.Append (Argument (1));
            elsif Argument (1) /= "" then
               --  Not one: said with those there are.
               declare
                  Named : Unbounded_String;
               begin
                  for Index in 1 .. R.Field_Count (Config) loop
                     declare
                        Field_Name : constant String := R.Field_Name (Config, Index);
                     begin
                        if Field_Name'Length > 8
                          and then Field_Name (Field_Name'First .. Field_Name'First + 7) = "profile."
                        then
                           Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                                   & Field_Name (Field_Name'First + 8 .. Field_Name'Last));
                        end if;
                     end;
                  end loop;
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "what to check");
                  E.Add_Text (Outcome, "value", Argument (1));
                  E.Add_Text (Outcome, "detail", "it is a profile (" & To_String (Named)
                              & "), full, consistency or a requirement");
                  Pres.Report (Screen, Outcome);
               end;
               return;
            end if;
            if Profiles.Is_Empty and then R.Get (Config, "scalar.verification.default") /= "" then
               Profiles.Append (R.Get (Config, "scalar.verification.default"));
            end if;
            if Profiles.Is_Empty then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "a verification profile");
               Pres.Report (Screen, Outcome);
               return;
            end if;
            --  A profile whose every check another in the list runs too is
            --  not run twice: what it would find, that one finds.
            declare
               function Checks_Of (Profile : String) return Names.Vector is
                  Result : Names.Vector;
                  Parsed : constant Vf.Check_List :=
                    Vf.Parse_Profile (R.Get (Config, "profile." & Profile));
               begin
                  for Index in 1 .. Vf.Length (Parsed) loop
                     Result.Append (To_String (Vf.Element (Parsed, Index).Command));
                  end loop;
                  return Result;
               end Checks_Of;

               Kept : Names.Vector;
            begin
               for Profile of Profiles loop
                  if Checks_Of (Profile).Is_Empty
                    or else not (for some Other of Profiles =>
                            Other /= Profile
                            and then (for all Command of Checks_Of (Profile) =>
                                        Checks_Of (Other).Contains (Command))
                            and then Natural (Checks_Of (Other).Length)
                                       > Natural (Checks_Of (Profile).Length))
                  then
                     Kept.Append (Profile);
                  end if;
               end loop;
               Profiles := Kept;
            end;
            for Profile of Profiles loop
               Run_One (Profile);
               exit when E.Is_Error (Outcome);
            end loop;
         end;
      end Check;

      --  Documents read for what the project must be: those named, or
      --  every Markdown file at the top and in docs.
      procedure Bootstrap (Store : in out S.Store) is
         Change : S.Transaction;
         Found  : Model_Runner.Framework.Bootstrap.Output_List;
         Report : Model_Runner.Framework.Bootstrap.Report;
         --  Each named as the project names it: ./docs/x.md and a whole
         --  path into the project are docs/x.md.
         --  A directory named is its Markdown files; one named twice is
         --  read once.
         function Named_Here return Names.Vector is
            Result : Names.Vector;
            procedure Add (One : String) is
            begin
               if not Result.Contains (One) then
                  Result.Append (One);
               end if;
            end Add;
         begin
            for Path of Positional loop
               declare
                  Here : constant String := Model_Runner.Framework.Repository.Relative_Path
                                              (Ada.Directories.Current_Directory, Path);
               begin
                  if Here /= "" and then Ada.Directories.Exists (Here)
                    and then Ada.Directories."=" (Ada.Directories.Kind (Here), Ada.Directories.Directory)
                  then
                     declare
                        Search : Ada.Directories.Search_Type;
                        One    : Ada.Directories.Directory_Entry_Type;
                        Base   : constant String :=
                          (if Here (Here'Last) = '/' then Here (Here'First .. Here'Last - 1) else Here);
                     begin
                        Ada.Directories.Start_Search
                          (Search, Here, "*.md", [Ada.Directories.Ordinary_File => True, others => False]);
                        while Ada.Directories.More_Entries (Search) loop
                           Ada.Directories.Get_Next_Entry (Search, One);
                           Add (Base & "/" & Ada.Directories.Simple_Name (One));
                        end loop;
                        Ada.Directories.End_Search (Search);
                     end;
                  else
                     Add (Here);
                  end if;
               end;
            end loop;
            return Result;
         end Named_Here;
         Named : constant Names.Vector := Named_Here;

         --  The documents named, or those the bootstrap policy reads.
         Files  : constant Names.Vector :=
           (if Positional.Is_Empty then Model_Runner.Framework.Bootstrap.Documents (Store)
            else Named);
      begin
         --  A document named is one within the project, outside its state,
         --  and there to be read: nothing is taken from one that is not.
         for Path of Named loop
            if Path = "" or else Path (Path'First) in '/' | '\'
              or else Ada.Strings.Fixed.Index (Path, "..") > 0
              or else Ada.Strings.Fixed.Index (Path, ".model_runner") > 0
              or else not Ada.Directories.Exists (Path)
              or else Ada.Directories."/=" (Ada.Directories.Kind (Path), Ada.Directories.Ordinary_File)
            then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "a document to read");
               E.Add_Text (Outcome, "value", Path);
               E.Add_Text (Outcome, "detail",
                           (if not Ada.Directories.Exists (Path) then "there is no such file"
                            else "it is not a file within the project, outside its state"));
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end loop;
         for Path of Files loop
            declare
               Scanned : constant Model_Runner.Framework.Bootstrap.Output_List :=
                 Model_Runner.Framework.Bootstrap.Scan (Path, Whole (Path));
            begin
               for Index in 1 .. Model_Runner.Framework.Bootstrap.Length (Scanned) loop
                  Model_Runner.Framework.Bootstrap.Append
                    (Found, Model_Runner.Framework.Bootstrap.Element (Scanned, Index));
               end loop;
            end;
         end loop;
         if Files.Is_Empty then
            Pres.Put_Note (Screen, "cli.next.no_documents");
            return;
         end if;
         Model_Runner.Framework.Bootstrap.Apply (Store, Change, Found, Report, Outcome);
         if E.Is_Ok (Outcome) then
            S.Commit (Store, Change, Outcome);
         end if;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.project.bootstrapped",
            [Loc.Named ("count", Image (Report.Created)),
             Loc.Named ("value", Image (Natural (Report.Revised.Length))),
             Loc.Named ("total", Image (Report.Existing)),
             Loc.Named ("extra", Image (Report.Issues))]);
         for Id of Report.Made loop
            --  Each with what it is now: a candidate waits to be accepted.
            declare
               Kind : constant Nt.Intent_Kind :=
                 (if Ada.Strings.Fixed.Index (Id, "DEC-") = 1 then Nt.Decision
                  elsif Ada.Strings.Fixed.Index (Id, "SPEC-") = 1 then Nt.Specification
                  else Nt.Requirement);
            begin
               Pres.Put_Message
                 (Screen, "cli.project.bootstrap.made",
                  [Loc.Named ("name", Id), Loc.Named ("value", Nt.State_Of (Store, Kind, Id))]);
            end;
         end loop;
         for Line of Report.Adopted loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.adopted", [Loc.Named ("detail", Line)]);
         end loop;
         for Id of Report.Revised loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.revised", [Loc.Named ("name", Id)]);
            --  Work done or doing for what it said before: named.
            declare
               Serving : Unbounded_String;
            begin
               for Task_Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Task_Id, Defined, Got);
                     if E.Is_Ok (Got)
                       and then Tk.State_Of (Store, Task_Id) not in "cancelled" | "rejected"
                       and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                                  .Contains (Id)
                     then
                        Append (Serving, (if Serving = Null_Unbounded_String then "" else ", ")
                                         & Task_Id);
                     end if;
                  end;
               end loop;
               if Serving /= Null_Unbounded_String then
                  Pres.Put_Note (Screen, "cli.project.bootstrap.revised_served",
                                 [Loc.Named ("name", Id), Loc.Named ("detail", To_String (Serving))]);
               end if;
            end;
         end loop;
         for Line of Report.Stale loop
            declare
               Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
            begin
               Pres.Put_Message
                 (Screen, "cli.project.bootstrap.stale",
                  [Loc.Named ("detail", (if Colon = 0 then Line
                                         else With_Id (Line (Line'First .. Colon - 1), Line)))]);
            end;
         end loop;

         --  What it imported as accepted is followed as any accepted
         --  requirement is: its tasks derived, readiness worked out.
         Model_Runner.CLI.Intents.Move_Along (Store, Screen);
         --  Nothing read from what was named: said, with how a document
         --  says a requirement.
         if Report.Created = 0 and then Report.Existing = 0 and then Report.Revised.Is_Empty
           and then Report.Issues = 0 and then Report.Adopted.Is_Empty
         then
            declare
               Listed : Unbounded_String;
            begin
               for One of Files loop
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
               end loop;
               Pres.Put_Note (Screen, "cli.next.bootstrap_nothing",
                              [Loc.Named ("detail", To_String (Listed))]);
            end;
         end if;

         --  A candidate requirement made waits to be accepted; with none
         --  read at all, how a document says one.
         if (for some Id of Report.Made =>
               Ada.Strings.Fixed.Index (Id, "REQ-") = Id'First
               and then Nt.State_Of (Store, Nt.Requirement, Id) = Nt.First_State (Nt.Requirement))
         then
            Pres.Put_Note (Screen, "cli.next.bootstrap");
         elsif not Report.Made.Is_Empty
           and then not (for some Id of Report.Made => Ada.Strings.Fixed.Index (Id, "REQ-") = Id'First)
           and then Report.Existing = 0 and then Report.Revised.Is_Empty
         then
            Pres.Put_Note (Screen, "cli.next.bootstrap_no_requirement");
         end if;
      end Bootstrap;

      --  A change to the settings: what it changes and reaches, and then,
      --  once it is confirmed, a new revision; what was verified is looked at
      --  again against it.
      procedure Reconfigure (Store : in out S.Store) is
         package Cf renames Model_Runner.Framework.Configurations;
         Known_Before : Names.Vector;
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Read     : E.Error_Info;
         Revision : Natural;
      begin
         --  NAME=VALUE, the value running on to the next NAME=: a value of
         --  several words needs no quotes.
         declare
            Name  : Unbounded_String;
            Value : Unbounded_String;
         begin
            for Index in 2 .. Natural (All_Words.Length) loop
               declare
                  Part  : constant String := All_Words (Index);
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Part, "=");
               begin
                  if Part = "confirm=yes" then
                     null;
                  --  A setting starts: named with its kind, or -- as the
                  --  first word -- named any way at all, to be found or
                  --  refused by name rather than dropped.
                  elsif Is_Setting (Part)
                    and then (Ada.Strings.Fixed.Index (Part (Part'First .. Equal - 1), ".") > 0
                              or else Name = Null_Unbounded_String)
                  then
                     if Name /= Null_Unbounded_String then
                        Changes.Include (To_String (Name), To_String (Value));
                     end if;
                     Name := To_Unbounded_String (Part (Part'First .. Equal - 1));
                     Value := To_Unbounded_String (Part (Equal + 1 .. Part'Last));
                  elsif Name /= Null_Unbounded_String then
                     Append (Value, " " & Part);
                  else
                     --  A name with no value: a value is what a change is.
                     Read := E.Make (E.CLI_Invalid_Option_Value);
                     E.Add_Text (Read, "option", Part);
                     E.Add_Text (Read, "value",
                                 (if Part (Part'First) = '='
                                  then "a setting is named before its =, as NAME=VALUE"
                                  else "a setting is changed as " & Part & "=VALUE; config "
                                       & Part & " shows what it is"));
                     Pres.Report (Screen, Read);
                     return;
                  end if;
               end;
            end loop;
            if Name /= Null_Unbounded_String then
               Changes.Include (To_String (Name), To_String (Value));
            end if;
         end;

         Cf.Plan_Change (Store, Changes, Planned, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         elsif Planned.Changed.Is_Empty then
            Pres.Put_Note (Screen, (if (for some Position in Changes.Iterate =>
                                          Cf.Value_Maps.Element (Position) = "inherit")
                                    then "cli.project.reconfigure.nothing_inherit"
                                    else "cli.project.reconfigure.nothing"));
            return;
         end if;
         for Line of Planned.Changed loop
            Pres.Put_Message (Screen, "cli.project.reconfigure.changed", [Loc.Named ("name", Line)]);
         end loop;
         for Line of Planned.Impact loop
            Pres.Put_Message (Screen, "cli.project.reconfigure.reaches", [Loc.Named ("name", Line)]);
         end loop;

         --  A kind or a role granted more than the project allows gets
         --  only what the project allows: before any change to permissions
         --  is made, every such level it would leave is said, once, with
         --  each capability it asks too much of and what it gets.
         if (for some Name of Planned.Changed =>
               Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First)
         then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Levels  : Names.Vector;
               Said_Project : Boolean;
               Of_Project   : constant Pm.Permission_Set :=
                 Pm.Level_Of (Planned.After, "project", Said_Project);
               Project : constant Pm.Permission_Set :=
                 (if Said_Project then Of_Project else Pm.Project_Default);
            begin
               for Index in 1 .. R.Field_Count (Planned.After) loop
                  declare
                     Field : constant String := R.Field_Name (Planned.After, Index);
                     Rest  : constant String :=
                       (if Field'Length > 15 and then Field (Field'First .. Field'First + 14)
                                                     = "map.permission."
                        then Field (Field'First + 15 .. Field'Last) else "");
                     Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
                     Level : constant String := (if Dot = 0 then "" else Rest (Rest'First .. Dot - 1));
                  begin
                     if Level'Length > 5 and then Level (Level'First .. Level'First + 4) in "kind." | "role."
                       and then not Levels.Contains (Level)
                     then
                        Levels.Append (Level);
                     end if;
                  end;
               end loop;
               for Level of Levels loop
                  declare
                     Present : Boolean;
                     --  What it asks for itself: one it inherits asks for
                     --  nothing, and follows what is above.
                     function Own_Asked return Pm.Permission_Set is
                        Result : Pm.Permission_Set := Pm.Level_Of (Planned.After, Level, Present);
                     begin
                        for One in Pm.Capability loop
                           if R.Get (Planned.After, "map.permission." & Level & "." & Pm.Word (One))
                                = "inherit"
                           then
                              Result (One) := Pm.Nothing (One);
                           end if;
                        end loop;
                        return Result;
                     end Own_Asked;
                     Given   : constant Pm.Permission_Set := Own_Asked;
                     Clipped : constant String := Pm.Clipped (Given, Project);
                  begin
                     if Present and then Clipped /= "" then
                        Pres.Put_Note
                          (Screen, "cli.project.clipped",
                           [Loc.Named ("name", Level), Loc.Named ("detail", Clipped)]);
                     end if;
                  end;
               end loop;
            end;
         end if;

         --  Confirmed by confirm=yes among the words, or asked -- but only
         --  on a terminal: a script's next line is not an answer.
         if All_Words.Contains ("confirm=yes") then
            null;
         elsif not Model_Runner.CLI.Choosers.Is_Available (Screen) then
            declare
               Missing : E.Error_Info := E.Make (E.Framework_Input_Missing);
            begin
               E.Add_Text (Missing, "name", "confirm");
               Pres.Report (Screen, Missing);
               Pres.Put_Note (Screen, "cli.next.confirm");
            end;
            return;
         else
            Pres.Put_Message (Screen, "cli.project.reconfigure.confirm", []);
            declare
               Answer : constant String :=
                 Ada.Characters.Handling.To_Lower
                   (Ada.Strings.Fixed.Trim (Ada.Text_IO.Get_Line, Ada.Strings.Both));
            begin
               if Answer not in "y" | "yes" | "j" | "ja" then
                  Pres.Put_Message (Screen, "cli.project.reconfigure.kept");
                  return;
               end if;
            exception
               when Ada.Text_IO.End_Error =>
                  Pres.Put_Message (Screen, "cli.project.reconfigure.kept");
                  return;
            end;
         end if;

         Known_Before := Tk.Components (Store);
         declare
            Change  : S.Transaction;
            Moved   : Names.Vector;
            Became  : Names.Vector;
         begin
            --  The new revision and the requirements it takes verification
            --  from, committed as one.
            Cf.Stage_Change (Store, Change, Planned, Read);
            if E.Is_Ok (Read) then
               Vf.Reevaluate_Requirements
                 (Store, Change, Moved, Read,
                  Configuration => Cf.Verification_Fingerprint (Planned.After));
            end if;
            if E.Is_Ok (Read) then
               S.Commit (Store, Change, Read);
            end if;
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
               return;
            end if;
            Revision := R.Revision (Planned.After);

            --  Readiness is derived, and worked out from the state as it
            --  now is.
            if E.Is_Ok (Read) then
               Tk.Recompute_Readiness (Store, Change, Became, Read);
            end if;
            if E.Is_Ok (Read) then
               S.Commit (Store, Change, Read);
            end if;
            for Requirement of Moved loop
               Pres.Put_Message
                 (Screen, "cli.work.requirement",
                  [Loc.Named ("name", Requirement),
                   Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
            end loop;
         end;
         --  Components changed: open tasks in one that is no longer the
         --  project's are named, a component at a time, with the way on;
         --  one declared with no roots is told where its files are said.
         if (for some Name of Planned.Changed =>
               Ada.Strings.Fixed.Index (Name, "map.component.") = Name'First
               or else Ada.Strings.Fixed.Index (Name, "set.components") = Name'First)
         then
            declare
               Known  : constant Names.Vector := Tk.Components (Store);
               Former : Names.Vector;

               function Joined (Items : Names.Vector) return String is
                  Text : Unbounded_String;
               begin
                  for One of Items loop
                     Append (Text, (if Text = Null_Unbounded_String then "" else ", ") & One);
                  end loop;
                  return To_String (Text);
               end Joined;
            begin
               for Id of Tk.List (Store) loop
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Id, Defined, Got);
                     if E.Is_Ok (Got) and then R.Get (Defined, "component") /= ""
                       and then not Known.Contains (R.Get (Defined, "component"))
                       and then not Former.Contains (R.Get (Defined, "component"))
                       --  Gone with this change, not said again at each one.
                       and then Known_Before.Contains (R.Get (Defined, "component"))
                       and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                     then
                        Former.Append (R.Get (Defined, "component"));
                     end if;
                  end;
               end loop;
               for Old of Former loop
                  declare
                     Count : Natural := 0;
                  begin
                     for Id of Tk.List (Store) loop
                        declare
                           Defined : R.Item;
                           Got     : E.Error_Info;
                        begin
                           Tk.Definition (Store, Id, Defined, Got);
                           if E.Is_Ok (Got) and then R.Get (Defined, "component") = Old
                             and then Tk.State_Of (Store, Id)
                                        not in "complete" | "cancelled" | "rejected"
                           then
                              Count := Count + 1;
                           end if;
                        end;
                     end loop;
                     Pres.Put_Note
                       (Screen, "cli.project.component_gone",
                        [Loc.Named ("count", Image (Count)), Loc.Named ("name", Old),
                         Loc.Named ("value", Joined (Known))]);
                  end;
               end loop;
               --  Roots within another's: said, with whose the files are.
               for Name of Known loop
                  for Other of Known loop
                     if Other /= Name then
                        for Inner of Model_Runner.Framework.Repository.Component_Roots (Store, Name) loop
                           for Outer of Model_Runner.Framework.Repository.Component_Roots (Store, Other)
                           loop
                              declare
                                 O : constant String :=
                                   (if Outer'Length > 1 and then Outer (Outer'Last) = '/'
                                    then Outer (Outer'First .. Outer'Last - 1) else Outer);
                                 I : constant String :=
                                   (if Inner'Length > 1 and then Inner (Inner'Last) = '/'
                                    then Inner (Inner'First .. Inner'Last - 1) else Inner);
                              begin
                                 --  Strictly within, and new with this change.
                                 if I'Length > O'Length + 1
                                   and then I (I'First .. I'First + O'Length) = O & "/"
                                   and then (for some Line of Planned.Changed =>
                                               Ada.Strings.Fixed.Index
                                                 (Line, "map.component." & Name & ":") = Line'First
                                               or else Ada.Strings.Fixed.Index
                                                 (Line, "map.component." & Other & ":") = Line'First)
                                 then
                                    Pres.Put_Note
                                      (Screen, "cli.project.component_overlap",
                                       [Loc.Named ("name", Name), Loc.Named ("value", Inner),
                                        Loc.Named ("other", Other), Loc.Named ("detail", Outer)]);
                                 end if;
                              end;
                           end loop;
                        end loop;
                     end if;
                  end loop;
               end loop;
               for Name of Known loop
                  if Model_Runner.Framework.Repository.Component_Roots (Store, Name).Is_Empty
                    and then R.Get (Planned.After, "input.project_name") /= Name
                  then
                     Pres.Put_Note (Screen, "cli.project.component_rootless",
                                    [Loc.Named ("name", Name)]);
                  end if;
               end loop;
            end;
         end if;

         declare
            Written : Boolean;
         begin
            Model_Runner.Framework.Git.Keep_Policy (Store, Written, Read);
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
            end if;
         end;
         Pres.Put_Message
           (Screen, "cli.project.reconfigure.done", [Loc.Named ("count", Image (Revision))]);
      end Reconfigure;

      --  How the project stands in Git, asked of Git: the branch, and each
      --  changed path with the tasks whose work changed it.
      procedure Git_Status (Store : in out S.Store) is
         Said : constant Model_Runner.Framework.Git.Status_Report :=
           Model_Runner.Framework.Git.Status_Of (Here);
      begin
         if not Said.Found then
            Pres.Put_Note (Screen, "cli.project.git.none");
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.project.git.branch", [Loc.Named ("name", To_String (Said.Branch))]);
         for Line of Said.Changes loop
            declare
               Path : constant String := Line (Line'First + 3 .. Line'Last);
               By   : Unbounded_String;
            begin
               for Id of Tk.List (Store) loop
                  declare
                     State : R.Item;
                     Read  : E.Error_Info;
                  begin
                     S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", State, Read);
                     if E.Is_Ok (Read)
                       and then Model_Runner.Framework.Lines_Of
                                  (R.Get (State, "changed_files")).Contains (Path)
                     then
                        Append (By, (if By = Null_Unbounded_String then "" else ", ") & Id);
                     end if;
                  end;
               end loop;
               Pres.Put_Message
                 (Screen, "cli.task.item",
                  [Loc.Named ("name", Path),
                   Loc.Named ("value", Line (Line'First .. Line'First + 1)),
                   Loc.Named ("detail", To_String (By))]);
            end;
         end loop;
         if Said.Changes.Is_Empty then
            Pres.Put_Note (Screen, "cli.project.git.clean");
         end if;
      end Git_Status;

      --  A person's explicit word on a subject, above every other source:
      --  given, withdrawn, or those standing listed.
      procedure Instruct (Store : in out S.Store) is
         package Au renames Model_Runner.Framework.Authority;
         Change : S.Transaction;
         Said   : Unbounded_String;
         Id     : Unbounded_String;
      begin
         for Index in 2 .. Natural (All_Words.Length) loop
            Append (Said, (if Index = 2 then "" else " ") & All_Words (Index));
         end loop;
         if Said = Null_Unbounded_String then
            for Line of Au.Standing_Instructions (Store) loop
               Pres.Put_Message (Screen, "cli.task.field",
                                 [Loc.Named ("name", Line (Line'First .. Ada.Strings.Fixed.Index (Line, ":") - 1)),
                                  Loc.Named ("value", Line (Ada.Strings.Fixed.Index (Line, ":") + 2 .. Line'Last))]);
            end loop;
            if Au.Standing_Instructions (Store).Is_Empty then
               Pres.Put_Note (Screen, "cli.project.instruct.none");
            end if;
            return;
         elsif Argument (1) = "withdraw" then
            Au.Withdraw (Store, Change, Argument (2), Model_Runner.Framework.Transitions.User,
                         Outcome);
            if E.Is_Ok (Outcome) then
               S.Commit (Store, Change, Outcome);
            end if;
            if E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
            else
               Pres.Put_Message (Screen, "cli.task.moved",
                                 [Loc.Named ("name", Argument (2)),
                                  Loc.Named ("value", "withdrawn")]);
            end if;
            return;
         end if;
         declare
            Text      : constant String := To_String (Said);
            Equals    : constant Natural := Ada.Strings.Fixed.Index (Text, "=");
            Overrides : constant Natural := Ada.Strings.Fixed.Index (Text, " overriding ");
            Subject   : constant String :=
              (if Equals = 0 then "" else Ada.Strings.Fixed.Trim (Text (Text'First .. Equals - 1), Ada.Strings.Both));
            Value     : constant String :=
              (if Equals = 0 then ""
               else Ada.Strings.Fixed.Trim
                      (Text (Equals + 1 .. (if Overrides > Equals then Overrides - 1 else Text'Last)),
                       Ada.Strings.Both));
            Over      : constant String :=
              (if Overrides > Equals then Ada.Strings.Fixed.Trim (Text (Overrides + 12 .. Text'Last), Ada.Strings.Both)
               else "");
         begin
            Au.Instruct (Store, Change, Subject, Value, Over,
                         Model_Runner.Framework.Transitions.User, Id, Outcome);
            if E.Is_Ok (Outcome) then
               S.Commit (Store, Change, Outcome);
            end if;
            if E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
            else
               Pres.Put_Message (Screen, "cli.task.created",
                                 [Loc.Named ("name", To_String (Id)),
                                  Loc.Named ("detail", Subject & " = " & Value)]);
            end if;
         end;
      end Instruct;

      --  The one candidate waiting, if there is exactly one.
      procedure Decide (Store : in out S.Store) is
         Tasks_Waiting : constant Names.Vector := Tk.List (Store, "candidate");
         Intent_Waiting : constant Names.Vector := Model_Runner.CLI.Intents.Pending (Store);
         Waiting : Names.Vector := Tasks_Waiting;
         Listed  : Unbounded_String;
      begin
         Waiting.Append (Intent_Waiting);

         --  One named: that one, and only if it waits to be decided.
         if Argument (1) /= "" then
            if Tasks_Waiting.Contains (Argument (1)) then
               Command.Action := T.To_Bounded (if Word = "/accept" then "accept" else "reject");
               Command.Action_Argument := T.To_Bounded (Argument (1));
               Command.Kind := Opt.Command_Task;
               return;
            end if;
            for Which of Intent_Waiting loop
               if Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last) = Argument (1) then
                  Model_Runner.CLI.Intents.Decide (Store, Which, Word = "/accept", Screen);
                  return;
               end if;
            end loop;
            declare
               Missing : E.Error_Info := E.Make (E.Framework_Not_Found);
            begin
               E.Add_Text (Missing, "name", "a proposal " & Argument (1));
               Pres.Report (Screen, Missing);
            end;
            return;
         end if;

         if Waiting.Is_Empty then
            Pres.Put_Note (Screen, "cli.project.no_pending");
         elsif Natural (Waiting.Length) > 1 then
            --  Each as the command that decides it.
            for Id of Tasks_Waiting loop
               declare
                  Defined : R.Item;
                  Got     : E.Error_Info;
               begin
                  Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Got);
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                          & "/task " & (if Word = "/accept" then "accept " else "reject ") & Id
                          & " (" & R.Get (Defined, "title") & ")");
               end;
            end loop;
            for Which of Intent_Waiting loop
               declare
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Which, ":");
                  Kind  : constant String := Which (Which'First .. Colon - 1);
               begin
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                          & (if Pres.In_Session (Screen) then "/" else "")
                          & (if Kind = "requirement" then "req"
                             elsif Kind = "decision" then "decision" else "spec")
                          & (if Word = "/accept" then " accept " else " reject ")
                          & Which (Colon + 1 .. Which'Last));
               end;
            end loop;
            --  Not decided: an error, said however quiet, with the ways on.
            declare
               Which_One : E.Error_Info := E.Make (E.Framework_Input_Missing);
            begin
               E.Add_Text (Which_One, "name", "the one to decide");
               Pres.Report (Screen, Which_One);
            end;
            Pres.Put_Message
              (Screen, "cli.project.pending_many", [Loc.Named ("detail", To_String (Listed))]);
         elsif Intent_Waiting.Is_Empty then
            Command.Action := T.To_Bounded (if Word = "/accept" then "accept" else "reject");
            Command.Action_Argument := T.To_Bounded (Waiting.First_Element);
            Command.Kind := Opt.Command_Task;
         else
            --  A requirement, specification or decision: decided here.
            Model_Runner.CLI.Intents.Decide
              (Store, Intent_Waiting.First_Element, Word = "/accept", Screen);
         end if;
      end Decide;

      --  /req, /decision and /spec: the registers of what the project is
      --  meant to be.
      procedure Intent_Command (Store : in out S.Store) is
         After : Names.Vector;
      begin
         for Index in 2 .. Natural (All_Words.Length) loop
            After.Append (All_Words (Index));
         end loop;
         Model_Runner.CLI.Intents.Run
           (Store,
            (if Word = "/req" then Nt.Requirement
             elsif Word = "/decision" then Nt.Decision
             else Nt.Specification),
            After, Screen);
      end Intent_Command;
   begin
      if Open_Quote then
         Pres.Put_Note (Screen, "cli.project.quote_open");
      end if;
      for Index in 2 .. Natural (All_Words.Length) loop
         declare
            Part : constant String := All_Words (Index);
         begin
            --  --set before NAME=VALUE, as the shell spells it, is the
            --  same as NAME=VALUE alone.
            if Part = "--set" then
               null;
            elsif Is_Setting (Part) and then Ada.Strings.Fixed.Head (Part, 2) /= "--"
              and then Command.Input_Count < Opt.Max_Guards
            then
               Command.Input_Count := Command.Input_Count + 1;
               Command.Inputs (Command.Input_Count) := T.To_Bounded (Part);
            else
               Positional.Append (Part);
            end if;
         end;
      end loop;

      --  A session works in the directory it was started in: another is
      --  refused by name, not worked in unasked or taken for text.
      if Word /= "/init"
        and then (for some One of All_Words =>
                    One = "--directory"
                    or else (One'Length > 12 and then One (One'First .. One'First + 11) = "--directory="))
      then
         Outcome := E.Make (E.CLI_Option_Not_For_Command);
         E.Add_Text (Outcome, "value", Word);
         E.Add_Text (Outcome, "option", "--directory");
         Pres.Report (Screen, Outcome);
         Pres.Put_Note (Screen, "cli.next.session_directory");
         return;
      end if;

      if Word = "/init" then
         Command.Kind := Opt.Command_Init;
         --  --directory DIR as the shell takes it: the project started
         --  there, the template the word that is neither.
         declare
            Template : Unbounded_String;
            Index    : Positive := 1;
         begin
            while Index <= Natural (Positional.Length) loop
               if Positional (Index) = "--directory" and then Index < Natural (Positional.Length) then
                  Command.Project_Directory := T.To_Bounded (Positional (Index + 1));
                  Index := Index + 2;
               elsif Ada.Strings.Fixed.Head (Positional (Index), 12) = "--directory="
                 and then Positional (Index) /= "--directory="
               then
                  Command.Project_Directory := T.To_Bounded
                    (Ada.Strings.Fixed.Delete (Positional (Index), 1, 12));
                  Index := Index + 1;
               else
                  if Template = Null_Unbounded_String then
                     Template := To_Unbounded_String (Positional (Index));
                  end if;
                  Index := Index + 1;
               end if;
            end loop;
            Command.Template_Name := T.To_Bounded (To_String (Template));
         end;
         Model_Runner.CLI.Init.Run (Command, Screen, Status);

      elsif Word = "/task" then
         Command.Kind := Opt.Command_Task;
         --  /task TASK-X is the task shown.
         if Ada.Strings.Fixed.Index (Argument (1), "TASK-") = 1 then
            Command.Action := T.To_Bounded ("show");
            Command.Action_Argument := T.To_Bounded (Argument (1));
         else
            Command.Action := T.To_Bounded (Argument (1));
            Command.Action_Argument := T.To_Bounded (Rest (2));
         end if;
         Model_Runner.CLI.Tasks.Run (Command, Screen, Status);

      elsif Word in "/accept" | "/reject" then
         With_Store (Decide'Access);
         if Command.Kind = Opt.Command_Task then
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
         end if;

      elsif Word = "/cancel" then
         if Argument (1) = "" then
            Pres.Put_Note (Screen, "cli.project.nothing_running");
         else
            Command.Kind := Opt.Command_Task;
            Command.Action := T.To_Bounded ("cancel");
            Command.Action_Argument := T.To_Bounded (Argument (1));
            Model_Runner.CLI.Tasks.Run (Command, Screen, Status);
         end if;

      elsif Word = "/work" then
         Command.Kind := Opt.Command_Work;
         Command.Action_Argument := T.To_Bounded (Rest (1));
         Model_Runner.CLI.Work.Run_With (Command, Screen, Agent, Status);

      elsif Word in "/tree" | "/sym" | "/refs" | "/deps" | "/users" | "/impact" | "/trace" then
         Command.Kind := Opt.Command_Repo;
         Command.Action := T.To_Bounded (Word (Word'First + 1 .. Word'Last));
         --  --verbose among the words: all of it, as the shell's option.
         Command.Action_Argument :=
           T.To_Bounded (if Argument (1) = "--verbose" then Argument (2) else Argument (1));
         if All_Words.Contains ("--verbose") then
            Command.Level := Opt.Verbose;
         end if;
         Model_Runner.CLI.Repo.Run (Command, Screen, Status);

      elsif Word = "/state" then
         With_Store (State'Access);
      elsif Word = "/config" then
         With_Store (Show_Config'Access);
      elsif Word in "/req" | "/decision" | "/spec" then
         With_Store (Intent_Command'Access);
      elsif Word = "/result" then
         With_Store (Show_Result'Access);
      elsif Word = "/check" then
         With_Store (Check'Access);
      elsif Word = "/bootstrap" then
         With_Store (Bootstrap'Access);
      elsif Word = "/git" then
         With_Store (Git_Status'Access);
      elsif Word = "/instruct" then
         With_Store (Instruct'Access);
      elsif Word = "/sandbox" then
         --  The run's own confinement, below every other level: it needs
         --  no project, and lasts until changed or the session ends.
         if Natural (All_Words.Length) > 1 then
            declare
               --  All of it, constraints such as roots=src/ included.
               Said : Unbounded_String;
            begin
               for Index in 2 .. Natural (All_Words.Length) loop
                  Append (Said, (if Index = 2 then "" else " ") & All_Words (Index));
               end loop;
               Model_Runner.Framework.Permissions.Set_Sandbox
                 ((if To_String (Said) = "off" then "" else To_String (Said)), Outcome);
            end;
            if E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end if;
         --  A variable that does not read is refused here as work refuses
         --  it, not shown as confining to nothing.
         if Model_Runner.Framework.Permissions.Sandbox_Problem /= "" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", Model_Runner.Framework.Permissions.Sandbox_Variable);
            E.Add_Text (Outcome, "value", Ada.Environment_Variables.Value
                                            (Model_Runner.Framework.Permissions.Sandbox_Variable));
            E.Add_Text (Outcome, "detail", Model_Runner.Framework.Permissions.Sandbox_Problem);
            Pres.Report (Screen, Outcome);
            return;
         end if;
         declare
            use type Model_Runner.Framework.Permissions.Permission_Set;
            Now : constant Model_Runner.Framework.Permissions.Permission_Set :=
              Model_Runner.Framework.Permissions.Sandbox;
         begin
            if Now = Model_Runner.Framework.Permissions.Unrestricted then
               Pres.Put_Note (Screen, "cli.project.sandbox.none");
               --  And what that is, where there is a project to say it.
               if S.Is_Initialized (".") then
                  declare
                     package Pm renames Model_Runner.Framework.Permissions;
                     Store : S.Store;
                     Read  : E.Error_Info;
                     Left  : Unbounded_String;
                  begin
                     S.Open_To_Read (Store, ".", Read);
                     if E.Is_Ok (Read) then
                        for Line of Model_Runner.Framework.Lines_Of
                          (Pm.Image (Pm.Effective (Store, "", "", Within_Sandbox => False)))
                        loop
                           Append (Left, (if Left = Null_Unbounded_String then "" else "; ") & Line);
                        end loop;
                        S.Close (Store);
                        Pres.Put_Message
                          (Screen, "cli.project.sandbox.effective",
                           [Loc.Named ("value", (if Left = Null_Unbounded_String then "nothing"
                                                 else To_String (Left)))]);
                     end if;
                  end;
               end if;
            else
               --  In the form /sandbox takes back: capabilities a ; apart.
               declare
                  Shown : Unbounded_String;
               begin
                  for Line of Model_Runner.Framework.Lines_Of
                    (Model_Runner.Framework.Permissions.Image (Now))
                  loop
                     Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ") & Line);
                  end loop;
                  Pres.Put_Message
                    (Screen, "cli.project.sandbox.set",
                     [Loc.Named ("value", (if Shown = Null_Unbounded_String then "nothing"
                                           else To_String (Shown))),
                      Loc.Named ("name", Model_Runner.Framework.Permissions.Sandbox_Source)]);
                  --  What that leaves agents here, the project's own
                  --  permissions being below it: a sandbox grants nothing
                  --  the project does not.
                  if S.Is_Initialized (".") then
                     declare
                        package Pm renames Model_Runner.Framework.Permissions;
                        Store : S.Store;
                        Read  : E.Error_Info;
                        Left  : Unbounded_String;
                     begin
                        S.Open_To_Read (Store, ".", Read);
                        if E.Is_Ok (Read) then
                           for Line of Model_Runner.Framework.Lines_Of
                             (Pm.Image (Pm.Effective (Store, "", "", Within_Sandbox => True)))
                           loop
                              Append (Left, (if Left = Null_Unbounded_String then "" else "; ") & Line);
                           end loop;
                           S.Close (Store);
                           if To_String (Left) /= To_String (Shown) then
                              Pres.Put_Note
                                (Screen, "cli.project.sandbox.effective",
                                 [Loc.Named ("value", (if Left = Null_Unbounded_String then "nothing"
                                                       else To_String (Left)))]);
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      elsif Word = "/reconfigure" then
         With_Store (Reconfigure'Access);
      end if;
   end Run;

   --  The agent a command from the shell has: none. Work is the work
   --  command's, which names its agent.
   type No_Agent is new Model_Runner.Framework.Work.Agent_Runner with null record;

   overriding procedure Run
     (Self        : No_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Check_Start
     (Self   : No_Agent;
      Item   : Model_Runner.Framework.Stores.Store;
      Status : in out E.Error_Info);

   overriding procedure Run
     (Self        : No_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out E.Error_Info)
   is
      pragma Unreferenced (Self, Prompt_Path, Project);
   begin
      Answer := Ada.Strings.Unbounded.Null_Unbounded_String;
      Status := E.Make (E.Framework_Input_Missing);
      E.Add_Text (Status, "name", "model");
   end Run;

   overriding procedure Check_Start
     (Self   : No_Agent;
      Item   : Model_Runner.Framework.Stores.Store;
      Status : in out E.Error_Info)
   is
      pragma Unreferenced (Self, Item);
   begin
      Status := E.Make (E.Framework_Input_Missing);
      E.Add_Text (Status, "name", "model");
   end Check_Start;

   --------------------
   -- Run_From_Shell --
   --------------------

   procedure Run_From_Shell
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Before    : constant String := Ada.Directories.Current_Directory;
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));
      Word      : constant String := T.To_String (Item.Action);
      Rest      : constant String := T.To_String (Item.Action_Argument);
      Ignored   : constant Natural := Pres.First_Failure (Screen);
      pragma Unreferenced (Ignored);

      --  --set NAME=VALUE, each as a session's NAME=VALUE, quoted as the
      --  command's other words are.
      function Set_Words return String is
         Result : Unbounded_String;
      begin
         for Index in 1 .. Item.Input_Count loop
            declare
               Given   : constant String := T.To_String (Item.Inputs (Index));
               Escaped : Unbounded_String;
            begin
               for C of Given loop
                  if C in '"' | '\' | ''' then
                     Append (Escaped, '\');
                  end if;
                  Append (Escaped, C);
               end loop;
               Append (Result, " " & (if Ada.Strings.Fixed.Index (Given, " ") > 0
                                      then '"' & To_String (Escaped) & '"'
                                      else To_String (Escaped)));
            end;
         end loop;
         return To_String (Result);
      end Set_Words;
   begin
      if Word = "" then
         declare
            Missing : E.Error_Info := E.Make (E.Framework_Input_Missing);
         begin
            E.Add_Text (Missing, "name", "the project command: req, state, bootstrap, config,"
                        & " reconfigure, check, decision, spec, result, sandbox, instruct,"
                        & " accept or reject");
            Pres.Report (Screen, Missing);
            Status := E.Exit_Status (Missing);
            return;
         end;
      end if;
      if not Ada.Directories.Exists (Directory) then
         declare
            Missing : E.Error_Info := E.Make (E.Framework_Not_Initialized);
         begin
            E.Add_Text (Missing, "path", Directory, E.Param_Path);
            Pres.Report (Screen, Missing);
            Status := E.Exit_Status (Missing);
            return;
         end;
      end if;
      --  A sandbox is a session's: from the shell it is said how to give
      --  one to a command, not set for nothing.
      if Word = "sandbox" and then Rest /= "" then
         Pres.Put_Note (Screen, "cli.project.sandbox.shell",
                        [Loc.Named ("value", (if Ada.Strings.Fixed.Index (Rest, "TASK-") = Rest'First
                                              then Rest else "TASK-ID"))]);
         Status := E.Exit_Success;
         return;
      end if;
      Ada.Directories.Set_Directory (Directory);
      begin
         Run ("/" & Word & (if Rest = "" then "" else " " & Rest) & Set_Words, Screen,
              No_Agent'(null record));
      exception
         when others =>
            Ada.Directories.Set_Directory (Before);
            raise;
      end;
      Ada.Directories.Set_Directory (Before);
      Status := Pres.First_Failure (Screen);
   end Run_From_Shell;

end Model_Runner.CLI.Project_Commands;
