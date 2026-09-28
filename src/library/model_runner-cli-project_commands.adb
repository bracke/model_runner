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

   --  The tools the session's model may use working on a task.
   Allowed_Tools : constant array (1 .. 6) of Word_Access :=
     [new String'("read_file"), new String'("write_file"),
      new String'("list_directory"), new String'("retrieve"),
      new String'("now"), new String'("memory_get")];

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

   ---------
   -- Run --
   ---------

   overriding procedure Run
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info)
   is
      Messages : Conv.History;
      Offered  : Model_Runner.Tools.Definitions;
      Runner   : Model_Runner.Tools.Builtin.Instance;
      Guard    : aliased Fence (Self.Screen);
      Watcher  : aliased Watch (Self.Screen);
      Sink     : aliased Pres.Standard_Output_Sink;
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;
      Request  : Model_Runner.Generation.Request;
      Outcome  : Model_Runner.Agent.Outcome;
      Calls    : Natural := 0;
      Before   : constant String := Ada.Directories.Current_Directory;

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

      Conv.Open (Messages, Status => Status);
      if E.Is_Ok (Status) then
         Conv.Append (Messages, Conv.User_Role, Whole (Prompt_Path), Status);
      end if;
      if E.Is_Ok (Status) then
         Model_Runner.Tools.Read
           (Offered, Model_Runner.Tools.Builtin.All_Definitions_Text, Status);
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

      --  The work is done where the task's files are, and its own
      --  conversation is on the session, which the screen's is read back
      --  into afterwards.
      L.Reset (Self.Session.all);
      Ada.Directories.Set_Directory (Project);

      --  A model that answers without calling a tool has changed nothing,
      --  whatever its answer says; it is told so and goes on, twice at
      --  most, before its answer is taken as it stands.
      for Round in 1 .. 3 loop
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
            Max_Steps   => 24,
            Tool_Syntax => Syntax,
            Thinking    => Self.Item.Thinking,
            Approve     => Guard'Unchecked_Access,
            Watch       => Watcher'Unchecked_Access,
            Result      => Outcome);
         Calls := Calls + Outcome.Calls;
         exit when Calls > 0 or else Round = 3
           or else Outcome.Reason /= Model_Runner.Agent.Answered;
         Conv.Append
           (Messages, Conv.User_Role,
            "You have not called a tool, so no file has changed. If the task"
            & " needs a change, make it now by calling write_file, then report"
            & " again.", Status);
         exit when E.Is_Error (Status);
      end loop;
      Ada.Directories.Set_Directory (Before);
      L.Reset (Self.Session.all);

      if Conv.Length (Messages) > 0
        and then Conv.Sender_At (Messages, Conv.Length (Messages)) = Conv.Assistant_Role
      then
         Answer := To_Unbounded_String (Conv.Content_At (Messages, Conv.Length (Messages)));
      end if;
      Conv.Close (Messages);
      Model_Runner.Tools.Close (Offered);

      if Outcome.Reason /= Model_Runner.Agent.Answered then
         Status :=
           (if E.Is_Error (Outcome.Error) then Outcome.Error
            else E.Make (E.Generation_Invalid_Request));
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Before);
         L.Reset (Self.Session.all);
         Status := E.Make (E.Internal_Unexpected_Exception);
   end Run;

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
