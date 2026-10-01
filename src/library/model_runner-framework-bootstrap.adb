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

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

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

   --  Whether a line states a requirement: SHALL, MUST or SHOULD in
   --  capitals anywhere; shall in any case; must and should in any case
   --  on a line the document lists -- an item, a numbered item, a table
   --  row -- where prose that merely uses the word is rare.
   function Says_Requirement (Item : String; Listed : Boolean) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Item);
   begin
      return Has_Word (Item, "SHALL") or else Has_Word (Item, "MUST") or else Has_Word (Item, "SHOULD")
        or else Has_Word (Lower, "shall")
        or else (Listed and then (Has_Word (Lower, "must") or else Has_Word (Lower, "should")));
   end Says_Requirement;

   --  A document's own label at the start of a line -- FR-001, [NFR-01],
   --  **R-10**, ADR-2: -- and what follows it. Letters in capitals, a
   --  dash, and a number; bold, brackets or backquotes around it, and a
   --  colon after it, taken off.
   procedure Label_Split
     (Item  : String;
      Label : out Ada.Strings.Unbounded.Unbounded_String;
      Rest  : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Index : Natural := Item'First;

      procedure Skip (Marks : String) is
      begin
         while Index <= Item'Last and then Ada.Strings.Fixed.Index (Marks, [1 => Item (Index)]) > 0 loop
            Index := Index + 1;
         end loop;
      end Skip;

      First_Letter : Natural;
      Dash         : Natural;
      Number_End   : Natural;
   begin
      Label := Null_Unbounded_String;
      Rest := Null_Unbounded_String;
      Skip ("*[`_");
      First_Letter := Index;
      while Index <= Item'Last and then Item (Index) in 'A' .. 'Z' loop
         Index := Index + 1;
      end loop;
      if Index - First_Letter not in 1 .. 8 or else Index > Item'Last or else Item (Index) /= '-' then
         return;
      end if;
      Dash := Index;
      Index := Index + 1;
      while Index <= Item'Last and then Item (Index) in '0' .. '9' | 'A' .. 'Z' | '.' | '-' | '_' loop
         Index := Index + 1;
      end loop;
      Number_End := Index - 1;
      while Number_End > Dash and then Item (Number_End) in '.' | '-' | '_' loop
         Number_End := Number_End - 1;
      end loop;
      if Number_End <= Dash
        or else not (for some C of Item (Dash + 1 .. Number_End) => C in '0' .. '9')
      then
         return;
      end if;
      Index := Number_End + 1;
      Skip ("*]`_:");
      if Index <= Item'Last and then Item (Index) /= ' ' then
         return;
      end if;
      Skip (" :-");
      if Index > Item'Last then
         return;
      end if;
      Label := To_Unbounded_String (Item (First_Letter .. Number_End));
      Rest := To_Unbounded_String (Item (Index .. Item'Last));
   end Label_Split;

   --  The key a document's identifiers are given under: its name, in
   --  capitals, as an identifier's word; a long one by the first letter
   --  of each of its words, and a short word whole.
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
      if Word'Length > 16 then
         declare
            Short : Ada.Strings.Unbounded.Unbounded_String;
            Start : Positive := Word'First;
         begin
            for Index in Word'First .. Word'Last + 1 loop
               if Index > Word'Last or else Word (Index) = '_' then
                  if Index > Start then
                     Ada.Strings.Unbounded.Append
                       (Short, (if Index - Start <= 3 then Word (Start .. Index - 1) else Word (Start .. Start)));
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            declare
               Made : constant String := Ada.Strings.Unbounded.To_String (Short);
            begin
               if Made'Length >= 2 and then Identifiers.Is_Valid (Made) then
                  return Made;
               end if;
            end;
         end;
      end if;
      return (if Identifiers.Is_Valid (Word) then Word else "DOC");
   exception
      when others =>
         return "DOC";
   end Key_Of;

   function Headline (Text : String) return String
   is (if Text'Length <= 100 then Text
       else Text (Text'First .. Text'First + 96) & "...");

   ----------
   -- Scan --
   ----------

   function Scan (Path : String; Text : String) return Output_List is
      Result  : Output_List;
      Key     : constant String := Key_Of (Path);
      Seen    : Name_Lists.Vector;
      Titled  : Boolean := False;
      Start   : Natural := Text'First;
      In_Fence : Boolean := False;

      --  The requirement a heading names, whose section is its statement
      --  until the next heading: the output it is, or zero.
      Section : Natural := 0;

      --  The requirement an Acceptance: line is about: the last one found.
      Last_Requirement : Natural := 0;

      --  A heading a document's own label opens -- ### FR-001 Capacity --
      --  whose first line stating a requirement is that requirement.
      Pending_Label : Unbounded_String;
      Pending_Title : Unbounded_String;

      --  A requirement whose line leads into a list -- SHALL distinguish:
      --  -- and so takes the items that follow as part of what it says.
      Lead : Natural := 0;

      procedure Found
        (Kind : Output_Kind; Provenance, Title, Body_Text : String; Given : String := "")
      is
      begin
         Append
           (Result,
            (Kind       => Kind,
             Provenance => To_Unbounded_String (Provenance),
             Key        => To_Unbounded_String (Key),
             Title      => To_Unbounded_String (Title),
             Text       => To_Unbounded_String (Body_Text),
             Source     => To_Unbounded_String (Path),
             Criteria   => Null_Unbounded_String,
             Given_Id   => To_Unbounded_String (Given)));
         if Kind in Imported_Item | Requirement_Candidate then
            Last_Requirement := Length (Result);
         end if;
      end Found;

      function Starts_With (Item, Prefix : String) return Boolean
      is (Item'Length > Prefix'Length
          and then Ada.Characters.Handling.To_Lower (Item (Item'First .. Item'First + Prefix'Length - 1))
                   = Ada.Characters.Handling.To_Lower (Prefix));

      --  A line as what it says, its markup taken off: a quote's >, a list
      --  item's - or * or 1. or 1), and a table row's cells -- the one that
      --  is an identifier first, as ID: the rest.
      function Unmarked (Line : String) return String is
      begin
         if Line'Length > 1 and then Line (Line'First) = '>' then
            return Unmarked (Trim (Line (Line'First + 1 .. Line'Last)));
         elsif Line'Length > 2 and then Line (Line'First) in '-' | '*' | '+'
           and then Line (Line'First + 1) = ' '
         then
            return Trim (Line (Line'First + 2 .. Line'Last));
         elsif Line'Length > 0 and then Line (Line'First) = '|' then
            declare
               Cells : Name_Lists.Vector;
               Start : Positive := Line'First + 1;
               Id    : Unbounded_String;
               Rest  : Unbounded_String;
            begin
               for Index in Line'First + 1 .. Line'Last + 1 loop
                  if Index > Line'Last or else Line (Index) = '|' then
                     if Trim (Line (Start .. Index - 1)) /= "" then
                        Cells.Append (Trim (Line (Start .. Index - 1)));
                     end if;
                     Start := Index + 1;
                  end if;
               end loop;
               --  The identifier, and of the rest the cell that says the
               --  most: a priority or a status beside it is not the
               --  statement.
               for Cell of Cells loop
                  declare
                     Label : Unbounded_String;
                     After : Unbounded_String;
                  begin
                     Label_Split (Cell & " x", Label, After);
                     if Id = Null_Unbounded_String and then To_String (Label) = Cell then
                        Id := To_Unbounded_String (Cell);
                     elsif (for some C of Cell => C not in '-' | ':' | ' ')
                       and then Cell'Length > Length (Rest)
                     then
                        Rest := To_Unbounded_String (Cell);
                     end if;
                  end;
               end loop;
               return (if Id = Null_Unbounded_String then To_String (Rest)
                       else To_String (Id) & ": " & To_String (Rest));
            end;
         else
            --  A numbered item: 1. or 12) and a space.
            declare
               Digits_End : Natural := Line'First - 1;
            begin
               while Digits_End < Line'Last and then Line (Digits_End + 1) in '0' .. '9' loop
                  Digits_End := Digits_End + 1;
               end loop;
               if Digits_End >= Line'First and then Digits_End + 2 <= Line'Last
                 and then Line (Digits_End + 1) in '.' | ')'
                 and then Line (Digits_End + 2) = ' '
               then
                  return Trim (Line (Digits_End + 3 .. Line'Last));
               end if;
            end;
            return Line;
         end if;
      end Unmarked;

      procedure Line_Of (Raw : String) is
         Line : constant String := Trim (Raw);
         Item : constant String := Unmarked (Line);
         Colon : constant Natural := Ada.Strings.Fixed.Index (Item, ":");
         --  Listed: an item, a numbered item or a table row.
         Listed : constant Boolean := Item /= Line and then Line'Length > 0 and then Line (Line'First) /= '>';
         Label  : Unbounded_String;
         Rest   : Unbounded_String;
      begin
         --  The items under a requirement that leads into them are what it
         --  says; anything else ends its list.
         if Lead > 0 and then Item /= "" then
            if Listed and then not Says_Requirement (Item, Listed) then
               declare
                  Held : Output := Result.Outputs (Lead);
               begin
                  Held.Text := Held.Text & ASCII.LF & "- " & Item;
                  Result.Outputs (Lead) := Held;
               end;
               return;
            end if;
            Lead := 0;
         end if;
         --  A blank line ends a heading's statement: what follows is said
         --  apart, though Acceptance: lines still go to the requirement.
         if Item = "" then
            --  Only once it has said something: a blank line under the
            --  heading is Markdown's, not the end of the statement.
            if Section > 0 and then Result.Outputs (Section).Text /= Null_Unbounded_String then
               Section := 0;
            end if;
            return;
         end if;

         if Item (Item'First) = '#' then
            declare
               Heading : constant String :=
                 Trim (Ada.Strings.Fixed.Trim
                         (Item, Ada.Strings.Maps.To_Set ('#'), Ada.Strings.Maps.Null_Set));
               Space   : constant Natural := Ada.Strings.Fixed.Index (Heading & " ", " ");
               First   : constant String := Heading (Heading'First .. Space - 1);
            begin
               if not Titled then
                  Titled := True;
                  Found (Specification_Candidate, Path, Heading, Text);
               end if;

               --  ## REQ-SHELL-001 Quoting: the requirement, at once, with
               --  its identifier and title; what its section says is its
               --  statement, and its Acceptance: lines its criteria.
               Section := 0;
               Pending_Label := Null_Unbounded_String;
               Label_Split (Heading, Label, Rest);
               if First'Length > 4 and then First (First'First .. First'First + 3) = "REQ-"
                 and then Identifiers.Is_Valid (First)
               then
                  null;
               --  ## ADR-001: Title -- a decision record: its section says it.
               elsif Length (Label) > 4 and then Slice (Label, 1, 4) = "ADR-" then
                  Found (Decision_Candidate, Path & "#" & To_String (Label),
                         To_String (Label) & ": " & To_String (Rest), "");
                  Section := Length (Result);
                  return;
               elsif Label /= Null_Unbounded_String then
                  Pending_Label := Label;
                  Pending_Title := Rest;
                  return;
               end if;
               if First'Length > 4 and then First (First'First .. First'First + 3) = "REQ-"
                 and then Identifiers.Is_Valid (First)
               then
                  declare
                     Title : constant String := Trim (Heading (Space .. Heading'Last));
                  begin
                     Found (Imported_Item, Path & "#" & First,
                            (if Title = "" then First else Title), "", Given => First);
                     Section := Length (Result);
                  end;
               end if;
            end;
            return;
         end if;

         --  Acceptance: what the requirement just stated is judged by.
         if Starts_With (Item, "Acceptance:") or else Starts_With (Item, "Acceptance criteria:") then
            if Section > 0 then
               Last_Requirement := Section;
            end if;
            if Last_Requirement > 0 then
               declare
                  Held : Output := Result.Outputs (Last_Requirement);
                  Said : constant String := Trim (Item (Colon + 1 .. Item'Last));
               begin
                  if Said /= "" then
                     Held.Criteria :=
                       (if Held.Criteria = Null_Unbounded_String then To_Unbounded_String (Said)
                        else Held.Criteria & ASCII.LF & Said);
                     Result.Outputs (Last_Requirement) := Held;
                  end if;
               end;
            else
               Found (Issue, Path & "#" & Item, "acceptance criteria before any requirement", Item);
            end if;
            return;
         end if;

         --  Fact: KEY = VALUE -- something the document says the project is.
         if Item'Length > 5 and then Item (Item'First .. Item'First + 4) = "Fact:" then
            declare
               Said  : constant String := Trim (Item (Item'First + 5 .. Item'Last));
               Equal : constant Natural := Ada.Strings.Fixed.Index (Said, "=");
               Name  : constant String :=
                 (if Equal = 0 then "" else Trim (Said (Said'First .. Equal - 1)));
               Value : constant String :=
                 (if Equal = 0 then "" else Trim (Said (Equal + 1 .. Said'Last)));
            begin
               if Name /= "" and then Value /= "" and then Facts.Is_Key (Name) then
                  Append
                    (Result,
                     (Kind       => Discovered_Fact,
                      Provenance => To_Unbounded_String (Path & "#fact:" & Name),
                      Key        => To_Unbounded_String (Name),
                      Title      => To_Unbounded_String (Name),
                      Text       => To_Unbounded_String (Value),
                      Source     => To_Unbounded_String (Path),
                      others     => <>));
               else
                  Found (Issue, Path & "#" & Item, "a fact that does not read", Item);
               end if;
            end;
            return;
         end if;

         --  Under a heading a document's own label opens, the first line
         --  stating a requirement is it, under that label.
         if Pending_Label /= Null_Unbounded_String and then Says_Requirement (Item, True) then
            Found (Requirement_Candidate, Path & "#" & To_String (Pending_Label),
                   To_String (Pending_Label) & ": " & Headline (To_String (Pending_Title)), Item);
            Pending_Label := Null_Unbounded_String;
            Section := Length (Result);
            return;
         end if;

         --  A line a document's own label begins -- FR-001, [NFR-01],
         --  **R-10** -- is known by it: the label kept in its title, and
         --  what it is found again by when the line is reworded.
         Label_Split (Item, Label, Rest);
         if Label /= Null_Unbounded_String
           and then not (Length (Label) > 4 and then Slice (Label, 1, 4) in "REQ-" | "DEC-")
           and then Says_Requirement (To_String (Rest), True)
         then
            Found (Requirement_Candidate, Path & "#" & To_String (Label),
                   To_String (Label) & ": " & Headline (To_String (Rest)), To_String (Rest));
            if To_String (Rest) (Length (Rest)) = ':' then
               Lead := Length (Result);
            end if;
            return;
         end if;

         --  We decided to ...: a decision, as the document tells it.
         if Starts_With (Item, "We decided ") or else Starts_With (Item, "We chose ")
           or else Starts_With (Item, "We will use ")
         then
            Found (Decision_Candidate, Path & "#" & Fingerprint (Item), Headline (Item), Item);
            return;
         end if;

         --  REQ-IO-003: text, or REQ-IO-003 text -- in a list item too: a
         --  requirement the document names; DEC-001 the same for a
         --  decision.
         declare
            Blank : constant Natural := Ada.Strings.Fixed.Index (Item, " ");
            Word  : constant String :=
              (if Blank = 0 then Item else Item (Item'First .. Blank - 1));
            Id    : constant String :=
              (if Word'Length > 1 and then Word (Word'Last) = ':'
               then Word (Word'First .. Word'Last - 1) else Word);
            Said  : constant String :=
              (if Blank = 0 then "" else Trim (Item (Blank + 1 .. Item'Last)));
         begin
            if Id'Length > 4 and then Id (Id'First .. Id'First + 3) in "REQ-" | "DEC-"
              and then Identifiers.Is_Valid (Id) and then Said /= ""
            then
               Found ((if Id (Id'First .. Id'First + 3) = "REQ-" then Imported_Item
                       else Decision_Candidate),
                      Path & "#" & Id, Headline (Said), Said, Given => Id);
               return;
            end if;
         end;

         --  Decision (2024-01): text -- a date or a note in brackets before
         --  its colon -- is a decision too.
         if Item'Length > 10 and then Item (Item'First .. Item'First + 9) = "Decision ("
           and then Ada.Strings.Fixed.Index (Item, "):") > 0
         then
            declare
               Said : constant String :=
                 Trim (Item (Ada.Strings.Fixed.Index (Item, "):") + 2 .. Item'Last));
            begin
               Found (Decision_Candidate, Path & "#" & Fingerprint (Said), Headline (Said), Said);
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

         --  In a section a requirement's heading opens, what is said is
         --  that requirement's statement.
         if Section > 0 then
            declare
               Held : Output := Result.Outputs (Section);
            begin
               Held.Text :=
                 (if Held.Text = Null_Unbounded_String then To_Unbounded_String (Item)
                  else Held.Text & ASCII.LF & Item);
               Result.Outputs (Section) := Held;
            end;
            return;
         end if;

         if Says_Requirement (Item, Listed) then
            declare
               Print : constant String := Fingerprint (Item);
            begin
               --  A line that leads into a list is said again with another
               --  list: not the same requirement twice, but one more.
               if Seen.Contains (Print) and then Item (Item'Last) = ':' then
                  declare
                     Again : Natural := 2;
                  begin
                     while Seen.Contains (Print & "-" & Image (Again)) loop
                        Again := Again + 1;
                     end loop;
                     Seen.Append (Print & "-" & Image (Again));
                     Found (Requirement_Candidate, Path & "#" & Print & "-" & Image (Again),
                            Headline (Item), Item);
                     Lead := Length (Result);
                  end;
               elsif Seen.Contains (Print) then
                  Found (Issue, Path & "#twice-" & Print,
                         "stated twice: " & Headline (Item), Item);
               else
                  Seen.Append (Print);
                  Found (Requirement_Candidate, Path & "#" & Print,
                         Headline (Item), Item);
                  if Item (Item'Last) = ':' then
                     Lead := Length (Result);
                  end if;
               end if;
            end;
         end if;
      end Line_Of;
      --  A paragraph wrapped over several lines is one line of what the
      --  document says: joined, so a requirement is not read from half a
      --  sentence. A line goes on the one before where that ended mid
      --  sentence and this one starts nothing of its own.
      Paragraph : Unbounded_String;

      function Starts_Own (Raw : String) return Boolean is
         Label : Unbounded_String;
         Rest  : Unbounded_String;
      begin
         if Raw = "" or else Raw (Raw'First) in '#' | '|' | '>' | '-' | '*' | '+' | '0' .. '9' then
            return True;
         end if;
         Label_Split (Raw, Label, Rest);
         return Label /= Null_Unbounded_String
           or else (for some Prefix of Name_Lists.Vector'(["Acceptance", "Fact:", "Decision", "Status:"])
                      => Starts_With (Raw, Prefix));
      end Starts_Own;

      procedure Flush is
      begin
         if Paragraph /= Null_Unbounded_String then
            Line_Of (To_String (Paragraph));
            Paragraph := Null_Unbounded_String;
         end if;
      end Flush;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            --  What a fenced block holds is code or an example, not what
            --  the document says the project must be.
            declare
               Raw : constant String := Trim (Text (Start .. Index - 1));
            begin
               if Raw'Length >= 3 and then Raw (Raw'First .. Raw'First + 2) in "```" | "~~~" then
                  Flush;
                  In_Fence := not In_Fence;
               elsif not In_Fence then
                  if Paragraph /= Null_Unbounded_String and then not Starts_Own (Raw)
                    and then Element (Paragraph, Length (Paragraph)) not in '.' | '!' | '?' | ':'
                    and then Element (Paragraph, 1) not in '#' | '|'
                  then
                     Append (Paragraph, " " & Raw);
                  else
                     Flush;
                     if Raw = "" then
                        Line_Of ("");
                     else
                        Paragraph := To_Unbounded_String (Raw);
                     end if;
                  end if;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      Flush;

      --  A heading with nothing under it says what it is by its title.
      for Index in 1 .. Length (Result) loop
         declare
            Held : Output := Result.Outputs (Index);
         begin
            if Held.Kind = Imported_Item and then Held.Text = Null_Unbounded_String then
               Held.Text := Held.Title;
               Result.Outputs (Index) := Held;
            end if;
         end;
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

      --  A history of changes names what was asked long ago, not what the
      --  project must be now: left out where a pattern finds it, read
      --  where it is named.
      function History (Name : String) return Boolean is
         Upper : constant String := Ada.Characters.Handling.To_Upper (Name);
      begin
         return (for some Word of Name_Lists.Vector'(["CHANGELOG", "CHANGES", "HISTORY", "NEWS"])
                   => Upper'Length >= Word'Length and then Upper (Upper'First .. Upper'First + Word'Length - 1) = Word);
      end History;

      --  The files in Dir (relative) matching Name; in its subdirectories
      --  too where Deep.
      procedure Collect (Dir, Name : String; Deep, Pattern : Boolean) is
         Where  : constant String := (if Dir = "" then Project else Project & "/" & Dir);
         Search : Ada.Directories.Search_Type;
         Found  : Ada.Directories.Directory_Entry_Type;
         Below  : Name_Lists.Vector;
      begin
         if not Ada.Directories.Exists (Where) then
            return;
         end if;
         Ada.Directories.Start_Search
           (Search, Where, Name, [Ada.Directories.Ordinary_File => True, others => False]);
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Found);
            declare
               Simple : constant String := Ada.Directories.Simple_Name (Found);
               Path   : constant String := (if Dir = "" then "" else Dir & "/") & Simple;
            begin
               if not Result.Contains (Path) and then not (Pattern and then History (Simple)) then
                  Result.Append (Path);
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
         if Deep then
            Ada.Directories.Start_Search
              (Search, Where, "", [Ada.Directories.Directory => True, others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Found);
               declare
                  Simple : constant String := Ada.Directories.Simple_Name (Found);
               begin
                  if Simple (Simple'First) /= '.' then
                     Below.Append ((if Dir = "" then "" else Dir & "/") & Simple);
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
            for Sub of Below loop
               Collect (Sub, Name, Deep, Pattern);
            end loop;
         end if;
      exception
         when others =>
            null;
      end Collect;
   begin
      if Listed.Is_Empty then
         Listed.Append ("*.md");
         Listed.Append ("docs/**/*.md");
      end if;
      for Entry_Text of Listed loop
         declare
            Given : constant String := Ada.Strings.Fixed.Trim (Entry_Text, Ada.Strings.Both);
            Slash : constant Natural := Ada.Strings.Fixed.Index (Given, "/", Ada.Strings.Backward);
            Dir   : constant String := (if Slash = 0 then "" else Given (Given'First .. Slash - 1));
            Name  : constant String := (if Slash = 0 then Given else Given (Slash + 1 .. Given'Last));
            --  dir/**: dir and every directory below it.
            Deep  : constant Boolean :=
              Dir'Length >= 2 and then Dir (Dir'Last - 1 .. Dir'Last) = "**";
            Base  : constant String :=
              (if not Deep then Dir
               elsif Dir'Length = 2 then ""
               else Dir (Dir'First .. Dir'Last - 3));
         begin
            --  Within the project, and never its state.
            if Given /= "" and then Given (Given'First) not in '/' | '\'
              and then Ada.Strings.Fixed.Index (Given, "..") = 0
              and then Ada.Strings.Fixed.Index (Given, State_Directory) = 0
            then
               Collect (Base, Name, Deep, Pattern => Ada.Strings.Fixed.Index (Name, "*") > 0);
            end if;
         end;
      end loop;
      Sorting.Sort (Result);
      return Result;
   end Documents;

   --  How alike two texts are, by their words: those they share, of all
   --  either has.
   function Likeness (Left, Right : String) return Float is
      function Words (Text : String) return Name_Lists.Vector is
         Result : Name_Lists.Vector;
         Start  : Natural := Text'First;
      begin
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' then
               if Index > Start then
                  declare
                     Word : constant String :=
                       Ada.Characters.Handling.To_Lower (Text (Start .. Index - 1));
                  begin
                     if not Result.Contains (Word) then
                        Result.Append (Word);
                     end if;
                  end;
               end if;
               Start := Index + 1;
            end if;
         end loop;
         return Result;
      end Words;

      A      : constant Name_Lists.Vector := Words (Left);
      B      : constant Name_Lists.Vector := Words (Right);
      Shared : Natural := 0;
   begin
      for Word of A loop
         if B.Contains (Word) then
            Shared := Shared + 1;
         end if;
      end loop;
      return (if Natural (A.Length) + Natural (B.Length) - Shared = 0 then 0.0
              else Float (Shared) / Float (Natural (A.Length) + Natural (B.Length) - Shared));
   end Likeness;

   procedure Apply
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Output_List;
      Result : out Report;
      Status : out Model_Runner.Errors.Error_Info;
      Accept_Numbered : Boolean := True)
   is
      function Field (Text : Unbounded_String) return String
      is (To_String (Text));

      Settings : constant Records.Item := Settings_Of (Item);
      Kinds    : constant Name_Lists.Vector :=
        Items_Of (Records.Get (Settings, "set.bootstrap.propose"));
      Accept_Imports : constant Boolean :=
        Accept_Numbered and then Records.Get (Settings, "scalar.bootstrap.import") /= "candidate";

      --  Whether a document's new words revise what it numbers without a
      --  person: only where the project says the documents rule, with
      --  scalar bootstrap.import = accepted. Otherwise an accepted one is a
      --  person's to change, as it is what work was judged by.
      Document_Rules : constant Boolean :=
        Records.Get (Settings, "scalar.bootstrap.import") = "accepted";

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
      --  The texts of what it made, as Result.Made has them.
      Made_Texts   : Name_Lists.Vector;
      Made_Sources : Name_Lists.Vector;

      --  Entries an output without an identifier was found to be the new
      --  wording of: each taken by one output only.
      Rewritten    : Name_Lists.Vector;

      --  Whether the documents read now still say what a provenance is of.
      function Still_Said (Provenance : String) return Boolean is
      begin
         for Other of Found.Outputs loop
            if Field (Other.Provenance) = Provenance then
               return True;
            end if;
         end loop;
         return False;
      end Still_Said;

      --  An issue, kept as a diagnostic result -- the same issue found
      --  again being the same result -- and said once, when it is new.
      --  What an issue says, before the ways on it names: two about the same
      --  words that say different things are two issues.
      function Gist (Summary : String) return String is
         Cut : constant Natural := Ada.Strings.Fixed.Index (Summary, ";");
      begin
         return (if Cut = 0 then Summary else Summary (Summary'First .. Cut - 1));
      end Gist;

      procedure Raise_Issue (Said : in out Results.Result) is
         Id  : constant String := Results.Identifier_Of (Said);
         New_One : constant Boolean := not Stores.Exists (Item, Results_Area, Id);
      begin
         --  One saying the same is there already: nothing more is raised.
         if New_One then
            for Name of Stores.Names (Item, Results_Area) loop
               declare
                  Held : Results.Result;
                  Read : E.Error_Info;
                  Kept : constant String :=
                    (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                     then Name (Name'First .. Name'Last - 4) else Name);
               begin
                  Results.Read (Item, Kept, Held, Read, With_Payload => False);
                  if E.Is_Ok (Read) and then To_String (Held.Producer) = "bootstrap"
                    and then (Held.Summary = Said.Summary
                              or else (Held.Provenance = Said.Provenance
                                       and then Length (Said.Provenance) > 0))
                  then
                     --  Of the same thing: the same issue where it says the
                     --  same words, whatever its summary adds; words the
                     --  document has changed since are another issue.
                     Results.Read (Item, Kept, Held, Read);
                     if E.Is_Ok (Read) and then Held.Payload = Said.Payload
                       and then Gist (To_String (Held.Summary)) = Gist (To_String (Said.Summary))
                     then
                        return;
                     end if;
                  end if;
               end;
            end loop;
         end if;
         Results.Add (Item, Change, Said, Status);
         if New_One then
            Result.Issues := Result.Issues + 1;
         end if;
         if E.Is_Ok (Status) and then New_One then
            Result.Stale.Append (Id & ": " & To_String (Said.Summary));
         end if;
      end Raise_Issue;
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

            function Area_Of (Kind : Intent.Intent_Kind) return Area
            is (case Kind is
                  when Intent.Requirement   => Requirements_Area,
                  when Intent.Specification => Specs_Area,
                  when Intent.Decision      => Decisions_Area);

            --  What the document said when it was imported, kept on what it
            --  made: what is compared with the next run, so a person's own
            --  revision is not taken for the document's.
            procedure Mark_Imported (Kind : Intent.Intent_Kind; Named : String) is
               Value  : Records.Item;
               Staged : Boolean;
            begin
               Stores.Pending (Change, Area_Of (Kind), Named, Value, Staged);
               if Staged then
                  Records.Set (Value, "imported_text", To_String (Next.Text));
                  Records.Set (Value, "imported_criteria", To_String (Next.Criteria));
                  Records.Set (Value, "imported_title", To_String (Next.Title));
                  Stores.Put (Change, Area_Of (Kind), Named, Value);
               end if;
            end Mark_Imported;

            --  Found again. The document unchanged since it was imported --
            --  whatever a person has made of it since -- is nothing new. The
            --  document changed: its next revision, where what it made is
            --  still a candidate or the policy takes the document's word;
            --  otherwise an issue for a person, who decides what is agreed.
            procedure Again (Kind : Intent.Intent_Kind; Known : String; Settled : Boolean) is
               Held   : Intent.Entity;
               Effect : Intent.Impact;
               Kept   : Records.Item;
               Read   : E.Error_Info;
            begin
               Intent.Read (Item, Kind, Known, Held, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Stores.Read (Item, Area_Of (Kind), Known, Kept, Read);
               declare
                  Imported : constant String :=
                    (if Records.Get (Kept, "imported_text") /= ""
                     then Records.Get (Kept, "imported_text") else To_String (Held.Text));
                  --  What it was judged by when it was imported: kept since,
                  --  or, from before that was kept, what it holds now.
                  Judged_By : constant String :=
                    (if Records.Has (Kept, "imported_criteria")
                     then Records.Get (Kept, "imported_criteria") else To_String (Held.Criteria));

                  --  The title it was imported with, or holds when that was
                  --  not kept.
                  Titled : constant String :=
                    (if Records.Has (Kept, "imported_title") then Records.Get (Kept, "imported_title")
                     else To_String (Held.Title));
               begin
                  if To_String (Held.State) in "obsolete" | "superseded" | "rejected" then
                     Result.Existing := Result.Existing + 1;
                     --  Retired, and the document still says it: the one or
                     --  the other is out of date, which a person decides.
                     if To_String (Held.State) in "obsolete" | "superseded" then
                        declare
                           Said : Results.Result :=
                             (Kind       => Results.Diagnostic,
                              Producer   => To_Unbounded_String ("bootstrap"),
                              Summary    => To_Unbounded_String
                                              (Field (Next.Source) & " still says "
                                               --  Quoted where the document names no
                                               --  identifier: that is what it says.
                                               & (if Field (Next.Given_Id) = "" then
                                                     """" & Field (Next.Text) & """ (what "
                                                     & Known & " was read from)"
                                                  else Known)
                                               & ", which is " & To_String (Held.State)
                                               & (if Held.Superseded_By = Null_Unbounded_String
                                                  then ""
                                                  else ", replaced by "
                                                       & To_String (Held.Superseded_By))
                                               & (if Held.Superseded_By /= Null_Unbounded_String
                                                    and then Field (Next.Given_Id) = ""
                                                  then "; take that line out, or write there what "
                                                       & To_String (Held.Superseded_By) & " says"
                                                  elsif Held.Superseded_By /= Null_Unbounded_String
                                                  then "; change it to "
                                                       & To_String (Held.Superseded_By)
                                                       & ", which is read from there then, or take"
                                                       & " the section out"
                                                  else "; take it out of the document, or, to have"
                                                       & " it again, "
                                                       & (if Intent."=" (Kind, Intent.Decision)
                                                          then "/decision"
                                                          elsif Intent."=" (Kind, Intent.Specification)
                                                          then "/spec" else "/req")
                                                       & " new with its words makes it anew")),
                              Payload    => Next.Text,
                              Provenance => Next.Provenance,
                              others     => <>);
                        begin
                           Raise_Issue (Said);
                        end;
                     end if;

                  --  Its words unchanged, or already what it holds -- a person
                  --  took them in by hand -- and at most its title renamed.
                  elsif (To_String (Next.Text) = Imported and then To_String (Next.Criteria) = Judged_By)
                    or else (To_String (Next.Text) = To_String (Held.Text)
                             and then (To_String (Next.Criteria) = To_String (Held.Criteria)
                                       or else To_String (Next.Criteria) = ""))
                  then
                     --  A heading renamed, where nobody renamed what it made:
                     --  the new title, a revision of no meaning.
                     if To_String (Next.Title) /= Titled and then To_String (Held.Title) = Titled
                       and then To_String (Next.Title) /= ""
                     then
                        Intent.Revise
                          (Item, Change, Kind, Known, Field (Next.Title), To_String (Held.Text),
                           To_String (Held.Criteria), Effect, Status);
                        if E.Is_Ok (Status) then
                           Mark_Imported (Kind, Known);
                           Result.Revised.Append (Known);
                        end if;
                     else
                        Result.Existing := Result.Existing + 1;
                     end if;
                  --  Agreed on -- accepted, whether by a person or as its
                  --  document numbered it -- a document's new words are a
                  --  person's to take: it is what work was judged by.
                  elsif (To_String (Held.State) /= Intent.First_State (Kind) and then not Settled)
                    or else (Records.Get (Kept, "imported_text") /= ""
                             and then To_String (Held.Text) /= Imported)
                  then
                     --  Agreed on, or revised by a person since: a person
                     --  decides whether the document's new words replace it.
                     declare
                        Word : constant String :=
                          (case Kind is
                              when Intent.Requirement   => "/req",
                              when Intent.Decision      => "/decision",
                              when Intent.Specification => "/spec");
                        Said : Results.Result :=
                          (Kind       => Results.Diagnostic,
                           Producer   => To_Unbounded_String ("bootstrap"),
                           Summary    => To_Unbounded_String
                                           (Field (Next.Source) & " now says what " & Known
                                            & " does not"
                                            & (if To_String (Held.Text) /= Imported
                                               then ", and " & Known & " holds a person's revision,"
                                                    & " kept"
                                               else "")
                                            & "; " & Word & " revise " & Known
                                            & " from-document takes the document's words"),
                           Payload    => Next.Text,
                           Provenance => Next.Provenance,
                           others     => <>);
                     begin
                        --  There, and kept as a person has it: counted so.
                        Result.Existing := Result.Existing + 1;
                        Raise_Issue (Said);
                     end;
                  else
                     --  The document's criteria where it changed them, the
                     --  ones held otherwise.
                     Intent.Revise
                       (Item, Change, Kind, Known, Field (Next.Title), Field (Next.Text),
                        (if To_String (Next.Criteria) /= Judged_By then Field (Next.Criteria)
                         else To_String (Held.Criteria)),
                        Effect, Status);
                     if E.Is_Ok (Status) then
                        Mark_Imported (Kind, Known);
                        Result.Revised.Append (Known);
                     end if;
                  end if;
               end;
            end Again;

            --  An entry made by hand that the document names by its
            --  identifier: the document is where it is read from from now
            --  on -- its words, where they differ, a revision as any -- not
            --  a second entry under another identifier.
            function Adopted (Kind : Intent.Intent_Kind; Given : String) return Boolean is
               Held   : Intent.Entity;
               Read   : E.Error_Info;
               Value  : Records.Item;
               Staged : Boolean;
            begin
               if Given = "" or else not Stores.Is_Name (Given) then
                  return False;
               end if;
               Intent.Read (Item, Kind, Given, Held, Read);
               --  Only one that is the document's in all but where it came
               --  from: made to replace what the document named before, or
               --  saying much the same. Another under that identifier is a
               --  clash, and raised as one.
               if E.Is_Error (Read) or else To_String (Held.Source) not in "" | "user"
                 or else To_String (Held.State) in "obsolete" | "superseded" | "rejected"
                 or else (Held.Supersedes = Null_Unbounded_String
                          and then Likeness (To_String (Held.Text), To_String (Next.Text)) <= 0.5)
               then
                  return False;
               end if;
               Again (Kind, Given, Settled => Document_Rules);
               if E.Is_Error (Status) then
                  return True;
               end if;
               Stores.Pending (Change, Area_Of (Kind), Given, Value, Staged);
               if not Staged then
                  Stores.Read (Item, Area_Of (Kind), Given, Value, Read);
                  Records.Set_Revision (Value, Records.Revision (Value) + 1);
               end if;
               Records.Set (Value, "source", Field (Next.Source));
               Records.Set (Value, "provenance", Provenance);
               Records.Set (Value, "imported_text", To_String (Next.Text));
               Records.Set (Value, "imported_criteria", To_String (Next.Criteria));
               Records.Set (Value, "imported_title", To_String (Next.Title));
               Stores.Put (Change, Area_Of (Kind), Given, Value);
               Result.Adopted.Append (Given & " from " & Field (Next.Source));
               return True;
            end Adopted;

            --  An entry read from a document that is gone, found here under
            --  the same part of it -- its label, identifier or wording: the
            --  document moved, and the entry is read from where it is now.
            function Moved_Here (Kind : Intent.Intent_Kind) return String is
               Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
               Mark    : constant Natural := Ada.Strings.Fixed.Index (Provenance, "#");
               Part    : constant String :=
                 (if Mark = 0 then "" else Provenance (Mark .. Provenance'Last));
            begin
               for Name of Intent.List (Item, Kind) loop
                  declare
                     Held  : Records.Item;
                     Read  : E.Error_Info;
                  begin
                     Stores.Read (Item, Area_Of (Kind), Name, Held, Read);
                     declare
                        Was    : constant String := Records.Get (Held, "provenance");
                        At_Was : constant Natural := Ada.Strings.Fixed.Index (Was, "#");
                        --  The document it was read from; a whole document --
                        --  a specification -- is its provenance.
                        From   : constant String :=
                          (if At_Was = 0 then Was else Was (Was'First .. At_Was - 1));
                     begin
                        if E.Is_Ok (Read) and then From /= "" and then From /= Field (Next.Source)
                          and then not Ada.Directories.Exists (Project & "/" & From)
                          and then (if Part = ""
                                    then At_Was = 0 and then Records.Get (Held, "title") = Field (Next.Title)
                                    else At_Was > Was'First and then Was (At_Was .. Was'Last) = Part)
                        then
                           Records.Set_Revision (Held, Records.Revision (Held) + 1);
                           Records.Set (Held, "provenance", Provenance);
                           Records.Set (Held, "source", Field (Next.Source));
                           Stores.Put (Change, Area_Of (Kind), Name, Held);
                           Result.Moved.Append (Name & " from " & Field (Next.Source));
                           return Name;
                        end if;
                     end;
                  end;
               end loop;
               return "";
            end Moved_Here;

            procedure Propose (Kind : Intent.Intent_Kind) is
               Found_Here : constant String := Intent.Find_By_Provenance (Item, Kind, Provenance);
               Known : constant String := (if Found_Here /= "" then Found_Here else Moved_Here (Kind));
               Given : constant String := Field (Next.Given_Id);
               Taken : constant Boolean :=
                 Given /= "" and then Stores.Is_Name (Given)
                 and then Stores.Exists (Item, Area_Of (Kind), Given);
            begin
               if Known /= "" then
                  Again (Kind, Known, Settled => False);
                  return;
               elsif Adopted (Kind, Given) then
                  return;
               end if;

               --  Said without an identifier, where the document said
               --  something much like it before and no longer does: its new
               --  wording, revised in place -- not a second entry beside it.
               if Given = "" then
                  declare
                     Best  : Unbounded_String;
                     Score : Float := 0.5;
                  begin
                     for Other of Intent.List (Item, Kind) loop
                        declare
                           Held : Intent.Entity;
                           Read : E.Error_Info;
                        begin
                           Intent.Read (Item, Kind, Other, Held, Read);
                           if E.Is_Ok (Read)
                             and then To_String (Held.Source) = Field (Next.Source)
                             and then Length (Held.Provenance) > 0
                             and then not Still_Said (To_String (Held.Provenance))
                             and then not Rewritten.Contains (Other)
                             and then To_String (Held.State) /= "rejected"
                             and then Likeness (To_String (Held.Text), Field (Next.Text)) > Score
                           then
                              Score := Likeness (To_String (Held.Text), Field (Next.Text));
                              Best := To_Unbounded_String (Other);
                           end if;
                        end;
                     end loop;
                     --  Its new words are like one retired: that one is not
                     --  proposed again beside what replaced it -- said, for a
                     --  person to put the document right.
                     if Best /= Null_Unbounded_String
                       and then Intent.State_Of (Item, Kind, To_String (Best)) in "obsolete" | "superseded"
                     then
                        declare
                           Held : Intent.Entity;
                           Read : E.Error_Info;
                           Said : Results.Result;
                        begin
                           Intent.Read (Item, Kind, To_String (Best), Held, Read);
                           Rewritten.Append (To_String (Best));
                           Said :=
                             (Kind       => Results.Diagnostic,
                              Producer   => To_Unbounded_String ("bootstrap"),
                              Summary    => To_Unbounded_String
                                              (Field (Next.Source) & " now says '" & Field (Next.Text)
                                               & "', which is like " & To_String (Best) & ", "
                                               & To_String (Held.State)
                                               & (if Held.Superseded_By = Null_Unbounded_String then ""
                                                  else " by " & To_String (Held.Superseded_By))
                                               & ": nothing new was proposed -- take the line out,"
                                               & " or write what replaced it there"),
                              Payload    => Next.Text,
                              Provenance => Next.Provenance,
                              others     => <>);
                           Raise_Issue (Said);
                        end;
                        return;
                     end if;
                     if Best /= Null_Unbounded_String then
                        declare
                           Value  : Records.Item;
                           Read   : E.Error_Info;
                           Staged : Boolean;
                        begin
                           Rewritten.Append (To_String (Best));
                           Again (Kind, To_String (Best), Settled => False);
                           if E.Is_Error (Status) then
                              return;
                           end if;
                           --  Read from where the document says it now.
                           Stores.Pending (Change, Area_Of (Kind), To_String (Best), Value, Staged);
                           if not Staged then
                              Stores.Read (Item, Area_Of (Kind), To_String (Best), Value, Read);
                              Records.Set_Revision (Value, Records.Revision (Value) + 1);
                           end if;
                           Records.Set (Value, "provenance", Provenance);
                           Stores.Put (Change, Area_Of (Kind), To_String (Best), Value);
                        end;
                        return;
                     end if;
                  end;
               end if;
               Intent.Propose
                 (Item, Change, Kind, Field (Next.Key), Field (Next.Title),
                  Field (Next.Text), Field (Next.Criteria), Field (Next.Source), Provenance,
                  "project", Id, Status, Given => Field (Next.Given_Id));
               if E.Is_Ok (Status) then
                  Mark_Imported (Kind, To_String (Id));
                  Result.Created := Result.Created + 1;
                  Result.Made.Append (To_String (Id));
                  Made_Texts.Append (Field (Next.Text));
                  Made_Sources.Append (Field (Next.Source));
               end if;
               --  Its identifier held by another: made under its own, and
               --  said, as a requirement's is.
               if E.Is_Ok (Status) and then Taken and then To_String (Id) /= Given then
                  declare
                     Said : Results.Result :=
                       (Kind       => Results.Diagnostic,
                        Producer   => To_Unbounded_String ("bootstrap"),
                        Summary    => To_Unbounded_String
                                        (Field (Next.Source) & " gives " & Given
                                         & ", which the project already has; it was made as "
                                         & To_String (Id) & ", " & State_Said (Intent.First_State (Kind))
                                         & " -- give it an identifier the project does not have in "
                                         & Field (Next.Source) & ", and "
                                         & (case Kind is
                                               when Intent.Decision      => "/decision",
                                               when Intent.Specification => "/spec",
                                               when Intent.Requirement   => "/req")
                                         & " reject " & To_String (Id) & " takes the one made here"
                                         & " away"),
                        Payload    => Next.Text,
                        Provenance => Next.Provenance,
                        others     => <>);
                  begin
                     Raise_Issue (Said);
                  end;
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
                     elsif E.Is_Ok (Status)
                       and then (Held.Confidence in Facts.Authoritative | Facts.Certain
                                 or else Held.Source in Facts.Explicit | Facts.Template)
                     then
                        --  A document does not outweigh what the template or
                        --  the project's own files say: the disagreement is
                        --  an issue for someone to settle, and the fact
                        --  stays.
                        declare
                           Said : Results.Result :=
                             (Kind       => Results.Diagnostic,
                              Producer   => To_Unbounded_String ("bootstrap"),
                              Summary    => To_Unbounded_String
                                              (Field (Next.Source) & " says " & Field (Next.Key)
                                               & " = " & Field (Next.Text) & ", which the project"
                                               & " has as " & To_String (Held.Value)),
                              Payload    => Next.Text,
                              Provenance => Next.Provenance,
                              others     => <>);
                        begin
                           Status := E.Success;
                           Raise_Issue (Said);
                        end;
                     else
                        Facts.Record_Fact
                          (Item, Change,
                           (Key        => Next.Key,
                            Value      => Next.Text,
                            Source     => Facts.Heuristic,
                            Confidence => Facts.Probable,
                            Origin     => Next.Source),
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
                     --  The same item again: where the policy takes the
                     --  document's word, what its line now says is the next
                     --  revision; otherwise a person decides.
                     Again (Intent.Requirement,
                            Intent.Find_By_Provenance (Item, Intent.Requirement, Provenance),
                            Settled => Document_Rules);
                  else
                     --  Under the identifier the document gives it -- unless
                     --  something else holds it: then made under another,
                     --  and left for a person to accept, for the document
                     --  and the project disagree.
                     declare
                        Given : constant String :=
                          Provenance (Ada.Strings.Fixed.Index (Provenance, "#") + 1
                                      .. Provenance'Last);
                        Held   : Records.Item;
                        Staged : Boolean;
                        Moved  : Boolean;
                     begin
                        if Adopted (Intent.Requirement, Given) then
                           goto Next_Output;
                        end if;
                        Moved := False;
                        if Stores.Is_Name (Given) then
                           Stores.Pending (Change, Requirements_Area, Given, Held, Staged);
                           Moved := Staged or else Stores.Exists (Item, Requirements_Area, Given);
                        end if;
                        Intent.Propose
                          (Item, Change, Intent.Requirement, Field (Next.Key),
                           Field (Next.Title), Field (Next.Text), Field (Next.Criteria),
                           Field (Next.Source), Provenance, "project", Id, Status,
                           Given => Given);
                        Moved := Moved and then E.Is_Ok (Status);
                        if E.Is_Ok (Status) then
                           Mark_Imported (Intent.Requirement, To_String (Id));
                        end if;
                        if E.Is_Ok (Status) and then Accept_Imports and then not Moved then
                           Intent.Move
                             (Item, Change, Intent.Requirement, To_String (Id),
                              "accepted", Transitions.Ordinary_Only, Status);
                        end if;
                        if E.Is_Ok (Status) then
                           Result.Created := Result.Created + 1;
                           Result.Made.Append (To_String (Id));
                           Made_Texts.Append (Field (Next.Text));
                           Made_Sources.Append (Field (Next.Source));
                        end if;
                        if Moved then
                           declare
                              Said : Results.Result :=
                                (Kind       => Results.Diagnostic,
                                 Producer   => To_Unbounded_String ("bootstrap"),
                                 Summary    => To_Unbounded_String
                                                 (Field (Next.Source) & " gives " & Given
                                                  & (if Intent.Find_By_Provenance
                                                          (Item, Intent.Requirement,
                                                           Field (Next.Source) & "#" & Given) /= ""
                                                     then " twice; the second"
                                                     else ", which the project already has; it")
                                                  & " was made as " & To_String (Id)
                                                  & ", a candidate"),
                                 Payload    => Next.Text,
                                 Provenance => Next.Provenance,
                                 others     => <>);
                           begin
                              Raise_Issue (Said);
                           end;
                        end if;
                     end;
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
                     Raise_Issue (Said);
                  end;
            end case;

            if E.Is_Error (Status) then
               return;
            end if;
         end;
         <<Next_Output>>
      end loop;

      --  What came from a document it read and that document no longer
      --  says: an issue for a person, who retires it or keeps it -- with
      --  what was made from the document now, which may be its successor.
      declare
         Read_From : Name_Lists.Vector;
         Said_Now  : Name_Lists.Vector;
      begin
         for Next of Found.Outputs loop
            if not Read_From.Contains (Field (Next.Source)) then
               Read_From.Append (Field (Next.Source));
            end if;
            Said_Now.Append (Field (Next.Provenance));
         end loop;
         for Kind in Intent.Requirement .. Intent.Decision loop
            for Known of Intent.List (Item, Kind) loop
               declare
                  Held : Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Intent.Read (Item, Kind, Known, Held, Read);
                  if E.Is_Ok (Read)
                    and then Read_From.Contains (To_String (Held.Source))
                    and then Length (Held.Provenance) > 0
                    and then not Said_Now.Contains (To_String (Held.Provenance))
                    and then not Rewritten.Contains (Known)
                    and then To_String (Held.State) not in "obsolete" | "superseded" | "rejected"
                  then
                     declare
                        Instead : Unbounded_String;
                        Said    : Results.Result;
                        Why     : constant String :=
                          Known & ": " & To_String (Held.Source) & " no longer says it";

                        --  Of its own register: a decision is not replaced by
                        --  a requirement.
                        function Same_Kind (Made : String) return Boolean
                        is (Made'Length > 4 and then Known'Length > 4
                            and then Made (Made'First .. Made'First + 3)
                                     = Known (Known'First .. Known'First + 3));
                     begin

                        --  The one made now whose words are most like its own,
                        --  where more than half of them are: its new wording,
                        --  most likely.
                        declare
                           Best  : Natural := 0;
                           Score : Float := 0.5;
                        begin
                           for Index in 1 .. Natural (Result.Made.Length) loop
                              if Made_Sources (Index) = To_String (Held.Source)
                                and then Same_Kind (Result.Made (Index))
                                and then Likeness (To_String (Held.Text), Made_Texts (Index)) > Score
                              then
                                 Score := Likeness (To_String (Held.Text), Made_Texts (Index));
                                 Best := Index;
                              end if;
                           end loop;
                           if Best > 0 then
                              Instead := To_Unbounded_String
                                (Result.Made (Best) & ", most like it -- "
                                 & (if Intent."=" (Kind, Intent.Decision) then "/decision" else "/req")
                                 & " supersede " & Known
                                 & " " & Result.Made (Best) & " keeps it as that one's history");
                           end if;
                        end;
                        Said :=
                          (Kind       => Results.Diagnostic,
                           Producer   => To_Unbounded_String ("bootstrap"),
                           Summary    => To_Unbounded_String
                                           (Why & "; "
                                            & (if Intent."=" (Kind, Intent.Decision) then "/decision "
                                               else "/req ")
                                            & (if To_String (Held.State) = Intent.First_State (Kind)
                                               then "reject " else "obsolete ")
                                            & Known & " retires it, or keep it as it is -- nothing"
                                            & " needs doing then, this is not raised again, and"
                                            & " /result dismiss ID takes it off the list"
                                            & (if Instead = Null_Unbounded_String then ""
                                               else "; made from the document now: "
                                                    & To_String (Instead))),
                           Payload    => Held.Text,
                           Provenance => Held.Provenance,
                           others     => <>);
                        Raise_Issue (Said);
                        if E.Is_Error (Status) then
                           return;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end loop;
      end;

      --  What it did, kept as a result: each output it was given, and how
      --  many it made, found there already, and raised as issues.
      declare
         Listed : Unbounded_String;
         Kept   : Results.Result;
      begin
         for Next of Found.Outputs loop
            Append (Listed, Output_Kind'Image (Next.Kind) & ASCII.HT & Next.Provenance & ASCII.LF);
         end loop;
         Kept :=
           (Kind       => Results.Bootstrap_Report,
            Producer   => To_Unbounded_String ("bootstrap"),
            Summary    => To_Unbounded_String
                            (Image (Result.Created) & " made, "
                             & Image (Natural (Result.Revised.Length)) & " revised, "
                             & Image (Result.Existing) & " there already, "
                             & Image (Result.Issues) & " new issues"),
            Payload    => Listed,
            others     => <>);
         Results.Add (Item, Change, Kept, Status);
      end;
   end Apply;

end Model_Runner.Framework.Bootstrap;
