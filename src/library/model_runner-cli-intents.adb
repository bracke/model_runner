with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.Errors;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Verification;
with Model_Runner.Localization;

package body Model_Runner.CLI.Intents is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package Nt renames Model_Runner.Framework.Intent;
   package S renames Model_Runner.Framework.Stores;
   package Pres renames Model_Runner.Presentation;
   package Loc renames Model_Runner.Localization;
   package Tr renames Model_Runner.Framework.Transitions;
   package Names renames Model_Runner.Framework.Name_Lists;

   use type Nt.Link_Kind;

   --  A title made from a text: the text, cut at a hundred characters.
   function Headline (Text : String) return String
   is (if Text'Length <= 100 then Text else Text (Text'First .. Text'First + 96) & "...");

   --  Whether an entry's title is its text's headline, as one made from a
   --  document's line is: a new text brings a new title with it.
   --  A path typed where the session was started, below the project's
   --  top -- price.rs, ../../api/x.go -- as the project names it; as typed
   --  where it is no place from there.
   function From_Start (Project, Word : String) return String is
      Below : constant String := Model_Runner.CLI.Project_Commands.Started_Below;
   begin
      --  From where it was started first, as Tab and /impact take it.
      if Below = "" or else Word = "" or else Word (Word'First) = '/'
        or else (Ada.Directories.Exists (Hostkit.Fs.Join (Project, Word))
                 and then not Ada.Directories.Exists (Hostkit.Fs.Join (Hostkit.Fs.Join (Project, Below), Word)))
      then
         return Word;
      end if;
      declare
         Whole : constant String :=
           Ada.Directories.Full_Name (Hostkit.Fs.Join (Hostkit.Fs.Join (Project, Below), Word));
         Top   : constant String := Ada.Directories.Full_Name (Project);
      begin
         if Ada.Directories.Exists (Whole) and then Whole'Length > Top'Length + 1
           and then Whole (Whole'First .. Whole'First + Top'Length - 1) = Top
         then
            return Whole (Whole'First + Top'Length + 1 .. Whole'Last);
         end if;
         return Word;
      end;
   exception
      when others =>
         return Word;
   end From_Start;

   function Title_From_Text (Held : Nt.Entity) return Boolean is
      Title : constant String := To_String (Held.Title);
      Text  : constant String := To_String (Held.Text);
      Stem  : constant String :=
        (if Title'Length > 3 and then Title (Title'Last - 2 .. Title'Last) = "..."
         then Title (Title'First .. Title'Last - 3) else Title);
   begin
      --  The whole text, or the text cut at a hundred characters and
      --  marked so: a title a person wrote that the text starts with is
      --  theirs.
      return Title = Text
        or else (Stem /= Title and then Text'Length >= Stem'Length
                 and then Text (Text'First .. Text'First + Stem'Length - 1) = Stem)
        --  Its first sentence, or the text without its stop, as a
        --  document's headline is cut.
        or else (Title /= "" and then Text'Length > Title'Length
                 and then Text (Text'First .. Text'First + Title'Length - 1) = Title
                 and then Text (Text'First + Title'Length) in '.' | ',' | ';' | ':' | '!' | '?');
   end Title_From_Text;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   --  The word a register is written as, and back.
   function Word_Of (Kind : Nt.Intent_Kind) return String
   is (case Kind is
         when Nt.Requirement   => "requirement",
         when Nt.Specification => "specification",
         when Nt.Decision      => "decision");

   --  Move the project along after a change, and say what that did.
   --  Set while a caller that decides the derived tasks too runs Decide:
   --  their next steps are its to say.
   Next_Held : Boolean := False;

   --  Set while several entries are moved in turn: the tasks they make
   --  waiting are gathered, and said once after the last.
   Collecting : Boolean := False;
   Collected  : Unbounded_String;

   --  Whether a task's document marks what it serves done: an issue
   --  bootstrap raised so, naming one of its requirements.
   function Marked_Done (Store : S.Store; Id : String) return Boolean is
      Defined : Model_Runner.Framework.Records.Item;
      Read    : E.Error_Info;
   begin
      Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Read);
      if E.Is_Error (Read) then
         return False;
      end if;
      for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
         declare
            Result_Id : constant String :=
              (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
               then Name (Name'First .. Name'Last - 4) else Name);
            One : Model_Runner.Framework.Results.Result;
            Got : E.Error_Info;
         begin
            Model_Runner.Framework.Results.Read (Store, Result_Id, One, Got, With_Payload => False);
            if E.Is_Ok (Got) and then Ada.Strings.Unbounded.Index (One.Summary, " is marked done in ") > 0
              and then (for some Requirement of Model_Runner.Framework.Lines_Of
                                                   (Model_Runner.Framework.Records.Get (Defined, "requirements"))
                        => Ada.Strings.Unbounded.Index (One.Summary, Requirement) > 0)
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Marked_Done;

   procedure Move_Along
     (Store  : in out S.Store;
      Screen : in out Pres.Console)
   is
      Done   : Model_Runner.Framework.Orchestration.Step_Report;
      Status : E.Error_Info;
      Candidates : Unbounded_String;
      Count      : Natural := 0;
   begin
      Model_Runner.Framework.Orchestration.Step (Store, Done, Status);
      if E.Is_Error (Status) then
         Pres.Report (Screen, Status);
         return;
      end if;
      for Id of Done.Derived loop
         Pres.Put_Message
              (Screen, "cli.task.derived",
               [Loc.Named ("name", Id),
                Loc.Named ("value", Model_Runner.Framework.Tasks.Component_Of_Task (Store, Id))]);
         --  Of several components, placed in the first for want of one of
         --  its own: said, with how to place it.
         if Natural (Model_Runner.Framework.Tasks.Components (Store).Length) > 1 then
            declare
               Defined : Model_Runner.Framework.Records.Item;
               Read    : E.Error_Info;
               Scoped  : Boolean := False;
            begin
               Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Read);
               for Requirement of Model_Runner.Framework.Lines_Of
                                    (Model_Runner.Framework.Records.Get (Defined, "requirements"))
               loop
                  declare
                     Held : Nt.Entity;
                  begin
                     Nt.Read (Store, Nt.Requirement, Requirement, Held, Read);
                     Scoped := Scoped
                       or else (E.Is_Ok (Read) and then To_String (Held.Scope) not in "" | "project")
                       or else not Nt.Links (Store, Nt.Requirement, Requirement, Nt.Component).Is_Empty;
                  end;
               end loop;
               if not Scoped then
                  Pres.Put_Note
                    (Screen, "cli.task.derived_placed",
                     [Loc.Named ("name", Id),
                      Loc.Named ("value", Model_Runner.Framework.Tasks.Component_Of_Task (Store, Id))]);
               end if;
               --  A requirement of several components: one task, in one of
               --  them, and said so.
               for Requirement of Model_Runner.Framework.Lines_Of
                                    (Model_Runner.Framework.Records.Get (Defined, "requirements"))
               loop
                  declare
                     Homes : constant Names.Vector :=
                       Nt.Links (Store, Nt.Requirement, Requirement, Nt.Component);
                     Listed : Unbounded_String;
                  begin
                     if Natural (Homes.Length) > 1 then
                        for One of Homes loop
                           Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
                        end loop;
                        Pres.Put_Note
                          (Screen, "cli.task.derived_one_of",
                           [Loc.Named ("name", Id), Loc.Named ("other", Requirement),
                            Loc.Named ("detail", To_String (Listed)),
                            Loc.Named ("value",
                                       Model_Runner.Framework.Tasks.Component_Of_Task (Store, Id))]);
                     end if;
                  end;
               end loop;
            end;
         end if;
         --  A candidate until someone takes it up: said once for them all.
         if Model_Runner.Framework.Tasks.State_Of (Store, Id) = "candidate" then
            Append (Candidates, (if Candidates = Null_Unbounded_String then "" else " ") & Id);
            Count := Count + 1;
         end if;
      end loop;
      if Next_Held then
         null;
      elsif Collecting then
         Append (Collected, (if Collected = Null_Unbounded_String or else Candidates = Null_Unbounded_String
                             then "" else " ") & To_String (Candidates));
      elsif Count = 1 and then Marked_Done (Store, To_String (Candidates)) then
         --  Its document marks it done: taken as done, not done again.
         Pres.Put_Note (Screen, "cli.next.accept_marked_done", [Loc.Named ("name", To_String (Candidates))]);
      elsif Count = 1 then
         Pres.Put_Note (Screen, "cli.next.accept_task", [Loc.Named ("name", To_String (Candidates))]);
      elsif Count > 1 then
         Pres.Put_Note (Screen, "cli.next.accept_tasks", [Loc.Named ("detail", To_String (Candidates))]);
      end if;
      for Id of Done.Became_Ready loop
         if Model_Runner.Framework.Tasks.State_Of (Store, Id) = "accepted" then
            Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
         end if;
      end loop;
   end Move_Along;

   --  An accepted entry that rules a setting over the configuration has
   --  its way: the configuration made to say what it rules, and said so.
   --  One that rules without saying it holds over the configuration is a
   --  disagreement /check consistency names, not settled here.
   procedure Apply_Rulings
     (Store  : in out S.Store;
      Kind   : Nt.Intent_Kind;
      Id     : String;
      Screen : in out Pres.Console;
      Said   : Boolean := True)
   is
      package Cf renames Model_Runner.Framework.Configurations;
      Rulings : Names.Vector := Nt.Also_Governs (Store, Kind, Id);
      Config  : Model_Runner.Framework.Records.Item;
      Read    : E.Error_Info;
   begin
      if Nt.State_Of (Store, Kind, Id) /= "accepted" then
         return;
      end if;
      if Nt.Governs (Store, Kind, Id) /= "" then
         Rulings.Prepend (Nt.Governs (Store, Kind, Id));
      end if;
      Cf.Read (Store, Config, Read);
      for One of Rulings loop
         declare
            Equal : constant Natural := Ada.Strings.Fixed.Index (One, " = ");
            Over  : constant Natural := Ada.Strings.Fixed.Index (One, " (over ");
         begin
            --  Ruling without holding over it, and the configuration says
            --  otherwise: the disagreement said now, with both ways out.
            if Equal > One'First and then Over = 0 and then E.Is_Ok (Read)
              and then Model_Runner.Framework.Records.Has (Config, One (One'First .. Equal - 1))
              and then Model_Runner.Framework.Records.Get (Config, One (One'First .. Equal - 1))
                         /= One (Equal + 3 .. One'Last)
              --  Saying, as it holds, what the ruling says -- inherit from
              --  a level that withholds it is off -- is no disagreement.
              and then not Model_Runner.Framework.Permissions.Ruling_Agrees
                             (Store, Config, One (One'First .. Equal - 1), One (Equal + 3 .. One'Last))
            then
               Pres.Put_Note (Screen, "cli.intent.ruling_disagrees",
                              [Loc.Named ("name", Id),
                               --  Its own register's command: /spec for a specification.
                               Loc.Named ("extra", (if Nt."=" (Kind, Nt.Specification) then "/spec"
                                                    elsif Nt."=" (Kind, Nt.Requirement) then "/req"
                                                    else "/decision")),
                               Loc.Named ("value", One (One'First .. Equal - 1)),
                               Loc.Named ("detail", One (Equal + 3 .. One'Last)),
                               Loc.Named ("other", Model_Runner.Framework.Permissions.Value_Said
                                                     (One (One'First .. Equal - 1),
                                                      Model_Runner.Framework.Records.Get
                                                        (Config, One (One'First .. Equal - 1))))]);
            end if;
            --  Held over the configuration -- or ruling on a setting it
            --  does not set, with nothing there to hold over: the ruling
            --  is made the setting, and so holds for the harness too.
            if Equal > One'First
              and then ((Over > Equal and then Ada.Strings.Fixed.Index (One (Over .. One'Last), "CONFIG") > 0)
                        or else (Over = 0 and then E.Is_Ok (Read)
                                 and then not Model_Runner.Framework.Records.Has
                                                (Config, One (One'First .. Equal - 1))
                                 and then (Cf.Known_Names.Contains (One (One'First .. Equal - 1))
                                           --  A kind's own limit is a setting too.
                                           or else (for some Limit of Names.Vector'
                                                      (["scalar.task.max_seconds.", "scalar.task.max_steps.",
                                                        "scalar.task.max_tool_calls.", "scalar.task.token_budget."])
                                                      => Ada.Strings.Fixed.Index (One, Limit) = One'First))))
            then
               declare
                  Setting : constant String := One (One'First .. Equal - 1);
                  Ruling  : constant String := One (Equal + 3 .. (if Over = 0 then One'Last else Over - 1));
                  Changes : Cf.Value_Maps.Map;
                  Planned : Cf.Change_Plan;
                  Done    : E.Error_Info;
                  Revision : Natural;
               begin
                  if E.Is_Ok (Read) and then Model_Runner.Framework.Records.Get (Config, Setting) /= Ruling then
                     Changes.Include (Setting, Ruling);
                     Cf.Plan_Change (Store, Changes, Planned, Done);
                     if E.Is_Ok (Done) then
                        Cf.Reconfigure (Store, Planned, Revision, Done);
                     end if;
                     if E.Is_Ok (Done) and then not Said then
                        null;
                     elsif E.Is_Ok (Done) then
                        --  With what it held before: a change made, said as one.
                        Pres.Put_Message (Screen, "cli.intent.ruling_applied",
                                          [Loc.Named ("name", Id),
                                           Loc.Named ("value",
                                                      Setting & ": "
                                                      & (if Model_Runner.Framework.Records.Get (Config, Setting) /= ""
                                                         then Model_Runner.Framework.Records.Get (Config, Setting)
                                                         elsif Cf.Default_Of (Setting) /= ""
                                                         then "(not set: " & Cf.Default_Of (Setting) & ")"
                                                         else "(not set)")
                                                      & " -> " & Ruling)]);
                        --  A place it names that the project has not: said.
                        if Ada.Strings.Fixed.Index (Setting, "map.permission.") = 1
                          and then Model_Runner.Framework.Permissions.Missing_Places
                                     (Ada.Directories.Containing_Directory (S.Root (Store)), Ruling) /= ""
                        then
                           Pres.Put_Note (Screen, "cli.project.places_missing",
                                          [Loc.Named ("name", Setting),
                                           Loc.Named ("detail", Model_Runner.Framework.Permissions.Missing_Places
                                                                  (Ada.Directories.Containing_Directory
                                                                     (S.Root (Store)), Ruling))]);
                        end if;
                     else
                        Pres.Report (Screen, Done);
                     end if;
                     --  A grant ruled that the level above does not give: it
                     --  gets none of it, said as /reconfigure says it.
                     if E.Is_Ok (Done) and then Ruling not in "off" | "none"
                       and then Ada.Strings.Fixed.Index (Setting, "map.permission.") = 1
                       and then Ada.Strings.Fixed.Index (Setting, "map.permission.project.") = 0
                       and then not Model_Runner.Framework.Permissions.Ruling_Agrees
                                      (Store, Planned.After, Setting, "on")
                     then
                        Pres.Put_Note (Screen, "cli.intent.ruling_above_withholds",
                                       [Loc.Named ("name", Id), Loc.Named ("value", Setting)]);
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Apply_Rulings;

   --  The project's components, a comma apart.
   function Joined_Components (Store : Model_Runner.Framework.Stores.Store) return String is
      Text : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Name of Model_Runner.Framework.Tasks.Components (Store) loop
         Ada.Strings.Unbounded.Append
           (Text, (if Ada.Strings.Unbounded.Length (Text) = 0 then "" else ", ") & Name);
      end loop;
      return Ada.Strings.Unbounded.To_String (Text);
   end Joined_Components;

   --  Commit a change, report a failure, and move along after a success.
   procedure Settle
     (Store  : in out S.Store;
      Change : in out S.Transaction;
      Status : in out E.Error_Info;
      Screen : in out Pres.Console;
      Said   : String;
      Detail : String) is
   begin
      if E.Is_Ok (Status) then
         S.Commit (Store, Change, Status);
      end if;
      if E.Is_Error (Status) then
         Pres.Report (Screen, Status);
         return;
      end if;
      if Said = "cli.task.created" then
         declare
            Space : constant Natural := Ada.Strings.Fixed.Index (Detail & " ", " ");
         begin
            Pres.Put_Message
              (Screen, Said,
               [Loc.Named ("name", Detail (Detail'First .. Space - 1)),
                Loc.Named ("detail", (if Space > Detail'Last then ""
                                      else Detail (Space + 1 .. Detail'Last)))]);
         end;
      elsif Said /= "" then
         Pres.Put_Message (Screen, Said, [Loc.Named ("name", Detail)]);
      end if;
      Move_Along (Store, Screen);
   end Settle;

   --  The command that has another decision govern what one governed:
   --  its setting, ruling and what it overrode -- none since retired.
   function Carried_On (Store : S.Store; Governed, Other : String) return String is
      Equal : constant Natural := Ada.Strings.Fixed.Index (Governed, " = ");
      Over  : constant Natural := Ada.Strings.Fixed.Index (Governed, " (over ");
      Kept  : Unbounded_String;
   begin
      if Equal = 0 then
         return "/decision govern " & Other & " SETTING RULING";
      end if;
      if Over > 0 then
         for Name of Model_Runner.Framework.Lines_Of
                       (Ada.Strings.Fixed.Translate
                          (Governed (Over + 7 .. Governed'Last - 1),
                           Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
         loop
            declare
               Bare : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
            begin
               if Bare = "CONFIG"
                 or else Nt.State_Of (Store, Nt.Decision, Bare) not in "obsolete" | "superseded" | "rejected"
               then
                  Append (Kept, (if Kept = Null_Unbounded_String then "" else ",") & Bare);
               end if;
            end;
         end loop;
      end if;
      return "/decision govern " & Other & " " & Governed (Governed'First .. Equal - 1) & " "
        & Governed (Equal + 3 .. (if Over = 0 then Governed'Last else Over - 1))
        & (if Kept = Null_Unbounded_String then "" else " overrides=" & To_String (Kept));
   end Carried_On;

   --  The command a register is worked with.
   --  What a link names, by its relation: what tests it, or implements it.
   function What_Links (Relation : String) return String
   is (if Ada.Characters.Handling.To_Lower (Relation) = "test" then "what tests it" else "what implements it");

   --  A link's kind as a person reads it: implemented by, tested by.
   function Relation_Said (Relation : Nt.Link_Kind) return String
   is (case Relation is
         when Nt.Implementation => "implemented by",
         when Nt.Test           => "tested by",
         when Nt.Verification   => "evidence linked",
         when Nt.Dependency     => "depends on",
         when Nt.Component      => "belongs to",
         when Nt.Task_Link      => "served by (linked)");

   function Word_Of_Command (Kind : Nt.Intent_Kind) return String
   is (case Kind is
          when Nt.Requirement   => "/req",
          when Nt.Specification => "/spec",
          when Nt.Decision      => "/decision");

   --  Work still open for a requirement retired: how to let that go.
   procedure Work_Left
     (Store       : in out S.Store;
      Screen      : in out Pres.Console;
      Requirement : String) is
   begin
      for Id of Model_Runner.Framework.Tasks.List (Store) loop
         declare
            Defined : Model_Runner.Framework.Records.Item;
            Read    : E.Error_Info;
            State   : constant String := Model_Runner.Framework.Tasks.State_Of (Store, Id);
         begin
            Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Read);
            if E.Is_Ok (Read)
              and then State not in "complete" | "cancelled" | "rejected"
              and then Model_Runner.Framework.Lines_Of
                         (Model_Runner.Framework.Records.Get (Defined, "requirements"))
                         .Contains (Requirement)
            then
               Pres.Put_Note
                 (Screen, "cli.intent.task_left",
                  [Loc.Named ("name", Id),
                   Loc.Named ("value", (if State = "candidate" then "reject" else "cancel")),
                   Loc.Named ("other", Requirement)]);
            end if;
         end;
      end loop;
   end Work_Left;

   ---------
   -- Run --
   ---------

   --  A yes or no read from the person: anything else asked again, a
   --  command typed in its place said and not run, and no answer a no.
   function Answered_Yes (Screen : in out Pres.Console) return Boolean is
   begin
      return Model_Runner.CLI.Choosers.Answered_Yes (Screen);
   end Answered_Yes;

   procedure Run
     (Store  : in out Model_Runner.Framework.Stores.Store;
      Kind   : Model_Runner.Framework.Intent.Intent_Kind;
      Words  : Model_Runner.Framework.Name_Lists.Vector;
      Screen : in out Model_Runner.Presentation.Console)
   is
      Plain    : Names.Vector;
      Settings : Names.Vector;
      Change   : S.Transaction;
      Status   : E.Error_Info;

      --  Errors said before this command: one it says itself is not said
      --  again at its end.
      Said_Before : constant Natural := Pres.Errors_Reported (Screen);

      --  A NAME=VALUE given, or "".
      function Given (Name : String) return String is
      begin
         for Pair of Settings loop
            if Pair'Length > Name'Length
              and then Pair (Pair'First .. Pair'First + Name'Length) = Name & "="
            then
               --  What it overrides is named as the project names it --
               --  config is CONFIG, dec-1 is DEC-1 -- in any case typed.
               return (if Name = "overrides"
                       then Ada.Characters.Handling.To_Upper (Pair (Pair'First + Name'Length + 1 .. Pair'Last))
                       else Pair (Pair'First + Name'Length + 1 .. Pair'Last));
            end if;
         end loop;
         return "";
      end Given;

      function Word (Index : Positive) return String
      is (if Index <= Natural (Plain.Length) then Plain (Index) else "");

      --  The words from one on, as one text.
      function From (Index : Positive) return String is
         Text : Unbounded_String;
      begin
         for At_Index in Index .. Natural (Plain.Length) loop
            Append (Text, (if Text = Null_Unbounded_String then "" else " ") & Plain (At_Index));
         end loop;
         return To_String (Text);
      end From;

      procedure Needs (Count : Positive; What : String) is
      begin
         if Natural (Plain.Length) < Count then
            Status := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Status, "name", What);
         end if;
      end Needs;

      --  What was asked, read once the words are split.
      --  edit, as /task says it, is revise here.
      function Action return String is (if Lower (Word (1)) = "edit" then "revise" else Lower (Word (1)));

      --  What a retired decision governed is governed no more: said, with
      --  what the setting is now, or what governs it still.
      --  A ruling's value without what it holds over.
      function Ruled_Value (Said : String) return String is
         Over : constant Natural := Ada.Strings.Fixed.Index (Said, " (over ");
      begin
         return (if Over = 0 then Said else Said (Said'First .. Over - 1));
      end Ruled_Value;

      procedure Say_Ruling_Gone (Id, Governed : String) is
      begin
         if Governed /= "" and then Ada.Strings.Fixed.Index (Governed, " = ") > 0 then
            declare
               Setting : constant String :=
                 Governed (Governed'First .. Ada.Strings.Fixed.Index (Governed, " = ") - 1);
               Config  : Model_Runner.Framework.Records.Item;
               Read    : E.Error_Info;
            begin
               Model_Runner.Framework.Configurations.Read (Store, Config, Read);
               --  Another decision governing it still: that one says.
               for Other of Nt.List (Store, Nt.Decision, "accepted") loop
                  if Other /= Id
                    and then (Ada.Strings.Fixed.Index
                                (Nt.Governs (Store, Nt.Decision, Other), Setting & " = ") = 1
                              or else (for some Line of Nt.Also_Governs (Store, Nt.Decision, Other) =>
                                         Ada.Strings.Fixed.Index (Line, Setting & " = ") = 1))
                  then
                     Pres.Put_Note
                       (Screen, "cli.intent.ruling_passed",
                        [Loc.Named ("name", Id), Loc.Named ("value", Governed),
                         Loc.Named ("other", Other),
                         Loc.Named ("detail", Nt.Governs (Store, Nt.Decision, Other))]);
                     goto Ruling_Said;
                  end if;
               end loop;
               Pres.Put_Note
                 (Screen, "cli.intent.ruling_gone",
                  [Loc.Named ("name", Id), Loc.Named ("value", Governed),
                   Loc.Named ("detail",
                              Setting & " = "
                              & (if Model_Runner.Framework.Records.Get (Config, Setting) = ""
                                   and then not Model_Runner.Framework.Records.Has (Config, Setting)
                                 then "(its default)"
                                 else Model_Runner.Framework.Permissions.Value_Said
                                        (Setting, Model_Runner.Framework.Records.Get (Config, Setting))))]);
               --  What the ruling wrote into the configuration stays there:
               --  said, with how it changes.
               --  Only where it did write it: the configuration holding
               --  what it ruled.
               if Model_Runner.Framework.Records.Has (Config, Setting)
                 and then Model_Runner.Framework.Records.Get (Config, Setting)
                          = Ruled_Value (Governed (Ada.Strings.Fixed.Index (Governed, " = ") + 3 .. Governed'Last))
               then
                  Pres.Put_Note (Screen, "cli.intent.ruling_value_stays",
                                 [Loc.Named ("name", Setting)]);
               end if;
               <<Ruling_Said>>
            end;
         end if;
      end Say_Ruling_Gone;

      --  Where a moved one was, for saying where it went from.
      From_State : Unbounded_String;

      --  The setting a decision is to govern, by its whole name.
      Governed_Setting : Unbounded_String;
   begin
      for Part of Words loop
         declare
            Equal : constant Natural := Ada.Strings.Fixed.Index (Part, "=");
         begin
            --  --set NAME=VALUE, as a task takes it, is NAME=VALUE.
            if Part = "--set" then
               null;
            elsif Equal > Part'First
              and then (for all C of Part (Part'First .. Equal - 1) =>
                          C in 'a' .. 'z' | 'A' .. 'Z' | '_')
            then
               --  acceptance= is what criteria= says.
               Settings.Append (if Lower (Part (Part'First .. Equal - 1)) = "acceptance"
                                then "criteria" & Part (Equal .. Part'Last) else Part);
            elsif not Settings.Is_Empty then
               --  A value runs on to the next NAME=: text=the parser
               --  shall stop is one text, not a word and three more.
               Settings.Replace_Element
                 (Settings.Last_Index, Settings.Last_Element & " " & Part);
            else
               Plain.Append (Part);
            end if;
         end;
      end loop;

      --  A ruling written as NAME=VALUE -- roots=tests/, max_children=5 --
      --  is the ruling a decision governs with, not a field of it.
      if not Plain.Is_Empty and then Lower (Plain.First_Element) = "govern" then
         declare
            Kept   : Names.Vector;
            Ruling : Unbounded_String;
         begin
            for Pair of Settings loop
               if Ada.Strings.Fixed.Index (Lower (Pair), "overrides=") = 1 then
                  Kept.Append (Pair);
               else
                  Append (Ruling, (if Ruling = Null_Unbounded_String then "" else " ") & Pair);
               end if;
            end loop;
            if Ruling /= Null_Unbounded_String then
               Plain.Append (To_String (Ruling));
               Settings := Kept;
            end if;
         end;
      end if;

      --  Another register's identifier: said as which, with its command --
      --  not as one the project has not.
      if Word (2) /= "" and then Action not in "new" | "list" then
         declare
            Upper : constant String := Ada.Characters.Handling.To_Upper (Word (2));
            Other : constant String :=
              (if Ada.Strings.Fixed.Head (Upper, 5) = "SPEC-" and then not Nt."=" (Kind, Nt.Specification)
               then "/spec"
               elsif Ada.Strings.Fixed.Head (Upper, 4) = "REQ-" and then not Nt."=" (Kind, Nt.Requirement)
               then "/req"
               elsif Ada.Strings.Fixed.Head (Upper, 4) = "DEC-" and then not Nt."=" (Kind, Nt.Decision)
               then "/decision"
               elsif Ada.Strings.Fixed.Head (Upper, 5) = "TASK-" then "/task"
               else "");
         begin
            if Other /= "" then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "the " & Word_Of (Kind));
               E.Add_Text (Status, "value", Word (2));
               E.Add_Text (Status, "detail", Word (2) & " is "
                           & (if Other = "/spec" then "a specification" elsif Other = "/req" then "a requirement"
                              elsif Other = "/decision" then "a decision" else "a task")
                           & ": " & Other & " " & Action & " " & Word (2) & " is the command");
               Pres.Report (Screen, Status);
               return;
            end if;
         end;
      end if;

      --  A field new or revise does not take is refused by name, not
      --  dropped unsaid.
      if Action in "new" | "revise" then
         for Pair of Settings loop
            declare
               Name : constant String :=
                 Lower (Pair (Pair'First .. Ada.Strings.Fixed.Index (Pair, "=") - 1));
            begin
               if Name not in "text" | "criteria" | "title" | "scope" then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", "the " & Word_Of (Kind) & "'s fields");
                  E.Add_Text (Status, "value", Name);
                  E.Add_Text (Status, "detail", Action & " takes text=, criteria=, title= and scope=; "
                              & Name & " is not one");
                  Pres.Report (Screen, Status);
                  return;
               end if;
            end;
         end loop;
      end if;

      --  None named, and one of its kind waiting to be decided: that one,
      --  said so.
      if Action in "accept" | "reject" and then Natural (Plain.Length) = 1 then
         declare
            Of_Kind : Names.Vector;
         begin
            for Which of Pending (Store) loop
               if Ada.Strings.Fixed.Index (Which, ":") > Which'First
                 and then Which (Which'First .. Ada.Strings.Fixed.Index (Which, ":") - 1) = Word_Of (Kind)
               then
                  Of_Kind.Append (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
               end if;
            end loop;
            if Natural (Of_Kind.Length) = 1 then
               Plain.Append (Of_Kind.First_Element);
               Pres.Put_Note (Screen, "cli.intent.only_one", [Loc.Named ("name", Of_Kind.First_Element)]);
            end if;
         end;
      end if;

      --  Several named, or all: each moved as if named alone, in turn.
      --  all is every one waiting to be decided.
      if Action in "accept" | "reject" | "reconsider" | "obsolete" | "block" | "unblock"
        and then (Natural (Plain.Length) > 2 or else Lower (Word (2)) = "all")
      then
         declare
            Named : Names.Vector;
         begin
            if Lower (Word (2)) = "all" then
               Named := Nt.List (Store, Kind, Nt.First_State (Kind));
               if Named.Is_Empty then
                  Pres.Put_Note (Screen, "cli.project.no_pending");
                  return;
               end if;
            else
               for Index in 2 .. Natural (Plain.Length) loop
                  Named.Append (Plain (Index));
               end loop;
               --  Every one named is one there is, or nothing is moved: a
               --  word that is none -- a reason typed bare -- is said.
               for Id of Named loop
                  if Nt.State_Of (Store, Kind, Id) = "" then
                     Status := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Status, "name", "the " & Word_Of (Kind) & "s to " & Action);
                     E.Add_Text (Status, "value", Id);
                     E.Add_Text (Status, "detail", "it is no " & Word_Of (Kind) & " there is, and nothing is "
                                 & "moved; a reason is given as reason=...");
                     Pres.Report (Screen, Status);
                     return;
                  end if;
               end loop;
            end if;
            --  The way on said once, after the last: not after each, and
            --  the tasks they made waiting named together.
            Collecting := True;
            Collected := Null_Unbounded_String;
            for Index in 1 .. Natural (Named.Length) loop
               declare
                  One : Names.Vector;
               begin
                  Pres.Hold_Next_Steps (Screen, Index < Natural (Named.Length));
                  One.Append (Word (1));
                  One.Append (Named (Index));
                  Run (Store, Kind, One, Screen);
               end;
            end loop;
            Collecting := False;
            Pres.Hold_Next_Steps (Screen, False);
            if Ada.Strings.Fixed.Index (To_String (Collected), " ") > 0 then
               Pres.Put_Note (Screen, "cli.next.accept_tasks", [Loc.Named ("detail", To_String (Collected))]);
            elsif Collected /= Null_Unbounded_String and then Marked_Done (Store, To_String (Collected)) then
               --  Its document marks it done: taken as done, not done again.
               Pres.Put_Note (Screen, "cli.next.accept_marked_done", [Loc.Named ("name", To_String (Collected))]);
            elsif Collected /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.next.accept_task", [Loc.Named ("name", To_String (Collected))]);
            end if;
         end;
         return;
      end if;

      if Action = "" or else Action = "list" then
         --  Its filter is state=, of a state the register has: anything
         --  else said, not answered with all or with nothing.
         declare
            States : constant String :=
              (case Kind is
                  when Nt.Requirement => "candidate, accepted, implemented, verified, blocked, rejected or obsolete",
                  when others         => "candidate, accepted, rejected, superseded or obsolete");
         begin
            for Pair of Settings loop
               if Ada.Strings.Fixed.Index (Pair, "state=") /= Pair'First then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", "a filter of " & Word_Of_Command (Kind) & " list");
                  E.Add_Text (Status, "value", Pair);
                  E.Add_Text (Status, "detail", "it takes state=STATE alone");
               end if;
            end loop;
            if E.Is_Ok (Status) and then Natural (Plain.Length) > (if Action = "" then 0 else 1) then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", Word_Of_Command (Kind) & " list");
               E.Add_Text (Status, "value", Word ((if Action = "" then 1 else 2)));
               E.Add_Text (Status, "detail", "it takes state=STATE alone; " & Word_Of_Command (Kind)
                           & " show ID shows one");
            end if;
            if E.Is_Ok (Status) and then Given ("state") /= ""
              and then not Tr.Is_State (Nt.Machine_Of (Kind), Given ("state"))
            then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "a state of " & Word_Of_Command (Kind) & " list");
               E.Add_Text (Status, "value", Given ("state"));
               E.Add_Text (Status, "detail", "an entry here is " & States);
            end if;
            if E.Is_Error (Status) then
               Pres.Report (Screen, Status);
               return;
            end if;
         end;
         if Given ("state") /= "" and then Nt.List (Store, Kind, Given ("state")).Is_Empty
           and then not Nt.List (Store, Kind).Is_Empty
         then
            Pres.Put_Note (Screen, "cli.intent.none_match",
                           [Loc.Named ("value", Given ("state")),
                            Loc.Named ("count", Ada.Strings.Fixed.Trim
                                                  (Natural'Image (Natural (Nt.List (Store, Kind).Length)),
                                                   Ada.Strings.Both))]);
         end if;
         declare
            Held : Nt.Entity;
            Read : E.Error_Info;
         begin
            for Id of Nt.List (Store, Kind, Given ("state")) loop
               Nt.Read (Store, Kind, Id, Held, Read);
               --  Its state coloured by how it stands, as /req show has it.
               Pres.Put_Marked
                 (Screen, "cli.task.item",
                  [Loc.Named ("name", Id),
                   --  Replaced, in every register alike: by what.
                   --  An accepted requirement is not done yet: said, so
                   --  its colour reads as waiting, not as a fault.
                   Loc.Named ("value", (if Length (Held.Superseded_By) > 0
                                        then "superseded by " & To_String (Held.Superseded_By)
                                        elsif Nt."=" (Kind, Nt.Requirement)
                                          and then To_String (Held.State) = "accepted"
                                        then "accepted, not verified"
                                        else To_String (Held.State))),
                   Loc.Named ("detail", To_String (Held.Title))],
                  (if Length (Held.Superseded_By) > 0 then "superseded"
                   elsif Nt."=" (Kind, Nt.Requirement) and then To_String (Held.State) = "accepted"
                   then "accepted, not verified"
                   else To_String (Held.State)),
                  (if Length (Held.Superseded_By) > 0 then Pres.Bad
                   elsif To_String (Held.State) = "accepted" and then not Nt."=" (Kind, Nt.Requirement)
                   then Pres.Good
                   else Pres.Tone_Of (To_String (Held.State))));
            end loop;
            --  None at all: how to make the first.
            if Nt."=" (Kind, Nt.Requirement) and then Nt.List (Store, Kind).Is_Empty then
               Pres.Put_Note (Screen, "cli.next.requirements");
            elsif Nt."=" (Kind, Nt.Specification) and then Nt.List (Store, Kind).Is_Empty then
               Pres.Put_Note (Screen, "cli.next.specifications");
            elsif Nt."=" (Kind, Nt.Decision) and then Nt.List (Store, Kind).Is_Empty then
               Pres.Put_Note (Screen, "cli.next.decisions");
            end if;
         end;

      elsif Action = "new" then
         Needs (2, "a title: " & Word_Of_Command (Kind) & " new TITLE text=... criteria=... scope=...");
         --  What it says is its text: a title alone says nothing to be
         --  held to.
         if E.Is_Ok (Status) and then Given ("text") = "" then
            Status := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Status, "name", "its text, as text=...: " & Word_Of_Command (Kind) & " new "
                        & """" & From (2) & """ text=what it says");
         end if;
         if E.Is_Ok (Status) then
            declare
               Scope : constant String :=
                 (if Given ("scope") = "" then "project" else Given ("scope"));
               Key   : String :=
                 Ada.Characters.Handling.To_Upper (if Scope = "project" then "" else Scope);
               Id    : Unbounded_String;
            begin
               --  A scope is the project or one of its components: another
               --  would be accepted and then derive nothing.
               if Scope /= "project"
                 and then not Model_Runner.Framework.Tasks.Components (Store).Contains (Scope)
               then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", "scope");
                  E.Add_Text (Status, "value", Scope);
                  --  An entry's identifier is no component: what relates
                  --  this one to it is a link.
                  E.Add_Text (Status, "detail", "a scope is project or one of the project's components ("
                              & Joined_Components (Store) & ")"
                              & (if Ada.Strings.Fixed.Index (Scope, "REQ-") = Scope'First
                                   or else Ada.Strings.Fixed.Index (Scope, "SPEC-") = Scope'First
                                   or else Ada.Strings.Fixed.Index (Scope, "DEC-") = Scope'First
                                 then "; " & Scope & " is an entry, which " & Word_Of_Command (Kind)
                                      & " link ID dependency " & Scope & " relates this one to, once made"
                                 else "; /reconfigure add set.components " & Scope & " makes it one, and"
                                      & " /reconfigure map.component." & Scope & "=roots=DIR places it"
                                      & " once its files are there"));
                  Pres.Report (Screen, Status);
                  return;
               end if;
               for C of Key loop
                  if C not in 'A' .. 'Z' | '0' .. '9' then
                     C := '_';
                  end if;
               end loop;
               Nt.Propose
                 (Store, Change, Kind, Key, From (2),
                  (if Given ("text") = "" then From (2) else Given ("text")),
                  Given ("criteria"), "user", "", Scope, Id, Status);
               Settle (Store, Change, Status, Screen, "cli.task.created",
                       To_String (Id) & " " & From (2));

               --  Made, and said where another has the same title.
               if E.Is_Ok (Status) then
                  for Other of Nt.List (Store, Kind) loop
                     declare
                        Held : Nt.Entity;
                        Read : E.Error_Info;
                     begin
                        Nt.Read (Store, Kind, Other, Held, Read);
                        if E.Is_Ok (Read) and then Other /= To_String (Id)
                          and then Lower (To_String (Held.Title)) = Lower (From (2))
                          and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                        then
                           Pres.Put_Note
                             (Screen, "cli.same_title",
                              [Loc.Named ("name", To_String (Id)), Loc.Named ("other", Other)]);
                        end if;
                     end;
                  end loop;

                  --  A requirement stating no criteria: only its words judge
                  --  what serves it, said where criteria are given.
                  if Nt."=" (Kind, Nt.Requirement) and then Given ("criteria") = "" then
                     Pres.Put_Note (Screen, "cli.req.no_criteria", [Loc.Named ("name", To_String (Id))]);
                  end if;

                  --  A candidate: how it comes to count.
                  if Nt.State_Of (Store, Kind, To_String (Id)) = Nt.First_State (Kind) then
                     Pres.Put_Note
                       (Screen, (if Nt."=" (Kind, Nt.Requirement) then "cli.next.accept_requirement"
                                 elsif Nt."=" (Kind, Nt.Decision) then "cli.next.accept_decision"
                                 else "cli.next.accept_intent"),
                        [Loc.Named ("name", To_String (Id)),
                         Loc.Named ("value", (case Kind is
                                                when Nt.Requirement   => "/req",
                                                when Nt.Specification => "/spec",
                                                when Nt.Decision      => "/decision"))]);
                  end if;
               end if;
            end;
         end if;

      elsif Action in "accept" | "reject" | "reconsider" | "obsolete" | "block" | "unblock" then
         Needs (2, "the " & Word_Of (Kind));
         --  A field a move takes: reason=, for a block. Any other is said,
         --  not dropped.
         for Pair of Settings loop
            if E.Is_Ok (Status) and then Ada.Strings.Fixed.Index (Pair, "reason=") /= Pair'First then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "a field of " & Word_Of_Command (Kind) & " " & Action);
               E.Add_Text (Status, "value", Pair);
               E.Add_Text (Status, "detail", "it takes reason=... alone");
            end if;
         end loop;
         if E.Is_Ok (Status) then
            declare
               Granted : Tr.Permissions := Tr.Ordinary_Only;
               Next    : constant String :=
                 (if Action = "accept" or else Action = "unblock" then "accepted"
                  elsif Action = "reject" then "rejected"
                  elsif Action = "reconsider" then Nt.First_State (Kind)
                  elsif Action = "obsolete" then "obsolete"
                  else "blocked");
               Governed : constant String :=
                 (if Next in "obsolete" | "rejected" then Nt.Governs (Store, Kind, Word (2)) else "");
            begin
               if Action = "reconsider" then
                  Granted (Tr.Reconsideration) := True;
               end if;
               --  Retired and replaced: the replacement is the one to act on.
               if Next /= "obsolete"
                 and then Nt.State_Of (Store, Kind, Word (2)) in "obsolete" | "superseded"
               then
                  declare
                     Held : Nt.Entity;
                     Got  : E.Error_Info;
                  begin
                     Nt.Read (Store, Kind, Word (2), Held, Got);
                     Status := E.Make (E.Framework_Transition_Invalid);
                     E.Add_Text (Status, "name", Word (2));
                     E.Add_Text (Status, "value", To_String (Held.State));
                     E.Add_Text (Status, "expected", Next);
                     E.Add_Text (Status, "detail",
                                 "what is retired stays retired"
                                 & (if Held.Superseded_By /= Null_Unbounded_String
                                    then "; " & To_String (Held.Superseded_By) & " replaced it: "
                                         & Word_Of_Command (Kind) & " " & To_String (Held.Superseded_By)
                                         & " shows it"
                                    else "; " & Word_Of_Command (Kind) & " new """ & To_String (Held.Title)
                                         & """ text=... makes it anew"));
                     Pres.Report (Screen, Status);
                     return;
                  end;
               end if;
               --  Already there: said so, and nothing to do.
               if Nt.State_Of (Store, Kind, Word (2)) = Next then
                  Pres.Put_Note (Screen, "cli.intent.already",
                                 [Loc.Named ("name", Word (2)),
                                  Loc.Named ("value", (if Next in "accepted" | "rejected" | "obsolete" | "blocked"
                                                       then Next else "a " & Next))]);
                  return;
               end if;
               --  Obsolete is final: asked first, where there is someone to ask.
               if Next = "obsolete" and then Nt.State_Of (Store, Kind, Word (2)) /= ""
                 and then Model_Runner.CLI.Choosers.Is_Available (Screen)
               then
                  declare
                     Held : Nt.Entity;
                     Got  : E.Error_Info;
                  begin
                     Nt.Read (Store, Kind, Word (2), Held, Got);
                     Pres.Put_Message (Screen, "cli.intent.obsolete_confirm",
                                       [Loc.Named ("name", Word (2)), Loc.Named ("detail", To_String (Held.Title))]);
                     if not Answered_Yes (Screen) then
                        Pres.Put_Message (Screen, "cli.project.cancel.kept", [Loc.Named ("name", Word (2))]);
                        return;
                     end if;
                  end;
               end if;
               Nt.Move (Store, Change, Kind, Word (2), Next, Granted, Status, Actor => Tr.User,
                        Reason => Given ("reason"));
               if E.Is_Ok (Status) then
                  S.Commit (Store, Change, Status);
               end if;
               if E.Is_Error (Status) then
                  Pres.Report (Screen, Status);
                  return;
               end if;
               Pres.Put_Message
                 (Screen, "cli.task.moved", [Loc.Named ("name", Word (2)),
                                             Loc.Named ("value", Model_Runner.Framework.State_Said (Next))]);
               Apply_Rulings (Store, Kind, Word (2), Screen);
               --  A candidate again: how it is decided.
               if Action = "reconsider" then
                  Pres.Put_Note (Screen, "cli.next.accept_entry",
                                 [Loc.Named ("name", Word (2)), Loc.Named ("value", Word_Of_Command (Kind))]);
               end if;
               --  Rejected, and kept: how it comes back.
               if Next = "rejected" then
                  Pres.Put_Note (Screen, "cli.intent.rejected_back",
                                 [Loc.Named ("name", Word (2)), Loc.Named ("value", Word_Of_Command (Kind))]);
               end if;
               --  Accepted, and what that means: a decision that rules on
               --  nothing yet, how it would; a specification, where it holds.
               if Next = "accepted" and then Nt."=" (Kind, Nt.Decision)
                 and then Nt.Governs (Store, Kind, Word (2)) = ""
               then
                  Pres.Put_Note (Screen, "cli.next.decision_govern", [Loc.Named ("name", Word (2))]);
               elsif Next = "accepted" and then Nt."=" (Kind, Nt.Specification) then
                  declare
                     Held : Nt.Entity;
                     Got  : E.Error_Info;
                  begin
                     Nt.Read (Store, Kind, Word (2), Held, Got);
                     Pres.Put_Note (Screen, "cli.intent.spec_in_force",
                                    [Loc.Named ("name", Word (2)),
                                     Loc.Named ("value", (if To_String (Held.Scope) in "" | "project"
                                                          then "the whole project"
                                                          else "the component " & To_String (Held.Scope)))]);
                  end;
               end if;
               Move_Along (Store, Screen);

               --  What it governed is governed no more: said, with what the
               --  setting is now.
               Say_Ruling_Gone (Word (2), Governed);

               --  Retired, with work still open for it: how to let that go.
               if Nt."=" (Kind, Nt.Requirement) and then Next in "rejected" | "obsolete" then
                  Work_Left (Store, Screen, Word (2));
               end if;
            end;
         end if;

      elsif Action = "verify" and then Nt."=" (Kind, Nt.Requirement) then
         --  The requirement itself, by the project's profile for them; then
         --  what that changes about which are verified.
         Needs (2, "the requirement");
         if E.Is_Ok (Status) then
            declare
               package Vf renames Model_Runner.Framework.Verification;
               Evidence : Unbounded_String;
               Passed   : Boolean;
               Moved    : Names.Vector;
            begin
               Vf.Verify_Requirement (Store, Change, Word (2), Evidence, Passed, Status);
               if E.Is_Ok (Status) then
                  S.Commit (Store, Change, Status);
               end if;
               if E.Is_Ok (Status) then
                  Vf.Reevaluate_Requirements (Store, Change, Moved, Status);
               end if;
               if E.Is_Ok (Status) then
                  S.Commit (Store, Change, Status);
               end if;
               if E.Is_Error (Status) then
                  Pres.Report (Screen, Status);
                  return;
               end if;
               --  Passed, and still not verified: said once, with why -- not a
               --  pass beside a not-verified.
               if Nt.State_Of (Store, Kind, Word (2)) = "verified" then
                  Pres.Put_Message
                    (Screen, "cli.intent.verify_outcome",
                     [Loc.Named ("name", Word (2)), Loc.Named ("other", To_String (Evidence)),
                      Loc.Named ("value", (if Passed then "passed" else "failed"))]);
               end if;
               if Nt.State_Of (Store, Kind, Word (2)) /= "verified" then
                  Pres.Put_Message
                    (Screen, (if Passed then "cli.check.passed_not_verified" else "cli.check.not_verified_failed"),
                     [Loc.Named ("name", Word (2) & " (" & To_String (Evidence) & ")"),
                      Loc.Named ("detail", Vf.Why_Not_Verified (Store, Word (2)))]);
               end if;
               for Requirement of Moved loop
                  if Requirement /= Word (2) then
                     Pres.Put_Message
                       (Screen, "cli.work.requirement",
                        [Loc.Named ("name", Requirement),
                         Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
                  end if;
               end loop;
            end;
         end if;

      elsif Action = "move" then
         --  To any state the project's lifecycle allows: its own among them.
         Needs (3, (if Word (2) = "" then "the " & Word_Of (Kind) & " and the state: " & Word_Of_Command (Kind)
                                          & " move ID STATE"
                    else "the state to move " & Word (2) & " to: " & Word_Of_Command (Kind) & " move " & Word (2)
                         & " STATE"));
         if E.Is_Ok (Status) then
            declare
               Held : Nt.Entity;
               Read : E.Error_Info;
            begin
               Nt.Read (Store, Kind, Word (2), Held, Read);
               From_State := Held.State;
            end;
            Nt.Move (Store, Change, Kind, Word (2), Word (3), Tr.Ordinary_Only, Status,
                     Actor => Tr.User);
            if E.Is_Ok (Status) then
               S.Commit (Store, Change, Status);
            end if;
            if E.Is_Error (Status) then
               Pres.Report (Screen, Status);
               return;
            end if;
            Pres.Put_Message
              (Screen, "cli.intent.moved",
               [Loc.Named ("name", Word (2)), Loc.Named ("other", To_String (From_State)),
                Loc.Named ("value", Word (3))]);
            Move_Along (Store, Screen);
         end if;

      elsif Action = "revise" then
         Needs (2, "the " & Word_Of (Kind));
         if E.Is_Ok (Status) then
            declare
               Held   : Nt.Entity;
               Result : Nt.Impact;
            begin
               Nt.Read (Store, Kind, Word (2), Held, Status);

               --  Retired: not revised however asked, and said so first.
               if E.Is_Ok (Status) and then Lower (Word (3)) = "from-document"
                 and then To_String (Held.State) in "obsolete" | "superseded" | "rejected"
               then
                  Status := E.Make (E.Framework_Transition_Invalid);
                  E.Add_Text (Status, "name", Word (2));
                  E.Add_Text (Status, "value", To_String (Held.State));
                  E.Add_Text (Status, "expected", "a new revision");
                  E.Add_Text (Status, "detail",
                              (if Held.Superseded_By /= Null_Unbounded_String
                               then "it was replaced by " & To_String (Held.Superseded_By) & "; "
                                    & Word_Of_Command (Kind) & " revise " & To_String (Held.Superseded_By)
                                    & " from-document reads that one from its document"
                               else "it is retired, and what is retired is not revised; "
                                    & Word_Of_Command (Kind) & " new """ & To_String (Held.Title)
                                    & """ text=... makes it anew"));
               end if;
               --  from-document: its text as its document says it now.
               if E.Is_Ok (Status) and then Lower (Word (3)) = "from-document" then
                  declare
                     Path : constant String :=
                       Hostkit.Fs.Join
                         (Ada.Directories.Containing_Directory (S.Root (Store)),
                          To_String (Held.Source));
                     Text : Ada.Strings.Unbounded.Unbounded_String;
                     File : Ada.Text_IO.File_Type;
                  begin
                     if To_String (Held.Source) in "" | "user" or else Length (Held.Provenance) = 0 then
                        --  Made by hand: there are no words to take.
                        Status := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Status, "name", "from-document");
                        E.Add_Text (Status, "value", Word (2));
                        E.Add_Text (Status, "detail", Word (2) & " was made by hand; it has no document to"
                                    & " take words from, and text=... revises it");
                     elsif not Ada.Directories.Exists (Path) then
                        --  Gone: no words to take, and how it is retired.
                        Status := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Status, "name", "the document " & Word (2) & " came from");
                        E.Add_Text (Status, "value", To_String (Held.Source));
                        E.Add_Text (Status, "detail", "it is gone from the project, so there are no words of it to"
                                    & " take; " & Word_Of_Command (Kind) & " obsolete " & Word (2)
                                    & " retires it, and text=... revises it by hand");
                     else
                        Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
                        while not Ada.Text_IO.End_Of_File (File) loop
                           Ada.Strings.Unbounded.Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
                        end loop;
                        Ada.Text_IO.Close (File);

                        --  Only its own part of the document: what the
                        --  document says at the place it was taken from.
                        declare
                           Found : constant Model_Runner.Framework.Bootstrap.Output_List :=
                             Model_Runner.Framework.Bootstrap.Scan
                               (To_String (Held.Source), To_String (Text));
                           Taken : Boolean := False;
                        begin
                           for Index in 1 .. Model_Runner.Framework.Bootstrap.Length (Found) loop
                              declare
                                 One : constant Model_Runner.Framework.Bootstrap.Output :=
                                   Model_Runner.Framework.Bootstrap.Element (Found, Index);
                              begin
                                 if not Taken and then One.Provenance = Held.Provenance then
                                    Taken := True;
                                    if One.Text = Held.Text and then One.Title = Held.Title
                                      and then (One.Criteria = Held.Criteria
                                                or else One.Criteria = Null_Unbounded_String)
                                    then
                                       Pres.Put_Note
                                         (Screen, "cli.intent.unchanged", [Loc.Named ("name", Word (2))]);
                                       return;
                                    end if;
                                    Nt.Revise
                                      (Store, Change, Kind, Word (2), To_String (One.Title),
                                       To_String (One.Text),
                                       (if One.Criteria = Null_Unbounded_String
                                        then To_String (Held.Criteria)
                                        else To_String (One.Criteria)),
                                       Result, Status);
                                    --  What changed, said; and the tasks named
                                    --  by its title named by the new one.
                                    if E.Is_Ok (Status) then
                                       if One.Text /= Held.Text then
                                          Pres.Put_Note
                                            (Screen, "cli.intent.text_changed",
                                             [Loc.Named ("name", Word (2)),
                                              Loc.Named ("value", To_String (Held.Text)),
                                              Loc.Named ("detail", To_String (One.Text))]);
                                       end if;
                                       if Nt."=" (Kind, Nt.Requirement) then
                                          declare
                                             Retitled : Names.Vector;
                                          begin
                                             Model_Runner.Framework.Tasks.Retitle_Derived
                                               (Store, Change, Word (2), To_String (Held.Title),
                                                To_String (One.Title), Retitled);
                                             for Id of Retitled loop
                                                Pres.Put_Note
                                                  (Screen, "cli.intent.task_retitled",
                                                   [Loc.Named ("name", Id), Loc.Named ("value", Word (2))]);
                                             end loop;
                                          end;
                                       end if;
                                    end if;

                                    --  Taken from the document: what it says is
                                    --  what it was imported as, so a later edit
                                    --  of the document is the document's.
                                    if E.Is_Ok (Status) then
                                       declare
                                          Where  : constant Model_Runner.Framework.Area :=
                                            (case Kind is
                                               when Nt.Requirement   =>
                                                  Model_Runner.Framework.Requirements_Area,
                                               when Nt.Specification =>
                                                  Model_Runner.Framework.Specs_Area,
                                               when Nt.Decision      =>
                                                  Model_Runner.Framework.Decisions_Area);
                                          Value  : Model_Runner.Framework.Records.Item;
                                          Staged : Boolean;
                                       begin
                                          S.Pending (Change, Where, Word (2), Value, Staged);
                                          if Staged then
                                             Model_Runner.Framework.Records.Set
                                               (Value, "imported_text", To_String (One.Text));
                                             Model_Runner.Framework.Records.Set
                                               (Value, "imported_criteria", To_String (One.Criteria));
                                             Model_Runner.Framework.Records.Set
                                               (Value, "imported_title", To_String (One.Title));
                                             S.Put (Change, Where, Word (2), Value);
                                          end if;
                                       end;
                                    end if;
                                 end if;
                              end;
                           end loop;
                           --  Marked retired there now: said as bootstrap says it.
                           if not Taken then
                              for Index in 1 .. Model_Runner.Framework.Bootstrap.Length (Found) loop
                                 declare
                                    One : constant Model_Runner.Framework.Bootstrap.Output :=
                                      Model_Runner.Framework.Bootstrap.Element (Found, Index);
                                 begin
                                    if not Taken and then One.Provenance = Held.Provenance & "#retired" then
                                       Taken := True;
                                       Status := E.Make (E.Framework_Input_Invalid);
                                       E.Add_Text (Status, "name", "from-document");
                                       E.Add_Text (Status, "value", Word (2));
                                       E.Add_Text
                                         (Status, "detail",
                                          To_String (Held.Source) & " now marks it " & To_String (One.Text) & "; "
                                          & Word_Of_Command (Kind) & " obsolete " & Word (2) & " retires it");
                                    end if;
                                 end;
                              end loop;
                           end if;
                           if not Taken then
                              Status := E.Make (E.Framework_Input_Invalid);
                              E.Add_Text (Status, "name", "from-document");
                              E.Add_Text (Status, "value", Word (2));
                              E.Add_Text
                                (Status, "detail",
                                 To_String (Held.Source) & " no longer says " & Word (2) & ": "
                                 & Word_Of_Command (Kind) & " revise " & Word (2) & " text=... says it anew, or "
                                 & Word_Of_Command (Kind) & " obsolete " & Word (2) & " retires it");
                           end if;
                        end;
                        Settle (Store, Change, Status, Screen, "cli.task.revised", Word (2));
                        return;
                     end if;
                  end;

               --  Something to revise, and something that differs.
               elsif E.Is_Ok (Status)
                 and then Given ("title") = "" and then Given ("text") = ""
                 and then Given ("criteria") = "" and then Given ("scope") = ""
               then
                  Status := E.Make (E.Framework_Input_Missing);
                  E.Add_Text (Status, "name", "what to revise: title=..., text=..., criteria=... or scope=...");
               elsif E.Is_Ok (Status)
                 and then (Given ("title") = "" or else Given ("title") = To_String (Held.Title))
                 and then (Given ("text") = "" or else Given ("text") = To_String (Held.Text))
                 and then (Given ("criteria") = ""
                           or else Given ("criteria") = To_String (Held.Criteria))
                 and then (Given ("scope") = "" or else Given ("scope") = To_String (Held.Scope))
               then
                  Pres.Put_Note (Screen, "cli.intent.unchanged", [Loc.Named ("name", Word (2))]);
                  return;
               end if;
               --  Its scope: the project, or a component it has.
               if E.Is_Ok (Status) and then Given ("scope") /= "" and then Given ("scope") /= To_String (Held.Scope)
               then
                  if Given ("scope") /= "project"
                    and then not Model_Runner.Framework.Tasks.Components (Store).Contains (Given ("scope"))
                  then
                     Status := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Status, "name", "scope");
                     E.Add_Text (Status, "value", Given ("scope"));
                     E.Add_Text (Status, "detail", "it is project, or one of the project's components: "
                                 & Joined_Components (Store));
                  else
                     Nt.Rescope (Store, Change, Kind, Word (2), Given ("scope"), Status);
                     --  An identifier keyed by the component it was made in
                     --  keeps it: said, so the two are not taken for one.
                     declare
                        Upper : constant String := Ada.Characters.Handling.To_Upper (Word (2));
                        Was   : constant String := Ada.Characters.Handling.To_Upper (To_String (Held.Scope));
                     begin
                        if E.Is_Ok (Status) and then Was /= "PROJECT"
                          and then Ada.Strings.Fixed.Index (Upper, "-" & Was & "-") > 0
                        then
                           Pres.Put_Note (Screen, "cli.intent.id_keeps_scope",
                                          [Loc.Named ("name", Word (2)),
                                           Loc.Named ("value", Given ("scope")),
                                           Loc.Named ("other", To_String (Held.Scope))]);
                        end if;
                     end;
                  end if;
                  if Given ("title") = "" and then Given ("text") = "" and then Given ("criteria") = "" then
                     Settle (Store, Change, Status, Screen, "cli.task.revised", Word (2));
                     return;
                  end if;
               end if;
               if E.Is_Ok (Status) then
                  Nt.Revise
                    (Store, Change, Kind, Word (2),
                     (if Given ("title") /= "" then Given ("title")
                      elsif Given ("text") /= "" and then Title_From_Text (Held)
                      then Headline (Given ("text"))
                      else To_String (Held.Title)),
                     (if Given ("text") = "" then To_String (Held.Text) else Given ("text")),
                     (if Given ("criteria") = "" then To_String (Held.Criteria)
                      else Given ("criteria")),
                     Result, Status);
                  --  A new title: the open tasks derived from it follow.
                  if E.Is_Ok (Status) and then Nt."=" (Kind, Nt.Requirement) then
                     declare
                        Retitled : Names.Vector;
                     begin
                        Model_Runner.Framework.Tasks.Retitle_Derived
                          (Store, Change, Word (2), To_String (Held.Title),
                           (if Given ("title") /= "" then Given ("title")
                            elsif Given ("text") /= "" and then Title_From_Text (Held)
                            then Headline (Given ("text"))
                            else To_String (Held.Title)),
                           Retitled);
                        for Id of Retitled loop
                           Pres.Put_Note (Screen, "cli.intent.task_retitled",
                                          [Loc.Named ("name", Id), Loc.Named ("value", Word (2))]);
                        end loop;
                     end;
                  end if;
               end if;
               Settle (Store, Change, Status, Screen, "cli.task.revised", Word (2));
               if E.Is_Ok (Status) and then Result.Invalidated then
                  Pres.Put_Note (Screen, "cli.intent.invalidated", [Loc.Named ("name", Word (2))]);
               end if;
            end;
         end if;

      elsif Action = "unlink" then
         Needs (4, "unlink ID RELATION TARGET, whose RELATION is dependency, component,"
                & " implementation, task, test or verification");
         if E.Is_Ok (Status) then
            declare
               Relation : Nt.Link_Kind := Nt.Dependency;
               Found    : Boolean := False;
            begin
               for One in Nt.Link_Kind loop
                  if Lower (Nt.Link_Kind'Image (One)) = Lower (Word (3))
                    or else (Nt."=" (One, Nt.Task_Link) and then Lower (Word (3)) = "task")
                  then
                     Relation := One;
                     Found := True;
                  end if;
               end loop;
               if not Found then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", "the kind of link");
                  E.Add_Text (Status, "value", Word (3));
                  E.Add_Text (Status, "detail", "a link is a dependency, component,"
                              & " implementation, task, test or verification");
               else
                  Nt.Unlink (Store, Change, Kind, Word (2), Relation, From (4), Status);
               end if;
               --  Which link: its kind and what it named.
               Settle (Store, Change, Status, Screen, "cli.intent.unlinked",
                       Word (2) & "'s " & Lower (Word (3)) & " link to " & From (4));
            end;
         end if;

      elsif Action = "link" then
         --  The relation as /trace says it -- implemented_by, tested_by --
         --  is the one it names; left out before a file or a symbol, it is
         --  implementation.
         if Natural (Plain.Length) >= 3 then
            declare
               Said : constant String := Lower (Word (3));
            begin
               if Said in "implemented_by" | "implements" | "implemented" then
                  Plain.Replace_Element (3, "implementation");
               elsif Said in "tested_by" | "tests" | "tested" then
                  Plain.Replace_Element (3, "test");
               elsif Said in "depends_on" | "depends" then
                  Plain.Replace_Element (3, "dependency");
               elsif Said in "served_by" | "tasks" then
                  Plain.Replace_Element (3, "task");
               elsif Natural (Plain.Length) = 3
                 and then Said not in "dependency" | "component" | "implementation" | "task" | "test"
                                    | "verification"
               then
                  Plain.Insert (3, "implementation");
               end if;
            end;
         end if;
         --  A place as /refs gives it, src/x.py:20, is its file.
         if Natural (Plain.Length) = 4 and then Lower (Word (3)) in "implementation" | "test" then
            declare
               Target : constant String := Word (4);
               Colon  : constant Natural := Ada.Strings.Fixed.Index (Target, ":", Ada.Strings.Backward);
            begin
               if Colon > Target'First and then Colon < Target'Last
                 and then (for all C of Target (Colon + 1 .. Target'Last) => C in '0' .. '9')
               then
                  Plain.Replace_Element (4, Target (Target'First .. Colon - 1));
               end if;
            end;
         end if;
         Needs (4, "link ID RELATION TARGET, whose RELATION is dependency, component,"
                & " implementation, task, test or verification -- as " & Word_Of_Command (Kind) & " link "
                & (case Kind is
                      when Nt.Requirement   => "REQ-001",
                      when Nt.Specification => "SPEC-001",
                      when Nt.Decision      => "DEC-001")
                & " implementation src/parser.c");
         --  A directory, or a path that is no file here, is nothing to
         --  point at: refused, as a name nothing is called is.
         if E.Is_Ok (Status) and then Lower (Word (3)) in "implementation" | "test"
           and then (Ada.Strings.Fixed.Index (From (4), "/") > 0
                     or else From (4) in "." | ".."
                     or else (Ada.Directories.Exists
                                (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), From (4)))
                              and then Ada.Directories."="
                                         (Ada.Directories.Kind
                                            (Hostkit.Fs.Join
                                               (Ada.Directories.Containing_Directory (S.Root (Store)), From (4))),
                                          Ada.Directories.Directory)))
         then
            declare
               Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
               Path    : constant String :=
                 Hostkit.Fs.Join (Project, Model_Runner.Framework.Repository.Relative_Path (Project, From (4)));
            begin
               if not Ada.Directories.Exists (Path) then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", What_Links (Word (3)));
                  E.Add_Text (Status, "value", From (4));
                  E.Add_Text (Status, "detail", "there is no such file here; a file is named by its path"
                              & " in the project, and /sym NAME finds a symbol");
               elsif Ada.Directories."=" (Ada.Directories.Kind (Path), Ada.Directories.Directory) then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", What_Links (Word (3)));
                  E.Add_Text (Status, "value", From (4));
                  E.Add_Text (Status, "detail", "it is a directory: a link names a file in it, or a symbol");
               end if;
            end;
         end if;
         if E.Is_Ok (Status) then
            declare
               Relation : Nt.Link_Kind := Nt.Dependency;
               Found    : Boolean := False;
            begin
               for One in Nt.Link_Kind loop
                  if Lower (Nt.Link_Kind'Image (One)) = Lower (Word (3))
                    or else (One = Nt.Task_Link and then Lower (Word (3)) = "task")
                  then
                     Relation := One;
                     Found := True;
                  end if;
               end loop;
               declare
                  --  A path as the project names it: ./src/x and a whole
                  --  path into the project are src/x.
                  Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
                  --  Typed where the session was started, below the top: from there.
                  Given_Path : constant String := From_Start (Project, From (4));
                  --  A symbol by the name the repository's graph gives it:
                  --  checksum is parse.checksum where that is the one.
                  Symbols : constant Names.Vector :=
                    (if Found and then Relation in Nt.Implementation | Nt.Test
                       and then Ada.Strings.Fixed.Index (Given_Path, "/") = 0
                       and then not Ada.Directories.Exists (Hostkit.Fs.Join (Project, Given_Path))
                     then Model_Runner.Framework.Repository.Find_Symbols
                            (Model_Runner.Framework.Repository.Now (Store), Given_Path)
                     else Names.Empty_Vector);
                  Target : constant String :=
                    (if Found and then Relation in Nt.Implementation | Nt.Test
                       and then Ada.Strings.Fixed.Index (Given_Path, "/") > 0
                     then Model_Runner.Framework.Repository.Relative_Path (Project, Given_Path)
                     elsif Natural (Symbols.Length) = 1 then Symbols.First_Element
                     else Given_Path);
               begin
                  if Found and then Relation in Nt.Implementation | Nt.Test
                    and then Ada.Strings.Fixed.Index (Given_Path, "/") = 0
                    and then not Ada.Directories.Exists (Hostkit.Fs.Join (Project, Given_Path))
                    and then Natural (Symbols.Length) /= 1
                  then
                     --  None, or several: said, not linked to a name the
                     --  graph does not know.
                     declare
                        Listed : Unbounded_String;
                     begin
                        for One of Symbols loop
                           Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
                        end loop;
                        Status := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Status, "name", What_Links (Word (3)));
                        E.Add_Text (Status, "value", From (4));
                        E.Add_Text (Status, "detail",
                                    (if Symbols.Is_Empty
                                     then "it is no file here and nothing in the repository is called so;"
                                          & " /sym NAME finds a symbol, and a file is named by its path"
                                     else "several symbols are called so -- " & To_String (Listed)
                                          & "; name one whole"));
                     end;
                  elsif not Found then
                     Status := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Status, "name", "the kind of link");
                     E.Add_Text (Status, "value", Word (3));
                     E.Add_Text (Status, "detail", "a link is a dependency, component,"
                                 & " implementation, task, test or verification");
                  elsif Nt.Links (Store, Kind, Word (2), Relation).Contains (Target) then
                     Pres.Put_Note (Screen, "cli.intent.already",
                                    [Loc.Named ("name", Word (2)),
                                     Loc.Named ("value", "linked to " & Target)]);
                     return;
                  elsif Nt."=" (Relation, Nt.Dependency) and then Nt.State_Of (Store, Kind, Target) = "" then
                     --  What it depends on is one of its own register there is.
                     Status := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Status, "name", "what " & Word (2) & " depends on");
                     E.Add_Text (Status, "value", Target);
                     E.Add_Text (Status, "detail", "a " & Word_Of (Kind) & " depends on another " & Word_Of (Kind)
                                 & ", and " & Target & " is "
                                 & (if (for some Other in Nt.Intent_Kind => Nt.State_Of (Store, Other, Target) /= "")
                                    then "of another register"
                                    else "none the project holds"));
                  elsif Nt."=" (Relation, Nt.Dependency) and then Target = Word (2) then
                     Status := E.Make (E.Framework_Dependency_Cycle);
                     E.Add_Text (Status, "name", Word (2));
                     E.Add_Text (Status, "detail", "a requirement does not depend on itself");
                  elsif Nt."=" (Relation, Nt.Task_Link)
                    and then Model_Runner.Framework.Tasks.State_Of (Store, Target) = ""
                  then
                     Status := E.Make (E.Framework_Not_Found);
                     E.Add_Text (Status, "name", Target);
                  else
                     Nt.Link (Store, Change, Kind, Word (2), Relation, Target, Status);
                  end if;
                  Settle (Store, Change, Status, Screen, "", Word (2));
                  if E.Is_Ok (Status) then
                     Pres.Put_Message (Screen, "cli.intent.linked",
                                       [Loc.Named ("name", Word (2)),
                                        Loc.Named ("detail", Lower (Word (3)) & " " & Target)]);
                  end if;
               end;

               --  What it implements or tests is looked for, and said when
               --  the repository has no such thing.
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Component)
                 and then not Model_Runner.Framework.Tasks.Components (Store).Contains (From (4))
               then
                  Pres.Put_Note
                    (Screen, "cli.intent.link_component",
                     [Loc.Named ("name", From (4)),
                      Loc.Named ("value", Joined_Components (Store)),
                      Loc.Named ("other", (if Nt."=" (Kind, Nt.Requirement) then "/req"
                                           elsif Nt."=" (Kind, Nt.Decision) then "/decision"
                                           else "/spec") & " unlink " & Word (2))]);
               end if;
               --  Linked to a component: the work serving it that is
               --  elsewhere is named, with how to place it there.
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Component)
                 and then Nt."=" (Kind, Nt.Requirement)
               then
                  for Id of Model_Runner.Framework.Tasks.List (Store) loop
                     declare
                        Defined : Model_Runner.Framework.Records.Item;
                        Read    : E.Error_Info;
                     begin
                        Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Read);
                        if E.Is_Ok (Read)
                          and then Model_Runner.Framework.Tasks.State_Of (Store, Id)
                                     not in "complete" | "cancelled" | "rejected"
                          and then Model_Runner.Framework.Lines_Of
                                     (Model_Runner.Framework.Records.Get (Defined, "requirements"))
                                     .Contains (Word (2))
                          and then Model_Runner.Framework.Records.Get (Defined, "component") /= From (4)
                          and then Model_Runner.Framework.Tasks.Components (Store).Contains (From (4))
                        then
                           Pres.Put_Note
                             (Screen, "cli.next.task_component",
                              [Loc.Named ("name", Id), Loc.Named ("value", From (4)),
                               Loc.Named ("other", Word (2))]);
                        end if;
                     end;
                  end loop;
               end if;

               --  A task linked that serves a requirement since retired:
               --  said, with the two ways on.
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Task_Link) then
                  declare
                     Defined : Model_Runner.Framework.Records.Item;
                     Read    : E.Error_Info;
                  begin
                     Model_Runner.Framework.Tasks.Definition (Store, From (4), Defined, Read);
                     if E.Is_Ok (Read) then
                        for Served of Model_Runner.Framework.Lines_Of
                                        (Model_Runner.Framework.Records.Get (Defined, "requirements"))
                        loop
                           if Nt.State_Of (Store, Nt.Requirement, Served)
                                in "obsolete" | "rejected" | "superseded"
                           then
                              Pres.Put_Note
                                (Screen, "cli.intent.link_task_retired",
                                 [Loc.Named ("name", From (4)), Loc.Named ("detail", Served),
                                  Loc.Named ("value", Word (2))]);
                           end if;
                        end loop;
                     end if;
                  end;
               end if;

               --  A dependency on one retired, or one that leads back to
               --  it; evidence that is not there: kept, and said.
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Dependency)
                 and then Nt.State_Of (Store, Kind, From (4)) in "obsolete" | "rejected" | "superseded"
               then
                  Pres.Put_Note
                    (Screen, "cli.intent.link_doubtful",
                     [Loc.Named ("name", Word (2)), Loc.Named ("value", From (4)),
                      Loc.Named ("detail", From (4) & " is " & Nt.State_Of (Store, Kind, From (4))
                                           & "; " & Word_Of_Command (Kind) & " unlink " & Word (2) & " dependency "
                                           & From (4)
                                           & " takes it off")]);
               elsif E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Dependency) then
                  declare
                     Seen : Names.Vector;
                     function Reaches (From_Id : String) return Boolean is
                     begin
                        if From_Id = Word (2) then
                           return True;
                        elsif Seen.Contains (From_Id) then
                           return False;
                        end if;
                        Seen.Append (From_Id);
                        for Next of Nt.Links (Store, Kind, From_Id, Nt.Dependency) loop
                           if Reaches (Next) then
                              return True;
                           end if;
                        end loop;
                        return False;
                     end Reaches;
                  begin
                     if Reaches (From (4)) then
                        Pres.Put_Note
                          (Screen, "cli.intent.link_doubtful",
                           [Loc.Named ("name", Word (2)), Loc.Named ("value", From (4)),
                            Loc.Named ("detail", From (4) & " depends on " & Word (2)
                                                 & " already, so each waits for the other; "
                                                 & Word_Of_Command (Kind) & " unlink "
                                                 & Word (2) & " dependency " & From (4)
                                                 & " takes it off")]);
                     end if;
                  end;
               end if;
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Verification)
                 and then not S.Exists (Store, Model_Runner.Framework.Verification_Area, From (4))
               then
                  Pres.Put_Note
                    (Screen, "cli.intent.link_doubtful",
                     [Loc.Named ("name", Word (2)), Loc.Named ("value", From (4)),
                      Loc.Named ("detail", "no evidence is called " & From (4) & "; /result lists what is"
                                           & " kept, and " & Word_Of_Command (Kind) & " unlink " & Word (2)
                                           & " verification "
                                           & From (4) & " takes it off")]);
               end if;

               if E.Is_Ok (Status) and then Relation in Nt.Implementation | Nt.Test then
                  declare
                     package Rp renames Model_Runner.Framework.Repository;
                     Now    : constant Rp.Graph := Rp.Now (Store);
                     Target : constant String :=
                       (if Ada.Strings.Fixed.Index
                             (From_Start (Ada.Directories.Containing_Directory (S.Root (Store)), From (4)), "/") > 0
                        then Rp.Relative_Path
                               (Ada.Directories.Containing_Directory (S.Root (Store)),
                                From_Start (Ada.Directories.Containing_Directory (S.Root (Store)), From (4)))
                        else From (4));
                     Known  : Boolean := not Rp.Find_Symbols (Now, Target).Is_Empty;
                  begin
                     for Index in 1 .. Rp.File_Count (Now) loop
                        Known := Known or else To_String (Rp.File_At (Now, Index).Path) = Target;
                     end loop;
                     if not Known then
                        Pres.Put_Note
                          (Screen, "cli.intent.link_unknown",
                           [Loc.Named ("name", Target),
                            Loc.Named ("other", (if Nt."=" (Kind, Nt.Requirement) then "/req"
                                                 elsif Nt."=" (Kind, Nt.Decision) then "/decision"
                                                 else "/spec") & " unlink " & Word (2)),
                            Loc.Named ("value", Lower (Word (3)))]);
                     end if;
                  end;
               end if;
            end;
         end if;

      elsif Action = "supersede" then
         Needs (3, "the " & Word_Of (Kind) & " replaced and the one replacing it");
         if E.Is_Ok (Status) then
            declare
               Was      : constant String := Nt.State_Of (Store, Kind, Word (3));
               Governed : constant String := Nt.Governs (Store, Kind, Word (2));
               Taken    : Names.Vector;
               Kept     : Names.Vector;

               --  The open work that serves the replacement already.
               function Served_By (Requirement : String) return String is
                  Found : Unbounded_String;
               begin
                  for Id of Model_Runner.Framework.Tasks.List (Store) loop
                     declare
                        Defined : Model_Runner.Framework.Records.Item;
                        Read    : E.Error_Info;
                     begin
                        Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Read);
                        if E.Is_Ok (Read)
                          and then Model_Runner.Framework.Tasks.State_Of (Store, Id)
                                     not in "cancelled" | "rejected"
                          and then Model_Runner.Framework.Lines_Of
                                     (Model_Runner.Framework.Records.Get (Defined, "requirements"))
                                     .Contains (Requirement)
                        then
                           Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Id);
                        end if;
                     end;
                  end loop;
                  return To_String (Found);
               end Served_By;
               Serving_New : constant String :=
                 (if Nt."=" (Kind, Nt.Requirement) then Served_By (Word (3)) else "");
            begin
               --  A replacement done and verified already is another's work
               --  finished: taking the old one's place would undo that, so
               --  it is asked for by name.
               if Nt."=" (Kind, Nt.Requirement) and then Was in "implemented" | "verified"
                 and then Lower (Word (4)) /= "anyway"
               then
                  Status := E.Make (E.Framework_Transition_Invalid);
                  E.Add_Text (Status, "name", Word (3));
                  E.Add_Text (Status, "value", Was);
                  E.Add_Text (Status, "expected", "the replacement of " & Word (2));
                  E.Add_Text (Status, "detail", Word (3) & " is " & Was & " already, and replacing "
                              & Word (2) & " would have it judged again; /req supersede " & Word (2) & " "
                              & Word (3) & " anyway does it, or /req obsolete " & Word (2)
                              & " retires it alone");
                  Pres.Report (Screen, Status);
                  return;
               end if;
               --  Final, as obsolete is: asked first, where someone can be.
               if Model_Runner.CLI.Choosers.Is_Available (Screen) then
                  Pres.Put_Message (Screen, "cli.intent.supersede_confirm",
                                    [Loc.Named ("name", Word (2)), Loc.Named ("value", Word (3))]);
                  if not Answered_Yes (Screen) then
                     Pres.Put_Message (Screen, "cli.project.cancel.kept", [Loc.Named ("name", Word (2))]);
                     return;
                  end if;
               end if;
               declare
                  Governed_Before : constant String := Nt.Governs (Store, Kind, Word (2));
               begin
                  Nt.Supersede (Store, Change, Kind, Word (2), Word (3), Status);
                  if E.Is_Ok (Status) and then Governed_Before /= "" then
                     S.Commit (Store, Change, Status);
                     Say_Ruling_Gone (Word (2), Governed_Before);
                  end if;
               end;

               --  A candidate replacing one accepted takes its place, and so
               --  is accepted with it: said, not done unsaid.
               if E.Is_Ok (Status) and then Was = Nt.First_State (Kind) then
                  Pres.Put_Note (Screen, "cli.intent.superseded_accepted",
                                 [Loc.Named ("name", Word (3)), Loc.Named ("value", Word (2))]);
               end if;

               --  The work open for the one replaced is the replacement's
               --  now: moved to it, not left for a task derived beside it.
               if E.Is_Ok (Status) and then Nt."=" (Kind, Nt.Requirement) then
                  for Id of Model_Runner.Framework.Tasks.List (Store) loop
                     declare
                        Defined : Model_Runner.Framework.Records.Item;
                        Read    : E.Error_Info;
                        Serves  : Names.Vector;
                        Fields  : Model_Runner.Framework.Tasks.Field_Map;
                        Now     : Unbounded_String;
                     begin
                        Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Read);
                        Serves := Model_Runner.Framework.Lines_Of
                          (Model_Runner.Framework.Records.Get (Defined, "requirements"));
                        if E.Is_Ok (Read) and then Serves.Contains (Word (2))
                          and then Model_Runner.Framework.Tasks.State_Of (Store, Id)
                                     in "candidate" | "accepted" | "blocked" | "failed"
                          and then Serving_New /= ""
                        then
                           --  The replacement has its work: this is not moved
                           --  onto it beside that, but said.
                           Kept.Append (Id);
                        elsif E.Is_Ok (Read) and then Serves.Contains (Word (2))
                          and then Model_Runner.Framework.Tasks.State_Of (Store, Id)
                                     in "candidate" | "accepted" | "blocked" | "failed"
                        then
                           for One of Serves loop
                              declare
                                 Named : constant String := (if One = Word (2) then Word (3) else One);
                              begin
                                 if Ada.Strings.Fixed.Index (To_String (Now), Named) = 0 then
                                    Append (Now, (if Now = Null_Unbounded_String then "" else ",")
                                                 & Named);
                                 end if;
                              end;
                           end loop;
                           Fields.Include ("requirements", To_String (Now));
                           --  Titled after the one replaced, as a derived task
                           --  is: titled after the replacement now.
                           declare
                              Title : constant String :=
                                Model_Runner.Framework.Records.Get (Defined, "title");
                              Held  : Nt.Entity;
                              Got   : E.Error_Info;
                           begin
                              if Ada.Strings.Fixed.Index (Title, Word (2) & ": ") = Title'First then
                                 Nt.Read (Store, Nt.Requirement, Word (3), Held, Got);
                                 if E.Is_Ok (Got) then
                                    Fields.Include ("title", Word (3) & ": " & To_String (Held.Title));
                                 end if;
                              end if;
                           end;
                           Model_Runner.Framework.Tasks.Revise (Store, Change, Id, Fields, Read);
                           if E.Is_Ok (Read) then
                              Taken.Append (Id);
                           end if;
                        end if;
                     end;
                  end loop;
               end if;
               if E.Is_Ok (Status) then
                  S.Commit (Store, Change, Status);
               end if;
               if E.Is_Error (Status) then
                  Pres.Report (Screen, Status);
                  return;
               end if;

               --  Said in the order it happened: replaced, what replaces it
               --  accepted, the work moved; then what follows from that.
               Pres.Put_Message
                 (Screen, "cli.intent.superseded",
                  [Loc.Named ("name", Word (2)),
                   Loc.Named ("value", Nt.State_Of (Store, Kind, Word (2))),
                   Loc.Named ("other", Word (3))]);
               if Was = Nt.First_State (Kind) then
                  Pres.Put_Message
                    (Screen, "cli.intent.moved",
                     [Loc.Named ("name", Word (3)), Loc.Named ("other", Was),
                      Loc.Named ("value", Nt.State_Of (Store, Kind, Word (3)))]);
               end if;
               for Id of Taken loop
                  Pres.Put_Message
                    (Screen, "cli.intent.work_moved",
                     [Loc.Named ("name", Id), Loc.Named ("value", Word (3)),
                      Loc.Named ("other", Word (2))]);
               end loop;
               for Id of Kept loop
                  Pres.Put_Note
                    (Screen, "cli.intent.work_kept",
                     [Loc.Named ("name", Id), Loc.Named ("value", Word (3)),
                      Loc.Named ("other", Word (2)), Loc.Named ("detail", Serving_New)]);
               end loop;
               if Governed /= "" and then Nt.Governs (Store, Kind, Word (3)) = "" then
                  Pres.Put_Note (Screen, "cli.intent.ruling_dropped",
                                 [Loc.Named ("name", Word (2)), Loc.Named ("other", Word (3)),
                                  Loc.Named ("value", Governed),
                                  Loc.Named ("detail", Carried_On (Store, Governed, Word (3)))]);
               end if;
               if Nt."=" (Kind, Nt.Requirement) and then Kept.Is_Empty then
                  Work_Left (Store, Screen, Word (2));
               end if;
               Move_Along (Store, Screen);
            end;
         end if;

      --  A requirement says what is wanted, not how the harness runs: a
      --  ruling on a setting is a decision's, or a specification's.
      elsif Action = "govern" and then Nt."=" (Kind, Nt.Requirement) then
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", "what a requirement does");
         E.Add_Text (Status, "value", "govern");
         E.Add_Text (Status, "detail", "a requirement rules on no setting; /decision govern ID SETTING RULING"
                     & " does, a decision saying why");
         Pres.Report (Screen, Status);
         return;
      elsif Action = "govern"
        and then (Natural (Plain.Length) = 3 or else (Natural (Plain.Length) = 4 and then Lower (Word (4)) = "none"))
      then
         --  A setting named and no ruling, or none: it governs that one no
         --  more, and what holds then is said. off is a ruling, as a
         --  permission is taken away.
         declare
            Rulings : Names.Vector := Nt.Also_Governs (Store, Kind, Word (2));
            Found   : Unbounded_String;
            Listed  : Unbounded_String;
         begin
            if Nt.Governs (Store, Kind, Word (2)) /= "" then
               Rulings.Prepend (Nt.Governs (Store, Kind, Word (2)));
            end if;
            for Line of Rulings loop
               declare
                  Setting : constant String := Line (Line'First .. Ada.Strings.Fixed.Index (Line & " = ", " = ") - 1);
               begin
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Setting);
                  if Setting = Word (3)
                    or else (Setting'Length > Word (3)'Length
                             and then Setting (Setting'Last - Word (3)'Length .. Setting'Last) = "." & Word (3))
                  then
                     Found := To_Unbounded_String (Line);
                  end if;
               end;
            end loop;
            if Found = Null_Unbounded_String then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "a setting " & Word (2) & " governs");
               E.Add_Text (Status, "value", Word (3));
               E.Add_Text (Status, "detail",
                           (if Listed = Null_Unbounded_String then Word (2) & " rules on no setting"
                            else "it rules on " & To_String (Listed) & " only")
                           & ", and none takes a ruling it has off"
                           & (if Ada.Strings.Fixed.Index (Word (3), "map.permission.") = Word (3)'First
                                and then not (for some One in Model_Runner.Framework.Permissions.Capability =>
                                                Ada.Strings.Fixed.Tail
                                                  (Word (3), Model_Runner.Framework.Permissions.Word (One)'Length + 1)
                                                = "." & Model_Runner.Framework.Permissions.Word (One))
                              then "; that a level grants nothing is ruled a capability at a time, as "
                                   & Word_Of_Command (Kind) & " govern " & Word (2) & " " & Word (3)
                                   & ".write_source off, or set by /reconfigure " & Word (3) & "=none"
                              --  A capability: withheld is ruled off, not none.
                              elsif Ada.Strings.Fixed.Index (Word (3), "map.permission.") = Word (3)'First
                              then "; that it is withheld is ruled off: " & Word_Of_Command (Kind) & " govern "
                                   & Word (2) & " " & Word (3) & " off"
                              elsif Listed /= Null_Unbounded_String
                              then "; " & Word_Of_Command (Kind) & " govern " & Word (2) & " SETTING none takes one"
                                   & " of those off, and " & Word_Of_Command (Kind)
                                   & " new TITLE text=... makes another to rule on " & Word (3)
                              else ""));
               Pres.Report (Screen, Status);
               return;
            end if;
            declare
               Line    : constant String := To_String (Found);
               Setting : constant String := Line (Line'First .. Ada.Strings.Fixed.Index (Line, " = ") - 1);
            begin
               Nt.Govern (Store, Change, Kind, Word (2), Setting, "", "", Status);
               Settle (Store, Change, Status, Screen, "", Word (2));
               if E.Is_Ok (Status) then
                  Say_Ruling_Gone (Word (2), Line);
               end if;
            end;
         end;

      elsif Action = "govern" then
         Needs (4, "what it governs and its ruling: " & Word_Of_Command (Kind) & " govern "
                   & (if Word (2) = "" then "ID" else Word (2)) & " SETTING RULING, as scalar.work.isolation project");
         --  A setting there is: one the configuration holds, one the
         --  harness reads, or a baseline; another is refused with the
         --  nearest there are.
         if E.Is_Ok (Status) then
            declare
               Config  : Model_Runner.Framework.Records.Item;
               Read    : E.Error_Info;
               Near    : Unbounded_String;

               --  A name without its kind, as reconfigure takes it: the one
               --  setting of that name there is, whole.
               function Whole_Name return String is
                  Found : Unbounded_String;
                  Count : Natural := 0;
               begin
                  if Model_Runner.Framework.Records.Has (Config, Word (3))
                    or else Model_Runner.Framework.Configurations.Known_Names.Contains (Word (3))
                  then
                     return Word (3);
                  end if;
                  for Prefix of Names.Vector'(["scalar.", "set.", "list.", "map."]) loop
                     if Model_Runner.Framework.Records.Has (Config, Prefix & Word (3))
                       or else Model_Runner.Framework.Configurations.Known_Names.Contains
                                 (Prefix & Word (3))
                       --  A level or capability of it, as /config takes it:
                       --  permission.project.use_network.
                       or else (Prefix = "map."
                                and then Ada.Strings.Fixed.Index (Word (3), "permission.") = Word (3)'First)
                       --  A kind's own limit, as /reconfigure takes it: task.max_steps.test.
                       or else (Prefix = "scalar."
                                and then (for some Limit of Names.Vector'
                                            (["task.max_seconds.", "task.max_steps.", "task.max_tool_calls.",
                                              "task.token_budget."]) =>
                                            Ada.Strings.Fixed.Index (Word (3), Limit) = Word (3)'First))
                     then
                        Found := To_Unbounded_String (Prefix & Word (3));
                        Count := Count + 1;
                     end if;
                  end loop;
                  return (if Count = 1 then To_String (Found) else Word (3));
               end Whole_Name;
            begin
               Model_Runner.Framework.Configurations.Read (Store, Config, Read);
               declare
                  Setting : constant String := Whole_Name;
               begin
                  if not Model_Runner.Framework.Records.Has (Config, Setting)
                    and then not Model_Runner.Framework.Configurations.Known_Names.Contains (Setting)
                    and then Ada.Strings.Fixed.Index (Setting, "baseline.") /= 1
                    --  A limit for a kind of task the project has is one
                    --  whether set or not, as reconfigure takes it.
                    and then not (for some Prefix of Names.Vector'
                                    (["scalar.task.max_steps.", "scalar.task.token_budget.",
                                      "scalar.task.max_tool_calls.", "scalar.task.max_seconds."]) =>
                                    Ada.Strings.Fixed.Index (Setting, Prefix) = 1
                                    and then Model_Runner.Framework.Tasks.Kinds (Store).Contains
                                               (Setting (Setting'First + Prefix'Length .. Setting'Last)))
                    --  A level's capability is one whether set or not.
                    and then not (Ada.Strings.Fixed.Index (Setting, "map.permission.") = 1
                                  and then (for some One in Model_Runner.Framework.Permissions.Capability =>
                                              Ada.Strings.Fixed.Tail
                                                (Setting, Model_Runner.Framework.Permissions.Word (One)'Length + 1)
                                              = "." & Model_Runner.Framework.Permissions.Word (One)))
                  then
                     --  The one most like it, by its letters, of those there are.
                     declare
                        Among : Names.Vector := Model_Runner.Framework.Configurations.Known_Names;
                     begin
                        for Index in 1 .. Model_Runner.Framework.Records.Field_Count (Config) loop
                           if not Among.Contains (Model_Runner.Framework.Records.Field_Name (Config, Index)) then
                              Among.Append (Model_Runner.Framework.Records.Field_Name (Config, Index));
                           end if;
                        end loop;
                        Near := To_Unbounded_String (Model_Runner.Framework.Nearest (Setting, Among));
                        if Near = Null_Unbounded_String then
                           Near := To_Unbounded_String (Model_Runner.Framework.Nearest ("scalar." & Setting, Among));
                        end if;
                     end;
                     Status := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Status, "name", "the setting a decision governs");
                     E.Add_Text (Status, "value", Setting);
                     E.Add_Text (Status, "detail",
                                 (if (for some One in Model_Runner.Framework.Permissions.Capability =>
                                        Model_Runner.Framework.Permissions.Word (One) = Setting)
                                  then "a capability is ruled at its level: map.permission.project." & Setting
                                       & " for the project, map.permission.kind.KIND." & Setting & " for a kind"
                                  else "no setting is called so; a decision governs one /config shows"
                                       & (if Near = Null_Unbounded_String then ""
                                          else "; did you mean " & To_String (Near) & "?")));
                  elsif Model_Runner.Framework.Records.Has (Config, Setting)
                    or else Model_Runner.Framework.Configurations.Known_Names.Contains (Setting)
                    or else Ada.Strings.Fixed.Index (Setting, "scalar.task.") = 1
                  then
                     --  A ruling is a value the setting takes: held to what a
                     --  change to it would be held to, and nothing is changed.
                     declare
                        One     : Model_Runner.Framework.Configurations.Value_Maps.Map;
                        Planned : Model_Runner.Framework.Configurations.Change_Plan;
                        Checked : E.Error_Info;
                     begin
                        One.Include (Setting, From (4));
                        Model_Runner.Framework.Configurations.Plan_Change (Store, One, Planned, Checked);
                        if E.Is_Error (Checked) and then E.Text_Of (Checked, "detail") /= ""
                          and then E."/=" (Checked.Code, E.Framework_Revision_Conflict)
                        then
                           Status := E.Make (E.Framework_Input_Invalid);
                           E.Add_Text (Status, "name", "a ruling on " & Setting);
                           E.Add_Text (Status, "value", From (4));
                           E.Add_Text (Status, "detail", E.Text_Of (Checked, "detail"));
                        end if;
                     end;
                  end if;
                  Governed_Setting := To_Unbounded_String (Setting);
               end;
            end;
         end if;
         --  Governing so already: said, and not revised again.
         if E.Is_Ok (Status)
           and then Nt.Governs (Store, Kind, Word (2))
                      = To_String (Governed_Setting) & " = " & From (4)
                        & (if Given ("overrides") = "" then "" else " (over " & Given ("overrides") & ")")
         then
            Pres.Put_Note (Screen, "cli.intent.already_governs",
                           [Loc.Named ("name", Word (2)),
                            Loc.Named ("value", Nt.Governs (Store, Kind, Word (2)))]);
            return;
         end if;
         --  What it says it holds over is CONFIG or an entry there is and
         --  stands: anything else is refused, not stored to override nothing.
         if E.Is_Ok (Status) then
            declare
               Said  : constant String := Given ("overrides");
               Start : Natural := Said'First;
            begin
               for Index in Said'First .. Said'Last + 1 loop
                  if Index > Said'Last or else Said (Index) in ',' | ' ' then
                     declare
                        Other : constant String := Said (Start .. Index - 1);
                        State : constant String :=
                          (if Other = "" or else Other = "CONFIG" then "accepted"
                           elsif Nt.State_Of (Store, Nt.Decision, Other) /= ""
                           then Nt.State_Of (Store, Nt.Decision, Other)
                           elsif Nt.State_Of (Store, Nt.Specification, Other) /= ""
                           then Nt.State_Of (Store, Nt.Specification, Other)
                           else Nt.State_Of (Store, Nt.Requirement, Other));
                     begin
                        if E.Is_Ok (Status) and then State = "" then
                           Status := E.Make (E.Framework_Input_Invalid);
                           E.Add_Text (Status, "name", "what it overrides");
                           E.Add_Text (Status, "value", Other);
                           E.Add_Text (Status, "detail", "it is CONFIG, or an entry the project holds"
                                       & " -- DEC-001, SPEC-002");
                        elsif E.Is_Ok (Status) and then State in "obsolete" | "superseded" | "rejected" then
                           Status := E.Make (E.Framework_Input_Invalid);
                           E.Add_Text (Status, "name", "what it overrides");
                           E.Add_Text (Status, "value", Other);
                           E.Add_Text (Status, "detail", Other & " is " & State & ", and overrides nothing now");
                        end if;
                     end;
                     Start := Index + 1;
                  end if;
               end loop;
            end;
         end if;
         if E.Is_Ok (Status) then
            declare
               --  The ruling it had on the setting, which this one replaces.
               Before : constant String := Nt.Governs (Store, Kind, Word (2));
               Prefix : constant String := To_String (Governed_Setting) & " = ";
            begin
               Nt.Govern (Store, Change, Kind, Word (2), To_String (Governed_Setting), From (4), Given ("overrides"),
                          Status);
               Settle (Store, Change, Status, Screen, "", Word (2));
               if E.Is_Ok (Status) and then Ada.Strings.Fixed.Index (Before, Prefix) = Before'First
                 and then Before'Length > Prefix'Length
                 --  The same ruling, now over another source: said as that.
                 and then Before (Before'First + Prefix'Length
                                  .. (if Ada.Strings.Fixed.Index (Before, " (over ") > 0
                                      then Ada.Strings.Fixed.Index (Before, " (over ") - 1 else Before'Last))
                          = From (4)
               then
                  if Given ("overrides") /= "" then
                     Pres.Put_Note (Screen, "cli.intent.ruling_now_over",
                                    [Loc.Named ("name", Word (2)), Loc.Named ("value", From (4)),
                                     Loc.Named ("other", Given ("overrides"))]);
                  end if;
               elsif E.Is_Ok (Status) and then Ada.Strings.Fixed.Index (Before, Prefix) = Before'First
                 and then Before'Length > Prefix'Length
               then
                  Pres.Put_Note (Screen, "cli.intent.ruling_replaced",
                                 [Loc.Named ("name", Word (2)),
                                  Loc.Named ("value", Before (Before'First + Prefix'Length .. Before'Last))]);
               end if;
            end;
            if E.Is_Ok (Status) then
               --  Only an accepted one governs; one waiting will once it is.
               Pres.Put_Message (Screen, (if Nt.State_Of (Store, Kind, Word (2)) = "accepted"
                                          then "cli.intent.governs" else "cli.intent.governs_later"),
                                 [Loc.Named ("name", Word (2)),
                                  Loc.Named ("value", Nt.Governs (Store, Kind, Word (2))),
                                  Loc.Named ("other", Word_Of_Command (Kind))]);
               --  Written into the configuration as well: said so.
               Apply_Rulings (Store, Kind, Word (2), Screen, Said => True);
               --  What else it rules on stays: said, so nothing seems lost.
               for Other of Nt.Also_Governs (Store, Kind, Word (2)) loop
                  Pres.Put_Message (Screen, "cli.intent.governs_still",
                                    [Loc.Named ("name", Word (2)), Loc.Named ("value", Other)]);
               end loop;
            end if;

            --  What it now stands against -- the configuration, another
            --  decision -- said at once, with how to settle it.
            if E.Is_Ok (Status) then
               declare
                  package Cs renames Model_Runner.Framework.Consistency;
                  Found : constant Cs.Finding_List := Cs.Check (Store);
               begin
                  --  Said once: a disagreement with the configuration is
                  --  said by the ruling's own note above, not again here.
                  for Index in 1 .. Cs.Length (Found) loop
                     if To_String (Cs.Element (Found, Index).Subject) = To_String (Governed_Setting)
                       and then Ada.Strings.Fixed.Index (To_String (Cs.Element (Found, Index).Detail),
                                                         "CONFIG says") = 0
                     then
                        Pres.Put_Note (Screen, "cli.intent.also_found",
                                       [Loc.Named ("detail", To_String (Cs.Element (Found, Index).Detail))]);
                     end if;
                  end loop;
               end;
            end if;

         end if;

      else
         --  An identifier -- or show and one: what it is.
         if Action = "show" then
            Needs (2, "the " & Word_Of (Kind));
            --  How it is written, as /task show says it.
            if E.Is_Error (Status) then
               Pres.Report (Screen, Status);
               Pres.Put_Note (Screen, "cli.task.usage_line",
                              [Loc.Named ("value", Word_Of_Command (Kind) & " show "
                                                   & (if Nt."=" (Kind, Nt.Requirement) then "REQ"
                                                      elsif Nt."=" (Kind, Nt.Decision) then "DEC" else "SPEC")
                                                   & "-ID, as " & Word_Of_Command (Kind) & " show 1 -- "
                                                   & Word_Of_Command (Kind) & " lists them")]);
               return;
            end if;
         end if;
         --  A word that is no identifier: an action there is not.
         if E.Is_Ok (Status) and then Action /= "show"
           and then Ada.Strings.Fixed.Index (Word (1), "-") = 0
         then
            Status := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Status, "value", Word (1)
                        & (if Model_Runner.Framework.Nearest
                                (Word (1), Names.Vector'(["list", "new", "accept", "reject", "reconsider",
                                                          "obsolete", "revise", "move", "link", "unlink",
                                                          "supersede", "verify", "block", "unblock", "govern",
                                                          "show"])) /= ""
                           then " (did you mean "
                                & Model_Runner.Framework.Nearest
                                    (Word (1), Names.Vector'(["list", "new", "accept", "reject", "reconsider",
                                                              "obsolete", "revise", "move", "link", "unlink",
                                                              "supersede", "verify", "block", "unblock", "govern",
                                                              "show"]))
                                & "?)"
                           else "")
                        & "; " & Word_Of_Command (Kind) & " takes list, new,"
                        & " accept, reject, reconsider, obsolete, revise, move, link, unlink, supersede"
                        & (if Nt."=" (Kind, Nt.Requirement) then ", verify, block, unblock" else "")
                        & (if Nt."=" (Kind, Nt.Decision) then ", govern" else "")
                        & ", or an identifier to show");
         end if;
         --  What follows the identifier is nothing it does: refused, not
         --  ignored, as a command after it -- req ID unlink -- would be.
         if E.Is_Ok (Status)
           and then Natural (Plain.Length) > (if Action = "show" then 2 else 1)
         then
            Status := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Status, "value", Word ((if Action = "show" then 3 else 2))
                        & "; the command comes first, as " & Word_Of_Command (Kind) & " "
                        & Word ((if Action = "show" then 3 else 2)) & " "
                        & Word ((if Action = "show" then 2 else 1)) & " ...");
         end if;
         declare
            Held  : Nt.Entity;
            Named : constant String := (if Action = "show" then Word (2) else Word (1));
         begin
            if E.Is_Ok (Status) then
               Nt.Read (Store, Kind, Named, Held, Status);
               --  None such: said, with where the ones there are are listed.
               if E."=" (Status.Code, E.Framework_Not_Found) then
                  Pres.Report (Screen, Status);
                  Pres.Put_Note (Screen, "cli.intent.list_hint",
                                 [Loc.Named ("name", Word_Of_Command (Kind))]);
                  return;
               end if;
            end if;
            if E.Is_Ok (Status) then
               --  It, by its identifier and title, set apart; then its
               --  fields in groups, each under its title, as /task show has
               --  them: what it says, where it stands, its work and its
               --  evidence, what it governs, and where it came from.
               Pres.Put_Header (Screen, "cli.task.heading",
                                [Loc.Named ("name", Named), Loc.Named ("value", To_String (Held.Title))]);
               declare
                  Is_Requirement : constant Boolean := Nt."=" (Kind, Nt.Requirement);
                  Retired        : constant Boolean :=
                    To_String (Held.State) in "obsolete" | "superseded" | "rejected";
                  Why            : constant String :=
                    (if Is_Requirement
                     then Model_Runner.Framework.Verification.Why_Not_Verified (Store, Named) else "");
                  Serving        : Unbounded_String;
                  Verified_By    : Unbounded_String;

                  procedure Item (Name, Value : String; Value_Tone : Pres.Tone := Pres.Plain) is
                  begin
                     Pres.Put_Pair (Screen, "cli.task.field", Name, Value, Value_Tone, Indent => 2);
                  end Item;
               begin
                  --  A requirement's work and what verified it, gathered first.
                  if Is_Requirement then
                     declare
                        Raw : Model_Runner.Framework.Records.Item;
                        Got : E.Error_Info;
                     begin
                        for Id of Model_Runner.Framework.Tasks.List (Store) loop
                           declare
                              Defined : Model_Runner.Framework.Records.Item;
                           begin
                              Model_Runner.Framework.Tasks.Definition (Store, Id, Defined, Got);
                              if E.Is_Ok (Got)
                                and then Model_Runner.Framework.Lines_Of
                                           (Model_Runner.Framework.Records.Get (Defined, "requirements"))
                                           .Contains (Named)
                              then
                                 Append (Serving, (if Serving = Null_Unbounded_String then "" else ", ")
                                         & Id & " (" & Model_Runner.Framework.Tasks.State_Of (Store, Id) & ")");
                              end if;
                           end;
                        end loop;
                        S.Read (Store, Model_Runner.Framework.Requirements_Area, Named, Raw, Got);
                        if E.Is_Ok (Got) then
                           Verified_By := To_Unbounded_String
                             (Model_Runner.Framework.Records.Get (Raw, "verified_by"));
                        end if;
                     end;
                  end if;

                  Pres.Put_Section (Screen, "cli.intent.section.says");
                  Item ("text", To_String (Held.Text));
                  if Length (Held.Criteria) > 0 then
                     Item ("criteria", To_String (Held.Criteria));
                  end if;
                  --  Its document read now, where it came from one: what it
                  --  says there, where that is not what is held.
                  declare
                     Path : constant String :=
                       Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)),
                                        To_String (Held.Source));
                     Text : Unbounded_String;
                     File : Ada.Text_IO.File_Type;
                     Said_Now : Unbounded_String;
                     --  Whether its document says it at all now.
                     Still_Said : Boolean := False;
                  begin
                     if Length (Held.Provenance) > 0 and then To_String (Held.Source) not in "" | "user"
                       and then Ada.Directories.Exists (Path)
                     then
                        Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
                        while not Ada.Text_IO.End_Of_File (File) loop
                           Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
                        end loop;
                        Ada.Text_IO.Close (File);
                        declare
                           Found : constant Model_Runner.Framework.Bootstrap.Output_List :=
                             Model_Runner.Framework.Bootstrap.Scan (To_String (Held.Source), To_String (Text));
                        begin
                           for Index in 1 .. Model_Runner.Framework.Bootstrap.Length (Found) loop
                              declare
                                 One : constant Model_Runner.Framework.Bootstrap.Output :=
                                   Model_Runner.Framework.Bootstrap.Element (Found, Index);
                              begin
                                 if One.Provenance = Held.Provenance then
                                    Still_Said := True;
                                 end if;
                                 if One.Provenance = Held.Provenance and then One.Text /= Held.Text then
                                    Said_Now := One.Text;
                                 end if;
                              end;
                           end loop;
                           --  A document that is one decision or specification
                           --  whole -- an ADR -- is known by its words, which
                           --  changed: the one of its kind it holds now.
                           if Said_Now = Null_Unbounded_String and then Kind in Nt.Decision | Nt.Specification then
                              declare
                                 package Bs renames Model_Runner.Framework.Bootstrap;
                                 Wanted : constant Bs.Output_Kind :=
                                   (if Nt."=" (Kind, Nt.Decision) then Bs.Decision_Candidate
                                    else Bs.Specification_Candidate);
                                 Count  : Natural := 0;
                                 Last   : Unbounded_String;
                              begin
                                 for Index in 1 .. Bs.Length (Found) loop
                                    if Bs."=" (Bs.Element (Found, Index).Kind, Wanted) then
                                       Count := Count + 1;
                                       Last := Bs.Element (Found, Index).Text;
                                    end if;
                                 end loop;
                                 if Count = 1 and then Last /= Held.Text then
                                    Said_Now := Last;
                                 end if;
                              end;
                           end if;
                        end;
                        if Said_Now /= Null_Unbounded_String then
                           Item ("its document says", To_String (Said_Now) & " -- " & Word_Of_Command (Kind)
                                 & " revise " & Named & " from-document takes it", Pres.Pending);
                        --  Read now, nothing of it there: said, with the way on.
                        elsif not Still_Said and then Nt."=" (Kind, Nt.Requirement)
                          and then To_String (Held.State) not in "obsolete" | "superseded" | "rejected"
                        then
                           Item ("its document", "no longer says it -- " & Word_Of_Command (Kind) & " obsolete "
                                 & Named & " retires it", Pres.Pending);
                        end if;
                     end if;
                     --  Not read here, as bootstrap found it otherwise: said.
                     if Said_Now = Null_Unbounded_String then
                        --  Its document saying otherwise now, as bootstrap found:
                        --  said here, with the step that takes the document's words.
                        for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
                           declare
                              package Rs renames Model_Runner.Framework.Results;
                              Result_Id : constant String :=
                                (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                                 then Name (Name'First .. Name'Last - 4) else Name);
                              One : Rs.Result;
                              Got : E.Error_Info;
                           begin
                              Rs.Read (Store, Result_Id, One, Got);
                              if E.Is_Ok (Got)
                                and then Ada.Strings.Unbounded.Index
                                           (One.Summary, " now says what " & Named & " does not") > 0
                                and then One.Payload /= Held.Text
                              then
                                 Item ("its document now says",
                                       To_String (One.Payload) & " -- " & Word_Of_Command (Kind) & " revise " & Named
                                       & " from-document takes it", Pres.Pending);
                                 exit;
                              end if;
                           end;
                        end loop;
                     end if;
                  exception
                     when others =>
                        if Ada.Text_IO.Is_Open (File) then
                           Ada.Text_IO.Close (File);
                        end if;
                  end;

                  --  How it stands, coloured by that: an accepted decision
                  --  or specification governs, an accepted requirement waits.
                  Pres.Put_Section (Screen, "cli.task.section.stands");
                  Item ("state", (if Length (Held.Superseded_By) > 0
                                  then "superseded by " & To_String (Held.Superseded_By)
                                       & " (" & To_String (Held.State) & ")"
                                  elsif Is_Requirement and then To_String (Held.State) = "accepted"
                                  then "accepted, not verified"
                                  else To_String (Held.State)),
                        (if Length (Held.Superseded_By) > 0 then Pres.Bad
                         elsif To_String (Held.State) = "accepted" and then not Is_Requirement
                         then Pres.Good
                         else Pres.Tone_Of (To_String (Held.State))));
                  --  How often its record changed: its moves count, its
                  --  words being what /req revise changes.
                  Item ("record changes", Ada.Strings.Fixed.Trim (Natural'Image (Held.Revision), Ada.Strings.Both)
                        & " (each revise and each move between states)");
                  Item ("scope", To_String (Held.Scope));
                  if Nt.Blocked_Because (Store, Kind, Named) /= "" then
                     Item ("blocked because", Nt.Blocked_Because (Store, Kind, Named), Pres.Bad);
                  end if;
                  --  Who decided it, as /task show has it; and for one
                  --  undecided, how it comes to count.
                  if To_String (Held.State) = "rejected" and then Nt.Moved_By (Store, Kind, Named, "rejected") /= ""
                  then
                     Item ("rejected by", Nt.Moved_By (Store, Kind, Named, "rejected"));
                  elsif Nt.Moved_By (Store, Kind, Named, "accepted") /= "" then
                     Item ("accepted by", Nt.Moved_By (Store, Kind, Named, "accepted"));
                  end if;
                  if To_String (Held.State) = Nt.First_State (Kind) then
                     Item ("to start", "it is a candidate: " & Word_Of_Command (Kind) & " accept " & Named
                                       & " accepts it first", Pres.Pending);
                  end if;

                  --  Its work, and what shows it done.
                  if Is_Requirement then
                     Pres.Put_Section (Screen, "cli.intent.section.work");
                     Item ("served by", (if Serving = Null_Unbounded_String then "no task yet"
                                         else To_String (Serving)));
                     --  Verified by it only while it is verified; evidence
                     --  taken before is said as that.
                     for Relation in Nt.Implementation .. Nt.Test loop
                        if Relation in Nt.Implementation | Nt.Test then
                           for Target of Nt.Links (Store, Kind, Named, Relation) loop
                              if Ada.Strings.Fixed.Index (Target, "/") > 0
                                and then Ada.Strings.Fixed.Index (Target, ":") = 0
                                and then not Ada.Directories.Exists
                                               (Hostkit.Fs.Join
                                                  (Ada.Directories.Containing_Directory (S.Root (Store)), Target))
                              then
                                 Item (Relation_Said (Relation),
                                       Target & " (missing: the repository does not hold it)", Pres.Bad);
                              else
                                 Item (Relation_Said (Relation), Target);
                              end if;
                           end loop;
                        end if;
                     end loop;
                     if Verified_By /= Null_Unbounded_String then
                        Item ((if To_String (Held.State) = "verified" then "verified by" else "evidence taken"),
                              To_String (Verified_By));
                     end if;
                     --  Recorded verified, where its evidence no longer holds.
                     if To_String (Held.State) = "verified" and then Why /= "" then
                        Item ("no longer holds", Why, Pres.Bad);
                     end if;
                     --  Not verified yet: what it still lacks, and what supplies it.
                     if To_String (Held.State) in "accepted" | "implemented" then
                        Item ("not verified",
                              (if Why /= "" then Why
                               else "its evidence holds; check " & Named & " records it verified"),
                              Pres.Pending);
                     end if;
                  end if;

                  --  What it rules on, where it rules on anything.
                  if Nt.Governs (Store, Kind, Named) /= "" or else not Nt.Also_Governs (Store, Kind, Named).Is_Empty
                  then
                     Pres.Put_Section (Screen, "cli.intent.section.governs");
                     if Nt.Governs (Store, Kind, Named) /= "" then
                        Item ((if Retired then "governed" else "governs"), Nt.Governs (Store, Kind, Named));
                     end if;
                     for Other of Nt.Also_Governs (Store, Kind, Named) loop
                        Item ((if Retired then "governed" else "governs"), Other);
                     end loop;
                  end if;

                  --  Where it came from, what it replaced, what it is tied to.
                  Pres.Put_Section (Screen, "cli.intent.section.origin");
                  --  A document no longer there: marked, as a missing link is.
                  if Length (Held.Source) > 0 and then To_String (Held.Source) /= "user"
                    and then Ada.Strings.Fixed.Index (To_String (Held.Source), ":") = 0
                    and then not Ada.Directories.Exists
                                   (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)),
                                                     To_String (Held.Source)))
                  then
                     declare
                        Became : constant String :=
                          Model_Runner.Framework.Git.Renamed_In_History
                            (Ada.Directories.Containing_Directory (S.Root (Store)), To_String (Held.Source));
                     begin
                        Item ("source", To_String (Held.Source)
                              & (if Became /= ""
                                 then " (moved: git shows it renamed to " & Became & " -- /bootstrap follows it)"
                                 else " (missing: the document is gone -- " & Word_Of_Command (Kind) & " obsolete "
                                      & Named & " retires it)"),
                              Pres.Bad);
                     end;
                  else
                     Item ("source", To_String (Held.Source));
                  end if;
                  if Held.Supersedes /= Null_Unbounded_String then
                     Item ("supersedes", To_String (Held.Supersedes));
                  end if;
                  if Held.Superseded_By /= Null_Unbounded_String then
                     Item ("superseded_by", To_String (Held.Superseded_By));
                  end if;
                  for Relation in Nt.Link_Kind loop
                     --  Its implementation and its tests are its work, said there.
                     if Is_Requirement and then Relation in Nt.Implementation | Nt.Test then
                        goto Next_Relation;
                     end if;
                     for Target of Nt.Links (Store, Kind, Named, Relation) loop
                        --  A file it names that is not there: marked.
                        if Ada.Strings.Fixed.Index (Target, "/") > 0
                          and then Ada.Strings.Fixed.Index (Target, ":") = 0
                          and then Ada.Strings.Fixed.Index (Target, "#") = 0
                          and then not Ada.Directories.Exists
                                         (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)),
                                                           Target))
                        then
                           Item (Relation_Said (Relation),
                                 Target & " (missing: the repository does not hold it)", Pres.Bad);
                        else
                           Item (Relation_Said (Relation), Target);
                        end if;
                     end loop;
                     <<Next_Relation>>
                  end loop;
               end;
            end if;
         end;
      end if;

      if E.Is_Error (Status) and then Pres.Errors_Reported (Screen) = Said_Before then
         Pres.Report (Screen, Status);
      end if;
   end Run;

   -------------
   -- Pending --
   -------------

   function Pending
     (Store : Model_Runner.Framework.Stores.Store)
      return Model_Runner.Framework.Name_Lists.Vector
   is
      Result : Names.Vector;
   begin
      for Kind in Nt.Intent_Kind loop
         for Id of Nt.List (Store, Kind, Nt.First_State (Kind)) loop
            Result.Append (Word_Of (Kind) & ":" & Id);
         end loop;
      end loop;
      return Result;
   end Pending;

   ------------
   -- Decide --
   ------------

   procedure Decide
     (Store     : in out Model_Runner.Framework.Stores.Store;
      Which     : String;
      Accepting : Boolean;
      Screen    : in out Model_Runner.Presentation.Console;
      Say_Next  : Boolean := True)
   is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Which, ":");
      Kind  : Nt.Intent_Kind := Nt.Requirement;
      Words : Names.Vector;
   begin
      for One in Nt.Intent_Kind loop
         if Word_Of (One) = Which (Which'First .. Colon - 1) then
            Kind := One;
         end if;
      end loop;
      Words.Append (if Accepting then "accept" else "reject");
      Words.Append (Which (Colon + 1 .. Which'Last));
      Next_Held := not Say_Next;
      Run (Store, Kind, Words, Screen);
      Next_Held := False;
   exception
      when others =>
         Next_Held := False;
         raise;
   end Decide;

end Model_Runner.CLI.Intents;
