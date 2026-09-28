with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with Model_Runner.Agent;
with Model_Runner.CLI.Init;
with Model_Runner.CLI.Repo;
with Model_Runner.CLI.Tasks;
with Model_Runner.CLI.Work;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Framework;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
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
      new String'("/impact"), new String'("/trace")];

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

   --  What the agent does, shown as it does it.
   type Watch (Screen : not null access Pres.Console) is
     limited new Model_Runner.Agent.Observer with null record;

   overriding procedure On_Call
     (Self : in out Watch; Named : String; Arguments : String);

   overriding procedure On_Result
     (Self : in out Watch; Named : String; Result : String);

   overriding procedure On_Call
     (Self : in out Watch; Named : String; Arguments : String) is
   begin
      Pres.Put_Tool_Call (Self.Screen.all, Named, Arguments);
   end On_Call;

   overriding procedure On_Result
     (Self : in out Watch; Named : String; Result : String)
   is
      pragma Unreferenced (Named);
   begin
      Pres.Put_Tool_Result (Self.Screen.all, Result);
   end On_Result;

   package Wk renames Model_Runner.Framework.Work;
   package Pm renames Model_Runner.Framework.Permissions;

   type Host_Access is access all Wk.Child_Host'Class;

   --  Whether a path stays inside the project: relative, and never climbing
   --  out of it.
   function Inside (Path : String) return Boolean is
      Start : Natural := Path'First;
   begin
      if Path'Length > 0
        and then (Path (Path'First) in '/' | '\' | '~'
                  or else (Path'Length > 1 and then Path (Path'First + 1) = ':'))
      then
         return False;
      end if;
      for Index in Path'First .. Path'Last + 1 loop
         if Index > Path'Last or else Path (Index) in '/' | '\' then
            if Path (Start .. Index - 1) = ".." then
               return False;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return True;
   end Inside;

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
   is new Model_Runner.Tools.Builtin.Instance with null record;

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
      Status : out Model_Runner.Errors.Error_Info)
   is
      Messages : Conv.History;
      Offered  : Model_Runner.Tools.Definitions;
      Runner   : Work_Tools (Self'Unchecked_Access, Host);
      Guard    : aliased Fence (Self.Screen);
      Watcher  : aliased Watch (Self.Screen);
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
            Max_Steps   => (if Root then 24 else 16),
            Max_Total_Tokens => Budget,
            Cancel      => Self.Cancel,
            Tool_Syntax => Syntax,
            Thinking    => Self.Item.Thinking,
            Approve     => Guard'Unchecked_Access,
            Watch       => Watcher'Unchecked_Access,
            Result      => Outcome);
         Calls := Calls + Outcome.Calls;
         Tokens := Tokens + Outcome.Generated_Tokens;
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
         Status := E.Make (E.Generation_Cancelled);
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
                      Root => False, Answer => Answer, Tokens => Tokens, Status => Ran);
            Self.Host.Close_Child (To_String (Answer), Tokens, Ran, Now, Retry);
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

      --  Whether the agent now working may read or write there: inside the
      --  project, and within its source or specification grants.
      function May (Reading : Boolean) return Boolean
      is (Inside (Path)
          and then (Self.Host = null
                    or else Self.Host.May
                              ((if Reading then Pm.Read_Source else Pm.Write_Source), Path)
                    or else Self.Host.May
                              ((if Reading then Pm.Read_Specs else Pm.Write_Specs), Path)));
   begin
      if Named = "delegate" then
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
   begin
      --  The work is done where the task's files are, and its own
      --  conversation -- and each child's -- is on the session, which the
      --  screen's is read back into afterwards.
      L.Reset (Self.Session.all);
      Ada.Directories.Set_Directory (Project);
      Run_Loop (Self, Prompt, Host, 0, True, Answer, Tokens, Status);
      Ada.Directories.Set_Directory (Before);
      L.Reset (Self.Session.all);
      if Host /= null then
         Host.Spend (Tokens);
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Before);
         L.Reset (Self.Session.all);
         Answer := Null_Unbounded_String;
         Status := E.Make (E.Internal_Unexpected_Exception);
   end Work_On;

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
      Pres.Put_Note (Screen, "cli.interactive.help.init");
      Pres.Put_Note (Screen, "cli.interactive.help.bootstrap");
      Pres.Put_Note (Screen, "cli.interactive.help.state");
      Pres.Put_Note (Screen, "cli.interactive.help.config");
      Pres.Put_Note (Screen, "cli.interactive.help.task");
      Pres.Put_Note (Screen, "cli.interactive.help.accept");
      Pres.Put_Note (Screen, "cli.interactive.help.reject");
      Pres.Put_Note (Screen, "cli.interactive.help.work");
      Pres.Put_Note (Screen, "cli.interactive.help.cancel");
      Pres.Put_Note (Screen, "cli.interactive.help.check");
      Pres.Put_Note (Screen, "cli.interactive.help.req");
      Pres.Put_Note (Screen, "cli.interactive.help.result");
      Pres.Put_Note (Screen, "cli.interactive.help.tree");
      Pres.Put_Note (Screen, "cli.interactive.help.sym");
      Pres.Put_Note (Screen, "cli.interactive.help.refs");
      Pres.Put_Note (Screen, "cli.interactive.help.impact");
      Pres.Put_Note (Screen, "cli.interactive.help.trace");
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
                    C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.');
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

         Ready : Natural := 0;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         Line_Of ("cli.project.template", R.Get (Config, "template_id"));
         Line_Of ("cli.project.configuration", Image (R.Revision (Config)));
         Line_Of ("cli.project.requirements",
                  Image (Natural (Nt.List (Store, Nt.Requirement).Length)));
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
         Line_Of ("cli.project.running", Count ("running"));
         Line_Of ("cli.project.complete", Count ("complete"));
         Line_Of ("cli.project.failed", Count ("failed"));
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

      procedure Show_Requirement (Store : in out S.Store) is
         Held : Nt.Entity;
         Read : E.Error_Info;
      begin
         if Argument (1) = "" then
            for Id of Nt.List (Store, Nt.Requirement) loop
               Nt.Read (Store, Nt.Requirement, Id, Held, Read);
               Pres.Put_Message
                 (Screen, "cli.task.item",
                  [Loc.Named ("name", Id), Loc.Named ("value", To_String (Held.State)),
                   Loc.Named ("detail", To_String (Held.Title))]);
            end loop;
            return;
         end if;
         Nt.Read (Store, Nt.Requirement, Argument (1), Held, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         Field ("title", To_String (Held.Title));
         Field ("state", To_String (Held.State));
         Field ("revision", Image (Held.Revision));
         Field ("scope", To_String (Held.Scope));
         Field ("text", To_String (Held.Text));
         Field ("criteria", To_String (Held.Criteria));
         Field ("source", To_String (Held.Source));
      end Show_Requirement;

      procedure Show_Result (Store : in out S.Store) is
         Held : Model_Runner.Framework.Results.Result;
         Read : E.Error_Info;
      begin
         Model_Runner.Framework.Results.Read (Store, Argument (1), Held, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         Field ("kind", Model_Runner.Framework.Results.Kind_Word (Held.Kind));
         Field ("producer", To_String (Held.Producer));
         Field ("created_at", To_String (Held.Created_At));
         Field ("summary", To_String (Held.Summary));
         Field ("payload", To_String (Held.Payload));
      end Show_Result;

      --  The project's verification, now, for no task in particular.
      procedure Check (Store : in out S.Store) is
         Config   : R.Item;
         Read     : E.Error_Info;
         Change   : S.Transaction;
         Evidence : Unbounded_String;
         Passed   : Boolean;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         declare
            Profile : constant String :=
              (if Argument (1) /= "" and then R.Has (Config, "profile." & Argument (1))
               then Argument (1)
               else R.Get (Config, "scalar.verification.default"));
         begin
            if Profile = "" then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "a verification profile");
               Pres.Report (Screen, Outcome);
               return;
            end if;
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
                      Loc.Named ("detail", To_String (Vf.Element (Said, Index).Message))]);
               end loop;
               Pres.Put_Message
                 (Screen, "cli.task.verified",
                  [Loc.Named ("name", To_String (Evidence)),
                   Loc.Named ("value", (if Passed then "passed" else "failed")),
                   Loc.Named ("count", Image (Vf.Length
                                (Vf.Parse_Profile (R.Get (Config, "profile." & Profile))))),
                   Loc.Named ("total", Image (Vf.Length (Said)))]);
            end;
         end;
      end Check;

      --  Documents read for what the project must be: those named, or
      --  every Markdown file at the top and in docs.
      procedure Bootstrap (Store : in out S.Store) is
         Change : S.Transaction;
         Found  : Model_Runner.Framework.Bootstrap.Output_List;
         Report : Model_Runner.Framework.Bootstrap.Report;
         Files  : Names.Vector := Positional;

         procedure Gather (Directory, Prefix : String) is
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
         begin
            if not Ada.Directories.Exists (Directory) then
               return;
            end if;
            Ada.Directories.Start_Search
              (Search, Directory, "*.md",
               [Ada.Directories.Ordinary_File => True, others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               Files.Append (Prefix & Ada.Directories.Simple_Name (Item));
            end loop;
            Ada.Directories.End_Search (Search);
         end Gather;
      begin
         if Files.Is_Empty then
            Gather (Here, "");
            Gather ("docs", "docs/");
         end if;
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
      end Bootstrap;

      --  The one candidate waiting, if there is exactly one.
      procedure Decide (Store : in out S.Store) is
         Waiting : constant Names.Vector := Tk.List (Store, "candidate");
         Listed  : Unbounded_String;
      begin
         if Waiting.Is_Empty then
            Pres.Put_Note (Screen, "cli.project.no_pending");
         elsif Natural (Waiting.Length) > 1 then
            for Id of Waiting loop
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Id);
            end loop;
            Pres.Put_Note
              (Screen, "cli.project.pending_many", [Loc.Named ("detail", To_String (Listed))]);
         else
            Command.Action := T.To_Bounded (if Word = "/accept" then "accept" else "reject");
            Command.Action_Argument := T.To_Bounded (Waiting.First_Element);
            Command.Kind := Opt.Command_Task;
         end if;
      end Decide;
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
         Command.Action := T.To_Bounded (Argument (1));
         Command.Action_Argument := T.To_Bounded (Rest (2));
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
         Command.Action_Argument := T.To_Bounded (Argument (1));
         Model_Runner.CLI.Work.Run_With (Command, Screen, Agent, Status);

      elsif Word in "/tree" | "/sym" | "/refs" | "/impact" | "/trace" then
         Command.Kind := Opt.Command_Repo;
         Command.Action := T.To_Bounded (Word (Word'First + 1 .. Word'Last));
         Command.Action_Argument := T.To_Bounded (Argument (1));
         Model_Runner.CLI.Repo.Run (Command, Screen, Status);

      elsif Word = "/state" then
         With_Store (State'Access);
      elsif Word = "/config" then
         With_Store (Show_Config'Access);
      elsif Word = "/req" then
         With_Store (Show_Requirement'Access);
      elsif Word = "/result" then
         With_Store (Show_Result'Access);
      elsif Word = "/check" then
         With_Store (Check'Access);
      elsif Word = "/bootstrap" then
         With_Store (Bootstrap'Access);
      end if;
   end Run;

end Model_Runner.CLI.Project_Commands;
