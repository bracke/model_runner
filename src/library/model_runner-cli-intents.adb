with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner.Errors;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
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
      return Stem /= "" and then Text'Length >= Stem'Length
        and then Text (Text'First .. Text'First + Stem'Length - 1) = Stem;
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
   procedure Move_Along
     (Store  : in out S.Store;
      Screen : in out Pres.Console)
   is
      Done   : Model_Runner.Framework.Orchestration.Step_Report;
      Status : E.Error_Info;
   begin
      Model_Runner.Framework.Orchestration.Step (Store, Done, Status);
      if E.Is_Error (Status) then
         Pres.Report (Screen, Status);
         return;
      end if;
      for Id of Done.Derived loop
         Pres.Put_Message (Screen, "cli.task.derived", [Loc.Named ("name", Id)]);
         --  A candidate until someone takes it up.
         if Model_Runner.Framework.Tasks.State_Of (Store, Id) = "candidate" then
            Pres.Put_Note (Screen, "cli.next.accept_task", [Loc.Named ("name", Id)]);
         end if;
      end loop;
      for Id of Done.Became_Ready loop
         Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
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
   begin
      for Part of Words loop
         declare
            Equal : constant Natural := Ada.Strings.Fixed.Index (Part, "=");
         begin
            if Equal > Part'First
              and then (for all C of Part (Part'First .. Equal - 1) =>
                          C in 'a' .. 'z' | 'A' .. 'Z' | '_')
            then
               Settings.Append (Part);
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
            end if;
         end;

      elsif Action = "new" then
         Needs (2, "a title");
         if E.Is_Ok (Status) then
            declare
               Scope : constant String :=
                 (if Given ("scope") = "" then "project" else Given ("scope"));
               Key   : String :=
                 Ada.Characters.Handling.To_Upper (if Scope = "project" then "" else Scope);
               Id    : Unbounded_String;
            begin
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
                       (Screen, "cli.next.accept_intent",
                        [Loc.Named ("name", To_String (Id)),
                         Loc.Named ("value", (case Kind is
                                                when Nt.Requirement   => "req",
                                                when Nt.Specification => "spec",
                                                when Nt.Decision      => "decision"))]);
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
            begin
               if Action = "reconsider" then
                  Granted (Tr.Reconsideration) := True;
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
                     if To_String (Held.Source) = "" or else not Ada.Directories.Exists (Path) then
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
         Needs (4, "unlink ID KIND TARGET, whose KIND is dependency, component,"
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
         Needs (4, "link ID KIND TARGET, whose KIND is dependency, component,"
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
               if not Found then
                  Status := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Status, "name", "the kind of link");
                  E.Add_Text (Status, "value", Word (3));
                  E.Add_Text (Status, "detail", "a link is a dependency, component,"
                              & " implementation, task, test or verification");
               else
                  Nt.Link (Store, Change, Kind, Word (2), Relation, From (4), Status);
               end if;
               Settle (Store, Change, Status, Screen, "cli.intent.linked", Word (2));

               --  What it implements or tests is looked for, and said when
               --  the repository has no such thing.
               if E.Is_Ok (Status) and then Nt."=" (Relation, Nt.Component)
                 and then not Model_Runner.Framework.Tasks.Components (Store).Contains (From (4))
               then
                  Pres.Put_Note
                    (Screen, "cli.intent.link_component",
                     [Loc.Named ("name", From (4)),
                      Loc.Named ("value", Joined_Components (Store))]);
               end if;
               if E.Is_Ok (Status) and then Relation in Nt.Implementation | Nt.Test then
                  declare
                     package Rp renames Model_Runner.Framework.Repository;
                     Now    : constant Rp.Graph := Rp.Now (Store);
                     Target : constant String := From (4);
                     Known  : Boolean := not Rp.Find_Symbols (Now, Target).Is_Empty;
                  begin
                     for Index in 1 .. Rp.File_Count (Now) loop
                        Known := Known or else To_String (Rp.File_At (Now, Index).Path) = Target;
                     end loop;
                     if not Known then
                        Pres.Put_Note (Screen, "cli.intent.link_unknown", [Loc.Named ("name", Target)]);
                     end if;
                  end;
               end if;
            end;
         end if;

      elsif Action = "supersede" then
         Needs (3, "the " & Word_Of (Kind) & " replaced and the one replacing it");
         if E.Is_Ok (Status) then
            declare
               Was : constant String := Nt.State_Of (Store, Kind, Word (3));
            begin
               Nt.Supersede (Store, Change, Kind, Word (2), Word (3), Status);
               Settle (Store, Change, Status, Screen, "cli.intent.superseded", Word (2));

               --  What replaces it stands in its place: a candidate is
               --  accepted by being made its replacement, and said so.
               if E.Is_Ok (Status) and then Was = Nt.First_State (Kind) then
                  Pres.Put_Message
                    (Screen, "cli.intent.moved",
                     [Loc.Named ("name", Word (3)), Loc.Named ("other", Was),
                      Loc.Named ("value", Nt.State_Of (Store, Kind, Word (3)))]);
               end if;
            end;
         end if;

      elsif Action = "govern" then
         Needs (4, "the " & Word_Of (Kind) & ", the setting it governs, and its ruling");
         --  A setting there is: one the configuration holds, one the
         --  harness reads, or a baseline; another is refused with the
         --  nearest there are.
         if E.Is_Ok (Status) then
            declare
               Setting : constant String := Word (3);
               Config  : Model_Runner.Framework.Records.Item;
               Read    : E.Error_Info;
               Near    : Unbounded_String;
            begin
               Model_Runner.Framework.Configurations.Read (Store, Config, Read);
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
                  E.Add_Text (Status, "detail",
                              "no setting is called so; a decision governs one config shows"
                              & (if Near = Null_Unbounded_String then ""
                                 else ", as " & To_String (Near)));
               end if;
            end;
         end if;
         if E.Is_Ok (Status) then
            Nt.Govern (Store, Change, Kind, Word (2), Word (3), From (4), Given ("overrides"),
                       Status);
            Settle (Store, Change, Status, Screen, "cli.task.revised", Word (2));
         end if;

      else
         --  An identifier -- or show and one: what it is.
         if Action = "show" then
            Needs (2, "the " & Word_Of (Kind));
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
                  Field ("governs", Nt.Governs (Store, Kind, Named));
               end if;

               --  Not verified yet: what it still lacks, and what supplies it.
               if Nt."=" (Kind, Nt.Requirement)
                 and then To_String (Held.State) in "accepted" | "implemented"
               then
                  Field ("not verified", Model_Runner.Framework.Verification.Why_Not_Verified
                                           (Store, Named));
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
      Screen    : in out Model_Runner.Presentation.Console)
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
      Run (Store, Kind, Words, Screen);
   end Decide;

end Model_Runner.CLI.Intents;
