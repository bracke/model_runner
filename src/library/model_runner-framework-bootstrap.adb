with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Transitions;

package body Model_Runner.Framework.Bootstrap is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   ------------
   -- Append --
   ------------

   procedure Append (Into : in out Output_List; Item : Output) is
   begin
      Into.Outputs.Append (Item);
   end Append;

   function Length (From : Output_List) return Natural
   is (Natural (From.Outputs.Length));

   function Element (From : Output_List; Index : Positive) return Output
   is (From.Outputs (Index));

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   --  Whether a word stands in a line on its own, in capitals.
   function Has_Word (Line, Word : String) return Boolean is
      At_Word : Natural := Ada.Strings.Fixed.Index (Line, Word);
   begin
      while At_Word > 0 loop
         declare
            After : constant Natural := At_Word + Word'Length;
         begin
            if (At_Word = Line'First
                or else not Ada.Characters.Handling.Is_Letter
                              (Line (At_Word - 1)))
              and then (After > Line'Last
                        or else not Ada.Characters.Handling.Is_Letter
                                      (Line (After)))
            then
               return True;
            end if;
            At_Word := Ada.Strings.Fixed.Index (Line, Word, After);
         end;
      end loop;
      return False;
   end Has_Word;

   --  The key a document's identifiers are given under: its name, in
   --  capitals, as an identifier's word.
   function Key_Of (Path : String) return String is
      Base : constant String :=
        Ada.Characters.Handling.To_Upper
          (Ada.Directories.Base_Name (Ada.Directories.Simple_Name (Path)));
      Word : String := Base;
   begin
      for Char of Word loop
         if Char not in 'A' .. 'Z' | '0' .. '9' then
            Char := '_';
         end if;
      end loop;
      return (if Identifiers.Is_Valid (Word) then Word else "DOC");
   exception
      when others =>
         return "DOC";
   end Key_Of;

   function Headline (Text : String) return String
   is (if Text'Length <= 72 then Text
       else Text (Text'First .. Text'First + 68) & "...");

   ----------
   -- Scan --
   ----------

   function Scan (Path : String; Text : String) return Output_List is
      Result  : Output_List;
      Key     : constant String := Key_Of (Path);
      Seen    : Name_Lists.Vector;
      Titled  : Boolean := False;
      Start   : Natural := Text'First;

      procedure Found (Kind : Output_Kind; Provenance, Title, Body_Text : String)
      is
      begin
         Append
           (Result,
            (Kind       => Kind,
             Provenance => To_Unbounded_String (Provenance),
             Key        => To_Unbounded_String (Key),
             Title      => To_Unbounded_String (Title),
             Text       => To_Unbounded_String (Body_Text),
             Source     => To_Unbounded_String (Path)));
      end Found;

      procedure Line_Of (Raw : String) is
         Line : constant String := Trim (Raw);
         Item : constant String :=
           (if Line'Length > 2 and then Line (Line'First) in '-' | '*'
              and then Line (Line'First + 1) = ' '
            then Trim (Line (Line'First + 2 .. Line'Last)) else Line);
         Colon : constant Natural := Ada.Strings.Fixed.Index (Item, ":");
      begin
         if Item = "" then
            return;
         end if;

         if Item (Item'First) = '#' then
            if not Titled then
               Titled := True;
               Found (Specification_Candidate, Path,
                      Trim (Ada.Strings.Fixed.Trim
                              (Item, Ada.Strings.Maps.To_Set ('#'),
                               Ada.Strings.Maps.Null_Set)),
                      Text);
            end if;
            return;
         end if;

         if Colon > Item'First
           and then Identifiers.Is_Valid (Item (Item'First .. Colon - 1))
           and then Item'Length > 4
           and then Item (Item'First .. Item'First + 3) = "REQ-"
         then
            declare
               Id : constant String := Item (Item'First .. Colon - 1);
               Said : constant String := Trim (Item (Colon + 1 .. Item'Last));
            begin
               Found (Imported_Item, Path & "#" & Id, Id & " " & Headline (Said),
                      Said);
            end;
            return;
         end if;

         if Item'Length > 9 and then Item (Item'First .. Item'First + 8) = "Decision:"
         then
            declare
               Said : constant String := Trim (Item (Item'First + 9 .. Item'Last));
            begin
               Found (Decision_Candidate, Path & "#" & Fingerprint (Said),
                      Headline (Said), Said);
            end;
            return;
         end if;

         if Has_Word (Item, "SHALL") or else Has_Word (Item, "MUST") then
            declare
               Print : constant String := Fingerprint (Item);
            begin
               if Seen.Contains (Print) then
                  Found (Issue, Path & "#twice-" & Print,
                         "stated twice: " & Headline (Item), Item);
               else
                  Seen.Append (Print);
                  Found (Requirement_Candidate, Path & "#" & Print,
                         Headline (Item), Item);
               end if;
            end;
         end if;
      end Line_Of;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            Line_Of (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Scan;

   -----------
   -- Apply --
   -----------

   package Sorting is new Name_Lists.Generic_Sorting;

   --  A setting's items, a line or a comma apart.
   function Items_Of (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Line of Lines_Of (Ada.Strings.Fixed.Translate
                              (Text, Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
      loop
         if Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) /= "" then
            Result.Append (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both));
         end if;
      end loop;
      return Result;
   end Items_Of;

   --  The resolved configuration, or an empty one.
   function Settings_Of (Item : Stores.Store) return Records.Item is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Value, Status);
      return (if E.Is_Ok (Status) then Value else Records.Create ("", 1, "", 0));
   end Settings_Of;

   ---------------
   -- Documents --
   ---------------

   function Documents (Item : Stores.Store) return Name_Lists.Vector is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      Listed  : Name_Lists.Vector :=
        Items_Of (Records.Get (Settings_Of (Item), "set.bootstrap.sources"));
      Result  : Name_Lists.Vector;
   begin
      if Listed.Is_Empty then
         Listed.Append ("*.md");
         Listed.Append ("docs/*.md");
      end if;
      for Entry_Text of Listed loop
         declare
            Given : constant String := Ada.Strings.Fixed.Trim (Entry_Text, Ada.Strings.Both);
            Slash : constant Natural := Ada.Strings.Fixed.Index (Given, "/", Ada.Strings.Backward);
            Dir   : constant String := (if Slash = 0 then "" else Given (Given'First .. Slash - 1));
            Name  : constant String := (if Slash = 0 then Given else Given (Slash + 1 .. Given'Last));
            Where : constant String := (if Dir = "" then Project else Project & "/" & Dir);
         begin
            --  Within the project, and never its state.
            if Given /= "" and then Given (Given'First) not in '/' | '\'
              and then Ada.Strings.Fixed.Index (Given, "..") = 0
              and then Ada.Strings.Fixed.Index (Given, State_Directory) = 0
              and then Ada.Directories.Exists (Where)
            then
               declare
                  Search : Ada.Directories.Search_Type;
                  Found  : Ada.Directories.Directory_Entry_Type;
               begin
                  Ada.Directories.Start_Search
                    (Search, Where, Name, [Ada.Directories.Ordinary_File => True, others => False]);
                  while Ada.Directories.More_Entries (Search) loop
                     Ada.Directories.Get_Next_Entry (Search, Found);
                     declare
                        Path : constant String :=
                          (if Dir = "" then "" else Dir & "/") & Ada.Directories.Simple_Name (Found);
                     begin
                        if not Result.Contains (Path) then
                           Result.Append (Path);
                        end if;
                     end;
                  end loop;
                  Ada.Directories.End_Search (Search);
               exception
                  when others =>
                     null;
               end;
            end if;
         end;
      end loop;
      Sorting.Sort (Result);
      return Result;
   end Documents;

   procedure Apply
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Output_List;
      Result : out Report;
      Status : out Model_Runner.Errors.Error_Info)
   is
      function Field (Text : Unbounded_String) return String
      is (To_String (Text));

      Settings : constant Records.Item := Settings_Of (Item);
      Kinds    : constant Name_Lists.Vector :=
        Items_Of (Records.Get (Settings, "set.bootstrap.propose"));
      Accept_Imports : constant Boolean :=
        Records.Get (Settings, "scalar.bootstrap.import") /= "candidate";

      --  Whether the policy lets bootstrap make outputs of a kind.
      function Made (Kind : Output_Kind) return Boolean
      is (Kinds.Is_Empty
          or else Kinds.Contains
                    (case Kind is
                        when Discovered_Fact         => "facts",
                        when Imported_Item           => "imports",
                        when Requirement_Candidate   => "requirements",
                        when Decision_Candidate      => "decisions",
                        when Specification_Candidate => "specifications",
                        when Issue                   => "issues"));
   begin
      Result := (others => <>);
      Status := E.Success;

      for Next of Found.Outputs loop
         if not Made (Next.Kind) then
            goto Next_Output;
         end if;
         declare
            Provenance : constant String := Field (Next.Provenance);
            Id         : Unbounded_String;

            procedure Propose (Kind : Intent.Intent_Kind) is
            begin
               if Intent.Find_By_Provenance (Item, Kind, Provenance) /= "" then
                  Result.Existing := Result.Existing + 1;
                  return;
               end if;
               Intent.Propose
                 (Item, Change, Kind, Field (Next.Key), Field (Next.Title),
                  Field (Next.Text), "", Field (Next.Source), Provenance,
                  "project", Id, Status);
               if E.Is_Ok (Status) then
                  Result.Created := Result.Created + 1;
               end if;
            end Propose;
         begin
            case Next.Kind is
               when Discovered_Fact =>
                  declare
                     Held : Facts.Fact;
                  begin
                     Facts.Find (Item, Field (Next.Key), Held, Status);
                     if E.Is_Ok (Status) and then Held.Value = Next.Text then
                        Result.Existing := Result.Existing + 1;
                     else
                        Facts.Record_Fact
                          (Item, Change,
                           (Key        => Next.Key,
                            Value      => Next.Text,
                            Source     => Facts.Heuristic,
                            Confidence => Facts.Probable),
                           Status);
                        if E.Is_Ok (Status) then
                           Result.Created := Result.Created + 1;
                        end if;
                     end if;
                  end;

               when Imported_Item =>
                  if Intent.Find_By_Provenance
                       (Item, Intent.Requirement, Provenance) /= ""
                  then
                     --  The same item again: as it was, or what its line
                     --  now says, as its next revision.
                     declare
                        Held    : Intent.Entity;
                        Known   : constant String :=
                          Intent.Find_By_Provenance (Item, Intent.Requirement, Provenance);
                        Effect  : Intent.Impact;
                     begin
                        Intent.Read (Item, Intent.Requirement, Known, Held, Status);
                        if E.Is_Ok (Status) and then Held.Text /= Next.Text then
                           Intent.Revise
                             (Item, Change, Intent.Requirement, Known, Field (Next.Title),
                              Field (Next.Text), To_String (Held.Criteria), Effect, Status);
                           if E.Is_Ok (Status) then
                              Result.Created := Result.Created + 1;
                           end if;
                        else
                           Result.Existing := Result.Existing + 1;
                        end if;
                     end;
                  else
                     --  Under the identifier the document gives it.
                     Intent.Propose
                       (Item, Change, Intent.Requirement, Field (Next.Key),
                        Field (Next.Title), Field (Next.Text), "",
                        Field (Next.Source), Provenance, "project", Id, Status,
                        Given => Provenance (Ada.Strings.Fixed.Index (Provenance, "#") + 1
                                             .. Provenance'Last));
                     if E.Is_Ok (Status) and then Accept_Imports then
                        Intent.Move
                          (Item, Change, Intent.Requirement, To_String (Id),
                           "accepted", Transitions.Ordinary_Only, Status);
                     end if;
                     if E.Is_Ok (Status) then
                        Result.Created := Result.Created + 1;
                     end if;
                  end if;

               when Requirement_Candidate =>
                  Propose (Intent.Requirement);

               when Decision_Candidate =>
                  Propose (Intent.Decision);

               when Specification_Candidate =>
                  Propose (Intent.Specification);

               when Issue =>
                  --  Kept as a diagnostic result, which is named by what it
                  --  says, so the same issue found again is the same result.
                  declare
                     Said : Results.Result :=
                       (Kind       => Results.Diagnostic,
                        Producer   => To_Unbounded_String ("bootstrap"),
                        Summary    => Next.Title,
                        Payload    => Next.Text,
                        Provenance => Next.Provenance,
                        others     => <>);
                  begin
                     Results.Add (Item, Change, Said, Status);
                     Result.Issues := Result.Issues + 1;
                  end;
            end case;

            if E.Is_Error (Status) then
               return;
            end if;
         end;
         <<Next_Output>>
      end loop;
   end Apply;

end Model_Runner.Framework.Bootstrap;
