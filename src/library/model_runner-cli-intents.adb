with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Transitions;
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
      end loop;
      for Id of Done.Became_Ready loop
         Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
      end loop;
   end Move_Along;

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

      elsif Action = "revise" then
         Needs (2, "the " & Word_Of (Kind));
         if E.Is_Ok (Status) then
            declare
               Held   : Nt.Entity;
               Result : Nt.Impact;
            begin
               Nt.Read (Store, Kind, Word (2), Held, Status);
               if E.Is_Ok (Status) then
                  Nt.Revise
                    (Store, Change, Kind, Word (2),
                     (if Given ("title") = "" then To_String (Held.Title) else Given ("title")),
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

      elsif Action = "link" then
         Needs (4, "the " & Word_Of (Kind) & ", what kind of link, and its target");
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
                  Status := E.Make (E.Framework_Schema_Violation);
                  E.Add_Text (Status, "name", Word (3));
                  E.Add_Text (Status, "detail", "a link is a dependency, component,"
                              & " implementation, task, test or verification");
               else
                  Nt.Link (Store, Change, Kind, Word (2), Relation, From (4), Status);
               end if;
               Settle (Store, Change, Status, Screen, "cli.intent.linked", Word (2));
            end;
         end if;

      elsif Action = "supersede" then
         Needs (3, "the " & Word_Of (Kind) & " replaced and the one replacing it");
         if E.Is_Ok (Status) then
            Nt.Supersede (Store, Change, Kind, Word (2), Word (3), Status);
            Settle (Store, Change, Status, Screen, "cli.intent.superseded", Word (2));
         end if;

      elsif Action = "govern" then
         Needs (4, "the " & Word_Of (Kind) & ", the setting it governs, and its ruling");
         if E.Is_Ok (Status) then
            Nt.Govern (Store, Change, Kind, Word (2), Word (3), From (4), Given ("overrides"),
                       Status);
            Settle (Store, Change, Status, Screen, "cli.task.revised", Word (2));
         end if;

      else
         --  An identifier: what it is.
         declare
            Held : Nt.Entity;
         begin
            Nt.Read (Store, Kind, Word (1), Held, Status);
            if E.Is_Ok (Status) then
               Field ("title", To_String (Held.Title));
               Field ("state", To_String (Held.State));
               Field ("revision", Natural'Image (Held.Revision));
               Field ("scope", To_String (Held.Scope));
               Field ("text", To_String (Held.Text));
               Field ("criteria", To_String (Held.Criteria));
               Field ("source", To_String (Held.Source));
               if Held.Supersedes /= Null_Unbounded_String then
                  Field ("supersedes", To_String (Held.Supersedes));
               end if;
               if Held.Superseded_By /= Null_Unbounded_String then
                  Field ("superseded_by", To_String (Held.Superseded_By));
               end if;
               for Relation in Nt.Link_Kind loop
                  for Target of Nt.Links (Store, Kind, Word (1), Relation) loop
                     Field ("link." & Lower (Nt.Link_Kind'Image (Relation)), Target);
                  end loop;
               end loop;
            end if;
         end;
      end if;

      if E.Is_Error (Status) then
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
