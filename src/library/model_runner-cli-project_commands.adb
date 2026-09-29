with Ada.Text_IO;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

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
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Verification;
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
      Sink     : aliased Pres.Standard_Output_Sink;
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
      elsif Outcome.Reason = Model_Runner.Agent.Timed_Out then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", "time");
         E.Add_Text (Status, "detail", "the work ran out of the time it was given");
      elsif Outcome.Reason /= Model_Runner.Agent.Answered then
         Status :=
           (if E.Is_Error (Outcome.Error) then Outcome.Error
            else E.Make (E.Generation_Invalid_Request));
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
         Put ("error: you may not read " & Path);
      elsif Named = "write_file" and then not May (Reading => False) then
         Put ("error: you may not write " & Path);
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
      Pres.Put_Message (Screen, "cli.interactive.help.init");
      Pres.Put_Message (Screen, "cli.interactive.help.bootstrap");
      Pres.Put_Message (Screen, "cli.interactive.help.state");
      Pres.Put_Message (Screen, "cli.interactive.help.config");
      Pres.Put_Message (Screen, "cli.interactive.help.git");
      Pres.Put_Message (Screen, "cli.interactive.help.sandbox");
      Pres.Put_Message (Screen, "cli.interactive.help.instruct");
      Pres.Put_Message (Screen, "cli.interactive.help.reconfigure");
      Pres.Put_Message (Screen, "cli.interactive.help.task");
      Pres.Put_Message (Screen, "cli.interactive.help.accept");
      Pres.Put_Message (Screen, "cli.interactive.help.reject");
      Pres.Put_Message (Screen, "cli.interactive.help.work");
      Pres.Put_Message (Screen, "cli.interactive.help.cancel");
      Pres.Put_Message (Screen, "cli.interactive.help.check");
      Pres.Put_Message (Screen, "cli.interactive.help.req");
      Pres.Put_Message (Screen, "cli.interactive.help.decision");
      Pres.Put_Message (Screen, "cli.interactive.help.spec");
      Pres.Put_Message (Screen, "cli.interactive.help.result");
      Pres.Put_Message (Screen, "cli.interactive.help.tree");
      Pres.Put_Message (Screen, "cli.interactive.help.sym");
      Pres.Put_Message (Screen, "cli.interactive.help.refs");
      Pres.Put_Message (Screen, "cli.interactive.help.deps");
      Pres.Put_Message (Screen, "cli.interactive.help.users");
      Pres.Put_Message (Screen, "cli.interactive.help.impact");
      Pres.Put_Message (Screen, "cli.interactive.help.trace");
   end Help;

   --  The words of a line, with a quoted stretch kept whole.
   function Split (Line : String) return Names.Vector is
      Result  : Names.Vector;
      Current : Unbounded_String;
      Quoted  : Boolean := False;
      Started : Boolean := False;
   begin
      for Char of Line loop
         if Char = '"' then
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
      end loop;
      if Started then
         Result.Append (To_String (Current));
      end if;
      return Result;
   end Split;

   --  Whether a word gives an input or a field, as NAME=VALUE.
   function Is_Setting (Word : String) return Boolean is
      Equal : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
   begin
      return Equal > Word'First
        and then (for all C of Word (Word'First .. Equal - 1) =>
                    C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '+');
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
         for Id of Tk.List (Store, "accepted") loop
            if Tk.Ready (Store, Id).Ready then
               Ready := Ready + 1;
            end if;
         end loop;
         Line_Of ("cli.project.candidates", Count ("candidate"));
         Line_Of ("cli.project.accepted", Count ("accepted"));
         Line_Of ("cli.project.ready", Image (Ready));
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
                  if E.Is_Ok (Read) and then Full.Contains (R.Get (Held, "profile")) then
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
               Name : constant String := R.Field_Name (Config, Index);
            begin
               if Name'Length < 5 or else Name (Name'First .. Name'First + 4) /= "file." then
                  Field (Name, R.Get (Config, Name));
               end if;
            end;
         end loop;
      end Show_Config;

      procedure Show_Result (Store : in out S.Store) is
         package Rs renames Model_Runner.Framework.Results;
         Held  : Rs.Result;
         Read  : E.Error_Info;
         Size  : constant Natural := Rs.Payload_Size (Store, Argument (1));
         --  A large payload is read only when asked for: /result ID full.
         Whole : constant Boolean := Size <= Rs.Inline_Limit or else Argument (2) = "full";
         Id    : constant String := Argument (1);

         --  Any identifier the harness prints: an invocation, a context's
         --  manifest, evidence or an agent is shown as it is recorded.
         function Starts (Prefix : String) return Boolean
         is (Id'Length > Prefix'Length and then Id (Id'First .. Id'First + Prefix'Length - 1) = Prefix);

         procedure Show_Record (Where : Model_Runner.Framework.Area; Name : String) is
            Value : R.Item;
         begin
            S.Read (Store, Where, Name, Value, Read);
            if E.Is_Error (Read) then
               Pres.Report (Screen, Read);
               return;
            end if;
            for Index in 1 .. R.Field_Count (Value) loop
               declare
                  Named : constant String := R.Field_Name (Value, Index);
               begin
                  if Named not in "schema_id" | "schema_version" | "entity_id" | "revision" then
                     Field (Named, R.Get (Value, Named));
                  end if;
               end;
            end loop;
         end Show_Record;
      begin
         if Id = "" then
            declare
               Missing : E.Error_Info := E.Make (E.Framework_Input_Missing);
            begin
               E.Add_Text (Missing, "name", "the result: RES-, INV-, CTX-, VER- or AG- and its number");
               Pres.Report (Screen, Missing);
               return;
            end;
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
         Field ("summary", To_String (Held.Summary));
         Field ("provenance", To_String (Held.Provenance));
         for Other of Model_Runner.Framework.Lines_Of (To_String (Held.References)) loop
            Field ("references", Other);
         end loop;
         Field ("payload",
                (if Whole then To_String (Held.Payload)
                 else "(" & Image (Size) & " bytes; /result " & Argument (1) & " full shows them)"));
      end Show_Result;

      --  The project's verification, now, for no task in particular.
      procedure Check (Store : in out S.Store) is
         Config   : R.Item;
         Read     : E.Error_Info;
         Change   : S.Transaction;
      begin
         --  The state itself, not the project's files: what does not hold
         --  together, found without a model.
         if Argument (1) = "consistency" then
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
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "the profile " & Argument (1));
               Pres.Report (Screen, Outcome);
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
         --  The documents named, or those the bootstrap policy reads.
         Files  : constant Names.Vector :=
           (if Positional.Is_Empty then Model_Runner.Framework.Bootstrap.Documents (Store)
            else Positional);
      begin
         --  A document named is one within the project, outside its state,
         --  and there to be read: nothing is taken from one that is not.
         for Path of Positional loop
            if Path = "" or else Path (Path'First) in '/' | '\'
              or else Ada.Strings.Fixed.Index (Path, "..") > 0
              or else Ada.Strings.Fixed.Index (Path, ".model_runner") > 0
              or else not Ada.Directories.Exists (Path)
              or else Ada.Directories."/=" (Ada.Directories.Kind (Path), Ada.Directories.Ordinary_File)
            then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", Path & " within the project");
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
             Loc.Named ("total", Image (Report.Existing)),
             Loc.Named ("extra", Image (Report.Issues))]);
         for Id of Report.Made loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.made", [Loc.Named ("name", Id)]);
         end loop;
         for Line of Report.Stale loop
            Pres.Put_Message (Screen, "cli.project.bootstrap.stale", [Loc.Named ("detail", Line)]);
         end loop;

         --  What it imported as accepted is followed as any accepted
         --  requirement is: its tasks derived, readiness worked out.
         Model_Runner.CLI.Intents.Move_Along (Store, Screen);
         if not Report.Made.Is_Empty then
            Pres.Put_Note (Screen, "cli.next.bootstrap");
         end if;
      end Bootstrap;

      --  A change to the settings: what it changes and reaches, and then,
      --  once it is confirmed, a new revision; what was verified is looked at
      --  again against it.
      procedure Reconfigure (Store : in out S.Store) is
         package Cf renames Model_Runner.Framework.Configurations;
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
                  elsif Is_Setting (Part)
                    and then Ada.Strings.Fixed.Index (Part (Part'First .. Equal - 1), ".") > 0
                  then
                     if Name /= Null_Unbounded_String then
                        Changes.Include (To_String (Name), To_String (Value));
                     end if;
                     Name := To_Unbounded_String (Part (Part'First .. Equal - 1));
                     Value := To_Unbounded_String (Part (Equal + 1 .. Part'Last));
                  elsif Name /= Null_Unbounded_String then
                     Append (Value, " " & Part);
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
            Pres.Put_Note (Screen, "cli.project.reconfigure.nothing");
            return;
         end if;
         for Line of Planned.Changed loop
            Pres.Put_Message (Screen, "cli.project.reconfigure.changed", [Loc.Named ("name", Line)]);
         end loop;
         for Line of Planned.Impact loop
            Pres.Put_Message (Screen, "cli.project.reconfigure.reaches", [Loc.Named ("name", Line)]);
         end loop;

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
                  Pres.Put_Note (Screen, "cli.project.reconfigure.kept");
                  return;
               end if;
            exception
               when Ada.Text_IO.End_Error =>
                  Pres.Put_Note (Screen, "cli.project.reconfigure.kept");
                  return;
            end;
         end if;

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
                  Configuration => R.Get (Planned.After, "configuration_fingerprint"));
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
               Pres.Put_Message (Screen, "cli.work.requirement", [Loc.Named ("name", Requirement),
                                                                  Loc.Named ("value", "")]);
            end loop;
         end;
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
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                       & "/task accept " & Id);
            end loop;
            for Which of Intent_Waiting loop
               declare
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Which, ":");
                  Kind  : constant String := Which (Which'First .. Colon - 1);
               begin
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ")
                          & (if Kind = "requirement" then "/req"
                             elsif Kind = "decision" then "/decision" else "/spec")
                          & " accept " & Which (Colon + 1 .. Which'Last));
               end;
            end loop;
            Pres.Put_Note
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
      for Index in 2 .. Natural (All_Words.Length) loop
         declare
            Part : constant String := All_Words (Index);
         begin
            if Is_Setting (Part) and then Command.Input_Count < Opt.Max_Guards then
               Command.Input_Count := Command.Input_Count + 1;
               Command.Inputs (Command.Input_Count) := T.To_Bounded (Part);
            else
               Positional.Append (Part);
            end if;
         end;
      end loop;

      if Word = "/init" then
         Command.Kind := Opt.Command_Init;
         Command.Template_Name := T.To_Bounded (Argument (1));
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
         Command.Action_Argument := T.To_Bounded (Argument (1));
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
         declare
            use type Model_Runner.Framework.Permissions.Permission_Set;
            Now : constant Model_Runner.Framework.Permissions.Permission_Set :=
              Model_Runner.Framework.Permissions.Sandbox;
         begin
            if Now = Model_Runner.Framework.Permissions.Unrestricted then
               Pres.Put_Note (Screen, "cli.project.sandbox.none");
            else
               Pres.Put_Message
                 (Screen, "cli.project.sandbox.set",
                  [Loc.Named ("value", Model_Runner.Framework.Permissions.Image (Now))]);
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
      Ada.Directories.Set_Directory (Directory);
      begin
         Run ("/" & Word & (if Rest = "" then "" else " " & Rest), Screen, No_Agent'(null record));
      exception
         when others =>
            Ada.Directories.Set_Directory (Before);
            raise;
      end;
      Ada.Directories.Set_Directory (Before);
      Status := Pres.First_Failure (Screen);
   end Run_From_Shell;

end Model_Runner.CLI.Project_Commands;
