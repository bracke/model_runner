with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner.Errors;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Repository;
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
                 and then Text (Text'First .. Text'First + Stem'Length - 1) = Stem);
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
                 (Screen, "cli.next.task_left",
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
               return Pair (Pair'First + Name'Length + 1 .. Pair'Last);
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

      procedure Field (Name, Value : String) is
      begin
         Pres.Put_Message (Screen, "cli.task.field",
                           [Loc.Named ("name", Name), Loc.Named ("value", Value)]);
      end Field;

      procedure Needs (Count : Positive; What : String) is
      begin
         if Natural (Plain.Length) < Count then
            Status := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Status, "name", What);
         end if;
      end Needs;

      --  What was asked, read once the words are split.
      function Action return String is (Lower (Word (1)));

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
            end if;
            for Id of Named loop
               declare
                  One : Names.Vector;
               begin
                  One.Append (Word (1));
                  One.Append (Id);
                  Run (Store, Kind, One, Screen);
               end;
            end loop;
         end;
         return;
      end if;

      if Action = "" or else Action = "list" then
         declare
            Held : Nt.Entity;
            Read : E.Error_Info;
         begin
            for Id of Nt.List (Store, Kind, Given ("state")) loop
               Nt.Read (Store, Kind, Id, Held, Read);
               Pres.Put_Message
                 (Screen, "cli.task.item",
                  [Loc.Named ("name", Id), Loc.Named ("value", To_String (Held.State)),
                   Loc.Named ("detail", To_String (Held.Title))]);
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
                  E.Add_Text (Status, "detail", "a scope is project or one of the project's components ("
                              & Joined_Components (Store) & "); /reconfigure map.component." & Scope
                              & "=roots=DIR makes it one");
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
               if Next in "accepted" | "rejected"
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
                  Pres.Put_Note (Screen, "cli.intent.already", [Loc.Named ("name", Word (2)),
                                                                Loc.Named ("value", Next)]);
                  return;
               end if;
               Nt.Move (Store, Change, Kind, Word (2), Next, Granted, Status, Actor => Tr.User);
               if E.Is_Ok (Status) then
                  S.Commit (Store, Change, Status);
               end if;
               if E.Is_Error (Status) then
                  Pres.Report (Screen, Status);
                  return;
               end if;
               Pres.Put_Message
                 (Screen, "cli.task.moved", [Loc.Named ("name", Word (2)), Loc.Named ("value", Next)]);
               Move_Along (Store, Screen);

               --  What it governed is governed no more: said, with what the
               --  setting is now.
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
                        if Other /= Word (2)
                          and then (Ada.Strings.Fixed.Index
                                      (Nt.Governs (Store, Nt.Decision, Other), Setting & " = ") = 1
                                    or else (for some Line of Nt.Also_Governs (Store, Nt.Decision, Other) =>
                                               Ada.Strings.Fixed.Index (Line, Setting & " = ") = 1))
                        then
                           Pres.Put_Note
                             (Screen, "cli.intent.ruling_passed",
                              [Loc.Named ("name", Word (2)), Loc.Named ("value", Governed),
                               Loc.Named ("other", Other),
                               Loc.Named ("detail", Nt.Governs (Store, Nt.Decision, Other))]);
                           goto Ruling_Said;
                        end if;
                     end loop;
                     Pres.Put_Note
                       (Screen, "cli.intent.ruling_gone",
                        [Loc.Named ("name", Word (2)), Loc.Named ("value", Governed),
                         Loc.Named ("detail",
                                    Setting & " = "
                                    & (if Model_Runner.Framework.Records.Get (Config, Setting) = ""
                                       then "(its default)"
                                       else Model_Runner.Framework.Records.Get (Config, Setting)))]);
                     <<Ruling_Said>>
                  end;
               end if;

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
               Pres.Put_Message
                 (Screen, "cli.task.verified",
                  [Loc.Named ("name", To_String (Evidence)),
                   Loc.Named ("value", (if Passed then "passed" else "failed")),
                   Loc.Named ("count", "1"), Loc.Named ("total", "0")]);
               --  Passed, and still not verified: why, not silence.
               if Nt.State_Of (Store, Kind, Word (2)) /= "verified" then
                  Pres.Put_Message
                    (Screen, "cli.check.passed_not_verified",
                     [Loc.Named ("name", Word (2)),
                      Loc.Named ("detail", Vf.Why_Not_Verified (Store, Word (2)))]);
               end if;
               for Requirement of Moved loop
                  Pres.Put_Message
                    (Screen, "cli.work.requirement",
                     [Loc.Named ("name", Requirement),
                      Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
               end loop;
            end;
         end if;

      elsif Action = "move" then
         --  To any state the project's lifecycle allows: its own among them.
         Needs (3, "the " & Word_Of (Kind) & " and the state");
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
                        Status := E.Make (E.Framework_Not_Found);
                        E.Add_Text (Status, "name", "the document " & Word (2) & " came from");
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
                           if not Taken then
                              Status := E.Make (E.Framework_Not_Found);
                              E.Add_Text
                                (Status, "name",
                                 "what " & Word (2) & " says, in " & To_String (Held.Source)
                                 & " (it no longer says it where it did; revise it with text=...)");
                           end if;
                        end;
                        Settle (Store, Change, Status, Screen, "cli.task.revised", Word (2));
                        return;
                     end if;
                  end;

               --  Something to revise, and something that differs.
               elsif E.Is_Ok (Status)
                 and then Given ("title") = "" and then Given ("text") = ""
                 and then Given ("criteria") = ""
               then
                  Status := E.Make (E.Framework_Input_Missing);
                  E.Add_Text (Status, "name", "what to revise: title=..., text=... or criteria=...");
               elsif E.Is_Ok (Status)
                 and then (Given ("title") = "" or else Given ("title") = To_String (Held.Title))
                 and then (Given ("text") = "" or else Given ("text") = To_String (Held.Text))
                 and then (Given ("criteria") = ""
                           or else Given ("criteria") = To_String (Held.Criteria))
               then
                  Pres.Put_Note (Screen, "cli.intent.unchanged", [Loc.Named ("name", Word (2))]);
                  return;
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
               Settle (Store, Change, Status, Screen, "cli.intent.unlinked", Word (2));
            end;
         end if;

      elsif Action = "link" then
         Needs (4, "link ID RELATION TARGET, whose RELATION is dependency, component,"
                & " implementation, task, test or verification");
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
                  Target : constant String :=
                    (if Found and then Relation in Nt.Implementation | Nt.Test
                       and then Ada.Strings.Fixed.Index (From (4), "/") > 0
                     then Model_Runner.Framework.Repository.Relative_Path
                            (Ada.Directories.Containing_Directory (S.Root (Store)), From (4))
                     else From (4));
               begin
                  if not Found then
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
                 and then Nt.State_Of (Store, Nt.Requirement, From (4)) in "obsolete" | "rejected" | "superseded"
               then
                  Pres.Put_Note
                    (Screen, "cli.intent.link_doubtful",
                     [Loc.Named ("name", Word (2)), Loc.Named ("value", From (4)),
                      Loc.Named ("detail", From (4) & " is " & Nt.State_Of (Store, Nt.Requirement, From (4))
                                           & "; /req unlink " & Word (2) & " dependency " & From (4)
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
                        for Next of Nt.Links (Store, Nt.Requirement, From_Id, Nt.Dependency) loop
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
                                                 & " already, so each waits for the other; /req unlink "
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
                                           & " kept, and /req unlink " & Word (2) & " verification "
                                           & From (4) & " takes it off")]);
               end if;

               --  What it depends on is a requirement there is.
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Dependency)
                 and then Nt.State_Of (Store, Nt.Requirement, From (4)) = ""
               then
                  Pres.Put_Note
                    (Screen, "cli.intent.link_missing",
                     [Loc.Named ("name", From (4)), Loc.Named ("value", Word (2))]);
               end if;
               if E.Is_Ok (Status) and then Relation in Nt.Implementation | Nt.Test then
                  declare
                     package Rp renames Model_Runner.Framework.Repository;
                     Now    : constant Rp.Graph := Rp.Now (Store);
                     Target : constant String :=
                       (if Ada.Strings.Fixed.Index (From (4), "/") > 0
                        then Rp.Relative_Path (Ada.Directories.Containing_Directory (S.Root (Store)), From (4))
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
               Nt.Supersede (Store, Change, Kind, Word (2), Word (3), Status);

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
                  then
                     for Index in 1 .. Model_Runner.Framework.Records.Field_Count (Config) loop
                        declare
                           Name : constant String := Model_Runner.Framework.Records.Field_Name (Config, Index);
                        begin
                           if Setting'Length >= 4
                             and then (Ada.Strings.Fixed.Index (Name, Setting) > 0
                                       or else Ada.Strings.Fixed.Index
                                                 (Name, Setting (Setting'First .. Setting'First + 3))
                                               > 0)
                             and then Length (Near) < 200
                           then
                              Append (Near, (if Near = Null_Unbounded_String then "" else ", ") & Name);
                           end if;
                        end;
                     end loop;
                     Status := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Status, "name", "the setting a decision governs");
                     E.Add_Text (Status, "value", Setting);
                     E.Add_Text (Status, "detail", "no setting is called so; a decision governs one config"
                                 & " shows" & (if Near = Null_Unbounded_String then ""
                                               else ", as " & To_String (Near)));
                  elsif Model_Runner.Framework.Records.Has (Config, Setting)
                    or else Model_Runner.Framework.Configurations.Known_Names.Contains (Setting)
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
         if E.Is_Ok (Status) then
            Nt.Govern (Store, Change, Kind, Word (2), To_String (Governed_Setting), From (4), Given ("overrides"),
                       Status);
            Settle (Store, Change, Status, Screen, "", Word (2));
            if E.Is_Ok (Status) then
               Pres.Put_Message (Screen, "cli.intent.governs",
                                 [Loc.Named ("name", Word (2)),
                                  Loc.Named ("value", Nt.Governs (Store, Kind, Word (2)))]);
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
                  for Index in 1 .. Cs.Length (Found) loop
                     if To_String (Cs.Element (Found, Index).Subject) = To_String (Governed_Setting) then
                        Pres.Put_Message
                          (Screen, "cli.task.item",
                           [Loc.Named ("name", To_String (Governed_Setting)),
                            Loc.Named ("value", Cs.Kind_Word (Cs.Element (Found, Index).Kind)),
                            Loc.Named ("detail", To_String (Cs.Element (Found, Index).Detail))]);
                     end if;
                  end loop;
               end;
            end if;

            --  What it says it holds over, where that is nothing there is.
            if E.Is_Ok (Status) then
               declare
                  Said  : constant String := Given ("overrides");
                  Start : Natural := Said'First;
               begin
                  for Index in Said'First .. Said'Last + 1 loop
                     if Index > Said'Last or else Said (Index) in ',' | ' ' then
                        declare
                           Other : constant String := Said (Start .. Index - 1);
                        begin
                           if Other /= "" and then Other /= "CONFIG"
                             and then Nt.State_Of (Store, Nt.Decision, Other) = ""
                             and then Nt.State_Of (Store, Nt.Specification, Other) = ""
                             and then Nt.State_Of (Store, Nt.Requirement, Other) = ""
                           then
                              Pres.Put_Note (Screen, "cli.intent.overrides_unknown",
                                             [Loc.Named ("name", Other)]);
                           end if;
                        end;
                        Start := Index + 1;
                     end if;
                  end loop;
               end;
            end if;
         end if;

      else
         --  An identifier -- or show and one: what it is.
         if Action = "show" then
            Needs (2, "the " & Word_Of (Kind));
         end if;
         --  A word that is no identifier: an action there is not.
         if E.Is_Ok (Status) and then Action /= "show"
           and then Ada.Strings.Fixed.Index (Word (1), "-") = 0
         then
            Status := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Status, "value", Word (1) & "; " & Word_Of_Command (Kind) & " takes list, new,"
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
            end if;
            if E.Is_Ok (Status) then
               Field ("title", To_String (Held.Title));
               Field ("state", To_String (Held.State));
               Field ("revision", Ada.Strings.Fixed.Trim (Natural'Image (Held.Revision), Ada.Strings.Both));
               Field ("scope", To_String (Held.Scope));
               Field ("text", To_String (Held.Text));
               Field ("criteria", To_String (Held.Criteria));
               if Nt.Governs (Store, Kind, Named) /= "" then
                  Field ((if To_String (Held.State) in "obsolete" | "superseded" | "rejected"
                          then "governed" else "governs"),
                         Nt.Governs (Store, Kind, Named));
               end if;
               --  A requirement's work and what verified it.
               if Nt."=" (Kind, Nt.Requirement) then
                  declare
                     Serving : Unbounded_String;
                     Raw     : Model_Runner.Framework.Records.Item;
                     Got     : E.Error_Info;
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
                     if Serving /= Null_Unbounded_String then
                        Field ("served by", To_String (Serving));
                     end if;
                     S.Read (Store, Model_Runner.Framework.Requirements_Area, Named, Raw, Got);
                     if E.Is_Ok (Got) and then Model_Runner.Framework.Records.Get (Raw, "verified_by") /= ""
                     then
                        Field ("verified by", Model_Runner.Framework.Records.Get (Raw, "verified_by"));
                     end if;
                  end;
               end if;
               for Other of Nt.Also_Governs (Store, Kind, Named) loop
                  Field ((if To_String (Held.State) in "obsolete" | "superseded" | "rejected"
                          then "governed" else "governs"), Other);
               end loop;

               --  Recorded verified, where its evidence no longer holds.
               if Nt."=" (Kind, Nt.Requirement) and then To_String (Held.State) = "verified"
                 and then Model_Runner.Framework.Verification.Why_Not_Verified (Store, Named) /= ""
               then
                  Field ("no longer holds",
                         Model_Runner.Framework.Verification.Why_Not_Verified (Store, Named));
               end if;

               --  Not verified yet: what it still lacks, and what supplies it.
               if Nt."=" (Kind, Nt.Requirement)
                 and then To_String (Held.State) in "accepted" | "implemented"
               then
                  declare
                     Why : constant String :=
                       Model_Runner.Framework.Verification.Why_Not_Verified (Store, Named);
                  begin
                     Field ("not verified",
                            (if Why /= "" then Why
                             else "its evidence holds; check " & Named & " records it verified"));
                  end;
               end if;
               Field ("source", To_String (Held.Source));
               if Held.Supersedes /= Null_Unbounded_String then
                  Field ("supersedes", To_String (Held.Supersedes));
               end if;
               if Held.Superseded_By /= Null_Unbounded_String then
                  Field ("superseded_by", To_String (Held.Superseded_By));
               end if;
               for Relation in Nt.Link_Kind loop
                  for Target of Nt.Links (Store, Kind, Named, Relation) loop
                     Field ("link." & Lower (Nt.Link_Kind'Image (Relation)), Target);
                  end loop;
               end loop;
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
