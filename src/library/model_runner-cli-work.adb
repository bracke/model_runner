with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Hostkit;
with Hostkit.Fs;

with Model_Runner.CLI.Choosers;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Localization;
with Model_Runner.Text;
with Model_Runner.Tools.Builtin;

package body Model_Runner.CLI.Work is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package Loc renames Model_Runner.Localization;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;
   package W renames Model_Runner.Framework.Work;

   --  The tools an agent working on a task is not given: no shell, no
   --  network, no delegation, nobody to ask.
   --  Refused outright; a program or the network are its where its
   --  permissions grant them, which its file tools' guard holds it to.
   Denied : constant array (1 .. 4) of access constant String :=
     [new String'("sql"), new String'("delegate"), new String'("ask_user"),
      new String'("retrieve")];

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

   --  A model, run as this program's own agent in the project.
   type Model_Agent is new W.Agent_Runner with record
      Model   : Unbounded_String;
      Steps   : Unbounded_String;
      Timeout : Natural := 1800;

      --  The context the harness budgets its prompt for, which the model
      --  is run with, so that the two are one; zero leaves it to run.
      Context : Natural := 0;
   end record;

   overriding procedure Run
     (Self        : Model_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Run
     (Self        : Model_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      package Pm renames Model_Runner.Framework.Permissions;
      Arguments : Model_Runner.Framework.Name_Lists.Vector;
      Output    : constant String := Prompt_Path & ".answer";
      Happened  : Model_Runner.Framework.Execution.Outcome;
      Given     : Model_Runner.Framework.Name_Lists.Vector;

      procedure Add (Word : String) is
      begin
         Arguments.Append (Word);
      end Add;
   begin
      Answer := Null_Unbounded_String;
      Status := E.Success;
      Add ("run");
      Add (To_String (Self.Model));
      Add ("--agent");
      Add ("--prompt-file");
      Add (Prompt_Path);
      Add ("--quiet");
      if Self.Steps /= Null_Unbounded_String then
         Add ("--max-steps");
         Add (To_String (Self.Steps));
      end if;
      if Self.Context > 0 then
         Add ("--context-size");
         Add (Ada.Strings.Fixed.Trim (Natural'Image (Self.Context), Ada.Strings.Both));
      end if;

      --  What it did, for the harness to account: its tokens and its calls.
      Add ("--trace-file");
      Add (Prompt_Path & ".trace");
      for Tool of Denied loop
         Add ("--deny-tool");
         Add (Tool.all);
      end loop;

      --  Held to the tree it works in and to its permissions, which its
      --  file tools read; what it may do was written beside its prompt,
      --  and none written is nothing granted.
      Given.Append (Pm.Agent_Root_Variable & "=" & Project);
      Given.Append (Pm.Agent_Permissions_Variable & "=" & Whole (Pm.Permissions_Beside (Prompt_Path)));
      Model_Runner.Framework.Execution.Run_Harness
        (Project   => Ada.Directories.Containing_Directory
                        (Ada.Directories.Containing_Directory
                           (Ada.Directories.Containing_Directory
                              (Ada.Directories.Containing_Directory (Prompt_Path)))),
         Program   => Hostkit.Fs.Own_Executable,
         Arguments => Arguments,
         Directory => Project,
         Output    => Output,
         Timeout   => Positive'Max (1, Self.Timeout),
         Result    => Happened,
         Passed    => "LANG,LC_ALL,XDG_DATA_HOME,XDG_CONFIG_HOME,XDG_CACHE_HOME,XDG_RUNTIME_DIR,"
                      & "MODEL_RUNNER_MODELS,MODEL_RUNNER_CONFIG,MODEL_RUNNER_LOCALE,"
                      & Pm.Sandbox_Variable,
         Added     => Given);

      Answer := To_Unbounded_String (Whole (Output));
      if Ada.Directories.Exists (Output) then
         Ada.Directories.Delete_File (Output);
      end if;

      --  Its trace, told to the harness in the harness's own terms.
      declare
         Trace : constant String := Whole (Prompt_Path & ".trace");

         --  The number after "KEY": in the trace, or zero.
         function Count_Of (Key : String) return String is
            At_Key : constant Natural := Ada.Strings.Fixed.Index (Trace, '"' & Key & '"' & ':');
            First  : constant Natural := At_Key + Key'Length + 3;
            Stop   : Natural := First;
         begin
            if At_Key = 0 then
               return "0";
            end if;
            while Stop <= Trace'Last and then Trace (Stop) in '0' .. '9' loop
               Stop := Stop + 1;
            end loop;
            return (if Stop = First then "0" else Trace (First .. Stop - 1));
         end Count_Of;

         Usage : Unbounded_String :=
           To_Unbounded_String ("prompt_tokens " & Count_Of ("prompt_tokens") & ASCII.LF
                                & "output_tokens " & Count_Of ("generated_tokens") & ASCII.LF);
         Mark  : constant String := "{" & '"' & "t_ms" & '"' & ":";
         Call  : constant String := '"' & "event" & '"' & ":" & '"' & "call" & '"';
         From  : Natural := Trace'First;
      begin
         if Trace /= "" then
            --  Each event is one object, up to the next event's start.
            loop
               declare
                  Start : constant Natural :=
                    Ada.Strings.Fixed.Index (Trace (From .. Trace'Last), Mark);
                  Next  : Natural;
               begin
                  exit when Start = 0;
                  Next := Ada.Strings.Fixed.Index (Trace (Start + 1 .. Trace'Last), Mark);
                  declare
                     One  : constant String :=
                       Trace (Start .. (if Next = 0 then Trace'Last else Next - 2));
                     Have : Boolean;
                  begin
                     if Ada.Strings.Fixed.Index (One, Call) > 0 then
                        Append (Usage, "call "
                                & Model_Runner.Tools.Builtin.Text_Argument (One, "name", Have)
                                & ASCII.HT
                                & Model_Runner.Tools.Builtin.Text_Argument (One, "arguments", Have)
                                & ASCII.LF);
                     end if;
                  end;
                  exit when Next = 0;
                  From := Next;
               end;
            end loop;
            declare
               File : Ada.Streams.Stream_IO.File_Type;
            begin
               Ada.Streams.Stream_IO.Create
                 (File, Ada.Streams.Stream_IO.Out_File, W.Usage_Beside (Prompt_Path));
               String'Write (Ada.Streams.Stream_IO.Stream (File), To_String (Usage));
               Ada.Streams.Stream_IO.Close (File);
            end;
            Ada.Directories.Delete_File (Prompt_Path & ".trace");
         end if;
      exception
         when others =>
            null;
      end;
      if not Happened.Started or else Happened.Timed_Out
        or else Happened.Exit_Status /= 0
      then
         Status := E.Make (E.Generation_Invalid_Request);
      end if;
   end Run;

   --  A command the configuration names, run through the execution
   --  policy like any other.
   type Command_Agent (Store : not null access S.Store) is new W.Agent_Runner with record
      Command : Unbounded_String;
   end record;

   overriding procedure Run
     (Self        : Command_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Run
     (Self        : Command_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      Change  : S.Transaction;
      Project_Root : constant String :=
        Ada.Directories.Containing_Directory (S.Root (Self.Store.all));
      Ran     : Model_Runner.Framework.Execution.Outcome;
      Written : constant String := To_String (Self.Command);
      Marker  : constant Natural := Ada.Strings.Fixed.Index (Written, "${prompt}");
      Command : constant String :=
        (if Marker = 0 then Written
         else Written (Written'First .. Marker - 1) & Prompt_Path
              & Written (Marker + 9 .. Written'Last));
   begin
      --  The command is the agent: off the network unless it may use it.
      declare
         Rules : Model_Runner.Framework.Execution.Policy :=
           Model_Runner.Framework.Execution.Policy_Of (Self.Store.all);
      begin
         Rules.No_Network := Rules.No_Network
           or else not Model_Runner.Framework.Permissions.Allows
                         (Model_Runner.Framework.Permissions.Value
                            (Whole (Model_Runner.Framework.Permissions.Permissions_Beside
                                      (Prompt_Path))),
                          Model_Runner.Framework.Permissions.Use_Network);
         Model_Runner.Framework.Execution.Run
           (Self.Store.all, Change, Rules, Command, "", Ran, Status,
            Base => (if Project = Project_Root then "" else Project));
      end;
      if E.Is_Ok (Status) then
         S.Commit (Self.Store.all, Change, Status);
      end if;
      Answer := Ran.Output;
      if E.Is_Ok (Status) and then (not Ran.Started or else Ran.Exit_Status /= 0) then
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", "it ended with" & Integer'Image (Ran.Exit_Status));
      end if;
   end Run;

   --  The command, with the agent given or chosen from the configuration.
   procedure Drive
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Given_Runner : access constant W.Agent_Runner'Class;
      Status : out Natural)
   is
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));
      Store     : aliased S.Store;
      Report    : S.Recovery_Report;
      Outcome   : E.Error_Info;
      Chosen    : Unbounded_String := To_Unbounded_String (T.To_String (Item.Action_Argument));
      Given     : Model_Runner.Framework.Configurations.Value_Maps.Map;
      Config    : R.Item;
      Done      : W.Report;
      Remaining : Model_Runner.Framework.Name_Lists.Vector;

      --  The accepted tasks a textual selector matched.
      Matching  : Model_Runner.Framework.Name_Lists.Vector;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      function Setting (Name, Default : String) return String
      is (if Given.Contains (Name) then Given (Name)
          elsif R.Get (Config, "scalar.work." & Name) /= ""
          then R.Get (Config, "scalar.work." & Name)
          else Default);

      procedure Say (Key : String; Name, Value : String) is
      begin
         Pres.Put_Message
           (Screen, Key, [Loc.Named ("name", Name), Loc.Named ("value", Value)]);
      end Say;
   begin
      Status := E.Exit_Success;

      for Index in 1 .. Item.Input_Count loop
         declare
            Pair : constant String := T.To_String (Item.Inputs (Index));
            Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
         begin
            if Cut > Pair'First then
               Given.Include (Pair (Pair'First .. Cut - 1), Pair (Cut + 1 .. Pair'Last));
            end if;
         end;
      end loop;

      S.Open (Store, Directory, Report, Outcome);
      if E.Is_Error (Outcome) then
         Fail (Outcome);
         return;
      end if;
      Model_Runner.Framework.Configurations.Read (Store, Config, Outcome);

      --  What an interruption left is put right first, so a task whose
      --  agent stopped can be chosen again.
      declare
         Said : Model_Runner.Framework.Name_Lists.Vector;
      begin
         W.Recover_On_Opening (Store, Report, Said, Outcome);
         for Line of Said loop
            Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
         end loop;
      end;

      --  Everything the plan can start, one after another: the state is
      --  one writer's, so the plan's batch runs in turn.
      if Chosen = Null_Unbounded_String and then Setting ("all", "") = "yes" then
         declare
            Planned : constant Model_Runner.Framework.Orchestration.Dispatch_Plan :=
              Model_Runner.Framework.Orchestration.Plan (Store);
         begin
            if Planned.Start.Is_Empty then
               Pres.Put_Note (Screen, "cli.work.nothing");
               S.Close (Store);
               return;
            end if;
            for Id of Planned.Start loop
               Chosen := To_Unbounded_String (Id);
               exit;
            end loop;
            Remaining := Planned.Start;
            Remaining.Delete_First;
         end;
      end if;

      --  A selector that is no task's identifier picks among the accepted
      --  tasks by their identifiers and titles: one match is the task, more
      --  are offered on a terminal and named elsewhere, none is an error.
      if Chosen /= Null_Unbounded_String
        and then not S.Exists (Store, Model_Runner.Framework.Tasks_Area, To_String (Chosen))
      then
         declare
            Wanted : constant String :=
              Ada.Characters.Handling.To_Lower (To_String (Chosen));
            Found  : Unbounded_String;
         begin
            for Id of Tk.List (Store, "accepted") loop
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
               begin
                  Tk.Definition (Store, Id, Defined, Read);
                  if Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Id), Wanted) > 0
                    or else Ada.Strings.Fixed.Index
                              (Ada.Characters.Handling.To_Lower (R.Get (Defined, "title")),
                               Wanted) > 0
                  then
                     Matching.Append (Id);
                     Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Id);
                  end if;
               end;
            end loop;
            if Matching.Is_Empty then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "an accepted task matching " & To_String (Chosen));
               Fail (Outcome);
               S.Close (Store);
               return;
            elsif Natural (Matching.Length) = 1 then
               Chosen := To_Unbounded_String (Matching.First_Element);
            elsif not Model_Runner.CLI.Choosers.Is_Available (Screen) then
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "one task: " & To_String (Found) & " all match");
               Fail (Outcome);
               S.Close (Store);
               return;
            else
               Chosen := Null_Unbounded_String;
            end if;
         end;
      end if;

      if Chosen = Null_Unbounded_String then
         if not Model_Runner.CLI.Choosers.Is_Available (Screen) then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "task");
            Fail (Outcome);
            S.Close (Store);
            return;
         end if;

         declare
            Offer   : Model_Runner.CLI.Choosers.Choice_List;
            Listed  : Model_Runner.Framework.Name_Lists.Vector;
            Ready   : Model_Runner.Framework.Name_Lists.Vector;
            Waiting : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Id of Tk.List (Store, "accepted") loop
               if not Matching.Is_Empty and then not Matching.Contains (Id) then
                  null;
               elsif Tk.Ready (Store, Id).Ready then
                  Ready.Append (Id);
               else
                  Waiting.Append (Id);
               end if;
            end loop;
            declare
               procedure Offer_All
                 (Group : Model_Runner.Framework.Name_Lists.Vector);

               procedure Offer_All
                 (Group : Model_Runner.Framework.Name_Lists.Vector) is
               begin
                  for Id of Group loop
                     declare
                        Defined : R.Item;
                        Read    : E.Error_Info;
                        Now     : constant Tk.Readiness := Tk.Ready (Store, Id);
                        Why     : Unbounded_String;
                     begin
                        Tk.Definition (Store, Id, Defined, Read);
                        for Reason of Now.Reasons loop
                           Append (Why, Reason & ASCII.LF);
                        end loop;
                        Model_Runner.CLI.Choosers.Append
                          (Offer,
                           (Label      => To_Unbounded_String
                                            (Id & "  " & R.Get (Defined, "title")),
                            Tag        => To_Unbounded_String
                                            (if Now.Ready then "[ready]" else "[blocked]"),
                            Details    => Why,
                            Selectable => Now.Ready));
                        Listed.Append (Id);
                     end;
                  end loop;
               end Offer_All;
            begin
               Offer_All (Ready);
               Offer_All (Waiting);
            end;

            declare
               Picked : constant Natural :=
                 Model_Runner.CLI.Choosers.Choose (Screen, "cli.work.choose", Offer);
            begin
               if Picked = 0 then
                  Pres.Put_Note (Screen, "cli.work.nothing");
                  Status := E.Exit_Cancelled;
                  S.Close (Store);
                  return;
               end if;
               Chosen := To_Unbounded_String (Listed (Picked));
            end;
         end;
      end if;

      loop
         declare
            --  A runner that knows its model budgets for it; otherwise the
            --  profile the configuration names.
            Model   : constant Model_Runner.Framework.Context.Model_Profile :=
              (if Given_Runner /= null and then Given_Runner.all in W.Parenting_Runner'Class
                 and then Setting ("profile", "") = ""
               then W.Parenting_Runner'Class (Given_Runner.all).Profile
               else Model_Runner.Framework.Context.Profile (Store, Setting ("profile", "")));
            Command : constant String := R.Get (Config, "scalar.work.agent");
            Path    : constant String := Setting ("model", "");
         begin
            if Given_Runner /= null then
               W.Execute
                 (Store, To_String (Chosen), Given_Runner.all, Model, Done, Outcome);
            elsif Command /= "" then
               W.Execute
                 (Store, To_String (Chosen),
                  Command_Agent'(Store => Store'Access, Command => To_Unbounded_String (Command)),
                  Model, Done, Outcome);
            elsif Path /= "" then
               W.Execute
                 (Store, To_String (Chosen),
                  Model_Agent'(Model   => To_Unbounded_String (Path),
                               Steps   => To_Unbounded_String (Setting ("steps", "")),
                               Timeout => Positive'Max
                                            (60, W.Time_Allowed (Store, To_String (Chosen))),
                               Context => Model.Context_Limit),
                  Model, Done, Outcome);
            else
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "model");
            end if;
         end;

         if E.Is_Error (Outcome) then
            Fail (Outcome);
            S.Close (Store);
            return;
         end if;

         Say ("cli.work.agent", To_String (Done.Agent_Id), To_String (Done.Task_Id));
         Say ("cli.work.context", To_String (Done.Manifest_Id), To_String (Done.Invocation_Id));
         for Path of Done.Changed_Files loop
            Say ("cli.work.changed", Path, "");
         end loop;
         for Child of Done.Children loop
            Say ("cli.work.child", Child, "");
         end loop;
         for Candidate of Done.Proposed loop
            Say ("cli.work.proposed", Candidate, "");
         end loop;
         for Other of Done.Waits_For loop
            Say ("cli.work.waits_for", Other, To_String (Done.Task_Id));
         end loop;
         if Done.Claimed /= Null_Unbounded_String then
            Say ("cli.work.claimed", To_String (Done.Claimed), To_String (Done.Summary));
         end if;
         if Done.Scope /= Null_Unbounded_String then
            Say ("cli.work.scope", To_String (Done.Scope), To_String (Done.Scope_Reason));
         end if;
         if Done.Evidence_Id /= Null_Unbounded_String then
            Say ("cli.work.evidence", To_String (Done.Evidence_Id), "");
         end if;
         for Requirement of Done.Requirements loop
            Say ("cli.work.requirement", Requirement, "");
         end loop;
         Say ("cli.work.ended", To_String (Done.Final_State), To_String (Done.Reason));

         exit when Remaining.Is_Empty;
         Chosen := To_Unbounded_String (Remaining.First_Element);
         Remaining.Delete_First;
      end loop;

      if To_String (Done.Final_State) /= "complete" then
         Status := E.Exit_Input_Output;
      end if;
      S.Close (Store);
   end Drive;

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural) is
   begin
      Drive (Item, Screen, null, Status);
   end Run;

   --------------
   -- Run_With --
   --------------

   procedure Run_With
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Runner : Model_Runner.Framework.Work.Agent_Runner'Class;
      Status : out Natural) is
   begin
      Drive (Item, Screen, Runner'Unchecked_Access, Status);
   end Run_With;

end Model_Runner.CLI.Work;
