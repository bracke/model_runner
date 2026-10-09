with Ada.Text_IO;
with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Terminal_Control;

with Model_Runner.Agent;
with Model_Runner.Agent_Runtime;
with Model_Runner.CLI.Choosers;
with Model_Runner.Platform.Signals;
with Model_Runner.CLI.Init;
with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Project_Requests;
with Model_Runner.CLI.Repo;
with Model_Runner.CLI.Tasks;
with Model_Runner.CLI.Work;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Code_Queries;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
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
with Model_Runner.Tools.Registry;
with Model_Runner.Tools.Editing;
with Model_Runner.Tools.Runner;
with Model_Runner.Tools.Schemas;

package body Model_Runner.CLI.Project_Commands is

   --  Where the session was started below the project's top; "" at it.
   --  The process's, not a session's: Recover_Here moves the process's
   --  working directory up to that top, and this is where it moved from,
   --  which every session in the process shares as it shares the
   --  directory.
   Below_Top : Ada.Strings.Unbounded.Unbounded_String;

   use Ada.Strings.Unbounded;
   use type Model_Runner.Agent.Stop_Reason;
   use type Model_Runner.Conversation.Role;

   package E renames Model_Runner.Errors;
   package Conv renames Model_Runner.Conversation;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;
   use type Tk.Core_State;
   package Nt renames Model_Runner.Framework.Intent;
   package Vf renames Model_Runner.Framework.Verification;
   package L renames Model_Runner.Llama;
   package Names renames Model_Runner.Framework.Name_Lists;

   --  The project is where the session was started.
   Here : constant String := ".";

   type Word_Access is access constant String;

   --  Which handler of Run's a command goes to: commands that share their
   --  handling share a route -- /accept and /reject, the repository's
   --  questions, the three kinds of intent.
   type Command_Route is
     (No_Route,
      Init_Route,
      Tasks_Route,
      Verdicts_Route,
      Cancel_Route,
      Work_Route,
      Repository_Route,
      State_Route,
      Config_Route,
      Intents_Route,
      Results_Route,
      Checks_Route,
      Bootstrapping_Route,
      Git_Route,
      Instructions_Route,
      Sandbox_Route,
      Reconfiguring_Route,
      Why_Route,
      History_Route,
      Brief_Route);

   --  Every project command, once: its word and the catalog key of its
   --  help line, in the order help lists them, and the handler it goes to. Whether a word is a project
   --  command and what help says of each are both read from here, so a
   --  command added here is one both know -- they were two lists kept by
   --  hand, and two such lists drift.
   --  Mid_Message says whether it may run while a message is being typed,
   --  the message kept: what looks or sets a record straight may; what
   --  starts a model's run or remakes the project's set-up waits for the
   --  message to be sent, and until then is its text.
   --  Needs says where it applies: in a project, or where there is none
   --  yet -- what /help lists here, and nothing else, unless asked for all.
   type Availability is (In_Project, Without_Project);

   type Command_Descriptor is record
      Name        : Word_Access;
      Help_Key    : Word_Access;
      Route       : Command_Route;
      Mid_Message : Boolean := True;
      Needs       : Availability := In_Project;
   end record;

   Commands : constant array (Positive range <>) of Command_Descriptor :=
     [(new String'("/init"),        new String'("cli.interactive.help.init"), Init_Route, False, Without_Project),
      (new String'("/bootstrap"),
       new String'("cli.interactive.help.bootstrap"), Bootstrapping_Route, False, In_Project),
      (new String'("/state"),       new String'("cli.interactive.help.state"), State_Route, True, In_Project),
      (new String'("/config"),      new String'("cli.interactive.help.config"), Config_Route, True, In_Project),
      (new String'("/git"),         new String'("cli.interactive.help.git"), Git_Route, True, In_Project),
      (new String'("/sandbox"),     new String'("cli.interactive.help.sandbox"), Sandbox_Route, True, In_Project),
      (new String'("/instruct"),    new String'("cli.interactive.help.instruct"), Instructions_Route, True, In_Project),
      (new String'("/reconfigure"),
       new String'("cli.interactive.help.reconfigure"), Reconfiguring_Route, False, In_Project),
      (new String'("/task"),        new String'("cli.interactive.help.task"), Tasks_Route, True, In_Project),
      (new String'("/accept"),      new String'("cli.interactive.help.accept"), Verdicts_Route, True, In_Project),
      (new String'("/reject"),      new String'("cli.interactive.help.reject"), Verdicts_Route, True, In_Project),
      (new String'("/work"),        new String'("cli.interactive.help.work"), Work_Route, False, In_Project),
      (new String'("/cancel"),      new String'("cli.interactive.help.cancel"), Cancel_Route, True, In_Project),
      (new String'("/check"),       new String'("cli.interactive.help.check"), Checks_Route, True, In_Project),
      (new String'("/req"),         new String'("cli.interactive.help.req"), Intents_Route, True, In_Project),
      (new String'("/decision"),    new String'("cli.interactive.help.decision"), Intents_Route, True, In_Project),
      (new String'("/spec"),        new String'("cli.interactive.help.spec"), Intents_Route, True, In_Project),
      (new String'("/result"),      new String'("cli.interactive.help.result"), Results_Route, True, In_Project),
      (new String'("/scan"),        new String'("cli.interactive.help.scan"), Repository_Route, True, In_Project),
      (new String'("/tree"),        new String'("cli.interactive.help.tree"), Repository_Route, True, In_Project),
      (new String'("/sym"),         new String'("cli.interactive.help.sym"), Repository_Route, True, In_Project),
      (new String'("/refs"),        new String'("cli.interactive.help.refs"), Repository_Route, True, In_Project),
      (new String'("/deps"),        new String'("cli.interactive.help.deps"), Repository_Route, True, In_Project),
      (new String'("/users"),       new String'("cli.interactive.help.users"), Repository_Route, True, In_Project),
      (new String'("/impact"),      new String'("cli.interactive.help.impact"), Repository_Route, True, In_Project),
      (new String'("/trace"),       new String'("cli.interactive.help.trace"), Repository_Route, True, In_Project),
      (new String'("/why"),         new String'("cli.interactive.help.why"), Why_Route, True, In_Project),
      (new String'("/history"),     new String'("cli.interactive.help.history"), History_Route, True, In_Project),
      (new String'("/brief"),       new String'("cli.interactive.help.brief"), Brief_Route, True, In_Project)];

   --  The tools that take a path in the tree, those of them that write,
   --  and those that ask the project's repository graph.
   function File_Tool (Named : String) return Boolean is
     (Named in "read_file" | "write_file" | "list_directory" | "edit_file" | "read_range"
              | "search_file" | "search_code" | "find");
   function Writes (Named : String) return Boolean is
     (Named in "write_file" | "edit_file");
   function Graph_Tool (Named : String) return Boolean is
     (Named in "find_symbol" | "find_references" | "dependencies" | "dependents" | "impact");

   function Image (Value : Natural) return String
   is (T.Image (Long_Long_Integer (Value)));

   --  A whole file, and whether it was read: a file not there and one
   --  that would not read are errors, IO_Open_Failed and IO_Read_Failed,
   --  and never the same as a file that is empty -- a specification that
   --  could not be read is not one that says nothing. Read within the
   --  bound every tool reads a text by, so a path to a large log or a model
   --  file is refused as too large, IO_File_Too_Large, not allocated whole.
   procedure Read_Whole
     (Path   : String;
      Text   : out Unbounded_String;
      Status : out E.Error_Info) renames Model_Runner.Tools.Editing.Read_Text;

   --  Every other tool refused, and said so.
   type Fence (Screen : not null access Pres.Console) is
     limited new Model_Runner.Agent.Approver with record
      --  What the agent may call: its capabilities, as the registry reads
      --  them -- the same that chose what it was offered.
      Can : Model_Runner.Tools.Registry.Capabilities := Model_Runner.Tools.Registry.Nothing;
   end record;

   overriding function Consider
     (Self : in out Fence; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict;

   overriding function Consider
     (Self : in out Fence; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict
   is
      pragma Unreferenced (Arguments);
   begin
      if Model_Runner.Tools.Registry.Allows (Self.Can, Named) then
         return Model_Runner.Agent.Allow;
      end if;
      Pres.Put_Note (Self.Screen.all, "cli.agent.denied", [Loc.Named ("name", Named)]);
      return Model_Runner.Agent.Deny;
   end Consider;

   package Wk renames Model_Runner.Framework.Work;
   package Pm renames Model_Runner.Framework.Permissions;

   type Host_Access is access all Wk.Child_Host'Class;

   --  What the agent does, shown as it does it and recorded on its
   --  invocation.
   --  Generated text written as it comes, and between its pieces the work
   --  asked after: ended elsewhere -- cancelled from another terminal --
   --  the turn stops there, not at its next call.
   type Watching_Sink is limited new Pres.Standard_Output_Sink with record
      Stop : Model_Runner.Cancellation.Token_Reference := null;

      --  A line that may open a call -- {, ``` or <tool_call> -- held back
      --  from where it starts: dropped when the call is made, as the call
      --  is shown in its own line; written out when it was only text.
      Held          : Unbounded_String;
      Holding       : Boolean := False;
      At_Line_Start : Boolean := True;

      --  A helper's run: what it writes is its report, which the agent
      --  that asked reads and the screen shows as that call's answer.
      Quiet         : Boolean := False;

      --  Whether standard output shows colour: an answer's JSON coloured.
      Styled        : Boolean := False;
   end record;

   --  What was held back was a call: not written.
   procedure Drop_Held (Self : in out Watching_Sink'Class);

   --  What was held back was text: written now.
   procedure Release_Held (Self : in out Watching_Sink'Class);

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean);

   type Started_Entries is array (1 .. 64) of Natural;

   type Watch
     (Screen : not null access Pres.Console;
      Host   : Host_Access)
   is limited new Model_Runner.Agent.Observer with record
      --  Where the reply is written: told of each call, so the call's own
      --  text is not shown beside it.
      Output : access Watching_Sink := null;

      --  Whether a file was written in this run: a run that then only
      --  repeats itself has done its work and is asked for its report.
      Wrote  : Boolean := False;

      --  What its calls were refused, first one of each: said with how
      --  the work ended, as what likely kept it from going on -- and
      --  whether one was a path outside the project.
      Refused : Names.Vector;
      Refused_Outside : Boolean := False;
      --  The last call that failed, and what it answered: a run going round
      --  on one is said by it.
      Last_Error : Unbounded_String;
      --  The first that failed, and how many: the root of a run gone round
      --  is its first error, not the "already made" its repeats got after.
      First_Error  : Unbounded_String;
      Errors_Count : Natural := 0;

      --  The run's own stop, asked for when its work is ended elsewhere.
      Stop  : Model_Runner.Cancellation.Token_Reference := null;

      --  The entries the state holds for this turn's calls that may change
      --  it, noted as started before they ran, by their place in the turn:
      --  each answer fills its own in.
      Started : Started_Entries := [others => 0];

      --  The agent the run started with, and the last answer shown: a
      --  helper's lines are marked with its identifier, and an answer the
      --  same as the one before is not written out again.
      Root  : Unbounded_String;
      Shown : Unbounded_String;

   end record;

   overriding procedure On_Turn
     (Self  : in out Watch;
      Step  : Positive;
      Calls : Positive);

   overriding procedure On_Call
     (Self      : in out Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String);

   overriding procedure On_Result
     (Self      : in out Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Model_Runner.Tools.Runner.Call_Outcome);

   --  A call's place in its turn as it is shown, where its turn asked for
   --  several: " #2". Nothing for the first, as its call was shown.
   function Place (Call : Model_Runner.Agent.Invocation) return String
   is (if Call.Of_Turn > 1 and then Call.In_Turn > 1
       then " #" & Ada.Strings.Fixed.Trim (Positive'Image (Call.In_Turn), Ada.Strings.Both)
       else "");

   --  Whose line it is: nothing for the agent the run started with, the
   --  helper's identifier for a helper's.
   function Whose (Self : in out Watch) return String is
   begin
      if Self.Host = null then
         return "";
      end if;
      declare
         Now : constant String := Wk.Current (Self.Host.all);
      begin
         if Self.Root = Null_Unbounded_String then
            Self.Root := To_Unbounded_String (Now);
         end if;
         return (if Now = To_String (Self.Root) or else Now = "" then "" else Now & " ");
      end;
   end Whose;

   --  Several asked at once: said so before the first is shown, as their
   --  answers come after them all, in the order asked.
   overriding procedure On_Turn
     (Self  : in out Watch;
      Step  : Positive;
      Calls : Positive)
   is
      pragma Unreferenced (Step);
   begin
      if Calls > 1 then
         Pres.Put_Note (Self.Screen.all, "cli.agent.calls_at_once");
      end if;
   end On_Turn;

   overriding procedure On_Call
     (Self      : in out Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String) is
      use type Model_Runner.Cancellation.Token_Reference;
   begin
      --  Its task ended elsewhere -- cancelled from another process -- the
      --  work stops rather than write on for a task that is not its.
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
      if Self.Output /= null then
         Drop_Held (Self.Output.all);
      end if;
      --  Each of several asked at once is numbered, as its answer is.
      Pres.Put_Tool_Call (Self.Screen.all, Whose (Self) & Named & Place (Call), Arguments);
      --  A call that may change state is in the record before it runs, so
      --  a run that stops in it leaves it said.
      if Call.In_Turn in Self.Started'Range then
         Self.Started (Call.In_Turn) := 0;
         if Self.Host /= null and then Call.Changes then
            Self.Host.Note_Start (Named, Arguments, Self.Started (Call.In_Turn));
         end if;
      end if;
   end On_Call;

   overriding procedure On_Result
     (Self      : in out Watch;
      Call      : Model_Runner.Agent.Invocation;
      Named     : String;
      Arguments : String;
      Result    : String;
      Ended     : Model_Runner.Tools.Runner.Call_Outcome)
   is
      package Tr renames Model_Runner.Tools.Runner;
      use type Tr.Answer_Kind;
      use type Tr.Refusal_Kind;

      --  What it answered past the "error: " its failures are written with.
      function Detail return String
      is (if Result'Length > 7 and then Result (Result'First .. Result'First + 6) = "error: "
          then Result (Result'First + 7 .. Result'Last) else Result);
      Owner : constant String := Whose (Self);
      --  Every answer named by its call; of several asked at once, by its
      --  number among them too.
      Label : constant String := Owner & Named & Place (Call) & ": ";
   begin
      if Ended.Answer /= Tr.Answered then
         Self.Last_Error := To_Unbounded_String (Named & ": " & Detail);
         Self.Errors_Count := Self.Errors_Count + 1;
         if Self.First_Error = Null_Unbounded_String then
            Self.First_Error := Self.Last_Error;
         end if;
      end if;
      --  The same answer as the one just shown, whatever its call's number.
      if Result = To_String (Self.Shown) then
         Pres.Put_Tool_Result (Self.Screen.all, Label & Pres.Message_Value (Self.Screen.all, "cli.agent.same_again"));
      else
         Pres.Put_Tool_Result (Self.Screen.all, Label & Result);
      end if;
      Self.Shown := To_Unbounded_String (Result);
      --  A write that changed a file: one of what the file already held is
      --  no work done.
      if Named = "write_file" and then Ended.Answer = Tr.Answered and then Ended.Changed then
         Self.Wrote := True;
      end if;
      --  Refused by a permission, a sandbox, the execution policy or the
      --  project's edge: what likely kept the work from going on.
      if Ended.Answer = Tr.Refused then
         Self.Refused_Outside := Self.Refused_Outside or else Ended.Refusal = Tr.Outside_Project;
         if Natural (Self.Refused.Length) < 3 and then not Self.Refused.Contains (Detail) then
            Self.Refused.Append (Detail);
         end if;
      end if;
      if Self.Host /= null then
         Self.Host.Note_Call
           (Named, Arguments, Result,
            Number => (if Call.In_Turn in Self.Started'Range then Self.Started (Call.In_Turn) else 0),
            --  How it ended, kept with it, for /why and /result to say.
            Ended  =>
              (case Ended.Answer is
                 when Tr.Answered => (if Ended.Changed then "answered, changed" else "answered"),
                 when Tr.Failed    => "failed",
                 when Tr.Timed_Out => "failed: timed out",
                 when Tr.Cancelled => "failed: cancelled",
                 when Tr.Refused   =>
                   (case Ended.Refusal is
                      when Tr.Outside_Project => "refused: outside the project",
                      when Tr.Harness_Owned   => "refused: the harness's own",
                      when Tr.Policy          => "refused: by the execution policy",
                      when Tr.Not_Permitted | Tr.Not_Refused => "refused: not permitted")));
      end if;
   end On_Result;

   --  Whether a path is one an agent's file tools may reach: inside the
   --  project once every link is followed, and not its state.
   function Within_Project (Path : String) return Boolean
   is (Pm.Path_Refusal (".", Path, Writing => False) = "");

   --  One tool as a model reads it.
   --  The roles the project gives permissions to -- map.permission.role.R
   --  -- as the helper's role is offered: one of them, or anything, where
   --  the project names none.
   function Configured_Roles return Names.Vector is
      Store  : S.Store;
      Status : E.Error_Info;
      Config : R.Item;
      Roles  : Names.Vector;
   begin
      if S.Is_Initialized (".") then
         S.Open_To_Read (Store, ".", Status);
         if E.Is_Ok (Status) then
            Model_Runner.Framework.Configurations.Read (Store, Config, Status);
         end if;
         S.Close (Store);
      end if;
      if E.Is_Ok (Status) then
         for Index in 1 .. R.Field_Count (Config) loop
            declare
               Field : constant String := R.Field_Name (Config, Index);
               Rest  : constant String :=
                 (if Field'Length > 20 and then Field (Field'First .. Field'First + 19)
                                               = "map.permission.role."
                  then Field (Field'First + 20 .. Field'Last) else "");
               Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".");
               Role  : constant String := (if Dot = 0 then Rest else Rest (Rest'First .. Dot - 1));
            begin
               if Role /= "" and then not Roles.Contains (Role) then
                  Roles.Append (Role);
               end if;
            end;
         end loop;
      end if;
      return Roles;
   end Configured_Roles;

   --  The role a helper may be given: one of those, or any where the
   --  project names none.
   function Role_Choices return Model_Runner.Tools.Schemas.Choice_Lists.Vector is
      Choices : Model_Runner.Tools.Schemas.Choice_Lists.Vector;
   begin
      for Role of Configured_Roles loop
         Choices.Append (Role);
      end loop;
      return Choices;
   end Role_Choices;

   --  What the agent now working can do, from its permissions: read the
   --  tree always; write where it may; ask the project's graph and run its
   --  checks where there is a project and it may; hand work to a helper
   --  where it may make children. What it is offered and what its calls
   --  are let through are both read from this, in the registry.
   function Work_Capabilities (Host : Host_Access) return Model_Runner.Tools.Registry.Capabilities is
      package Rg renames Model_Runner.Tools.Registry;
   begin
      return
        [Rg.Read_Files     => True,
         Rg.Write_Files    => Host = null or else Host.May (Pm.Write_Source) or else Host.May (Pm.Write_Specs),
         Rg.Project_Graph  => Host /= null,
         Rg.Project_Checks => Host /= null and then Host.May_Check (Host.Task_Profile),
         Rg.Delegation     => Host /= null and then Host.May (Pm.Create_Children),
         others            => False];
   end Work_Capabilities;

   --  The tools an agent is offered: those its capabilities allow.
   function Offered_Text (Host : Host_Access) return String is
     (Model_Runner.Tools.Registry.Offered (Work_Capabilities (Host), Role_Choices));

   --  The file tools, fenced by the permissions of the agent now working,
   --  and delegate, which makes a child through the harness and runs it.
   type Work_Tools
     (Agent : not null access constant Session_Agent;
      Host  : Host_Access)
   is new Model_Runner.Tools.Builtin.Instance with record
      --  The calls this agent has made, against its tool budget.
      Made : Natural := 0;

      --  How the work went, for the record: calls before its first
      --  change -- finding its way -- whole reads, reads of part, searches,
      --  questions to the graph, and checks run more than once.
      Before_Change : Natural := 0;
      Changed_Yet   : Boolean := False;
      Whole_Reads   : Natural := 0;
      Part_Reads    : Natural := 0;
      Searches      : Natural := 0;
      Graph_Asks    : Natural := 0;
      Check_Runs    : Natural := 0;
   end record;

   --  Those, in a line.
   function Figures (Self : Work_Tools'Class) return String;

   overriding procedure Run
     (Self      : in out Work_Tools;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

   --  run_checks reads the tree as it stands, and answers the same until
   --  something is written; delegate's child may write anything. The rest
   --  are the built-in tools'.
   overriding function Kind
     (Self : Work_Tools; Named : String) return Model_Runner.Tools.Runner.Call_Kind;

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean)
   is
      use type Model_Runner.Cancellation.Token_Reference;
      From : constant Positive := Item'First;
   begin
      Closed := False;
      if Self.Quiet then
         if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
            Self.Stop.Request;
         end if;
         return;
      end if;
      if Self.Holding then
         Append (Self.Held, Item);
      else
         for Index in Item'Range loop
            if Self.At_Line_Start and then Item (Index) in '{' | '`' | '<' then
               if Index > From then
                  Pres.Standard_Output_Sink (Self).Write (Item (From .. Index - 1), Closed);
               end if;
               Self.Holding := True;
               Self.Held := To_Unbounded_String (Item (Index .. Item'Last));
               exit;
            end if;
            Self.At_Line_Start :=
              Item (Index) = ASCII.LF or else (Self.At_Line_Start and then Item (Index) in ' ' | ASCII.HT);
         end loop;
         if not Self.Holding and then From <= Item'Last then
            Pres.Standard_Output_Sink (Self).Write (Item (From .. Item'Last), Closed);
         end if;
      end if;
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
   end Write;

   procedure Drop_Held (Self : in out Watching_Sink'Class) is
   begin
      Self.Held := Null_Unbounded_String;
      Self.Holding := False;
      Self.At_Line_Start := True;
   end Drop_Held;

   procedure Release_Held (Self : in out Watching_Sink'Class) is
      Closed : Boolean;
   begin
      if Self.Holding and then Self.Held /= Null_Unbounded_String then
         --  Ended on its own line, as a reply streamed whole would be
         --  before what the harness says next; a line said over and over
         --  -- a model gone round -- shown a few times and then counted.
         declare
            Shown   : Unbounded_String;
            Last    : Unbounded_String;
            Same     : Natural := 0;
            Skipped  : Natural := 0;
            In_Fence : Boolean := False;

            procedure Flush_Skipped is
            begin
               if Skipped > 0 then
                  Append (Shown, "... the same line" & Natural'Image (Skipped) & " times more" & ASCII.LF);
                  Skipped := 0;
               end if;
            end Flush_Skipped;
         begin
            for Raw of Model_Runner.Framework.Lines_Of (To_String (Self.Held)) loop
               declare
                  --  JSON in a fence, or an answer that is JSON whole, coloured
                  --  as JSON where colour shows.
                  Fence : constant Boolean :=
                    Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Left), "```") = 1;
                  Line  : constant String :=
                    (if not Self.Styled then Raw
                     elsif Fence then Raw
                     elsif In_Fence or else Pres.Looks_Like_JSON (To_String (Self.Held))
                     then Pres.JSON_Coloured (Raw)
                     else Raw);
               begin
                  if Fence then
                     In_Fence := not In_Fence;
                  end if;
                  if Raw = To_String (Last) then
                     Same := Same + 1;
                  else
                     Flush_Skipped;
                     Same := 0;
                     Last := To_Unbounded_String (Raw);
                  end if;
                  if Same < 3 then
                     Append (Shown, Line & ASCII.LF);
                  else
                     Skipped := Skipped + 1;
                  end if;
               end;
            end loop;
            Flush_Skipped;
            Pres.Standard_Output_Sink (Self).Write (To_String (Shown), Closed);
         end;
      end if;
      Drop_Held (Self);
   end Release_Held;

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
      Sink     : aliased Watching_Sink :=
        (Pres.Standard_Output_Sink with Styled => Pres.Styles_Answers (Self.Screen.all), others => <>);
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;
      Request  : Model_Runner.Generation.Request;
      Outcome  : Model_Runner.Agent.Outcome;
      Calls    : Natural := 0;
      Asked_To_Report : Boolean := False;
      --  The work as the harness saw it happen, the last round's.
      Recorded : Unbounded_String;

      --  The template's own shape of call, and where that is the JSON
      --  envelope, the bare or fenced object too: models asked for a call
      --  often write it without the envelope, the 14B ones as well.
      Written  : constant Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Templates.Syntax_Of (L.Template_Format (Self.Prepared.all));
      Syntax   : constant Model_Runner.Tools.Call_Syntax :=
        (if Model_Runner.Tools."=" (Written, Model_Runner.Tools.Tool_Call_JSON)
         then Model_Runner.Tools.Open_JSON else Written);
   begin
      Guard.Can := Work_Capabilities (Host);
      Answer := Null_Unbounded_String;
      Tokens := 0;
      Prompt_Tokens := 0;
      Watcher.Stop := Self.Cancel;
      Sink.Stop := Self.Cancel;
      Watcher.Output := Sink'Unchecked_Access;
      Sink.Quiet := not Root;

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
         --  Held back and never a call: the reply's own text, written.
         Release_Held (Sink);
         Calls := Calls + Outcome.Calls;
         Tokens := Tokens + Outcome.Generated_Tokens;
         if Length (Outcome.Work_Record) > 0 then
            Recorded := Outcome.Work_Record;
         end if;
         Prompt_Tokens := Natural'Max (Prompt_Tokens, Outcome.Prompt_Tokens);
         --  Written, then only repeating what is done: the work is there,
         --  and what is missing is its report -- asked for once, not the
         --  work failed for it.
         if Outcome.Reason = Model_Runner.Agent.Repeating and then Watcher.Wrote and then Round < 3
           and then not Asked_To_Report
         then
            Asked_To_Report := True;
            Conv.Append
              (Messages, Conv.User_Role,
               "That call was made already and its file is written; repeating it changes nothing."
               & " If the task is done, finish now with the report lines: status: done, summary:,"
               & " changed_files:.", Status);
            exit when E.Is_Error (Status);
         else
            exit when Calls > 0 or else Round = 3
              or else Outcome.Reason /= Model_Runner.Agent.Answered;
            Conv.Append
              (Messages, Conv.User_Role,
               "You have not called a tool, so no file has changed. If the task"
               & " needs a change, make it now by calling write_file, then report"
               & " again.", Status);
            exit when E.Is_Error (Status);
         end if;
      end loop;

      if Conv.Length (Messages) > 0
        and then Conv.Sender_At (Messages, Conv.Length (Messages)) = Conv.Assistant_Role
      then
         Answer := To_Unbounded_String
           (Model_Runner.Agent.Answer_Of (Conv.Content_At (Messages, Conv.Length (Messages))));
      end if;
      --  What it was refused on the way, for the outcome to say.
      --  The root's work as the harness recorded it, said when it ends: what
      --  it changed, what still fails, what it was refused.
      --  And set against its plan: the calls it made of the calls it had.
      if Root and then Length (Recorded) > 0 then
         Pres.Put_Aside
           (Self.Screen.all, "cli.agent.work_record",
            [Loc.Named ("detail",
                        To_String (Recorded)
                        & (if Host = null or else Host.Tool_Budget = 0 then ""
                           else "calls:" & Natural'Image (Calls) & " of"
                                & Natural'Image (Host.Tool_Budget) & " planned" & ASCII.LF)
                        & Figures (Runner) & ASCII.LF)]);
      end if;
      if Root then
         Self.Notes.Refused := Null_Unbounded_String;
         Self.Notes.Outside := Watcher.Refused_Outside;
         for One of Watcher.Refused loop
            Append (Self.Notes.Refused, (if Self.Notes.Refused = Null_Unbounded_String then "" else "; ") & One);
         end loop;
      end if;
      Conv.Close (Messages);
      Model_Runner.Tools.Close (Offered);

      --  What the stop asks decides what the task is told: a person's stop
      --  is a cancellation, a budget spent or a run going round is a limit
      --  -- the task waits, blocked, for more or for another way -- and the
      --  rest is the failure it was. The words are each reason's own.
      declare
         Traits : constant Model_Runner.Agent.Stop_Traits := Model_Runner.Agent.Traits_Of (Outcome.Reason);

         --  What was refused and what failed on the way, said after why.
         function On_The_Way return String is
            Met : Unbounded_String;
         begin
            for One of Watcher.Refused loop
               Append (Met, (if Met = Null_Unbounded_String then "" else "; ") & One);
            end loop;
            return (if Met = Null_Unbounded_String then ""
                    else " -- on the way it was refused: " & To_String (Met))
              & (if Watcher.First_Error = Null_Unbounded_String then ""
                 elsif Watcher.Errors_Count = 1
                 then " -- one call failed on the way: " & To_String (Watcher.First_Error)
                 else " -- calls failed on the way," & Natural'Image (Watcher.Errors_Count)
                      & " in all, the first: " & To_String (Watcher.First_Error));
         end On_The_Way;
      begin
         if Traits.Finished then
            null;
         elsif Outcome.Reason = Model_Runner.Agent.Cancelled then
            --  Stopped for work ended elsewhere, not by the person: the
            --  session's own stop is not left asked for.
            if Model_Runner.Framework.Execution.Work_Withdrawn
              and then Model_Runner.Cancellation."/=" (Self.Cancel, null)
            then
               Self.Cancel.Reset;
            end if;
            Status := E.Make (E.Generation_Cancelled);
         elsif Traits.Exhausted then
            --  A budget spent: the limit named, with what raises it.
            Status := E.Make (E.Framework_Limit_Exceeded);
            case Outcome.Reason is
               when Model_Runner.Agent.Timed_Out =>
                  E.Add_Text (Status, "name", "time");
                  E.Add_Text (Status, "detail", "the work ran out of the time it was given");
               when Model_Runner.Agent.Token_Limit =>
                  E.Add_Text (Status, "name", "the agent's token budget");
                  E.Add_Text (Status, "detail", "the model used all its tokens -- /config token_budget says which"
                              & " setting holds for this task (its kind's task.token_budget.KIND, else"
                              & " agents.token_budget, and a decision's ruling over either), and /reconfigure"
                              & " of that one gives it more");
               when others =>
                  E.Add_Text (Status, "name", "the agent's steps");
                  E.Add_Text (Status, "detail", "the model used all its steps with a call still open -- /config"
                              & " max_steps says which setting holds for this task (its kind's task.max_steps.KIND,"
                              & " else agents.max_steps, and a decision's ruling over either), and /reconfigure"
                              & " of that one gives it more");
            end case;
         elsif Outcome.Reason = Model_Runner.Agent.Repeating then
            --  Going round wants another way, not a request that was wrong.
            Status := E.Make (E.Framework_Limit_Exceeded);
            E.Add_Text (Status, "name", "the model");
            E.Add_Text (Status, "detail", "it kept repeating calls it had already made, and got no further"
                        & On_The_Way);
         elsif E.Is_Error (Outcome.Error) then
            Status := Outcome.Error;
         else
            --  Why the model stopped without answering, in words.
            Status := E.Make (E.Generation_Invalid_Request);
            E.Add_Text
              (Status, "field",
               (case Outcome.Reason is
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
      end;
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
   function Delegate
     (Self      : Work_Tools;
      Arguments : String;
      Ended     : out Model_Runner.Tools.Runner.Call_Outcome) return String
   is
      package Tr renames Model_Runner.Tools.Runner;

      --  The call failed, in the words given.
      function Fails (Text : String) return String is
      begin
         Ended := (Answer => Tr.Failed, Refusal => Tr.Not_Refused, others => <>);
         return Text;
      end Fails;

      --  The call refused: no helper may be made here.
      function Refuses (Text : String) return String is
      begin
         Ended := (Answer => Tr.Refused, Refusal => Tr.Not_Permitted, others => <>);
         return Text;
      end Refuses;

      package Rt renames Model_Runner.Agent_Runtime;
      Found    : Boolean;

      --  The contract beside the task, as every delegate reads it: what the
      --  helper starts from, what it must write, and when it is done --
      --  each said in the brief as what it is, and the outputs checked by
      --  the harness after, not taken from the helper's word.
      Contract : constant Rt.Contract := Rt.Contract_Of (Arguments, Found);
      Asked    : constant String := To_String (Contract.Task_Text);
      Brief    : constant String := Rt.Brief (Contract);
      Named_Outputs : constant Rt.Paths.Vector := Rt.Output_Paths (Contract);

      --  What each output held before the helper ran.
      Before   : constant Rt.Paths.Vector := Rt.Prints (Named_Outputs);
      Role     : constant String := To_String (Contract.Role);
      Need     : constant String := To_String (Contract.Need);
      Retry_Of : Unbounded_String;
      Told     : Unbounded_String;
   begin
      Ended := Tr.Done;
      if not Found or else Asked = "" then
         return Fails ("error: delegate needs a task string");
      --  A role is one the project names, where it names any; a tool's
      --  name is never one.
      elsif Role in "read_file" | "write_file" | "list_directory" | "run_checks" | "delegate" then
         return Fails ("error: " & Role & " is a tool, not a role: a role says what the helper is for, as reviewer");
      elsif Role /= "" and then not Configured_Roles.Is_Empty and then not Configured_Roles.Contains (Role) then
         declare
            Listed : Unbounded_String;
         begin
            for One of Configured_Roles loop
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
            end loop;
            return Fails ("error: " & Role & " is no role here; the roles are " & To_String (Listed));
         end;
      elsif Self.Host = null then
         return Refuses ("error: no helper can be made here; do the work with the other tools");
      end if;
      --  Nothing more is started for work already cancelled.
      if Model_Runner.Framework.Execution.Work_Withdrawn then
         return Fails ("error: the work was cancelled; no helper is made");
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
               return Refuses
                 ((if Told = Null_Unbounded_String then ""
                   else To_String (Told) & ASCII.LF)
                  & "error: no helper was made: " & Refusal (Status));
            end if;
            --  Where a helper's lines begin and end, said: what it does is
            --  shown as it does it, and told apart from its parent's.
            Pres.Put_Aside (Self.Agent.Screen.all, "cli.agent.helper_starts",
                            [Loc.Named ("name", To_String (Id)),
                             Loc.Named ("value", (if Role = "" then "helper" else Role)),
                             Loc.Named ("detail", (if Brief'Length > 80
                                                   then Brief (Brief'First .. Brief'First + 76) & "..."
                                                   else Brief))]);
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
            --  A run that failed and is run again is said now, before the
            --  next starts; the answer then names it, and says the last.
            if Retry then
               Pres.Put_Tool_Result (Self.Agent.Screen.all, To_String (Now));
               Told := (if Told = Null_Unbounded_String then Null_Unbounded_String else Told & ASCII.LF)
                 & To_Unbounded_String (To_String (Id) & " failed, and was run once more");
            else
               Told := (if Told = Null_Unbounded_String then Now else Told & ASCII.LF & Now);
            end if;
            --  The helper's last run is the call's ending: failed where it
            --  failed, however its answer reads.
            if not Retry and then E.Is_Error (Ran) then
               Ended := (Answer => Tr.Failed, Refusal => Tr.Not_Refused, others => <>);
            end if;
            exit when not Retry;
            Retry_Of := Id;
         end;
      end loop;

      --  The outputs it was to write, checked: written where their content
      --  is not what it was, and the call failed where one is not.
      if not Named_Outputs.Is_Empty then
         declare
            Missing_Said : constant String := Rt.Unwritten (Named_Outputs, Before);
            Written, Missing : Unbounded_String;
         begin
            Missing := To_Unbounded_String (Missing_Said);
            for Path of Named_Outputs loop
               if Ada.Strings.Fixed.Index (", " & Missing_Said & ",", ", " & Path & ",") = 0 then
                  Append (Written, (if Written = Null_Unbounded_String then "" else ", ") & Path);
               end if;
            end loop;
            Append (Told, ASCII.LF & "(the harness checked the outputs:"
                          & (if Written = Null_Unbounded_String then ""
                             else " written: " & To_String (Written) & ";")
                          & (if Missing = Null_Unbounded_String then ""
                             else " not written: " & To_String (Missing) & ";")
                          & ")");
            if Missing /= Null_Unbounded_String then
               Ended := (Answer => Tr.Failed, Refusal => Tr.Not_Refused, others => <>);
            end if;
         end;
      end if;
      return To_String (Told);
   end Delegate;

   function Figures (Self : Work_Tools'Class) return String is
     ("calls before the first change:" & Natural'Image (Self.Before_Change)
      & (if Self.Changed_Yet then "" else " (none made)")
      & "; whole reads:" & Natural'Image (Self.Whole_Reads)
      & ", reads of part:" & Natural'Image (Self.Part_Reads)
      & ", searches:" & Natural'Image (Self.Searches)
      & ", graph questions:" & Natural'Image (Self.Graph_Asks)
      & ", checks run:" & Natural'Image (Self.Check_Runs));

   overriding function Kind
     (Self : Work_Tools; Named : String) return Model_Runner.Tools.Runner.Call_Kind
   is (if Named = "run_checks" or else Graph_Tool (Named) then Model_Runner.Tools.Runner.Reads
       elsif Named = "delegate" then Model_Runner.Tools.Runner.Changes
       else Model_Runner.Tools.Builtin.Kind (Model_Runner.Tools.Builtin.Instance (Self), Named));

   overriding procedure Run
     (Self      : in out Work_Tools;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      package Tr renames Model_Runner.Tools.Runner;

      --  The call refused, by what.
      procedure Refuse (By : Tr.Refusal_Kind) is
      begin
         Outcome := (Answer => Tr.Refused, Refusal => By, others => <>);
      end Refuse;

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

      Given_Path : Boolean;
      Given : constant String :=
        Model_Runner.Tools.Builtin.Text_Argument (Arguments, "path", Given_Path);
      --  search_code with no folder searches the whole tree.
      Path  : constant String :=
        (if Given_Path then Given elsif Named in "search_code" | "find" then "." else "");
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
      --  A path written from the root -- /src/main.py -- that names a file
      --  or directory of the project once the root is taken off: the one
      --  meant, as a small model writes it.
      function Inside return String is
         Bare : Natural := Path'First;
      begin
         --  / alone, where the host's root is never the project: its top.
         if Path = "/" then
            return ".";
         elsif Path'Length < 2 or else Path (Path'First) /= '/' or else Within_Project (Path) then
            return "";
         end if;
         while Bare <= Path'Last and then Path (Bare) = '/' loop
            Bare := Bare + 1;
         end loop;
         --  Rooted where nothing on the host is: meant from the project's
         --  top, as the model was told paths are -- the longest end of it the
         --  project holds: /home/user/src/x.adb is src/x.adb where src/ is
         --  the project's, and never a home/user/ tree made inside it.
         if Ada.Directories.Exists (Path) then
            return "";
         end if;
         --  Under the project's own name -- /demo/a.txt in the project demo
         --  -- it is the project: a.txt, and /demo its top. So for every
         --  file tool alike, as the agent run apart has it.
         declare
            --  The project's own name, from a workspace's tree too, where
            --  the work is done in .model_runner/workspaces/WS/tree.
            Here    : constant String := Ada.Directories.Current_Directory;
            State   : constant Natural := Ada.Strings.Fixed.Index (Here, "/.model_runner/");
            Project : constant String :=
              Ada.Directories.Simple_Name (if State > Here'First then Here (Here'First .. State - 1) else Here);
            Rest    : constant String := Path (Bare .. Path'Last);
         begin
            if Rest = Project or else Rest = Project & "/" then
               return ".";
            elsif Rest'Length > Project'Length + 1
              and then Rest (Rest'First .. Rest'First + Project'Length) = Project & "/"
            then
               declare
                  Tail   : constant String := Rest (Rest'First + Project'Length + 1 .. Rest'Last);
                  Slash  : constant Natural := Ada.Strings.Fixed.Index (Tail, "/", Ada.Strings.Backward);
               begin
                  if Within_Project (Tail)
                    and then (Ada.Directories.Exists (Tail)
                              or else (Writes (Named)
                                       and then (Slash = 0
                                                 or else Ada.Directories.Exists (Tail (Tail'First .. Slash - 1)))))
                  then
                     return Tail;
                  end if;
               end;
            end if;
         exception
            when others =>
               null;
         end;
         --  A write goes where the path says from the project's top, and
         --  nowhere a shorter end of it happens to match: a made-up
         --  /path/to/hi.py does not overwrite the project's hi.py.
         if Writes (Named) then
            declare
               Whole  : constant String := Path (Bare .. Path'Last);
               Slash  : constant Natural := Ada.Strings.Fixed.Index (Whole, "/", Ada.Strings.Backward);
            begin
               return (if Whole /= "" and then Within_Project (Whole)
                         and then (Slash = 0 or else Ada.Directories.Exists (Whole (Whole'First .. Slash - 1)))
                       then Whole else "");
            end;
         end if;
         declare
            Start : Natural := Bare;
         begin
            loop
               declare
                  Tail   : constant String := Path (Start .. Path'Last);
                  Slash  : constant Natural := Ada.Strings.Fixed.Index (Tail, "/", Ada.Strings.Backward);
                  Folder : constant String := (if Slash = 0 then "." else Tail (Tail'First .. Slash - 1));
               begin
                  if Tail /= "" and then Within_Project (Tail)
                    and then (Ada.Directories.Exists (Tail)
                              or else (Writes (Named) and then Ada.Directories.Exists (Folder)
                                       and then (Folder /= "." or else Start = Bare)))
                  then
                     return Tail;
                  end if;
                  Start := Ada.Strings.Fixed.Index (Tail, "/");
                  exit when Start = 0;
                  Start := Start + 1;
               end;
            end loop;
            --  Nothing of it is the project's: a new file under a new
            --  directory, as written from the top.
            return (if Writes (Named) and then Within_Project (Path (Bare .. Path'Last))
                      and then Ada.Strings.Fixed.Count (Path (Bare .. Path'Last), "/") <= 1
                    then Path (Bare .. Path'Last) else "");
         exception
            when others =>
               return "";
         end;
      end Inside;
      Found_Scope : Boolean;
   begin
      Outcome := Tr.Done;
      --  Calls before the first change: the agent finding its way.
      if not Self.Changed_Yet then
         Self.Before_Change := Self.Before_Change + 1;
      end if;
      if Writes (Named) or else Named = "delegate" then
         Self.Changed_Yet := True;
      end if;
      --  Past the work's time, nothing more is done: the call is refused,
      --  and the run ends as out of time.
      if Self.Host /= null and then Wk.Time_Is_Up (Self.Host.all) then
         Outcome.Answer := Tr.Failed;
         Put ("error: the work's time is up; no further call is run");
         return;
      end if;
      if Given_Path and then File_Tool (Named) and then Inside /= "" then
         declare
            Quoted : constant String := '"' & Path & '"';
            At_Path : constant Natural := Ada.Strings.Fixed.Index (Arguments, Quoted);
         begin
            if At_Path > 0 then
               declare
                  Taken : constant String := Inside;
               begin
                  Run (Self, Named,
                       Arguments (Arguments'First .. At_Path - 1) & '"' & Taken & '"'
                       & Arguments (At_Path + Quoted'Length .. Arguments'Last),
                       Result, Last, Outcome, Status);
                  --  Read from a shorter end of the path it gave: said, so
                  --  the agent knows which file it was.
                  if not Writes (Named) and then Taken /= "." and then Last >= Result'First
                    and then Ada.Strings.Fixed.Index (Path, "/" & Taken) /= Path'First
                  then
                     declare
                        Was : constant String := Result (Result'First .. Last);
                     begin
                        Put ("(" & Path & " is taken as the project's " & Taken & ")" & ASCII.LF & Was);
                     end;
                  end if;
               end;
               return;
            end if;
         end;
      end if;
      Self.Made := Self.Made + 1;
      if Budget > 0 and then Self.Made > Budget then
         Outcome.Answer := Tr.Failed;
         Put ("error: the budget of" & Natural'Image (Budget)
              & (if Budget = 1 then " tool call" else " tool calls") & " is spent; give your answer now");
      elsif Named = "delegate" then
         Put (Delegate (Self, Arguments, Outcome));
         --  A helper that answered may have changed anything its
         --  permissions let it.
         Outcome.Changed := Tr."=" (Outcome.Answer, Tr.Answered);
      elsif Named = "find"
        and then Model_Runner.Tools.Registry.Graph_Finding
                   (Model_Runner.Tools.Builtin.Text_Argument (Arguments, "kind", Found_Scope))
      then
         Self.Graph_Asks := Self.Graph_Asks + 1;
         if Self.Host = null then
            Outcome.Answer := Tr.Failed;
            Put ("error: there is no project graph to ask here");
         else
            declare
               Asked_Failed : Boolean;
               Said : constant String :=
                 Model_Runner.Framework.Code_Queries.Find
                   (Self.Host.Store_Of.all,
                    Model_Runner.Tools.Builtin.Text_Argument (Arguments, "kind", Found_Scope),
                    Model_Runner.Tools.Builtin.Text_Argument (Arguments, "query", Found_Scope),
                    Asked_Failed);
            begin
               if Asked_Failed then
                  Outcome.Answer := Tr.Failed;
               end if;
               Put (Said);
            end;
         end if;
      elsif Graph_Tool (Named) then
         Self.Graph_Asks := Self.Graph_Asks + 1;
         if Self.Host = null then
            Outcome.Answer := Tr.Failed;
            Put ("error: there is no project graph to ask here");
         else
            declare
               Asked_Failed : Boolean;
               Said : constant String :=
                 Model_Runner.Framework.Code_Queries.Answer (Self.Host.Store_Of.all, Named, Arguments, Asked_Failed);
            begin
               if Asked_Failed then
                  Outcome.Answer := Tr.Failed;
               end if;
               Put (Said);
            end;
         end if;
      elsif Named = "run_checks" then
         if Self.Host = null then
            Outcome.Answer := Tr.Failed;
            Put ("error: no checks can be run here");
         else
            declare
               Report : Unbounded_String;
               Ran    : E.Error_Info;
            begin
               Self.Check_Runs := Self.Check_Runs + 1;
               Self.Host.Run_Checks
                 (Self.Host.Task_Profile, Report, Ran,
                  Affected => Model_Runner.Tools.Builtin.Text_Argument (Arguments, "scope", Found_Scope)
                              = "affected");
               if E.Is_Error (Ran) then
                  if E."=" (Ran.Code, E.Framework_Execution_Refused) then
                     Refuse (Tr.Policy);
                  else
                     Outcome.Answer := Tr.Failed;
                  end if;
               end if;
               Put (if E.Is_Ok (Ran) then To_String (Report)
                    else "error: the checks were not run: " & Refusal (Ran));
            end;
         end if;
      elsif File_Tool (Named)
        and then Pm.Path_Refusal (".", Path, Writing => Writes (Named)) /= ""
      then
         Refuse
           (case Pm.Path_Refused_As (".", Path, Writing => Writes (Named)) is
              when Pm.Path_Outside       => Tr.Outside_Project,
              when Pm.Path_Harness_Owned => Tr.Harness_Owned,
              when others                => Tr.Not_Permitted);
         Put ("error: " & Pm.Path_Refusal (".", Path, Writing => Writes (Named)));
      elsif File_Tool (Named) and then not Writes (Named) and then not May (Reading => True) then
         Refuse (if Within_Project (Path) then Tr.Not_Permitted else Tr.Outside_Project);
         Put ("error: you may not read " & Path
              & (if Pm.Sandbox_Refuses (Path, False) then " (" & Pm.Sandbox_Source & " confines it)" else ""));
      elsif Writes (Named) and then not May (Reading => False) then
         Refuse (if Within_Project (Path) then Tr.Not_Permitted else Tr.Outside_Project);
         Put ("error: you may not write " & Path
              & (if Pm.Sandbox_Refuses (Path, True) then " (" & Pm.Sandbox_Source & " confines it)" else "")
              & (if Self.Host = null then "" else "; you may write " & Wk.Where_Writes (Self.Host.all)));
      else
         --  What it overwrites in the project is kept as it was first; a
         --  file whose copy could not be made is not written over.
         declare
            Kept : E.Error_Info := E.Success;
         begin
            if Writes (Named) and then Self.Host /= null then
               Wk.Keep_Before_Write (Self.Host.all, Path, Kept);
            end if;
            if E.Is_Error (Kept) then
               Outcome.Answer := Tr.Failed;
               Put ("error: " & Path & " was not written: a copy of it as it was could not be"
                    & " kept first, so the write could not be undone");
            else
               Model_Runner.Tools.Builtin.Run
                 (Model_Runner.Tools.Builtin.Instance (Self), Named, Arguments, Result, Last,
                  Outcome, Status);
               --  How the work went, counted as it goes.
               if Named = "read_file"
                 and then Ada.Strings.Fixed.Index (Arguments, """first_line""") = 0
               then
                  Self.Whole_Reads := Self.Whole_Reads + 1;
               elsif Named in "read_range" | "read_file" then
                  Self.Part_Reads := Self.Part_Reads + 1;
               elsif Named in "search_file" | "search_code" | "find" then
                  Self.Searches := Self.Searches + 1;
               end if;
               --  A change said with what uses what was changed, so the
               --  agent knows what else to look at without asking.
               if Outcome.Changed and then Self.Host /= null and then E.Is_Ok (Status)
                 and then Last >= Result'First
               then
                  declare
                     Users : constant String :=
                       Model_Runner.Framework.Code_Queries.Users_Of_File (Self.Host.Store_Of.all, Path);
                     Was   : constant String := Result (Result'First .. Last);
                  begin
                     if Users /= "" then
                        Put (Was & ASCII.LF & "used by: " & Users);
                     end if;
                  end;
               end if;
            end if;
         end;
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
      Prompt : Unbounded_String;
      Tokens : Natural;
      Read   : Natural;
   begin
      --  The task's context, read: a context that would not read is the
      --  work failing, not an agent sent off with nothing to go on.
      Read_Whole (Prompt_Path, Prompt, Status);
      if E.Is_Error (Status) then
         Answer := Null_Unbounded_String;
         return;
      end if;
      --  The work is done where the task's files are, and its own
      --  conversation -- and each child's -- is on the session, which the
      --  screen's is read back into afterwards.
      L.Reset (Self.Session.all);
      Ada.Directories.Set_Directory (Project);
      Run_Loop (Self, To_String (Prompt), Host, (if Host = null then 0 else Host.Token_Budget), True,
                Answer, Tokens, Status, Read);
      --  Stopped at Ctrl-C, however the model's run then ended -- a closed
      --  backend among them: interrupted, and the task set aside.
      if E.Is_Error (Status)
        and then (Model_Runner.Framework.Execution.Cancel_Requested
                  or else Model_Runner.Framework.Execution.Work_Withdrawn)
      then
         Status := E.Make (E.Generation_Cancelled);
      end if;
      Ada.Directories.Set_Directory (Before);
      L.Reset (Self.Session.all);
      if Host /= null then
         Host.Spend (Tokens, Prompt_Tokens => Read);
      end if;
   exception
      when Failure : others =>
         Ada.Directories.Set_Directory (Before);
         L.Reset (Self.Session.all);
         Answer := Null_Unbounded_String;
         Status := E.Unexpected (Failure, "work");
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
         Resource_Class => To_Unbounded_String ("local"),
         Profile_Reserve => 0);
   end Profile;

   package Rs renames Model_Runner.Framework.Results;

   --  An issue's text with its own identifier where it says ID: it cannot
   --  hold that itself, as it is named by what it says.
   function With_Id (Id, Summary : String) return String is
      Said : constant String := "/result dismiss ";
      Mark : constant Natural := Ada.Strings.Fixed.Index (Summary, Said & "ID");
   begin
      return (if Mark = 0 then Summary
              else Summary (Summary'First .. Mark + Said'Length - 1) & Id
                   & With_Id (Id, Summary (Mark + Said'Length + 2 .. Summary'Last)));
   end With_Id;

   --  The requirements a task serves, one a line.
   function Task_Requirements (Store : S.Store; Task_Id : String) return Names.Vector is
      Defined : R.Item;
      Read    : E.Error_Info;
   begin
      Tk.Definition (Store, Task_Id, Defined, Read);
      return (if E.Is_Error (Read) then Names.Empty_Vector
              else Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")));
   end Task_Requirements;

   --  An issue as it reads now: one that a document marks an entry done
   --  names the entry made of it and the task to complete, as they stand.
   function Issue_Said (Store : S.Store; Id, Summary : String) return String is
      Generic_Step : constant String :=
        "once it is accepted, /task complete takes the task derived for it as done";
      At_Step : constant Natural := Ada.Strings.Fixed.Index (Summary, Generic_Step);
   begin
      if At_Step = 0 then
         return With_Id (Id, Summary);
      end if;
      declare
         Issue : Model_Runner.Framework.Results.Result;
         Got   : E.Error_Info;
      begin
         Model_Runner.Framework.Results.Read (Store, Id, Issue, Got, With_Payload => False);
         if E.Is_Error (Got) or else Length (Issue.Provenance) < 6
           or else Slice (Issue.Provenance, Length (Issue.Provenance) - 4, Length (Issue.Provenance)) /= "#done"
         then
            return With_Id (Id, Summary);
         end if;
         declare
            Where : constant String := Slice (Issue.Provenance, 1, Length (Issue.Provenance) - 5);
            Hash  : constant Natural := Ada.Strings.Fixed.Index (Where, "#", Ada.Strings.Backward);
            --  Made from its place; or, made under its own identifier --
            --  accepted at once -- by that identifier.
            Req  : constant String :=
              (if Nt.Find_By_Provenance (Store, Nt.Requirement, Where) /= ""
               then Nt.Find_By_Provenance (Store, Nt.Requirement, Where)
               elsif Hash > 0 and then Hash < Where'Last
                 and then Nt.State_Of (Store, Nt.Requirement, Where (Hash + 1 .. Where'Last)) /= ""
               then Where (Hash + 1 .. Where'Last)
               else "");
            Open : Unbounded_String;
         begin
            if Req = "" then
               return With_Id (Id, Summary);
            end if;
            for Task_Id of Tk.List (Store) loop
               if Open = Null_Unbounded_String and then Task_Requirements (Store, Task_Id).Contains (Req)
                 and then Tk.State_Of (Store, Task_Id) not in "complete" | "cancelled" | "rejected"
               then
                  Open := To_Unbounded_String (Task_Id);
               end if;
            end loop;
            declare
               --  Named by its own identifier already: not said again.
               Is_Said : constant String :=
                 (if Ada.Strings.Fixed.Index (Summary, Req & " is marked") > 0 then ""
                  else "it is " & Req);
            begin
               return With_Id
                 (Id, Summary (Summary'First .. At_Step - 1)
                      & (if Open /= Null_Unbounded_String
                         then (if Is_Said = "" then "" else Is_Said & ", and ")
                              & "/task complete " & To_String (Open) & " takes it as done"
                         elsif Nt.State_Of (Store, Nt.Requirement, Req) = Nt.First_State (Nt.Requirement)
                         then (if Is_Said = "" then "" else Is_Said & ": ")
                              & "once /req accept " & Req & " derives its task, /task complete takes that as done"
                         else (if Is_Said = "" then "" else Is_Said & ", and ")
                              & "/task complete takes the task derived for it as done")
                      & Summary (At_Step + Generic_Step'Length .. Summary'Last));
            end;
         end;
      end;
   end Issue_Said;

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

   --  The task an issue came from: named in it, or the task of the
   --  invocation it names.
   function Task_Of_Issue
     (Store : S.Store;
      One   : Model_Runner.Framework.Results.Result) return String
   is
      Text : constant String := To_String (One.Summary) & " " & To_String (One.Provenance);
      At_Task : constant Natural := Ada.Strings.Fixed.Index (Text, "TASK-");
      At_Inv  : constant Natural := Ada.Strings.Fixed.Index (Text, "INV-");
   begin
      if At_Task > 0 then
         declare
            Stop : Natural := At_Task + 5;
         begin
            while Stop <= Text'Last and then Text (Stop) in 'A' .. 'Z' | '0' .. '9' | '-' | '_' loop
               Stop := Stop + 1;
            end loop;
            return Text (At_Task .. Stop - 1);
         end;
      elsif At_Inv > 0 and then At_Inv + 9 <= Text'Last then
         declare
            Held : R.Item;
            Got  : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Invocations_Area, Text (At_Inv .. At_Inv + 9), Held, Got);
            if E.Is_Ok (Got) and then R.Get (Held, "task") /= "" then
               return R.Get (Held, "task");
            end if;
         end;
      end if;
      --  Else the task of the agent that made it.
      if Ada.Strings.Fixed.Index (To_String (One.Producer), "AG-") = 1 then
         declare
            Held : R.Item;
            Got  : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Runtime_Area, "agent." & To_String (One.Producer), Held, Got);
            return (if E.Is_Ok (Got) then R.Get (Held, "task") else "");
         end;
      end if;
      return "";
   end Task_Of_Issue;

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
                    --  A line that stated nothing, reworded or gone since.
                    and then Ada.Strings.Fixed.Index (Summary, "states no SHALL, MUST or SHOULD") = 0
                    and then Ada.Strings.Fixed.Index (Summary, " is marked done in ") = 0
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
            --  A done mark kept under the document's own label: that label,
            --  which its line keeps however a table sets it out.
            Done_Label : constant String :=
              (if Ada.Strings.Fixed.Index (Summary, " is marked done in ") > 0
                 and then Length (Issue.Provenance) > Mark + 5
                 and then Slice (Issue.Provenance, Length (Issue.Provenance) - 4, Length (Issue.Provenance)) = "#done"
               then Slice (Issue.Provenance, Mark + 1, Length (Issue.Provenance) - 5) else "");
            Needle : constant String :=
              (if Ada.Strings.Fixed.Index (Summary, " still says ") > 0
                  or else Ada.Strings.Fixed.Index (Summary, ", which the project already has") > 0
               then Slice (Issue.Provenance, Mark + 1, Length (Issue.Provenance))
               elsif Done_Label /= "" and then Ada.Strings.Fixed.Index (Done_Label, "-") > 0
               then Done_Label
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
      --  An issue whose own next step retires entries -- /req obsolete
      --  REQ-001 REQ-003, /decision supersede DEC-001 DEC-002 -- once each
      --  it names is retired: done as it said.
      function Step_Taken return Boolean is
         Any : Boolean := False;
      begin
         for Register in Nt.Intent_Kind loop
            for Verb of Names.Vector'(["obsolete", "supersede", "reject"]) loop
               declare
                  Word  : constant String :=
                    (case Register is
                       when Nt.Requirement   => "/req ",
                       when Nt.Specification => "/spec ",
                       when Nt.Decision      => "/decision ") & Verb & " ";
                  At_Step : constant Natural := Ada.Strings.Fixed.Index (Summary, Word);
               begin
                  if At_Step > 0 then
                     declare
                        Start : Natural := At_Step + Word'Length;
                        Stop  : Natural;
                     begin
                        loop
                           Stop := Start;
                           while Stop <= Summary'Last and then Summary (Stop) in 'A' .. 'Z' | '0' .. '9' | '-' | '_'
                           loop
                              Stop := Stop + 1;
                           end loop;
                           exit when Stop = Start
                             or else Ada.Strings.Fixed.Index (Summary (Start .. Stop - 1), "-") = 0;
                           --  supersede OLD NEW: only the old is retired.
                           if Verb /= "supersede" or else not Any then
                              if Nt.State_Of (Store, Register, Summary (Start .. Stop - 1))
                                 not in "obsolete" | "superseded" | "rejected"
                              then
                                 return False;
                              end if;
                              Any := True;
                           end if;
                           exit when Verb = "supersede" or else Stop > Summary'Last or else Summary (Stop) /= ' ';
                           Start := Stop + 1;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end loop;
         return Any;
      end Step_Taken;
      --  An entry its document marks done, once the tasks serving it are
      --  complete: taken as done, as the issue said.
      function Done_Taken return Boolean is
         Issue : Rs.Result;
         Got   : E.Error_Info;
      begin
         if Ada.Strings.Fixed.Index (Summary, " is marked done in ") = 0
           and then Ada.Strings.Fixed.Index (Summary, " is ticked as done in ") = 0
           and then Ada.Strings.Fixed.Index (Summary, " is marked ") = 0
         then
            return False;
         end if;
         Rs.Read (Store, Issue_Id, Issue, Got, With_Payload => False);
         if E.Is_Error (Got) or else Length (Issue.Provenance) < 6
           or else Slice (Issue.Provenance, Length (Issue.Provenance) - 4, Length (Issue.Provenance)) /= "#done"
         then
            return False;
         end if;
         declare
            Entry_Of : constant String := Slice (Issue.Provenance, 1, Length (Issue.Provenance) - 5);
            Req      : constant String := Nt.Find_By_Provenance (Store, Nt.Requirement, Entry_Of);
            Serving  : Natural := 0;
         begin
            if Req = "" then
               return False;
            end if;
            for Task_Id of Tk.List (Store) loop
               if Task_Requirements (Store, Task_Id).Contains (Req) then
                  if Tk.State_Of (Store, Task_Id) /= Tk.Complete then
                     return False;
                  end if;
                  Serving := Serving + 1;
               end if;
            end loop;
            return Serving > 0;
         end;
      end Done_Taken;
   begin
      if Ada.Strings.Fixed.Index (Summary, "output of ") = Summary'First then
         return True;
      elsif Step_Taken or else Done_Taken then
         return True;
      end if;
      --  A record bootstrap did not propose, for what it says of itself:
      --  done with once the record is gone, or an entry made of it says it.
      if Ada.Strings.Fixed.Index (Summary, ", so it is not proposed: ") > 0 then
         declare
            Issue : Rs.Result;
            Got   : E.Error_Info;
         begin
            Rs.Read (Store, Issue_Id, Issue, Got);
            if E.Is_Ok (Got) and then Ada.Strings.Unbounded.Index (Issue.Provenance, "#") > 0 then
               declare
                  Whole : constant String := To_String (Issue.Provenance);
                  Mark  : constant Natural := Ada.Strings.Fixed.Index (Whole, "#");
                  Path  : constant String := Whole (Whole'First .. Mark - 1);
                  Entry_Of : constant String :=
                    (if Whole'Length > 8 and then Whole (Whole'Last - 7 .. Whole'Last) = "#retired"
                     then Whole (Whole'First .. Whole'Last - 8) else Whole);
               begin
                  if not Ada.Directories.Exists
                           (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), Path))
                    or else (for some Kind in Nt.Requirement .. Nt.Decision =>
                               Nt.Find_By_Provenance (Store, Kind, Entry_Of) /= "")
                  then
                     return True;
                  end if;
               end;
            end if;
         end;
      end if;
      --  A call's failure, or what an agent reported, on work since done:
      --  the work that followed dealt with it -- and one of an attempt a
      --  later attempt of the same task came after: that one says it now.
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
            if E.Is_Ok (Got) and then R.Get (Held, "task") /= "" then
               for Other of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
                  declare
                     Later : R.Item;
                     Read  : E.Error_Info;
                  begin
                     if Other > Call then
                        S.Read (Store, Model_Runner.Framework.Invocations_Area, Other, Later, Read);
                        if E.Is_Ok (Read) and then R.Get (Later, "task") = R.Get (Held, "task")
                          and then R.Get (Later, "parent") = ""
                        then
                           return True;
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end if;
      end;
      if Document_Dropped then
         return True;
      end if;
      --  A labelled line that stated nothing, made an entry since: what it
      --  said is a requirement now.
      declare
         Issue : Rs.Result;
         Got   : E.Error_Info;
      begin
         Rs.Read (Store, Issue_Id, Issue, Got, With_Payload => False);
         if E.Is_Ok (Got) and then Length (Issue.Provenance) > 9
           and then Slice (Issue.Provenance, Length (Issue.Provenance) - 8, Length (Issue.Provenance)) = "#unstated"
           and then Nt.Find_By_Provenance
                      (Store, Nt.Requirement, Slice (Issue.Provenance, 1, Length (Issue.Provenance) - 9)) /= ""
         then
            return True;
         end if;
      end;
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

   --  Words as said, whatever their case and closing stop: two
   --  instructions that differ only so say the same.
   function Plain_Words (Text : String) return String is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));
      Stop  : Natural := Lower'Last;
   begin
      while Stop >= Lower'First and then Lower (Stop) in '.' | '!' | ';' | ' ' loop
         Stop := Stop - 1;
      end loop;
      return Lower (Lower'First .. Stop);
   end Plain_Words;

   -------------------
   -- Started_Below --
   -------------------

   function Started_Below return String is (To_String (Below_Top));

   -----------------
   -- Open_Issues --
   -----------------

   function Open_Issues (Store : S.Store) return Names.Vector is
      package Rs renames Model_Runner.Framework.Results;
      package Tk renames Model_Runner.Framework.Tasks;
      Dismissed : constant Names.Vector := Dismissed_List (Store);
      Result    : Names.Vector;
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
              and then not (Task_Of_Issue (Store, One) /= ""
                            and then Tk.State_Of (Store, Task_Of_Issue (Store, One))
                                       in "accepted" | "running" | "verification" | "complete"
                                        | "cancelled" | "rejected")
            then
               Result.Append (Result_Id);
            end if;
         end;
      end loop;
      return Result;
   end Open_Issues;

   ----------------------
   -- Dismissed_Issues --
   ----------------------

   function Dismissed_Issues (Store : S.Store) return Names.Vector is (Dismissed_List (Store));

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
      --  Started below a project's top, as git is: the project above is the
      --  one worked on, and the session moves there -- not a second one
      --  started inside it.
      if not S.Is_Initialized (Here) then
         declare
            Above : Unbounded_String :=
              To_Unbounded_String (Ada.Directories.Current_Directory);
         begin
            loop
               declare
                  Parent : constant String :=
                    Ada.Directories.Containing_Directory (To_String (Above));
               begin
                  exit when Parent = To_String (Above) or else Parent = "";
                  Above := To_Unbounded_String (Parent);
                  if S.Is_Initialized (Parent) then
                     declare
                        Started : constant String := Ada.Directories.Current_Directory;
                     begin
                        if Started'Length > Parent'Length + 1 then
                           Below_Top := To_Unbounded_String
                             (Started (Started'First + Parent'Length + 1 .. Started'Last));
                        end if;
                     end;
                     Ada.Directories.Set_Directory (Parent);
                     Pres.Put_Note (Screen, "cli.project.found_above", [Loc.Named ("path", Parent)]);
                     exit;
                  end if;
               end;
            end loop;
         exception
            when others =>
               null;
         end;
      end if;
      if not S.Is_Initialized (Here) then
         return;
      end if;
      S.Open (Store, Here, Report, Status);
      if E.Is_Ok (Status) then
         Model_Runner.Framework.Work.Recover_On_Opening (Store, Report, Said, Status);
      elsif E."=" (Status.Code, E.Framework_Locked) then
         --  Another run holds it: nothing of this session stops, and what
         --  only looks reads it meanwhile.
         S.Open_To_Read (Store, Here, Status);
         if E.Is_Ok (Status) then
            Pres.Put_Note (Screen, "cli.project.held_at_open");
         end if;
      end if;
      if E.Is_Error (Status) then
         Pres.Report (Screen, Status);
      end if;
      for Line of Said loop
         Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
      end loop;

      --  The project worked on, in a line: what is ready and what waits.
      if E.Is_Ok (Status) then
         declare
            Ready_Count : Natural := 0;
         begin
            for Id of Tk.List (Store, "accepted") loop
               if Tk.Ready (Store, Id).Ready then
                  Ready_Count := Ready_Count + 1;
               end if;
            end loop;
            Pres.Put_Note (Screen, "cli.project.opening_line",
                           [Loc.Named ("name", S.Project_Name (Store)),
                            Loc.Named ("count", Image (Ready_Count)),
                            Loc.Named ("total", Image (Natural (Tk.List (Store, "candidate").Length)
                                                       + Natural (Model_Runner.CLI.Intents.Pending (Store).Length)))]);
         end;
      end if;

      --  Work finished and waiting on a person to be taken in: said as the
      --  session opens, not left for /state to find.
      if E.Is_Ok (Status) then
         declare
            Waiting : Unbounded_String;
            Count   : Natural := 0;
         begin
            for Id of Tk.List (Store, "verification") loop
               if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
                  Count := Count + 1;
                  Append (Waiting, (if Waiting = Null_Unbounded_String then "" else ", ")
                                   & "/task integrate " & Id);
               end if;
            end loop;
            if Count > 0 then
               Pres.Put_Note (Screen, "cli.project.opening_waiting",
                              [Loc.Named ("count", Image (Count)),
                               Loc.Named ("detail", To_String (Waiting))]);
            end if;
         end;
         --  Tasks set aside, and why in a word each: said as the session
         --  opens, with where the rest is.
         declare
            Stuck : Unbounded_String;
            Count : Natural := 0;

            procedure Take (State_Name : String) is
            begin
               for Id of Tk.List (Store, State_Name) loop
                  --  A parent waiting for its parts is not set aside: it
                  --  goes on once they are done.
                  if State_Name = "blocked"
                    and then (for some Part of Tk.Children (Store, Id) =>
                                Tk.State_Of (Store, Part) not in "complete" | "cancelled" | "rejected")
                  then
                     goto Next_Task;
                  end if;
                  Count := Count + 1;
                  if Count <= 5 then
                     Append (Stuck, (if Stuck = Null_Unbounded_String then "" else ", ")
                                    & Id & " " & State_Name);
                  end if;
                  <<Next_Task>>
               end loop;
            end Take;
         begin
            Take ("blocked");
            Take ("failed");
            if Count > 0 then
               Pres.Put_Note (Screen, "cli.project.opening_stuck",
                              [Loc.Named ("count", Image (Count)),
                               Loc.Named ("detail", To_String (Stuck) & (if Count > 5 then ", ..." else ""))]);
            end if;
         end;
      end if;
      S.Close (Store);
   end Recover_Here;

   ------------------------
   -- Is_Project_Command --
   ------------------------

   function Is_Project_Command (Word : String) return Boolean
   is (for some Known of Commands => Known.Name.all = Word);

   function Runs_Mid_Message (Word : String) return Boolean
   is (for some Known of Commands => Known.Name.all = Word and then Known.Mid_Message);

   ----------------------
   -- Project_Revision --
   ----------------------

   function Project_Revision return Natural is
      Store  : S.Store;
      Opened : E.Error_Info;
   begin
      if not Ada.Directories.Exists (Here & "/.model_runner") then
         return 0;
      end if;
      S.Open_To_Read (Store, Here, Opened);
      if E.Is_Error (Opened) then
         return 0;
      end if;
      return Revision : constant Natural := Model_Runner.Framework.Events.Revision (Store) do
         S.Close (Store);
      end return;
   exception
      when others =>
         return 0;
   end Project_Revision;

   -------------------
   -- Changes_Since --
   -------------------

   function Changes_Since (Seen : in out Natural) return String is
      package Ev renames Model_Runner.Framework.Events;
      Now    : constant Natural := Project_Revision;
      Store  : S.Store;
      Opened : E.Error_Info;
      Said   : Unbounded_String;
      Shown  : Natural := 0;
      Most   : constant := 8;
   begin
      if Now <= Seen then
         Seen := Natural'Max (Seen, Now);
         return "";
      end if;
      S.Open_To_Read (Store, Here, Opened);
      if E.Is_Ok (Opened) then
         declare
            Since : constant Ev.Event_List := Ev.Since (Store, Seen);
            Count : constant Natural := Ev.Length (Since);
         begin
            for Index in Natural'Max (1, Count - Most + 1) .. Count loop
               declare
                  One : constant Ev.Event := Ev.Element (Since, Index);
               begin
                  Append (Said, "- " & To_String (One.Kind_Word) & " " & To_String (One.Subject)
                          & (if Length (One.Detail) = 0 then "" else ": " & To_String (One.Detail))
                          & ASCII.LF);
                  Shown := Shown + 1;
               end;
            end loop;
            if Count > Shown then
               Said := To_Unbounded_String ("- (" & Image (Count - Shown) & " earlier)" & ASCII.LF) & Said;
            end if;
         end;
         S.Close (Store);
      end if;
      Seen := Now;
      return (if Said = Null_Unbounded_String then ""
              else "(note from the harness, not the user: the project's state changed since your last"
                   & " turn -- what was said before about it may be out of date; the project is"
                   & " authoritative, /state shows it)" & ASCII.LF & To_String (Said) & ASCII.LF);
   exception
      when others =>
         Seen := Now;
         return "";
   end Changes_Since;

   --  A command's route, or No_Route for a word that is none.
   function Route_Of (Word : String) return Command_Route is
   begin
      for Known of Commands loop
         if Known.Name.all = Word then
            return Known.Route;
         end if;
      end loop;
      return No_Route;
   end Route_Of;

   ----------
   -- Help --
   ----------

   procedure Help (Screen : in out Model_Runner.Presentation.Console; All_Of_Them : Boolean := False) is
      --  Where this session stands: in a project or not.
      Here_Is : constant Availability :=
        (if Ada.Directories.Exists (Here & "/.model_runner") then In_Project else Without_Project);
      Left    : Natural := 0;
   begin
      for Command of Commands loop
         if All_Of_Them or else Command.Needs = Here_Is then
            Pres.Put_Help_Line (Screen, Command.Help_Key.all);
         else
            Left := Left + 1;
         end if;
      end loop;
      if Left > 0 then
         Pres.Put_Note (Screen, "cli.interactive.help_more", [Loc.Named ("count", Image (Left))]);
      end if;
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

      --  Whether the quotes of the word being read are kept: words of a
      --  value, not the quoting of a whole one.
      Kept_Quote : Boolean := False;
   begin
      for Index in Line'Range loop
         declare
            Char : constant Character := Line (Index);
         begin
            if Single then
               if Char = ''' and then (Index = Line'Last or else Line (Index + 1) in ' ' | ASCII.HT) then
                  Single := False;
                  --  Quoted words inside a field's value are its words,
                  --  quotes and all: returns 'Hello' keeps them.
                  if Kept_Quote then
                     Append (Current, Char);
                     Kept_Quote := False;
                  end if;
               else
                  Append (Current, Char);
               end if;
               Started := True;
            elsif Char = ''' and then not Quoted and then not Escape
              and then (not Started
                        or else (Length (Current) > 0 and then Element (Current, Length (Current)) = '='))
            then
               Single := True;
               --  A word of a value after NAME= went before: its quotes kept.
               Kept_Quote := not Started
                 and then (for some Word of Result =>
                             Ada.Strings.Fixed.Index (Word, "=") > 1 and then Word (Word'First) /= '-');
               if Kept_Quote then
                  Append (Current, Char);
               end if;
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

   --  The words of a line with each identifier as the project keeps it:
   --  task-8, TASK-8 and -- where a task is what is named -- 8 alone are
   --  TASK-008; req-1 is REQ-001; REQ-CALC-3 is REQ-CALC-003.
   --  A yes or no read from the person: anything else asked again, a
   --  command typed in its place said and not run, and no answer a no.
   function Answered_Yes (Screen : in out Pres.Console) return Boolean is
   begin
      return Model_Runner.CLI.Choosers.Answered_Yes (Screen);
   end Answered_Yes;

   --  A number typed that names two entries -- REQ-001 and a document's
   --  own REQ-1 -- found while the words were read: said, not guessed.
   Number_Ambiguity : Unbounded_String;

   function Identifiers_As_Kept (Words : Names.Vector) return Names.Vector is
      Result : Names.Vector;

      function Padded (Number : String) return String
      is (if Number'Length >= 3 then Number else [1 .. 3 - Number'Length => '0'] & Number);

      function All_Digits (Text : String) return Boolean
      is (Text'Length in 1 .. 6 and then (for all C of Text => C in '0' .. '9'));

      --  The project's state directory, here or above; "" outside one.
      function State_Directory return String is
         Here : Unbounded_String := To_Unbounded_String (Ada.Directories.Current_Directory);
      begin
         for Ignored in 1 .. 64 loop
            if Ada.Directories.Exists (To_String (Here) & "/.model_runner") then
               return To_String (Here) & "/.model_runner";
            end if;
            declare
               Up : constant String := Ada.Directories.Containing_Directory (To_String (Here));
            begin
               exit when Up = To_String (Here);
               Here := To_Unbounded_String (Up);
            end;
         end loop;
         return "";
      exception
         when others =>
            return "";
      end State_Directory;

      State : constant String := State_Directory;

      --  Whether the project holds an item under this identifier as written.
      function Held_As (Id : String) return Boolean is
         Area : constant String :=
           (if Id'Length > 4 and then Id (Id'First .. Id'First + 3) = "REQ-" then "requirements"
            elsif Id'Length > 4 and then Id (Id'First .. Id'First + 3) = "DEC-" then "decisions"
            elsif Id'Length > 5 and then Id (Id'First .. Id'First + 4) = "SPEC-" then "specs"
            elsif Id'Length > 5 and then Id (Id'First .. Id'First + 4) = "TASK-" then "tasks"
            else "");
      begin
         return State /= "" and then Area /= ""
           and then Ada.Directories.Exists (State & "/" & Area & "/" & Id & ".rec");
      end Held_As;

      --  The entry a document's own label was read into: a requirement or
      --  a decision whose provenance ends #LABEL; "" for none.
      function Labelled (Label : String) return String is
         Mark   : constant String := "#" & Label;
         Search : Ada.Directories.Search_Type;
         Found  : Ada.Directories.Directory_Entry_Type;
      begin
         if State = "" then
            return "";
         end if;
         for Area of Names.Vector'(["requirements", "decisions"]) loop
            if Ada.Directories.Exists (State & "/" & Area) then
               Ada.Directories.Start_Search
                 (Search, State & "/" & Area, "*.rec", [Ada.Directories.Ordinary_File => True, others => False]);
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  declare
                     File : Ada.Text_IO.File_Type;
                     Name : constant String := Ada.Directories.Simple_Name (Found);
                  begin
                     Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Ada.Directories.Full_Name (Found));
                     while not Ada.Text_IO.End_Of_File (File) loop
                        declare
                           Line : constant String := Ada.Text_IO.Get_Line (File);
                        begin
                           if Line'Length > Mark'Length
                             and then Line (Line'Last - Mark'Length + 1 .. Line'Last) = Mark
                           then
                              Ada.Text_IO.Close (File);
                              Ada.Directories.End_Search (Search);
                              --  A kept revision's record is its entry's: the
                              --  label names the entry, as it now is.
                              declare
                                 Base : constant String := Name (Name'First .. Name'Last - 4);
                                 Rev  : constant Natural := Ada.Strings.Fixed.Index (Base, ".rev-");
                              begin
                                 return (if Rev > 0 then Base (Base'First .. Rev - 1) else Base);
                              end;
                           end if;
                        end;
                     end loop;
                     Ada.Text_IO.Close (File);
                  exception
                     when others =>
                        if Ada.Text_IO.Is_Open (File) then
                           Ada.Text_IO.Close (File);
                        end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
            end if;
         end loop;
         return "";
      end Labelled;

      --  A number that names both the padded entry and a document's own
      --  unpadded one: the two kept, to be said.
      procedure Check_Both (Prefix, Number : String) is
         Bare : constant String := Ada.Strings.Fixed.Trim (Number, Ada.Strings.Maps.To_Set ("0"),
                                                           Ada.Strings.Maps.Null_Set);
      begin
         if Bare /= "" and then Padded (Number) /= Bare
           and then Held_As (Prefix & Padded (Number)) and then Held_As (Prefix & Bare)
         then
            Number_Ambiguity := To_Unbounded_String (Prefix & Padded (Number) & " and " & Prefix & Bare);
         end if;
      end Check_Both;

      function Kept (Word : String) return String is
         Upper : constant String := Ada.Characters.Handling.To_Upper (Word);
         Dash  : constant Natural := Ada.Strings.Fixed.Index (Upper, "-", Ada.Strings.Backward);
      begin
         --  Kept as a document numbered it -- REQ-1 -- it is that one.
         if Held_As (Upper) then
            return Upper;
         end if;
         --  A document's own label -- FR-001 -- is the entry read from it.
         if Dash > Upper'First and then Ada.Strings.Fixed.Index (Upper, "REQ-") /= Upper'First
           and then Ada.Strings.Fixed.Index (Upper, "TASK-") /= Upper'First
           and then Labelled (Upper) /= ""
         then
            return Labelled (Upper);
         end if;
         if Dash > Upper'First
           and then (Ada.Strings.Fixed.Index (Upper, "TASK-") = Upper'First
                     or else Ada.Strings.Fixed.Index (Upper, "REQ-") = Upper'First
                     or else Ada.Strings.Fixed.Index (Upper, "DEC-") = Upper'First
                     or else Ada.Strings.Fixed.Index (Upper, "SPEC-") = Upper'First)
           and then All_Digits (Upper (Dash + 1 .. Upper'Last))
           and then (for all C of Upper => C in 'A' .. 'Z' | '0' .. '9' | '-' | '_')
         then
            Check_Both (Upper (Upper'First .. Dash), Upper (Dash + 1 .. Upper'Last));
            declare
               Bare : constant String :=
                 Ada.Strings.Fixed.Trim (Upper (Dash + 1 .. Upper'Last), Ada.Strings.Maps.To_Set ("0"),
                                         Ada.Strings.Maps.Null_Set);
            begin
               if Bare /= ""
                 and then not Held_As (Upper (Upper'First .. Dash) & Padded (Upper (Dash + 1 .. Upper'Last)))
                 and then Held_As (Upper (Upper'First .. Dash) & Bare)
               then
                  return Upper (Upper'First .. Dash) & Bare;
               end if;
            end;
            --  Held neither way: as typed, so what is not there is said
            --  by the name it was asked by.
            return (if Held_As (Upper (Upper'First .. Dash) & Padded (Upper (Dash + 1 .. Upper'Last)))
                    then Upper (Upper'First .. Dash) & Padded (Upper (Dash + 1 .. Upper'Last))
                    else Upper);
         end if;
         return Word;
      end Kept;

      Command : constant String := (if Words.Is_Empty then "" else Words.First_Element);

      --  What a number alone at a place stands for: TASK- where a task is
      --  named, REQ-, SPEC- or DEC- where the register's entry is.
      function Number_Kind (Index : Positive) return String;

      function Number_Kind (Index : Positive) return String is
         Act : constant String :=
           (if Natural (Words.Length) >= 2 then Ada.Characters.Handling.To_Lower (Words (2)) else "");
      begin
         if Command in "/work" | "/cancel" and then Index >= 2 then
            return "TASK-";
         elsif Command = "/task" and then Index >= 3
           and then Act in "show" | "audit" | "accept" | "reject" | "cancel" | "complete" | "verify"
                         | "integrate" | "diff" | "edit" | "depend" | "split" | "reopen" | "reconsider"
                         | "move" | "rehome" | "context" | "plan"
         then
            return "TASK-";
         --  The task alone: a note's words and a capability are not
         --  identifiers for being numbers.
         elsif Command = "/task" and then Index = 3 and then Act in "note" | "grant" | "withhold" then
            return "TASK-";
         elsif Command = "/task" and then Act = "link" then
            return (if Index = 3 then "TASK-" elsif Index >= 4 then "REQ-" else "");
         elsif Command in "/req" | "/spec" | "/decision" and then Index = 3 and then Act = "move" then
            return (if Command = "/req" then "REQ-" elsif Command = "/spec" then "SPEC-" else "DEC-");
         elsif Command = "/instruct" and then Index = 3 and then Act = "withdraw" then
            return "INSTR-";
         elsif Command in "/req" | "/spec" | "/decision"
           and then ((Index >= 3
                      and then Act in "show" | "accept" | "reject" | "reconsider" | "obsolete" | "block"
                                    | "unblock" | "verify" | "trace")
                     --  The entry alone: a ruling, a text or a target is not
                     --  an identifier for being a number.
                     or else (Index = 3 and then Act in "link" | "unlink" | "govern" | "revise")
                     or else (Index in 3 .. 4 and then Act = "supersede"))
         then
            return (if Command = "/req" then "REQ-" elsif Command = "/spec" then "SPEC-" else "DEC-");
         --  A link's target by its relation: a task is TASK-, a dependency
         --  of the command's own register.
         elsif Command in "/req" | "/spec" | "/decision" and then Index = 5 and then Act in "link" | "unlink"
           and then Natural (Words.Length) >= 4
         then
            declare
               Relation : constant String := Ada.Characters.Handling.To_Lower (Words (4));
            begin
               return (if Relation in "task" | "served_by" | "tasks" then "TASK-"
                       elsif Relation in "dependency" | "depends_on" | "depends"
                       then (if Command = "/req" then "REQ-" elsif Command = "/spec" then "SPEC-" else "DEC-")
                       else "");
            end;
         elsif Command in "/check" | "/trace" and then Index >= 2 then
            return "REQ-";
         end if;
         return "";
      end Number_Kind;
   begin
      --  What the code is asked about is a name in the code, as typed: a
      --  document's label is not an entry there.
      if Command in "/refs" | "/sym" | "/deps" | "/users" | "/impact" | "/tree" | "/scan" then
         return Words;
      end if;
      for Index in 1 .. Natural (Words.Length) loop
         declare
            Word : constant String := Words (Index);
         begin
            --  A number alone where an identifier is named: a task's, or
            --  the register's the command is about.
            if All_Digits (Word) and then Number_Kind (Index) /= "" then
               Check_Both (Number_Kind (Index), Word);
               --  The register's own way of numbering: REQ-1 where it holds
               --  that and no REQ-001.
               declare
                  Bare : constant String := Ada.Strings.Fixed.Trim (Word, Ada.Strings.Maps.To_Set ("0"),
                                                                    Ada.Strings.Maps.Null_Set);
               begin
                  if Bare /= "" and then not Held_As (Number_Kind (Index) & Padded (Word))
                    and then Held_As (Number_Kind (Index) & Bare)
                  then
                     Result.Append (Number_Kind (Index) & Bare);
                  else
                     Result.Append (Number_Kind (Index) & Padded (Word));
                  end if;
               end;

            --  parent=2, depends_on=1,3, requirements=4: the identifiers a
            --  task's fields hold, each as typed.
            elsif Command = "/task" and then Ada.Strings.Fixed.Index (Word, "=") > 1 then
               declare
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
                  Name  : constant String := Ada.Characters.Handling.To_Lower (Word (Word'First .. Equal - 1));
                  Kind  : constant String :=
                    (if Name in "parent" | "depends_on" then "TASK-"
                     elsif Name = "requirements" then "REQ-" else "");
                  Value : constant String := Word (Equal + 1 .. Word'Last);
                  Out_V : Unbounded_String;
                  Start : Natural := Value'First;
               begin
                  if Kind = "" or else Value = "" then
                     Result.Append (Word);
                  else
                     for At_Index in Value'First .. Value'Last + 1 loop
                        if At_Index > Value'Last or else Value (At_Index) = ',' then
                           declare
                              One : constant String := Value (Start .. At_Index - 1);
                           begin
                              Append (Out_V, (if All_Digits (One) then Kind & Padded (One)
                                              elsif One = "" then "" else Kept (One))
                                             & (if At_Index > Value'Last then "" else ","));
                           end;
                           Start := At_Index + 1;
                        end if;
                     end loop;
                     Result.Append (Word (Word'First .. Equal) & To_String (Out_V));
                  end if;
               end;
            elsif Index > 1 and then Ada.Strings.Fixed.Index (Word, "=") = 0 then
               Result.Append (Kept (Word));
            else
               Result.Append (Word);
            end if;
         end;
      end loop;
      return Result;
   end Identifiers_As_Kept;

   ---------
   -- Run --
   ---------

   --  The exit status the last command's own part set, beside what the
   --  console counted of the errors it reported.
   Last_Status : Natural := 0;

   --  Whether a task's finished work waits in a workspace to be taken in.
   function Waiting_In_Workspace (Task_Id : String) return Boolean is
      Store  : S.Store;
      Read   : E.Error_Info;
      Result : Boolean := False;
   begin
      if S.Is_Initialized (Ada.Directories.Current_Directory) then
         S.Open_To_Read (Store, Ada.Directories.Current_Directory, Read);
         if E.Is_Ok (Read) then
            Result := Tk.State_Of (Store, Task_Id) = Tk.Verification
              and then Model_Runner.Framework.Workspaces.Active_For (Store, Task_Id) /= "";
            S.Close (Store);
         end if;
      end if;
      return Result;
   exception
      when others =>
         return False;
   end Waiting_In_Workspace;

   --  Whether a /work just ended with echo held off: a line typed during
   --  it was not shown, and is shown as it is taken up.
   Typed_Ahead : Boolean := False;

   function Last_Refusals
     (Agent : Model_Runner.Framework.Work.Agent_Runner'Class) return String
   is (if Agent in Session_Agent'Class
       then To_String (Session_Agent'Class (Agent).Notes.Refused) else "");

   function Refused_Outside
     (Agent : Model_Runner.Framework.Work.Agent_Runner'Class) return Boolean
   is (Agent in Session_Agent'Class and then Session_Agent'Class (Agent).Notes.Outside);

   function Typed_During_Work return Boolean is
      Was : constant Boolean := Typed_Ahead;
   begin
      Typed_Ahead := False;
      return Was;
   end Typed_During_Work;

   --  Of a fault's account, what was raised and the first place in the
   --  source it passed: enough to find it, not the whole stack.
   function Where_Raised (Information : String) return String is
      Result : Unbounded_String;
      Placed : Boolean := False;
   begin
      for Line of Model_Runner.Framework.Lines_Of (Information) loop
         if Result = Null_Unbounded_String then
            Result := To_Unbounded_String (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both));
         elsif not Placed and then Ada.Strings.Fixed.Index (Line, ".adb:") > 0 then
            Append (Result, ", in " & Ada.Strings.Fixed.Trim
                                         (Line (Ada.Strings.Fixed.Index (Line, " ", Line'First + 3) .. Line'Last),
                                          Ada.Strings.Both));
            Placed := True;
         end if;
      end loop;
      return To_String (Result);
   end Where_Raised;

   ----------------
   -- Request_Of --
   ----------------

   function Request_Of (Line : String) return Model_Runner.CLI.Command_Lines.Request is
      All_Words : constant Names.Vector := Identifiers_As_Kept (Split (Line));
      Result    : Model_Runner.CLI.Command_Lines.Request;
      Continues : Boolean := False;
      Is_Note   : Boolean;
   begin
      if All_Words.Is_Empty then
         return Result;
      end if;
      Result.Word := To_Unbounded_String (All_Words.First_Element);
      Is_Note := All_Words.First_Element = "/task" and then Natural (All_Words.Length) >= 4
        and then All_Words (2) = "note";
      --  A note is free text: kept as it was typed -- its quotes, its
      --  NAME=VALUE words -- not taken apart into settings.
      if Is_Note then
         declare
            Cursor : Natural := Line'First;
         begin
            for Skipped in 1 .. 3 loop
               while Cursor <= Line'Last and then Line (Cursor) in ' ' | ASCII.HT loop
                  Cursor := Cursor + 1;
               end loop;
               while Cursor <= Line'Last and then Line (Cursor) not in ' ' | ASCII.HT loop
                  Cursor := Cursor + 1;
               end loop;
            end loop;
            Result.Positional.Append (All_Words (2));
            Result.Positional.Append (All_Words (3));
            Result.Positional.Append (Ada.Strings.Fixed.Trim (Line (Cursor .. Line'Last), Ada.Strings.Both));
            Result.Free_Last := True;
         end;
         return Result;
      end if;
      for Index in 2 .. Natural (All_Words.Length) loop
         declare
            Part : constant String := All_Words (Index);
         begin
            --  --set before NAME=VALUE, as the shell spells it, is the
            --  same as NAME=VALUE alone.
            if Part = "--set" then
               null;
            elsif Is_Setting (Part) and then Ada.Strings.Fixed.Head (Part, 2) /= "--" then
               Result.Settings.Append (Part);
               Continues := True;
            elsif Continues and then Ada.Strings.Fixed.Head (Part, 2) /= "--" then
               --  A value runs on to the next NAME=, as /reconfigure takes
               --  one: notes=for users is one value, not a word dropped.
               Result.Settings.Replace_Element
                 (Result.Settings.Last_Index, Result.Settings.Last_Element & " " & Part);
            else
               Continues := False;
               --  IDs a comma apart, as a list is written: TASK-008, TASK-009,
               --  or TASK-008,TASK-009 -- each its own.
               if Ada.Strings.Fixed.Index (Part, ",") > 0
                 and then (Part (Part'First) in '0' .. '9'
                           or else (for some Prefix of Names.Vector'(["TASK-", "REQ-", "SPEC-", "DEC-"]) =>
                                      Ada.Strings.Fixed.Head (Part, Prefix'Length) = Prefix))
               then
                  declare
                     From : Natural := Part'First;
                  begin
                     for At_Comma in Part'Range loop
                        if Part (At_Comma) = ',' or else At_Comma = Part'Last then
                           declare
                              Piece : constant String :=
                                Part (From .. (if Part (At_Comma) = ',' then At_Comma - 1 else At_Comma));
                           begin
                              if Piece /= "" then
                                 Result.Positional.Append (Piece);
                              end if;
                           end;
                           From := At_Comma + 1;
                        end if;
                     end loop;
                  end;
               else
                  Result.Positional.Append (Part);
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Request_Of;

   --  A command line, carried out: Run_Line, a subunit of its own, as each
   --  of its handlers is.
   procedure Run_Line
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class)
     is separate;

   procedure Run
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class)
   is
   begin
      Run_Line (Line, Screen, Agent);
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

   -----------------------
   -- Run_Without_Model --
   -----------------------

   procedure Run_Without_Model
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Ignored : constant Natural := Pres.First_Failure (Screen);
      pragma Unreferenced (Ignored);
   begin
      Last_Status := 0;
      Run (Line, Screen, No_Agent'(null record));
      Status := Natural'Max (Pres.First_Failure (Screen), Last_Status);
   end Run_Without_Model;

   --------------------
   -- Run_With_Agent --
   --------------------

   procedure Run_With_Agent
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class;
      Status : out Natural)
   is
      Ignored : constant Natural := Pres.First_Failure (Screen);
      pragma Unreferenced (Ignored);
   begin
      Last_Status := 0;
      Run (Line, Screen, Agent);
      Status := Natural'Max (Pres.First_Failure (Screen), Last_Status);
   end Run_With_Agent;

end Model_Runner.CLI.Project_Commands;
