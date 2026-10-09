separate (Model_Runner.CLI.Project_Commands)
procedure Run_Line
  (Line   : String;
   Screen : in out Model_Runner.Presentation.Console;
   Agent  : Model_Runner.Framework.Work.Agent_Runner'Class)
is
   All_Words  : constant Names.Vector := Identifiers_As_Kept (Split (Line));
   Open_Quote : constant Boolean := Left_Open;
   Word       : constant String := All_Words.First_Element;
   Positional : Names.Vector;
   Command    : Model_Runner.CLI.Project_Requests.Request;
   Continues  : Boolean := False;
   To_Task    : Boolean := False;
   Status     : Natural := 0;
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

   --  Names a comma apart.
   function Joined_Names (Listed : Names.Vector) return String is
      Text : Unbounded_String;
   begin
      for One of Listed loop
         Append (Text, (if Text = Null_Unbounded_String then "" else ", ") & One);
      end loop;
      return To_String (Text);
   end Joined_Names;

   --  Whether fields are said under a group's title, set in from it.
   Sectioned : Boolean := False;

   --  A field, its name muted and its value in its tone at a terminal
   --  that shows colour.
   procedure Field (Name, Value : String; Value_Tone : Pres.Tone := Pres.Plain) is
   begin
      Pres.Put_Pair (Screen, "cli.task.field", Name, Value, Value_Tone, Indent => (if Sectioned then 2 else 0));
   end Field;

   --  Words a space apart.
   function Joined_Words (Listed : Names.Vector) return String is
      Text : Unbounded_String;
   begin
      for One of Listed loop
         Append (Text, (if Text = Null_Unbounded_String then "" else " ") & One);
      end loop;
      return To_String (Text);
   end Joined_Words;

   --  The work ready to be done, where there is some: one, or all.
   procedure Say_Ready_Work (Store : in out S.Store) is
      Ready_Ones : Names.Vector;
   begin
      for Id of Tk.List (Store, "accepted") loop
         if Tk.Ready (Store, Id).Ready then
            Ready_Ones.Append (Id);
         end if;
      end loop;
      if Natural (Ready_Ones.Length) > 1 then
         Pres.Put_Note (Screen, "cli.next.work_all",
                        [Loc.Named ("count", Image (Natural (Ready_Ones.Length))),
                         Loc.Named ("name", Ready_Ones.First_Element)]);
      elsif not Ready_Ones.Is_Empty then
         Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Ready_Ones.First_Element)]);
      end if;
   end Say_Ready_Work;

   --  Of tasks named together, the first now ready: what to work on next.
   procedure Say_First_Ready (Named : Names.Vector; From : Positive) is
      Store : S.Store;
      Read  : E.Error_Info;
   begin
      if not S.Is_Initialized (Here) then
         return;
      end if;
      S.Open_To_Read (Store, Here, Read);
      --  Several ready: all of them, in turn, and one of them.
      if E.Is_Ok (Read) then
         declare
            Ready_Ones : Names.Vector;
         begin
            for Id of Tk.List (Store, "accepted") loop
               if Tk.Ready (Store, Id).Ready then
                  Ready_Ones.Append (Id);
               end if;
            end loop;
            if Natural (Ready_Ones.Length) > 1 then
               Pres.Put_Note (Screen, "cli.next.work_all",
                              [Loc.Named ("count", Image (Natural (Ready_Ones.Length))),
                               Loc.Named ("name", Ready_Ones.First_Element)]);
               S.Close (Store);
               return;
            end if;
         end;
         for Index in From .. Natural (Named.Length) loop
            declare
               Given : constant String := Ada.Characters.Handling.To_Upper (Named (Index));
               Id    : constant String :=
                 (if Given /= "" and then Given'Length <= 6 and then (for all C of Given => C in '0' .. '9')
                  then "TASK-" & (if Given'Length >= 3 then Given else [1 .. 3 - Given'Length => '0'] & Given)
                  else Given);
            begin
               if Ada.Strings.Fixed.Index (Id, "TASK-") = Id'First and then Tk.Ready (Store, Id).Ready then
                  Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Id)]);
                  exit;
               end if;
            end;
         end loop;
      end if;
      S.Close (Store);
   end Say_First_Ready;

   --  What still waits to be decided, as one line: how many, and
   --  where they are listed.
   procedure Say_Still_Waiting (Store : in out S.Store) is
      Count : Natural := Natural (Model_Runner.CLI.Intents.Pending (Store).Length);
      Last  : Unbounded_String;
   begin
      for Which of Model_Runner.CLI.Intents.Pending (Store) loop
         Last := To_Unbounded_String (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
      end loop;
      for Id of Tk.List (Store, "candidate") loop
         Count := Count + 1;
         Last := To_Unbounded_String (Id);
      end loop;
      --  One: named, as /accept takes it at once rather than listing it --
      --  but not the task just derived from what was accepted, whose way
      --  on that said already.
      if Count = 1 and then Ada.Strings.Fixed.Index (To_String (Last), "TASK-") = 1
        and then Task_Requirements (Store, To_String (Last)).Contains
                   (Ada.Characters.Handling.To_Upper (Argument (1)))
      then
         null;
      elsif Count = 1 then
         Pres.Put_Note (Screen, "cli.next.still_waiting_one", [Loc.Named ("name", To_String (Last))]);
      elsif Count > 0 then
         Pres.Put_Note (Screen, "cli.next.still_waiting", [Loc.Named ("count", Image (Count))]);
      end if;
   end Say_Still_Waiting;

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
      --  What a session that died left -- a task running with nobody
      --  running it -- is put right whenever the project is opened, not
      --  only when a session starts: a live one sees it too.
      if not S.Is_Read_Only (Store) then
         declare
            Said : Names.Vector;
            Kept : E.Error_Info;
         begin
            Model_Runner.Framework.Work.Recover (Store, Said, Kept);
            for Id of Said loop
               Pres.Put_Note (Screen, "cli.project.recovered",
                              [Loc.Named ("detail", Id & " was running with no one running it; it is "
                                                    & Tk.State_Of (Store, Id) & " now")]);
            end loop;
         end;
      end if;
      Act (Store);
      --  What the command changed follows at once, said under it: a
      --  requirement no longer verified, a task now ready. A command that
      --  only looks changes nothing, and so leaves this to the next that
      --  does.
      if not S.Is_Read_Only (Store)
        and then not (Word in "/state" | "/config" | "/trace" | "/result" | "/help"
                      or else (Word in "/req" | "/spec" | "/decision" | "/task"
                               and then Argument (1) in "" | "show" | "list" | "audit" | "context" | "diff"))
      then
         declare
            Said : Names.Vector;
            Kept : E.Error_Info;
         begin
            Model_Runner.Framework.Work.Reevaluate (Store, Said, Kept);
            for Line of Said loop
               Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
            end loop;
         end;
      end if;
      S.Close (Store);
   end With_Store;

   procedure State (Store : in out S.Store) is separate;

   procedure Show_Config (Store : in out S.Store) is separate;

   procedure Show_Result (Store : in out S.Store) is separate;

   --  The project's verification, now, for no task in particular.
   procedure Check (Store : in out S.Store) is separate;

   --  Documents read for what the project must be: those named, or
   --  every Markdown file at the top and in docs.
   procedure Bootstrap (Store : in out S.Store) is separate;

   --  A change to the settings: what it changes and reaches, and then,
   --  once it is confirmed, a new revision; what was verified is looked at
   --  again against it.
   procedure Reconfigure (Store : in out S.Store) is separate;

   --  How the project stands in Git, asked of Git: the branch, and each
   --  changed path with the tasks whose work changed it.
   procedure Git_Status (Store : in out S.Store) is separate;

   --  A person's explicit word on a subject, above every other source:
   --  given, withdrawn, or those standing listed.
   procedure Instruct (Store : in out S.Store) is separate;

   --  The one candidate waiting, if there is exactly one.
   procedure Decide (Store : in out S.Store) is separate;

   --  /req, /decision and /spec: the registers of what the project is
   --  meant to be.
   procedure Intent_Command (Store : in out S.Store) is separate;
   --  The branches of the init route, in the order the
   --  dispatch tried them.
   procedure Route_Init is separate;

   --  The branches of the tasks route, in the order the
   --  dispatch tried them.
   procedure Route_Tasks is separate;

   --  The branches of the verdicts route, in the order the
   --  dispatch tried them.
   procedure Route_Verdicts is separate;

   --  The branches of the cancel route, in the order the
   --  dispatch tried them.
   procedure Route_Cancel is separate;

   --  The branches of the work route, in the order the
   --  dispatch tried them.
   procedure Route_Work is separate;

   --  The branches of the repository route, in the order the
   --  dispatch tried them.
   procedure Route_Repository is separate;

   --  The branches of the state route, in the order the
   --  dispatch tried them.
   procedure Route_State is separate;

   --  The branches of the config route, in the order the
   --  dispatch tried them.
   procedure Route_Config is separate;

   --  The branches of the intents route, in the order the
   --  dispatch tried them.
   procedure Route_Intents is separate;

   --  The branches of the results route, in the order the
   --  dispatch tried them.
   procedure Route_Results is separate;

   --  The branches of the checks route, in the order the
   --  dispatch tried them.
   procedure Route_Checks is separate;

   --  The branches of the bootstrapping route, in the order the
   --  dispatch tried them.
   procedure Route_Bootstrapping is separate;

   --  The branches of the git route, in the order the
   --  dispatch tried them.
   procedure Route_Git is separate;

   --  The branches of the instructions route, in the order the
   --  dispatch tried them.
   procedure Route_Instructions is separate;

   --  The branches of the sandbox route, in the order the
   --  dispatch tried them.
   procedure Route_Sandbox is separate;

   --  The branches of the reconfiguring route, in the order the
   --  dispatch tried them.
   procedure Route_Reconfiguring is separate;

begin
   --  A usage error of this command points to its own help.
   Pres.Use_Command (Screen, Word (Word'First + 1 .. Word'Last));
   --  A number naming two entries: which, asked for by name.
   if Number_Ambiguity /= Null_Unbounded_String then
      Outcome := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Outcome, "name", "the number given");
      E.Add_Text (Outcome, "value", To_String (Number_Ambiguity));
      E.Add_Text (Outcome, "detail", "it names both; give the one meant as it is written");
      Number_Ambiguity := Null_Unbounded_String;
      Pres.Report (Screen, Outcome);
      return;
   end if;
   --  The model /work would run on, for what is budgeted as /work does.
   if Agent in Wk.Parenting_Runner'Class then
      Command.Session_Profile := Wk.Parenting_Runner'Class (Agent).Profile;
      Command.Has_Session_Profile := True;
   end if;
   if All_Words.Contains ("--verbose")
     --  Read before the words are parsed: the action is the second.
     and then not (Word = "/task"
                   and then (Natural (All_Words.Length) < 2
                             or else All_Words (2) not in "show" | "context" | "audit" | "list" | "plan"))
   then
      Command.Level := Opt.Verbose;
   end if;
   if Open_Quote then
      Pres.Put_Note (Screen, "cli.project.quote_open");
   end if;
   --  A note is free text: kept as it was typed -- its quotes, its
   --  NAME=VALUE words -- not taken apart into settings.
   if Word = "/task" and then Natural (All_Words.Length) >= 4 and then All_Words (2) = "note" then
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
         Positional.Append (All_Words (2));
         Positional.Append (All_Words (3));
         Positional.Append (Ada.Strings.Fixed.Trim (Line (Cursor .. Line'Last), Ada.Strings.Both));
      end;
   end if;
   for Index in 2 .. Natural (All_Words.Length) loop
      exit when Word = "/task" and then Natural (All_Words.Length) >= 4 and then All_Words (2) = "note";
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
            Continues := True;
         elsif Continues and then Ada.Strings.Fixed.Head (Part, 2) /= "--" then
            --  A value runs on to the next NAME=, as /reconfigure takes
            --  one: notes=for users is one value, not a word dropped.
            Command.Inputs (Command.Input_Count) :=
              T.To_Bounded (T.To_String (Command.Inputs (Command.Input_Count)) & " " & Part);
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
                  for Index in Part'Range loop
                     if Part (Index) = ',' or else Index = Part'Last then
                        declare
                           Piece : constant String :=
                             Part (From .. (if Part (Index) = ',' then Index - 1 else Index));
                        begin
                           if Piece /= "" then
                              Positional.Append (Piece);
                           end if;
                        end;
                        From := Index + 1;
                     end if;
                  end loop;
               end;
            else
               Positional.Append (Part);
            end if;
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

   --  Each command by its route, which the table of commands gives it:
   --  a case, so a route without a handler is a compilation that fails.
   case Route_Of (Word) is
      when No_Route => null;
      when Init_Route => Route_Init;
      when Tasks_Route => Route_Tasks;
      when Verdicts_Route => Route_Verdicts;
      when Cancel_Route => Route_Cancel;
      when Work_Route => Route_Work;
      when Repository_Route => Route_Repository;
      when State_Route => Route_State;
      when Config_Route => Route_Config;
      when Intents_Route => Route_Intents;
      when Results_Route => Route_Results;
      when Checks_Route => Route_Checks;
      when Bootstrapping_Route => Route_Bootstrapping;
      when Git_Route => Route_Git;
      when Instructions_Route => Route_Instructions;
      when Sandbox_Route => Route_Sandbox;
      when Reconfiguring_Route => Route_Reconfiguring;
   end case;
exception
   --  A fault in one command is that command's: said, with what was
   --  raised where, and the session goes on.
   when Fault : others =>
      Pres.Report (Screen, E.Unexpected (Fault, Word));
      Pres.Put_Note (Screen, "cli.project.internal",
                     [Loc.Named ("name", Word),
                      Loc.Named ("detail", Where_Raised (Ada.Exceptions.Exception_Information (Fault)))]);
      Last_Status := E.Exit_Internal;
end Run_Line;
