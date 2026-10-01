with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Files;
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
   --  What a line says of a record's standing, where it is a status line
   --  in any of the ways documents write one -- Status: Accepted, * Status:
   --  Accepted, :Status: Accepted, **Status:** Accepted, | Status | Accepted
   --  | -- its value; "" for any other line.
   function Status_Said (Raw : String) return String is
      Line  : constant String := Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both);
      Lower : constant String := Ada.Characters.Handling.To_Lower (Line);
      Words : constant Name_Lists.Vector :=
        ["accepted", "proposed", "draft", "superseded", "deprecated", "rejected", "withdrawn", "obsolete",
         "approved", "replaced"];

      function Cleaned (Value : String) return String
      is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Maps.To_Set (" *_`"), Ada.Strings.Maps.To_Set (" *_`")));
   begin
      if Line'Length > 1 and then Line (Line'First) = '|' then
         --  A row of a table of particulars: Status, then its value.
         declare
            Cells : Name_Lists.Vector;
            Start : Natural := Line'First + 1;
         begin
            for Index in Line'First + 1 .. Line'Last + 1 loop
               if Index > Line'Last or else Line (Index) = '|' then
                  if Ada.Strings.Fixed.Trim (Line (Start .. Index - 1), Ada.Strings.Both) /= ""
                    or else Index <= Line'Last
                  then
                     Cells.Append (Cleaned (Line (Start .. Index - 1)));
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            if Natural (Cells.Length) >= 2 and then Ada.Characters.Handling.To_Lower (Cells (1)) = "status"
              and then (for some Word of Words =>
                          Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Cells (2)), Word) = 1)
            then
               return Cells (2);
            end if;
            return "";
         end;
      end if;
      for Lead of Name_Lists.Vector'(["status:", "* status:", "- status:", ":status:", "**status:**", "**status**:",
                                       "* **status:**", "- **status:**", "*status:*", "_status:_"])
      loop
         if Lower'Length > Lead'Length and then Lower (Lower'First .. Lower'First + Lead'Length - 1) = Lead then
            return Cleaned (Line (Line'First + Lead'Length .. Line'Last));
         end if;
      end loop;
      return "";
   end Status_Said;

   --  A decision record's label as it is said: ADR-0004 and adr 4 both
   --  ADR-4, so that one project's records read alike.
   function Adr_Said (Text : String) return String is
      Lower  : constant String := Ada.Characters.Handling.To_Lower (Text);
      Result : Unbounded_String;
      At_Char : Natural := Text'First;
   begin
      while At_Char <= Text'Last loop
         if At_Char + 3 <= Text'Last and then Lower (At_Char .. At_Char + 2) = "adr"
           and then Text (At_Char + 3) in ' ' | '-'
           and then (At_Char = Text'First or else Lower (At_Char - 1) not in 'a' .. 'z')
           and then At_Char + 4 <= Text'Last and then Text (At_Char + 4) in '0' .. '9'
         then
            declare
               Stop : Natural := At_Char + 4;
            begin
               while Stop < Text'Last and then Text (Stop + 1) in '0' .. '9' loop
                  Stop := Stop + 1;
               end loop;
               Append (Result, "ADR-" & Ada.Strings.Fixed.Trim
                                          (Natural'Image (Natural'Value (Text (At_Char + 4 .. Stop))),
                                           Ada.Strings.Both));
               At_Char := Stop + 1;
            end;
         else
            Append (Result, Text (At_Char));
            At_Char := At_Char + 1;
         end if;
      end loop;
      return To_String (Result);
   exception
      when others =>
         return Text;
   end Adr_Said;

   --  Whether a status says a record is no longer in force.
   function Retired_Status (Said : String) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Said);
   begin
      return (for some Word of Name_Lists.Vector'(["supersede", "deprecate", "reject", "withdrawn", "obsolete",
                                                    "replaced"]) =>
                Ada.Strings.Fixed.Index (Lower, Word) > 0);
   end Retired_Status;

   function Says_Requirement (Item : String; Listed : Boolean) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Item);
   begin
      --  What a document says of itself -- This document states what it
      --  must do -- is about the document, not a requirement.
      if (for some Opening of Name_Lists.Vector'(["this document", "this section", "this specification",
                                                  "this file", "this chapter"]) =>
            Lower'Length >= Opening'Length and then Lower (Lower'First .. Lower'First + Opening'Length - 1) = Opening)
      then
         return False;
      end if;
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
      if Index - First_Letter not in 1 .. 8 or else Index > Item'Last then
         return;
      end if;
      --  R1. and A1: a short label without its dash, letters then digits,
      --  closed by a mark -- . : ) -- or bold or brackets.
      if Item (Index) in '0' .. '9' then
         declare
            Digits_End : Natural := Index;
         begin
            while Digits_End < Item'Last and then Item (Digits_End + 1) in '0' .. '9' loop
               Digits_End := Digits_End + 1;
            end loop;
            if Digits_End - Index > 3 or else Digits_End >= Item'Last
              or else Item (Digits_End + 1) not in '.' | ':' | ')' | '*' | ']' | ' '
            then
               return;
            end if;
            Index := Digits_End + 1;
            Skip (".:)*]`_");
            if Index <= Item'Last and then Item (Index) /= ' ' then
               return;
            end if;
            Skip (" :-");
            --  An em dash or an en dash after it.
            while Index + 2 <= Item'Last and then Item (Index) = Character'Val (16#E2#)
              and then Item (Index + 1) = Character'Val (16#80#)
              and then Item (Index + 2) in Character'Val (16#93#) | Character'Val (16#94#)
            loop
               Index := Index + 3;
               Skip (" ");
            end loop;
            if Index > Item'Last then
               return;
            end if;
            Label := To_Unbounded_String (Item (First_Letter .. Digits_End));
            Rest := To_Unbounded_String (Item (Index .. Item'Last));
            return;
         end;
      end if;
      if Item (Index) /= '-' then
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
      --  An em dash or an en dash after it: **CACHE-INV-001** -- Put then Get.
      while Index + 2 <= Item'Last and then Item (Index) = Character'Val (16#E2#)
        and then Item (Index + 1) = Character'Val (16#80#)
        and then Item (Index + 2) in Character'Val (16#93#) | Character'Val (16#94#)
      loop
         Index := Index + 3;
         Skip (" ");
      end loop;
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

   function Headline (Text : String) return String is
   begin
      if Text'Length <= 100 then
         return Text;
      end if;
      --  Cut at a word, not inside one.
      for Cut in reverse Text'First + 60 .. Text'First + 96 loop
         if Text (Cut) = ' ' then
            return Text (Text'First .. Cut - 1) & " ...";
         end if;
      end loop;
      return Text (Text'First .. Text'First + 96) & "...";
   end Headline;

   ----------
   -- Scan --
   ----------

   function Scan_Markdown (Path : String; Text : String) return Output_List is
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

      --  The requirement an "Acceptance criteria for REQ-001:" line named,
      --  whose criteria the list under it is.
      Criteria_For : Natural := 0;

      --  A document of requirements, by its name or its first heading:
      --  each labelled line in it is one, whatever words it uses.
      function Of_Requirements return Boolean is
         Lower_Path : constant String := Ada.Characters.Handling.To_Lower (Path);
         Heading_At : constant Natural := Ada.Strings.Fixed.Index (Text, "# ");
         Heading_End : constant Natural :=
           (if Heading_At = 0 then 0 else Ada.Strings.Fixed.Index (Text (Heading_At .. Text'Last), [1 => ASCII.LF]));
         Heading : constant String :=
           (if Heading_At = 0 then ""
            else Ada.Characters.Handling.To_Lower
                   (Text (Heading_At .. (if Heading_End = 0 then Text'Last else Heading_End - 1))));
      begin
         return (for some Word of Name_Lists.Vector'
                   (["requirement", "invariant", "acceptance", "srs", "criteria", "specification"])
                 => Ada.Strings.Fixed.Index (Lower_Path, Word) > 0
                    or else Ada.Strings.Fixed.Index (Heading, Word) > 0);
      exception
         when others =>
            return False;
      end Of_Requirements;
      Requirements_Here : constant Boolean := Of_Requirements;

      --  A document about how the project is worked on, or what it decided,
      --  is not a specification of it.
      Lower_Name : constant String := Ada.Characters.Handling.To_Lower (Ada.Directories.Simple_Name (Path));
      Process_Document : constant Boolean :=
        (for some Word of Name_Lists.Vector'
           (["decision", "adr", "contributing", "code_of_conduct", "conduct", "security", "process",
             "workflow", "release", "governance", "support", "maintain", "style", "todo"])
         => Ada.Strings.Fixed.Index (Lower_Name, Word) > 0)
        or else Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Path), "/adr/") > 0;

      --  A to-do list: its open boxes are what is wanted.
      Todo_Document : constant Boolean := Ada.Strings.Fixed.Index (Lower_Name, "todo") > 0;

      --  Under a heading of decisions: each listed line is one.
      Decisions_Here : Boolean := False;

      --  Under a heading of requirements: an item there that states none
      --  is said, not dropped without a word.
      Requirements_Heading : Boolean := False;

      --  Under a heading about how the project is released or worked on --
      --  a release checklist -- a must is the team's, not the product's.
      Process_Here : Boolean := False;

      --  A heading a document's own label opens -- ### FR-001 Capacity --
      --  whose first line stating a requirement is that requirement.
      Pending_Label : Unbounded_String;
      Pending_Title : Unbounded_String;

      --  A requirement whose line leads into a list -- SHALL distinguish:
      --  -- and so takes the items that follow as part of what it says.
      Lead : Natural := 0;

      --  Text as it reads, its markup off: **bold** and __bold__ marks
      --  dropped, and a link [words](target) its words.
      function Plain (Text : String) return String is
         Output : Unbounded_String;
         Index  : Natural := Text'First;
      begin
         while Index <= Text'Last loop
            --  Emphasis, and reStructuredText's literal marks, are no
            --  part of the words.
            if Index < Text'Last and then Text (Index .. Index + 1) in "**" | "__" | "``" then
               Index := Index + 2;
            elsif Text (Index) = '['
              and then Ada.Strings.Fixed.Index (Text (Index .. Text'Last), "](") > 0
              and then Ada.Strings.Fixed.Index
                         (Text (Ada.Strings.Fixed.Index (Text (Index .. Text'Last), "](") .. Text'Last), ")") > 0
            then
               declare
                  Close  : constant Natural := Ada.Strings.Fixed.Index (Text (Index .. Text'Last), "](");
                  Finish : constant Natural := Ada.Strings.Fixed.Index (Text (Close .. Text'Last), ")");
               begin
                  Append (Output, Text (Index + 1 .. Close - 1));
                  Index := Finish + 1;
               end;
            else
               Append (Output, Text (Index));
               Index := Index + 1;
            end if;
         end loop;
         return To_String (Output);
      end Plain;

      --  A title that is a bold lead-in, **Title.** and more after it: the
      --  bold part, not the sentence after it.
      function Lead_In (Title : String) return String is
         First  : constant Natural := Ada.Strings.Fixed.Index (Title, "**");
         Second : constant Natural :=
           (if First = 0 then 0 else Ada.Strings.Fixed.Index (Title (First + 2 .. Title'Last), "**"));
         Cut    : constant Natural :=
           (if Second > 0 then Second
            elsif First > Title'First + 1 then First
            else 0);
         Kept   : constant String :=
           Trim (Plain (if Cut = 0 then Title else Title (Title'First .. Cut - 1)));
      begin
         return (if Kept'Length > 1 and then Kept (Kept'Last) = '.' then Kept (Kept'First .. Kept'Last - 1)
                 else Kept);
      end Lead_In;

      --  A requirement's title without the section number a document
      --  numbers it by: 2.5 The core shall ... is The core shall ...
      function Unsectioned (Title : String) return String is
         Stop : Natural := Title'First;
      begin
         while Stop <= Title'Last and then Title (Stop) in '0' .. '9' | '.' loop
            Stop := Stop + 1;
         end loop;
         return (if Stop > Title'First + 1 and then Stop < Title'Last and then Title (Stop) = ' '
                   and then Ada.Strings.Fixed.Index (Title (Title'First .. Stop - 1), ".") > 0
                   and then Title (Stop + 1) in 'A' .. 'Z' | 'a' .. 'z'
                 then Title (Stop + 1 .. Title'Last) else Title);
      end Unsectioned;

      procedure Found
        (Kind : Output_Kind; Provenance, Title, Body_Text : String; Given : String := "")
      is
      begin
         Append
           (Result,
            (Kind       => Kind,
             Provenance => To_Unbounded_String (Provenance),
             Key        => To_Unbounded_String (Key),
             Title      => To_Unbounded_String
                             (if Kind = Requirement_Candidate then Unsectioned (Lead_In (Title))
                              else Lead_In (Title)),
             --  A document read whole keeps its markup; a line, its words.
             Text       => To_Unbounded_String
                             (if Kind = Specification_Candidate then Body_Text else Plain (Body_Text)),
             Source     => To_Unbounded_String (Path),
             Criteria   => Null_Unbounded_String,
             Given_Id   => To_Unbounded_String (Given),
             Status     => Null_Unbounded_String));
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
            --  A task box, - [ ] or - [x], is not what the item says.
            declare
               Item : constant String := Trim (Line (Line'First + 2 .. Line'Last));
            begin
               return (if Item'Length > 4 and then Item (Item'First) = '['
                         and then Item (Item'First + 1) in ' ' | 'x' | 'X'
                         and then Item (Item'First + 2 .. Item'First + 3) = "] "
                       then Trim (Item (Item'First + 4 .. Item'Last))
                       else Item);
            end;
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
                     --  A cell that is a label alone -- FR-1, A1 -- read as
                     --  one, with a colon after it as a line would have.
                     Label_Split (Cell & ": x", Label, After);
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

         --  A table row's status cell -- superseded, deprecated, rejected:
         --  what the row says of itself, or "".
         --  A table row's cells, the last one too where the row does not
         --  close with a bar, as AsciiDoc's do not.
         function Row_Cells return Name_Lists.Vector is
            Cells : Name_Lists.Vector;
            Start : Natural := Line'First + 1;
         begin
            if Line = "" or else Line (Line'First) /= '|' then
               return Cells;
            end if;
            for Index in Line'First + 1 .. Line'Last + 1 loop
               if Index > Line'Last or else Line (Index) = '|' then
                  if Index <= Line'Last or else Trim (Line (Start .. Line'Last)) /= "" then
                     Cells.Append (Trim (Line (Start .. Index - 1)));
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            return Cells;
         end Row_Cells;

         function Row_Status return String is
         begin
            for Cell of Row_Cells loop
               declare
                  Lower : constant String := Ada.Characters.Handling.To_Lower (Cell);
               begin
                  if Lower in "superseded" | "deprecated" | "rejected" | "withdrawn" | "obsolete"
                    or else (Lower'Length > 14 and then Lower (Lower'First .. Lower'First + 13) = "superseded by ")
                  then
                     return Lower;
                  end if;
               end;
            end loop;
            return "";
         end Row_Status;
      begin
         --  A row that marks itself retired: not proposed, and what was made
         --  of it before is retired with it.
         if Row_Status /= "" then
            Label_Split (Item, Label, Rest);
            if Label /= Null_Unbounded_String then
               Found (Issue, Path & "#" & To_String (Label) & "#retired",
                      To_String (Label) & " is " & Row_Status & ", so it is not proposed: "
                      & Headline (Trim (To_String (Rest))),
                      Row_Status);
               return;
            end if;
         end if;

         --  A row of a register of decisions -- ADR-1 | Title | Accepted --
         --  is that decision, with the status its row gives it.
         if Line'Length > 1 and then Line (Line'First) = '|' then
            declare
               Cells : constant Name_Lists.Vector := Row_Cells;
               First_Cell : constant String := (if Cells.Is_Empty then "" else Cells.First_Element);
            begin
               if Natural (Cells.Length) >= 2 and then First_Cell'Length > 4
                 and then Ada.Characters.Handling.To_Upper (First_Cell (First_Cell'First .. First_Cell'First + 3))
                          = "ADR-"
                 and then (for all C of First_Cell (First_Cell'First + 4 .. First_Cell'Last) => C in '0' .. '9')
               then
                  Found (Decision_Candidate, Path & "#" & First_Cell, First_Cell & ": " & Cells (2), Cells (2));
                  for Cell of Cells loop
                     if Status_Said ("Status: " & Cell) /= ""
                       and then (for some Word of Name_Lists.Vector'(["accepted", "proposed", "approved", "draft"]) =>
                                   Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Cell), Word) = 1)
                     then
                        declare
                           Held : Output := Result.Outputs (Length (Result));
                        begin
                           Held.Status := To_Unbounded_String (Cell);
                           Result.Outputs (Length (Result)) := Held;
                        end;
                     end if;
                  end loop;
                  return;
               end if;
            end;
         end if;

         --  A to-do list's open box is work wanted: a candidate requirement
         --  in its words; a ticked one is done, and nothing is made of it.
         if Todo_Document and then Line'Length > 6 and then Line (Line'First) in '-' | '*' | '+'
           and then Ada.Characters.Handling.To_Lower (Line (Line'First + 1 .. Line'First + 5)) in " [ ] " | " [x] "
         then
            if Line (Line'First + 3) = ' ' and then not Seen.Contains (Fingerprint (Item)) then
               Seen.Append (Fingerprint (Item));
               Found (Requirement_Candidate, Path & "#" & Fingerprint (Item), Headline (Item), Item);
            elsif Line (Line'First + 3) /= ' ' then
               --  Ticked: done, so not proposed -- said, not left unsaid.
               Found (Issue, Path & "#" & Fingerprint (Item) & "#retired",
                      "an item ticked as done in " & Path & ", so it is not proposed: " & Headline (Item), "done");
            end if;
            return;
         end if;

         --  A ticked box -- - [x] -- is done already: said, as work taken
         --  as done, not done again; what it says is read as ever. Only
         --  one the document labels is made at once, with a task for it.
         Label_Split (Item, Label, Rest);
         if Line'Length > 6 and then Line (Line'First) in '-' | '*' | '+'
           and then Ada.Characters.Handling.To_Lower (Line (Line'First + 1 .. Line'First + 5)) = " [x] "
           and then Label /= Null_Unbounded_String
           --  Only what is made a requirement has a task to take as done.
           and then (Says_Requirement (Item, True) or else Requirements_Here
                     or else (Length (Label) > 4 and then Slice (Label, 1, 4) = "REQ-"))
         then
            Found (Issue, Path & "#" & (if Label /= Null_Unbounded_String then To_String (Label)
                                        else Fingerprint (Item)) & "#done",
                   (if Label /= Null_Unbounded_String then To_String (Label) else Headline (Item))
                   & " is marked done in " & Path & ": once it is accepted, /task complete takes the task"
                   & " derived for it as done, its checks passing, rather than /work doing it again",
                   Item);
         end if;
         Label := Null_Unbounded_String;
         Rest := Null_Unbounded_String;

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
                  --  A document that says nothing past its headings
                  --  specifies nothing: not made a specification.
                  if not Process_Document
                    and then (for some One of Lines_Of (Text) =>
                                Trim (One) /= "" and then Trim (One) (Trim (One)'First) /= '#')
                  then
                     Found (Specification_Candidate, Path, Heading, Text);
                  end if;
               end if;
               Process_Here :=
                 (for some Word of Name_Lists.Vector'(["release", "checklist", "contributing", "how to contribute"])
                  => Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Heading), Word) > 0);
               Decisions_Here :=
                 Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Heading), "decision") > 0
                 and then Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Heading), "decision ") = 0;
               Requirements_Heading :=
                 Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Heading), "requirement") > 0;

               --  ## REQ-SHELL-001 Quoting: the requirement, at once, with
               --  its identifier and title; what its section says is its
               --  statement, and its Acceptance: lines its criteria.
               Section := 0;
               Criteria_For := 0;
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
               --  ### REQ-004: Title -- the project's own identifier, at any
               --  heading level and with a colon: imported, as ## REQ-004 is.
               elsif Length (Label) > 4 and then Slice (Label, 1, 4) = "REQ-"
                 and then Identifiers.Is_Valid (To_String (Label))
               then
                  Found (Imported_Item, Path & "#" & To_String (Label),
                         (if Length (Rest) = 0 then To_String (Label) else Trim (To_String (Rest))), "",
                         Given => To_String (Label));
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

         --  The criteria of a requirement named: Acceptance criteria for
         --  REQ-001: and the list under it, its criteria.
         if Criteria_For > 0 and then Listed then
            declare
               Held : Output := Result.Outputs (Criteria_For);
            begin
               Held.Criteria :=
                 (if Held.Criteria = Null_Unbounded_String then To_Unbounded_String (Item)
                  else Held.Criteria & ASCII.LF & Item);
               Result.Outputs (Criteria_For) := Held;
            end;
            return;
         end if;
         Criteria_For := 0;
         if Starts_With (Item, "Acceptance criteria for ") and then Colon > 0 then
            declare
               Named : constant String :=
                 Trim (Ada.Strings.Fixed.Trim (Item (Item'First + 24 .. Colon - 1),
                                               Ada.Strings.Maps.To_Set ("*[]` "), Ada.Strings.Maps.To_Set ("*[]` ")));
            begin
               for Index in 1 .. Length (Result) loop
                  if To_String (Result.Outputs (Index).Provenance) = Path & "#" & Named then
                     Criteria_For := Index;
                     if Trim (Item (Colon + 1 .. Item'Last)) /= "" then
                        declare
                           Held : Output := Result.Outputs (Index);
                        begin
                           Held.Criteria := To_Unbounded_String (Trim (Item (Colon + 1 .. Item'Last)));
                           Result.Outputs (Index) := Held;
                        end;
                     end if;
                  end if;
               end loop;
               if Criteria_For > 0 then
                  return;
               end if;
            end;
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
            --  A label that is a requirement's identifier is the one it is
            --  made under, where the project does not hold it already.
            declare
               Own : constant Boolean :=
                 Length (Pending_Label) > 4 and then Slice (Pending_Label, 1, 4) = "REQ-"
                 and then Identifiers.Is_Valid (To_String (Pending_Label));
            begin
               Found ((if Own then Imported_Item else Requirement_Candidate),
                      Path & "#" & To_String (Pending_Label),
                      (if Own then Headline (To_String (Pending_Title))
                       else To_String (Pending_Label) & ": " & Headline (To_String (Pending_Title))),
                      Item, Given => (if Own then To_String (Pending_Label) else ""));
            end;
            Pending_Label := Null_Unbounded_String;
            Section := Length (Result);
            return;
         end if;

         --  A line the project's own identifier begins, however marked --
         --  **REQ-001**:, [REQ-002], REQ-003 | text, REQ-004: Title --
         --  statement -- is that requirement, imported under it, as its
         --  heading form is: the identifier is not its title.
         Label_Split (Item, Label, Rest);
         if Length (Label) > 4 and then Slice (Label, 1, 4) = "REQ-"
           and then Identifiers.Is_Valid (To_String (Label))
         then
            declare
               Said  : constant String :=
                 Trim (Ada.Strings.Fixed.Trim (To_String (Rest), Ada.Strings.Maps.To_Set ("|:-* "),
                                               Ada.Strings.Maps.Null_Set));
               Dash  : constant Natural := Ada.Strings.Fixed.Index (Said, " -- ");
               Title : constant String := (if Dash > 0 then Trim (Said (Said'First .. Dash - 1)) else "");
               Body_Text : constant String :=
                 (if Dash > 0 then Trim (Said (Dash + 4 .. Said'Last)) else Said);
            begin
               if Said = "" or else (Dash = 0 and then not Says_Requirement (Said, True)
                                      and then Said (Said'Last) not in '.' | '!' | '?')
               then
                  --  Its title alone: its statement follows.
                  Pending_Label := Label;
                  Pending_Title := To_Unbounded_String (Said);
               else
                  Found (Imported_Item, Path & "#" & To_String (Label),
                         (if Title /= "" then Title else Headline (Body_Text)), Body_Text,
                         Given => To_String (Label));
               end if;
               return;
            end;
         end if;

         --  A line a document's own label begins -- FR-001, [NFR-01],
         --  **R-10** -- is known by it: the label kept in its title, and
         --  what it is found again by when the line is reworded.
         if Label /= Null_Unbounded_String
           and then not (Length (Label) > 4 and then Slice (Label, 1, 4) in "REQ-" | "DEC-")
           and then (Says_Requirement (To_String (Rest), True)
                     or else (Requirements_Here and then Listed))
         then
            Found (Requirement_Candidate, Path & "#" & To_String (Label),
                   To_String (Label) & ": " & Headline (To_String (Rest)), To_String (Rest));
            if To_String (Rest) (Length (Rest)) = ':' then
               Lead := Length (Result);
            end if;
            return;
         end if;

         --  A listed line an ADR- or DEC- label begins, or any listed line
         --  under a heading of decisions, is a decision.
         if Listed then
            Label_Split (Item, Label, Rest);
            if (Length (Label) > 4 and then Slice (Label, 1, 4) = "ADR-") or else Decisions_Here then
               declare
                  Said : constant String :=
                    (if Label = Null_Unbounded_String then Item else Trim (To_String (Rest)));
                  Mark : constant String :=
                    (if Label = Null_Unbounded_String then Headline (Item) else To_String (Label));
               begin
                  if Said /= "" then
                     Found (Decision_Candidate, Path & "#" & Mark,
                            (if Label = Null_Unbounded_String then Headline (Said)
                             else Mark & ": " & Headline (Said)), Said);
                     return;
                  end if;
               end;
            end if;
         --  A sentence of its own under a heading of decisions -- not a
         --  list, not a requirement -- is a decision too.
         elsif Decisions_Here and then Item'Length > 10 and then Item (Item'Last) = '.'
           and then not Says_Requirement (Item, False)
         then
            Found (Decision_Candidate, Path & "#" & Fingerprint (Item), Headline (Item), Item);
            return;
         end if;

         --  In a document of decisions, a listed D1: text is one.
         if Listed and then Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Path), "decision") > 0
           and then Colon > Item'First + 1
           and then Item (Item'First) in 'A' .. 'Z'
           and then not Starts_With (Item, "REQ-")
           and then (for all C of Item (Item'First .. Colon - 1) => C in 'A' .. 'Z' | '0' .. '9' | '-')
           and then (for some C of Item (Item'First .. Colon - 1) => C in '0' .. '9')
         then
            Found (Decision_Candidate, Path & "#" & Item (Item'First .. Colon - 1),
                   Item (Item'First .. Colon - 1) & ": " & Headline (Trim (Item (Colon + 1 .. Item'Last))),
                   Trim (Item (Colon + 1 .. Item'Last)));
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
         if Section > 0 and then Status_Said (Line) /= ""
           and then Result.Outputs (Section).Kind = Decision_Candidate
         then
            --  A decision's status: kept as what it says of itself, not as
            --  its text; one no longer in force is not proposed.
            declare
               Held : Output := Result.Outputs (Section);
            begin
               Held.Status := To_Unbounded_String (Status_Said (Line));
               if Retired_Status (Status_Said (Line)) then
                  Held.Kind := Issue;
                  Held.Provenance := Held.Provenance & "#retired";
                  Held.Title := Held.Title & " is " & Ada.Characters.Handling.To_Lower (Status_Said (Line))
                    & ", so it is not proposed";
                  Held.Text := To_Unbounded_String (Ada.Characters.Handling.To_Lower (Status_Said (Line)));
               end if;
               Result.Outputs (Section) := Held;
            end;
            return;
         end if;
         if Section > 0 and then Status_Said (Line) /= "" then
            --  Its status is no part of what it says: done already, it is
            --  said, as work a person takes as done, not does again.
            declare
               Held  : constant Output := Result.Outputs (Section);
               Said  : constant String := Ada.Characters.Handling.To_Lower (Status_Said (Line));
               Label : constant String :=
                 (if Held.Given_Id /= Null_Unbounded_String then To_String (Held.Given_Id)
                  else To_String (Held.Title));
            begin
               if Starts_With (Said, "implemented") or else Starts_With (Said, "done")
                 or else Starts_With (Said, "complete")
               then
                  Found (Issue, Path & "#" & Label & "#done",
                         Label & " is marked " & Said & " in " & Path & ": /task complete takes the task derived"
                         & " for it as done, its checks passing, rather than /work doing it again",
                         Item);
               end if;
            end;
            return;
         end if;
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

         if not Process_Here and then Says_Requirement (Item, Listed or else Requirements_Here) then
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
         elsif Requirements_Heading and then Listed and then not Process_Here
           and then Item'Length > 3 and then Item (Item'First) /= '#'
         then
            --  Listed as a requirement and stating none: said, with how it
            --  comes to count.
            Found (Issue, Path & "#" & Fingerprint (Item) & "#unstated",
                   "under a heading of requirements, this states no SHALL, MUST or SHOULD, so it is not"
                   & " proposed: " & Headline (Item) & " -- reword it so, or /req new TITLE text=... makes it",
                   Item);
         end if;
      end Line_Of;
      --  A paragraph wrapped over several lines is one line of what the
      --  document says: joined, so a requirement is not read from half a
      --  sentence. A line goes on the one before where that ended mid
      --  sentence and this one starts nothing of its own.
      Paragraph : Unbounded_String;

      --  A line that is a document's label and a short title, no more.
      function Labelled_Title (Raw : String) return Boolean is
         Label : Unbounded_String;
         Rest  : Unbounded_String;
      begin
         Label_Split (Unmarked (Raw), Label, Rest);
         return Label /= Null_Unbounded_String and then Length (Rest) in 1 .. 80
           and then Element (Rest, Length (Rest)) not in '.' | '!' | '?';
      end Labelled_Title;

      function Starts_Own (Raw : String) return Boolean is
         Label : Unbounded_String;
         Rest  : Unbounded_String;
      begin
         if Raw = "" or else Raw (Raw'First) in '#' | '|' | '>' then
            return True;
         end if;
         --  A list item: its mark and a space -- not a sentence that goes on
         --  with a number, "200 milliseconds."
         if Raw'Length > 1 and then Raw (Raw'First) in '-' | '*' | '+' and then Raw (Raw'First + 1) = ' ' then
            return True;
         end if;
         declare
            Digits_End : Natural := Raw'First - 1;
         begin
            while Digits_End < Raw'Last and then Raw (Digits_End + 1) in '0' .. '9' loop
               Digits_End := Digits_End + 1;
            end loop;
            if Digits_End >= Raw'First and then Digits_End + 2 <= Raw'Last
              and then Raw (Digits_End + 1) in '.' | ')' and then Raw (Digits_End + 2) = ' '
            then
               return True;
            end if;
         end;
         Label_Split (Raw, Label, Rest);
         return Label /= Null_Unbounded_String
           or else (for some Prefix of Name_Lists.Vector'(["Acceptance", "Fact:", "Decision", "Status:"])
                      => Starts_With (Raw, Prefix));
      end Starts_Own;

      --  How many of some sentences state a requirement.
      function Saying (Parts : Name_Lists.Vector) return Natural is
         Count : Natural := 0;
      begin
         for Part of Parts loop
            if Says_Requirement (Part, Requirements_Here) then
               Count := Count + 1;
            end if;
         end loop;
         return Count;
      end Saying;

      procedure Flush is
         Text : constant String := To_String (Paragraph);
         Parts : Name_Lists.Vector;
         Start : Positive := Text'First;
      begin
         if Paragraph = Null_Unbounded_String then
            return;
         end if;
         Paragraph := Null_Unbounded_String;
         --  A paragraph of prose that states several requirements is each
         --  of its sentences: one ends at a full stop a capital follows.
         if Text (Text'First) not in '#' | '|' | '>' | '-' | '*' | '+' then
            for Index in Text'First .. Text'Last - 2 loop
               if Text (Index) = '.' and then Text (Index + 1) = ' ' and then Text (Index + 2) in 'A' .. 'Z' then
                  Parts.Append (Text (Start .. Index));
                  Start := Index + 2;
               end if;
            end loop;
            Parts.Append (Text (Start .. Text'Last));
            if Natural (Parts.Length) > 1
              and then Saying (Parts) > 1
            then
               for Part of Parts loop
                  Line_Of (Part);
               end loop;
               return;
            end if;
         end if;
         Line_Of (Text);
      end Flush;

      --  The document's lines, as they are.
      function Lines return Name_Lists.Vector is
         All_Lines : Name_Lists.Vector;
         From      : Positive := Text'First;
      begin
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = ASCII.LF then
               All_Lines.Append (Trim (Text (From .. Index - 1)));
               From := Index + 1;
            end if;
         end loop;
         return All_Lines;
      end Lines;

      --  A decision record -- an ADR -- is one decision, read whole: what
      --  its Decision section says, or else its body, under its title;
      --  its Status kept with it. It is one by its place (adr/,
      --  decisions/) or by its first heading: ADR-1, ADR 0001, or the
      --  numbered "2. Use JSON" adr-tools writes, with a Status section.
      function Decision_Record return Boolean is
         Every    : constant Name_Lists.Vector := Lines;
         Lower    : constant String := Ada.Characters.Handling.To_Lower (Path);
         Heading  : Unbounded_String;
         Has_Status : Boolean := False;
         Has_Decision : Boolean := False;
         Links    : Natural := 0;
         Labelled : Natural := 0;
         Content  : Natural := 0;

         --  A line without its list mark.
         function Bare (Line : String) return String
         is (if Line'Length > 2 and then Line (Line'First) in '*' | '-' | '+' and then Line (Line'First + 1) = ' '
             then Trim (Line (Line'First + 2 .. Line'Last)) else Line);
      begin
         for Line of Every loop
            if Heading = Null_Unbounded_String and then Line'Length > 2 and then Line (Line'First) = '#'
              and then Line (Line'First + 1) = ' '
            then
               Heading := To_Unbounded_String (Trim (Line (Line'First + 2 .. Line'Last)));
            end if;
            Has_Status := Has_Status or else Starts_With (Bare (Line), "Status:") or else Status_Said (Line) /= ""
              or else Line = "## Status" or else Starts_With (Line, "## Status")
              --  | Status | Date |: a table of its particulars.
              or else (Line'Length > 1 and then Line (Line'First) = '|'
                       and then Ada.Strings.Fixed.Index
                                  (Ada.Characters.Handling.To_Lower (Line), "| status |") > 0);
            Has_Decision := Has_Decision
              or else Ada.Characters.Handling.To_Lower (Line) in "## decision" | "## decision outcome";
            if Line /= "" and then Line (Line'First) /= '#' then
               Content := Content + 1;
               if Bare (Line) /= Line and then Ada.Strings.Fixed.Index (Line, "](") > 0 then
                  Links := Links + 1;
               end if;
               declare
                  Label : Unbounded_String;
                  Rest  : Unbounded_String;
               begin
                  Label_Split (Bare (Line), Label, Rest);
                  if Label /= Null_Unbounded_String then
                     Labelled := Labelled + 1;
                  end if;
               end;
            end if;
         end loop;
         --  An index of decision records -- links to them, and nothing else:
         --  the records themselves are read, not it.
         if Links > 0 and then Links * 2 >= Content then
            return True;
         end if;
         --  Several decisions listed, each by its label: read a line each,
         --  as a document of decisions is.
         if Labelled >= 2 then
            return False;
         end if;
         declare
            Title : constant String := To_String (Heading);
            Upper : constant String := Ada.Characters.Handling.To_Upper (Title);
            Digits_End : Natural := Title'First - 1;
         begin
            while Digits_End < Title'Last and then Title (Digits_End + 1) in '0' .. '9' loop
               Digits_End := Digits_End + 1;
            end loop;
            if Title = ""
              or else not (Ada.Strings.Fixed.Index (Lower, "/adr/") > 0
                           or else Ada.Strings.Fixed.Index (Lower, "/decisions/") > 0
                           or else Ada.Strings.Fixed.Index (Upper, "ADR") = Upper'First
                           or else (Digits_End >= Title'First and then Digits_End < Title'Last
                                    and then Title (Digits_End + 1) = '.' and then Has_Status)
                           --  Wherever it is, a record by its sections.
                           or else (Has_Status and then Has_Decision))
            then
               return False;
            end if;
            declare
               Said     : Unbounded_String;
               Status   : Unbounded_String;
               In_Part  : Unbounded_String;
               Decision : Unbounded_String;
               --  Its number, from its title or its file's name: ADR-0002.
               Base     : constant String := Ada.Directories.Base_Name (Path);
               Past     : constant Natural :=
                 Ada.Strings.Fixed.Index (Base, Ada.Strings.Maps.To_Set ("0123456789"), Ada.Strings.Outside);
               Base_End : constant Natural :=
                 (if Base = "" or else Base (Base'First) not in '0' .. '9' then Base'First - 1
                  elsif Past = 0 then Base'Last else Past - 1);
               Label    : constant String :=
                 (if Ada.Strings.Fixed.Index (Upper, "ADR") = Upper'First
                  then Ada.Strings.Fixed.Trim
                         (Title (Title'First .. (if Ada.Strings.Fixed.Index (Title, ":") > 0
                                                 then Ada.Strings.Fixed.Index (Title, ":") - 1
                                                 else Title'First + 2)), Ada.Strings.Both)
                  elsif Base_End >= Base'First then "ADR-" & Base (Base'First .. Base_End)
                  elsif Digits_End >= Title'First then "ADR-" & Title (Title'First .. Digits_End)
                  else "ADR-" & Base);
               Name     : constant String :=
                 (if Ada.Strings.Fixed.Index (Title, ":") > 0
                  then Trim (Title (Ada.Strings.Fixed.Index (Title, ":") + 1 .. Title'Last))
                  elsif Digits_End >= Title'First and then Digits_End + 1 < Title'Last
                  then Trim (Title (Digits_End + 2 .. Title'Last))
                  else Title);
               Mark     : constant String :=
                 Ada.Strings.Fixed.Translate (Label, Ada.Strings.Maps.To_Mapping (" ", "-"));
               After_Status : Boolean := False;
               Replaces     : Unbounded_String;
               --  The column a table's Status heads, 0 where none does.
               Status_Column : Natural := 0;
               --  Where the last line said ended a paragraph or a table row:
               --  the break kept, not run into one line.
               Broken        : Boolean := False;

               --  A table row's cells, trimmed.
               function Cells (Row : String) return Name_Lists.Vector is
                  Result : Name_Lists.Vector;
                  Start  : Natural := Row'First + 1;
               begin
                  for Index in Row'First + 1 .. Row'Last loop
                     if Row (Index) = '|' then
                        Result.Append (Trim (Row (Start .. Index - 1)));
                        Start := Index + 1;
                     end if;
                  end loop;
                  if Start <= Row'Last and then Trim (Row (Start .. Row'Last)) /= "" then
                     Result.Append (Trim (Row (Start .. Row'Last)));
                  end if;
                  return Result;
               end Cells;
            begin
               for Line of Every loop
                  if Line = "" then
                     Broken := Said /= Null_Unbounded_String;
                  elsif Line'Length > 1 and then Line (Line'First) = '|' and then Status = Null_Unbounded_String
                    and then Status_Said (Line) = ""
                    and then (Status_Column > 0
                              or else Ada.Strings.Fixed.Index
                                        (Ada.Characters.Handling.To_Lower (Line), "| status |") > 0)
                  then
                     declare
                        Row : constant Name_Lists.Vector := Cells (Line);
                     begin
                        if Status_Column = 0 then
                           for Index in 1 .. Natural (Row.Length) loop
                              if Ada.Characters.Handling.To_Lower (Row (Index)) = "status" then
                                 Status_Column := Index;
                              end if;
                           end loop;
                        elsif Natural (Row.Length) >= Status_Column
                          and then Row (Status_Column) /= ""
                          and then (for some C of Row (Status_Column) => C not in '-' | ':' | ' ')
                        then
                           Status := To_Unbounded_String (Row (Status_Column));
                        end if;
                     end;
                  elsif Line'Length > 3 and then Line (Line'First .. Line'First + 2) = "## " then
                     In_Part := To_Unbounded_String
                       (Ada.Characters.Handling.To_Lower (Trim (Line (Line'First + 3 .. Line'Last))));
                     After_Status := To_String (In_Part) = "status";
                  elsif Line /= "" and then Line (Line'First) /= '#' then
                     if Status_Said (Line) /= "" then
                        Status := To_Unbounded_String (Status_Said (Line));
                     elsif Starts_With (Bare (Line), "Supersedes:") then
                        Replaces := To_Unbounded_String
                          (Trim (Bare (Line) (Bare (Line)'First + 11 .. Bare (Line)'Last)));
                     elsif Starts_With (Bare (Line), "Deciders:") or else Starts_With (Bare (Line), "Date:") then
                        null;
                     elsif After_Status and then Status = Null_Unbounded_String then
                        Status := To_Unbounded_String (Line);
                     elsif To_String (In_Part) in "decision" | "decision outcome" then
                        Append (Decision, (if Decision = Null_Unbounded_String then "" else " ") & Line);
                     elsif not After_Status then
                        Append (Said, (if Said = Null_Unbounded_String then ""
                                       elsif Broken then ASCII.LF & ASCII.LF
                                       elsif Line (Line'First) = '|' then [1 => ASCII.LF]
                                       else " ") & Line);
                        Broken := Line (Line'First) = '|';
                     end if;
                  end if;
               end loop;
               --  One no longer in force -- superseded, deprecated, rejected --
               --  is not proposed: said, as what the record says of itself.
               declare
                  Lower_Status : constant String := Ada.Characters.Handling.To_Lower (To_String (Status));
               begin
                  if Ada.Strings.Fixed.Index (Lower_Status, "supersede") > 0
                    or else Ada.Strings.Fixed.Index (Lower_Status, "deprecate") > 0
                    or else Ada.Strings.Fixed.Index (Lower_Status, "reject") > 0
                  then
                     --  Under a provenance of its own: what was made from the
                     --  record before is no longer said, and retired with it.
                     declare
                        --  As a sentence reads it: lower case, its link's words,
                        --  and a record named by number as ADR-0005 (Title).
                        Plain_Status : constant String := Lead_In (Lower_Status);
                        By           : constant Natural := Ada.Strings.Fixed.Index (Plain_Status, " by ");
                        After        : constant String :=
                          (if By = 0 then "" else Trim (Plain_Status (By + 4 .. Plain_Status'Last)));
                        Digits_End   : Natural := After'First - 1;
                     begin
                        while Digits_End < After'Last and then After (Digits_End + 1) in '0' .. '9' loop
                           Digits_End := Digits_End + 1;
                        end loop;
                        declare
                           Said : constant String :=
                             (if Digits_End >= After'First and then Digits_End + 2 <= After'Last
                                and then After (Digits_End + 1) = '.'
                              then Plain_Status (Plain_Status'First .. By + 3) & "ADR-"
                                   & [1 .. Natural'Max (0, 4 - (Digits_End - After'First + 1)) => '0']
                                   & After (After'First .. Digits_End) & " ("
                                   & Trim (Lead_In (To_String (Status)) (Lead_In (To_String (Status))'Last
                                           - (After'Last - Digits_End - 2) .. Lead_In (To_String (Status))'Last))
                                   & ")"
                              else Plain_Status);
                        begin
                           Found (Issue, Path & "#" & Mark & "#retired",
                                  Adr_Said (Mark & " is " & Said) & ", so it is not proposed: " & Headline (Name),
                                  Adr_Said (Said));
                        end;
                     end;
                     return True;
                  end if;
               end;
               Found (Decision_Candidate, Path & "#" & Mark, Adr_Said (Mark) & ": " & Headline (Name),
                      (if Decision /= Null_Unbounded_String then To_String (Decision)
                       elsif Said /= Null_Unbounded_String then To_String (Said)
                       else Name)
                      & (if Replaces = Null_Unbounded_String then ""
                         else " (it replaces " & To_String (Replaces) & ")"));
               --  What the record says of its standing, for what it is made.
               declare
                  Held : Output := Result.Outputs (Length (Result));
               begin
                  Held.Status := Status;
                  Result.Outputs (Length (Result)) := Held;
               end;
               return True;
            end;
         end;
      end Decision_Record;
   begin
      if Decision_Record then
         return Result;
      end if;
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
                  --  LABEL: Title, with its statement on the line after: the
                  --  label and title the statement's, as under a heading.
                  if Paragraph /= Null_Unbounded_String and then Raw /= ""
                    and then Says_Requirement (Raw, True)
                    and then not Says_Requirement (To_String (Paragraph), True)
                    and then Labelled_Title (To_String (Paragraph))
                  then
                     declare
                        Label : Unbounded_String;
                        Rest  : Unbounded_String;
                     begin
                        Label_Split (Unmarked (To_String (Paragraph)), Label, Rest);
                        Paragraph := Null_Unbounded_String;
                        Pending_Label := Label;
                        Pending_Title := Rest;
                        Paragraph := To_Unbounded_String (Raw);
                     end;
                  elsif Paragraph /= Null_Unbounded_String and then not Starts_Own (Raw)
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

      --  A document read for its requirements or decisions is those, not
      --  a specification besides: what it says is not proposed twice.
      if (for some One of Result.Outputs =>
            One.Kind in Imported_Item | Requirement_Candidate | Decision_Candidate)
      then
         declare
            Kept : Output_Vectors.Vector;
         begin
            for One of Result.Outputs loop
               if One.Kind /= Specification_Candidate then
                  Kept.Append (One);
               end if;
            end loop;
            Result.Outputs := Kept;
         end;
      end if;
      return Result;
   end Scan_Markdown;

   --  A document in AsciiDoc or reStructuredText, read as Markdown says
   --  the same: = Title and == Section are # and ##, a title underlined
   --  with = or - is # or ##, and a * item is a - one.
   --  Every line of a text, the empty ones too: a blank line ends a part.
   function Lines_Of_All (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Positive := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            Result.Append
              (if Index - 1 >= Start and then Text (Index - 1) = ASCII.CR then Text (Start .. Index - 2)
               else Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Lines_Of_All;

   function As_Markdown (Path : String; Text : String) return String is
      Lower   : constant String := Ada.Characters.Handling.To_Lower (Path);
      function Ends (Suffix : String) return Boolean
      is (Lower'Length > Suffix'Length and then Lower (Lower'Last - Suffix'Length + 1 .. Lower'Last) = Suffix);
      Asciidoc : constant Boolean := Ends (".adoc") or else Ends (".asciidoc");
      Rst      : constant Boolean := Ends (".rst");
      Lines    : constant Name_Lists.Vector := Lines_Of_All (Text);
      Output   : Unbounded_String;
      Skip     : Boolean := False;

      function Underline (Line : String) return Character is
      begin
         if Line'Length >= 3 and then Line (Line'First) in '=' | '-' | '~' | '^'
           and then (for all C of Line => C = Line (Line'First))
         then
            return Line (Line'First);
         end if;
         return ' ';
      end Underline;
      --  Whether a cell is an identifier a document gives: NFR-1, FR-02.
      function Is_Label (Cell : String) return Boolean is
         Dash : constant Natural := Ada.Strings.Fixed.Index (Cell, "-", Ada.Strings.Backward);
      begin
         return Dash > Cell'First and then Dash < Cell'Last
           and then (for all C of Cell (Cell'First .. Dash - 1) => C in 'A' .. 'Z' | '0' .. '9' | '-' | '_')
           and then Cell (Cell'First) in 'A' .. 'Z'
           --  Its number, with letters before it where a label has them:
           --  REQ-3, REQ-S3.
           and then Cell (Cell'Last) in '0' .. '9'
           and then (for all C of Cell (Dash + 1 .. Cell'Last) => C in '0' .. '9' | 'A' .. 'Z');
      end Is_Label;

      --  A table's row of an identifier and its words: a labelled line, as
      --  a list says it; one marked done, ticked. A row marked retired is
      --  left as it is, to be said so.
      function Row (Line : String) return String is
         Cells : Name_Lists.Vector;
         Start : Positive := Line'First + 1;
         Done  : Boolean := False;
      begin
         for At_Index in Line'First + 1 .. Line'Last loop
            if Line (At_Index) = '|' then
               Cells.Append (Ada.Strings.Fixed.Trim (Line (Start .. At_Index - 1), Ada.Strings.Both));
               Start := At_Index + 1;
            end if;
         end loop;
         if Natural (Cells.Length) < 2 or else not Is_Label (Cells (1)) or else Cells (2) = "" then
            return Line;
         end if;
         for Cell of Cells loop
            declare
               Lower_Cell : constant String := Ada.Characters.Handling.To_Lower (Cell);
            begin
               if Lower_Cell in "superseded" | "deprecated" | "rejected" | "withdrawn" | "obsolete" then
                  return Line;
               end if;
               Done := Done or else Lower_Cell in "done" | "implemented" | "complete" | "completed";
            end;
         end loop;
         return "- " & (if Done then "[x] " else "") & Cells (1) & ": " & Cells (2);
      end Row;
   begin
      for Index in 1 .. Natural (Lines.Length) loop
         declare
            Line : constant String := Lines (Index);
            Said : Unbounded_String := To_Unbounded_String (Line);
            Bare : constant String := Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
         begin
            if Skip then
               Skip := False;
               goto Next_Line;
            end if;
            if Bare'Length > 2 and then Bare (Bare'First) = '|' then
               Said := To_Unbounded_String (Row (Bare));
            --  reStructuredText's list-table: * - ID, then - its words.
            elsif Rst and then Bare'Length > 4 and then Bare (Bare'First .. Bare'First + 3) = "* - "
              and then Index < Natural (Lines.Length)
              and then Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Lines (Index + 1), Ada.Strings.Both), "- ") = 1
              and then Is_Label (Ada.Strings.Fixed.Trim (Bare (Bare'First + 4 .. Bare'Last), Ada.Strings.Both))
            then
               declare
                  Next_Line : constant String := Ada.Strings.Fixed.Trim (Lines (Index + 1), Ada.Strings.Both);
               begin
                  Said := To_Unbounded_String
                    ("- " & Ada.Strings.Fixed.Trim (Bare (Bare'First + 4 .. Bare'Last), Ada.Strings.Both)
                     & ": " & Next_Line (Next_Line'First + 2 .. Next_Line'Last));
                  Skip := True;
               end;
            end if;
            if Said /= To_Unbounded_String (Line) then
               null;
            elsif Asciidoc and then Line'Length > 2 and then Line (Line'First) = '=' then
               declare
                  Depth : Natural := 0;
               begin
                  while Depth < Line'Length and then Line (Line'First + Depth) = '=' loop
                     Depth := Depth + 1;
                  end loop;
                  if Depth < Line'Length and then Line (Line'First + Depth) = ' ' then
                     Said := To_Unbounded_String
                       ([1 .. Depth => '#'] & Line (Line'First + Depth .. Line'Last));
                  end if;
               end;
            elsif Asciidoc and then Line'Length > 2 and then Line (Line'First .. Line'First + 1) = "* " then
               Said := To_Unbounded_String ("- " & Line (Line'First + 2 .. Line'Last));
            elsif Rst and then Index < Natural (Lines.Length) and then Line /= ""
              and then Underline (Lines (Index + 1)) /= ' '
              and then Underline (Line) = ' '
            then
               Said := To_Unbounded_String
                 ((if Underline (Lines (Index + 1)) = '=' then "# "
                   elsif Underline (Lines (Index + 1)) = '-' then "## " else "### ") & Line);
               Skip := True;
            end if;
            Append (Output, To_String (Said) & ASCII.LF);
         end;
         <<Next_Line>>
      end loop;
      return To_String (Output);
   end As_Markdown;

   function Scan (Path : String; Text : String) return Output_List
   is (Scan_Markdown (Path, As_Markdown (Path, Text)));

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

   function Documents (Item : Stores.Store; Patterns : String := "") return Name_Lists.Vector is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      Listed  : Name_Lists.Vector :=
        Items_Of (if Patterns /= "" then Patterns else Records.Get (Settings_Of (Item), "set.bootstrap.sources"));
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
                  --  A project of its own below is its own: not read here.
                  if Simple (Simple'First) /= '.'
                    and then not Ada.Directories.Exists
                                   (Ada.Directories.Full_Name (Found) & "/" & State_Directory)
                  then
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
      --  The directories a directory pattern names, each a path: a * in a
      --  part -- packages/*/docs -- any one directory there.
      function Directories_Of (Pattern : String) return Name_Lists.Vector is
         Result : Name_Lists.Vector;

         procedure Walk (Done, Rest : String) is
            Slash : constant Natural := Ada.Strings.Fixed.Index (Rest, "/");
            Part  : constant String := (if Slash = 0 then Rest else Rest (Rest'First .. Slash - 1));
            After : constant String := (if Slash = 0 then "" else Rest (Slash + 1 .. Rest'Last));
         begin
            if Rest = "" then
               Result.Append (Done);
            elsif Ada.Strings.Fixed.Index (Part, "*") = 0 then
               Walk ((if Done = "" then Part else Done & "/" & Part), After);
            else
               declare
                  Where  : constant String := (if Done = "" then Project else Project & "/" & Done);
                  Search : Ada.Directories.Search_Type;
                  Found  : Ada.Directories.Directory_Entry_Type;
                  Below  : Name_Lists.Vector;
               begin
                  if not Ada.Directories.Exists (Where) then
                     return;
                  end if;
                  Ada.Directories.Start_Search
                    (Search, Where, Part, [Ada.Directories.Directory => True, others => False]);
                  while Ada.Directories.More_Entries (Search) loop
                     Ada.Directories.Get_Next_Entry (Search, Found);
                     if Ada.Directories.Simple_Name (Found) (Ada.Directories.Simple_Name (Found)'First) /= '.'
                       and then not Ada.Directories.Exists (Ada.Directories.Full_Name (Found) & "/" & State_Directory)
                     then
                        Below.Append (Ada.Directories.Simple_Name (Found));
                     end if;
                  end loop;
                  Ada.Directories.End_Search (Search);
                  for Sub of Below loop
                     Walk ((if Done = "" then Sub else Done & "/" & Sub), After);
                  end loop;
               exception
                  when others =>
                     null;
               end;
            end if;
         end Walk;
      begin
         Walk ("", Pattern);
         return Result;
      end Directories_Of;
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
               for One of Directories_Of (Base) loop
                  Collect (One, Name, Deep, Pattern => Ada.Strings.Fixed.Index (Name, "*") > 0);
               end loop;
            end if;
         end;
      end loop;
      --  Patterns asked about alone: what they find, and nothing more.
      if Patterns /= "" then
         Sorting.Sort (Result);
         return Result;
      end if;
      --  And every document something was read from before -- one named
      --  to /bootstrap outside these, a .rst or a .txt -- while it is there:
      --  what it says now is read again with the rest.
      for Kind in Intent.Intent_Kind loop
         for Known of Intent.List (Item, Kind) loop
            declare
               Held : Intent.Entity;
               Got  : E.Error_Info;
            begin
               Intent.Read (Item, Kind, Known, Held, Got);
               if E.Is_Ok (Got) and then Length (Held.Source) > 0
                 and then not Result.Contains (To_String (Held.Source))
                 and then Ada.Directories.Exists (Project & "/" & To_String (Held.Source))
               then
                  Result.Append (To_String (Held.Source));
               end if;
            end;
         end loop;
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

      --  What a document numbers itself first, then the rest: an
      --  identifier a document gives is its own, not taken by a line that
      --  gave none and happened to be read before it.
      function Numbered_First return Output_List is
         Result : Output_List;
      begin
         for Pass in 1 .. 2 loop
            for Next of Found.Outputs loop
               if (Length (Next.Given_Id) > 0) = (Pass = 1) then
                  Result.Outputs.Append (Next);
               end if;
            end loop;
         end loop;
         return Result;
      end Numbered_First;
      Ordered : constant Output_List := Numbered_First;

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
      Made_Provenances : Name_Lists.Vector;

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

      for Next of Ordered.Outputs loop
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
                           Result.Moved.Append (Name & " from " & From & " to " & Field (Next.Source));
                           return Name;
                        end if;
                     end;
                  end;
               end loop;
               return "";
            end Moved_Here;

            --  One bootstrap let go when its document stopped saying it,
            --  said there again: a candidate again, and said so.
            procedure Revive (Kind : Intent.Intent_Kind; Known : String) is
               Value : Records.Item;
               Read  : E.Error_Info;
               Moved : E.Error_Info;
            begin
               Stores.Read (Item, Area_Of (Kind), Known, Value, Read);
               if E.Is_Ok (Read) and then Records.Get (Value, "state") = "rejected"
                 and then Records.Get (Value, "moved_by") = "bootstrap"
               then
                  declare
                     Granted : Transitions.Permissions := Transitions.Ordinary_Only;
                  begin
                     Granted (Transitions.Reconsideration) := True;
                     Intent.Move (Item, Change, Kind, Known, Intent.First_State (Kind), Granted, Moved,
                                  Actor => "bootstrap");
                  end;
                  if E.Is_Ok (Moved) then
                     Result.Stale.Append (Known & ": " & Field (Next.Source) & " says it again; it is a"
                                          & " candidate again");
                  end if;
               end if;
            end Revive;

            procedure Propose (Kind : Intent.Intent_Kind) is
               Found_Here : constant String := Intent.Find_By_Provenance (Item, Kind, Provenance);
               Known : constant String := (if Found_Here /= "" then Found_Here else Moved_Here (Kind));
               Given : constant String := Field (Next.Given_Id);
               Taken : constant Boolean :=
                 Given /= "" and then Stores.Is_Name (Given)
                 and then Stores.Exists (Item, Area_Of (Kind), Given);
            begin
               if Known /= "" then
                  Revive (Kind, Known);
                  Again (Kind, Known, Settled => False);
                  return;
               elsif Adopted (Kind, Given) then
                  return;
               end if;

               --  Said already, in the same words, by another document: one
               --  entry, not two -- said, so the second place is known.
               if Intent."/=" (Kind, Intent.Specification) then
                  for Other of Intent.List (Item, Kind) loop
                     declare
                        Held : Intent.Entity;
                        Got  : E.Error_Info;
                     begin
                        Intent.Read (Item, Kind, Other, Held, Got);
                        if E.Is_Ok (Got)
                          and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                          and then To_String (Held.Source) /= Field (Next.Source)
                          and then Fingerprint (To_String (Held.Text)) = Fingerprint (Field (Next.Text))
                          and then Length (Held.Source) > 0
                          and then not Ada.Directories.Exists
                                         (Ada.Directories.Containing_Directory (Stores.Root (Item)) & "/"
                                          & To_String (Held.Source))
                        then
                           --  The document it came from is gone, and this one
                           --  says it too: it is read from here now.
                           declare
                              Value  : Records.Item;
                              Read   : E.Error_Info;
                           begin
                              Stores.Read (Item, Area_Of (Kind), Other, Value, Read);
                              Records.Set_Revision (Value, Records.Revision (Value) + 1);
                              Records.Set (Value, "provenance", Provenance);
                              Records.Set (Value, "source", Field (Next.Source));
                              Stores.Put (Change, Area_Of (Kind), Other, Value);
                              Result.Moved.Append (Other & " from " & To_String (Held.Source) & " to "
                                                   & Field (Next.Source));
                              Result.Existing := Result.Existing + 1;
                           end;
                           return;
                        elsif E.Is_Ok (Got)
                          and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                          and then To_String (Held.Source) /= Field (Next.Source)
                          and then Fingerprint (To_String (Held.Text)) = Fingerprint (Field (Next.Text))
                        then
                           Result.Existing := Result.Existing + 1;
                           Result.Stale.Append
                             (Other & ": " & Field (Next.Source) & " says it too, in the same words; it is"
                              & " kept once, as read from " & To_String (Held.Source));
                           return;
                        end if;
                     end;
                  end loop;
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
               --  Numbered as a person's entries are -- REQ-007 -- the
               --  document it came from kept as its source: a document's
               --  name is not a component's.
               Intent.Propose
                 (Item, Change, Kind, Intent.Namespace (Kind), Field (Next.Title),
                  Field (Next.Text), Field (Next.Criteria), Field (Next.Source), Provenance,
                  "project", Id, Status, Given => Field (Next.Given_Id));
               if E.Is_Ok (Status) then
                  Mark_Imported (Kind, To_String (Id));
                  Result.Created := Result.Created + 1;
                  Result.Made.Append (To_String (Id));
                  Made_Texts.Append (Field (Next.Text));
                  Made_Sources.Append (Field (Next.Source));
                  Made_Provenances.Append (Field (Next.Provenance));
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
                     Revive (Intent.Requirement, Intent.Find_By_Provenance (Item, Intent.Requirement, Provenance));
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
                        --  Its document moved: the entry it made is followed
                        --  there, not made a second time.
                        declare
                           Followed : constant String := Moved_Here (Intent.Requirement);
                        begin
                           if Followed /= "" then
                              Again (Intent.Requirement, Followed, Settled => Document_Rules);
                              goto Next_Output;
                           end if;
                        end;
                        if Adopted (Intent.Requirement, Given) then
                           goto Next_Output;
                        end if;
                        Moved := False;
                        if Stores.Is_Name (Given) then
                           Stores.Pending (Change, Requirements_Area, Given, Held, Staged);
                           Moved := Staged or else Stores.Exists (Item, Requirements_Area, Given);
                        end if;
                        Intent.Propose
                          (Item, Change, Intent.Requirement, Intent.Namespace (Intent.Requirement),
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
                           Made_Provenances.Append (Field (Next.Provenance));
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
                  declare
                     Before : constant Natural := Natural (Result.Made.Length);

                     --  The record says of itself that it is accepted: a
                     --  Status: line, or a status: field, that begins so.
                     function Says_Accepted return Boolean is
                        Path : constant String :=
                          Ada.Directories.Containing_Directory (Stores.Root (Item)) & "/" & Field (Next.Source);
                        Text : Unbounded_String;
                        Read : E.Error_Info;
                        Lower : Unbounded_String;
                     begin
                        --  Its own status, where it said one: that, not another
                        --  record's in the same document.
                        if Next.Status /= Null_Unbounded_String then
                           return Ada.Strings.Fixed.Index
                                    (Ada.Characters.Handling.To_Lower (Field (Next.Status)), "accepted") = 1
                             or else Ada.Strings.Fixed.Index
                                       (Ada.Characters.Handling.To_Lower (Field (Next.Status)), "approved") = 1;
                        end if;
                        if not Ada.Directories.Exists (Path) then
                           return False;
                        end if;
                        Files.Read_Text (Path, Text, Read);
                        Lower := To_Unbounded_String (Ada.Characters.Handling.To_Lower (To_String (Text)));
                        return E.Is_Ok (Read)
                          and then (Index (Lower, "status: accepted") > 0
                                    or else Index (Lower, "## status" & ASCII.LF & ASCII.LF & "accepted") > 0
                                    or else Index (Lower, "## status" & ASCII.LF & "accepted") > 0);
                     end Says_Accepted;
                  begin
                     Propose (Intent.Decision);
                     --  Made now, and accepted by its own record: accepted, as
                     --  a requirement the document labels is.
                     if E.Is_Ok (Status) and then Accept_Imports
                       and then Natural (Result.Made.Length) = Before + 1
                       and then Ada.Strings.Fixed.Index (Result.Made.Last_Element, "DEC-") = 1
                       and then Says_Accepted
                     then
                        Intent.Move (Item, Change, Intent.Decision, Result.Made.Last_Element,
                                     "accepted", Transitions.Ordinary_Only, Status);
                     end if;
                  end;

               when Specification_Candidate =>
                  Propose (Intent.Specification);

               when Issue =>
                  --  A record that marks itself retired, made into an entry
                  --  before: what is said of that entry says it, not this.
                  if Ada.Strings.Fixed.Index (Provenance, "#retired") = Provenance'Last - 7
                    and then Provenance'Length > 8
                    and then (for some Kind in Intent.Requirement .. Intent.Decision =>
                                Intent.Find_By_Provenance
                                  (Item, Kind, Provenance (Provenance'First .. Provenance'Last - 8)) /= "")
                  then
                     goto Next_Output;
                  end if;
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
         Read_From    : Name_Lists.Vector;
         Said_Now     : Name_Lists.Vector;
         Gone_Entries : Name_Lists.Vector;
      begin
         for Next of Found.Outputs loop
            if not Read_From.Contains (Field (Next.Source)) then
               Read_From.Append (Field (Next.Source));
            end if;
            Said_Now.Append (Field (Next.Provenance));
         end loop;
         --  A document gone altogether, with what was taken up from it: one
         --  issue for it, naming them all, not one an entry.
         declare
            Root    : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
            Sources : Name_Lists.Vector;

            --  The commands that retire entries a space apart, each by its
            --  register: /req obsolete REQ-001 REQ-002, /spec obsolete SPEC-001.
            function Retiring (Named : String) return String is
               Said : Unbounded_String;
            begin
               for Prefix of Name_Lists.Vector'(["REQ-", "SPEC-", "DEC-"]) loop
                  declare
                     These : Unbounded_String;
                  begin
                     for One of Lines_Of (Ada.Strings.Fixed.Translate
                                            (Named, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF])))
                     loop
                        if Ada.Strings.Fixed.Index (One, Prefix) = One'First then
                           Append (These, " " & One);
                        end if;
                     end loop;
                     if These /= Null_Unbounded_String then
                        Append (Said, (if Said = Null_Unbounded_String then "" else ", ")
                                & (if Prefix = "REQ-" then "/req" elsif Prefix = "SPEC-" then "/spec"
                                   else "/decision")
                                & " obsolete" & To_String (These));
                     end if;
                  end;
               end loop;
               return To_String (Said);
            end Retiring;

            function Source_Of (Kind : Intent.Intent_Kind; Known : String) return String is
               Held : Intent.Entity;
               Read : E.Error_Info;
            begin
               Intent.Read (Item, Kind, Known, Held, Read);
               return (if E.Is_Ok (Read) then To_String (Held.Source) else "");
            end Source_Of;
         begin
            for Kind in Intent.Intent_Kind loop
               for Known of Intent.List (Item, Kind) loop
                  declare
                     Held : Intent.Entity;
                     Read : E.Error_Info;
                  begin
                     Intent.Read (Item, Kind, Known, Held, Read);
                     if E.Is_Ok (Read) and then Length (Held.Source) > 0 and then Length (Held.Provenance) > 0
                       and then To_String (Held.State) not in "obsolete" | "superseded" | "rejected"
                       and then To_String (Held.State) /= Intent.First_State (Kind)
                       and then not Ada.Directories.Exists (Hostkit.Fs.Join (Root, To_String (Held.Source)))
                       and then not (for some Line of Result.Moved =>
                                       Ada.Strings.Fixed.Index (Line, Known & " ") = Line'First)
                     then
                        Gone_Entries.Append (Known);
                        if not Sources.Contains (To_String (Held.Source)) then
                           Sources.Append (To_String (Held.Source));
                        end if;
                     end if;
                  end;
               end loop;
            end loop;
            for Source of Sources loop
               declare
                  Named : Unbounded_String;
                  Count : Natural := 0;
               begin
                  for Kind in Intent.Intent_Kind loop
                     for Known of Intent.List (Item, Kind) loop
                        if Gone_Entries.Contains (Known) and then Source_Of (Kind, Known) = Source
                        then
                           Append (Named, (if Named = Null_Unbounded_String then "" else " ") & Known);
                           Count := Count + 1;
                        end if;
                     end loop;
                  end loop;
                  if Count > 1 then
                     declare
                        Said : Results.Result :=
                          (Kind       => Results.Diagnostic,
                           Producer   => To_Unbounded_String ("bootstrap"),
                           Summary    => To_Unbounded_String
                                           (Source & " is gone; it was where " & To_String (Named)
                                            & " came from: " & Retiring (To_String (Named))
                                            & " retires them, or a document that says them again keeps them"),
                           Provenance => To_Unbounded_String (Source & "#gone"),
                           others     => <>);
                     begin
                        Raise_Issue (Said);
                     end;
                  else
                     --  One alone: said of itself, below.
                     for Kind in Intent.Intent_Kind loop
                        for Known of Intent.List (Item, Kind) loop
                           if Source_Of (Kind, Known) = Source and then Gone_Entries.Contains (Known) then
                              Gone_Entries.Delete (Gone_Entries.Find_Index (Known));
                           end if;
                        end loop;
                     end loop;
                  end if;
               end;
            end loop;
         end;
         for Kind in Intent.Intent_Kind loop
            for Known of Intent.List (Item, Kind) loop
               declare
                  Held : Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Intent.Read (Item, Kind, Known, Held, Read);
                  --  Its document read now, or gone altogether -- deleted,
                  --  or moved without this part of it -- either way no
                  --  longer saying it.
                  if E.Is_Ok (Read)
                    and then (Read_From.Contains (To_String (Held.Source))
                              or else (Length (Held.Source) > 0
                                       and then not Ada.Directories.Exists
                                                      (Hostkit.Fs.Join
                                                         (Ada.Directories.Containing_Directory (Stores.Root (Item)),
                                                          To_String (Held.Source)))
                                       and then not (for some Line of Result.Moved =>
                                                       Ada.Strings.Fixed.Index (Line, Known & " ") = Line'First)))
                    and then Length (Held.Provenance) > 0
                    and then not Said_Now.Contains (To_String (Held.Provenance))
                    and then not Rewritten.Contains (Known)
                    and then not Gone_Entries.Contains (Known)
                    and then To_String (Held.State) not in "obsolete" | "superseded" | "rejected"
                  then
                     declare
                        Instead : Unbounded_String;
                        Said    : Results.Result;
                        --  A record that marks itself retired says so: that is
                        --  why, not that the line went.
                        function Retired_As return String is
                        begin
                           for Next of Found.Outputs loop
                              if Field (Next.Provenance) = To_String (Held.Provenance) & "#retired" then
                                 return Field (Next.Text);
                              end if;
                           end loop;
                           return "";
                        end Retired_As;
                        Why     : constant String :=
                          Known & ": " & To_String (Held.Source)
                          & (if Retired_As = "" then " no longer says it"
                             else " now marks it " & Retired_As);

                        --  The decision made of the record it says replaced it
                        --  -- superseded by ADR-0003 -- now or before; "".
                        function Replaced_By return String is
                           Said_As : constant String := Retired_As;
                           By      : constant Natural := Ada.Strings.Fixed.Index (Said_As, "superseded by ");
                           Label   : Unbounded_String;
                        begin
                           if By = 0 or else not Intent."=" (Kind, Intent.Decision) then
                              return "";
                           end if;
                           for C of Said_As (By + 14 .. Said_As'Last) loop
                              exit when C in ' ' | '(' | ',' | ';';
                              Append (Label, C);
                           end loop;
                           if Length (Label) = 0 then
                              return "";
                           end if;
                           for Index in 1 .. Natural (Result.Made.Length) loop
                              declare
                                 Mark : constant String := Made_Provenances (Index);
                              begin
                                 if Mark'Length > Length (Label)
                                   and then Mark (Mark'Last - Length (Label) .. Mark'Last) = "#" & To_String (Label)
                                 then
                                    return Result.Made (Index);
                                 end if;
                              end;
                           end loop;
                           for Other of Intent.List (Item, Intent.Decision) loop
                              declare
                                 That : Intent.Entity;
                                 Got  : E.Error_Info;
                                 Mark : Unbounded_String;
                              begin
                                 Intent.Read (Item, Intent.Decision, Other, That, Got);
                                 Mark := That.Provenance;
                                 if E.Is_Ok (Got) and then Other /= Known and then Length (Mark) > Length (Label)
                                   and then Slice (Mark, Length (Mark) - Length (Label), Length (Mark))
                                            = "#" & To_String (Label)
                                 then
                                    return Other;
                                 end if;
                              end;
                           end loop;
                           return "";
                        end Replaced_By;
                        Successor : constant String := Replaced_By;

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
                                 & (if Intent."=" (Kind, Intent.Decision) then "/decision"
                                    elsif Intent."=" (Kind, Intent.Specification) then "/spec" else "/req")
                                 & " supersede " & Known
                                 & " " & Result.Made (Best) & " keeps it as that one's history");
                           end if;
                        end;
                        --  A candidate no one took up, its document no
                        --  longer saying it: let go, and said so -- there
                        --  is nothing for a person to weigh.
                        if To_String (Held.State) = Intent.First_State (Kind) and then Instead = Null_Unbounded_String
                        then
                           declare
                              Moved   : E.Error_Info;
                           begin
                              Intent.Move (Item, Change, Kind, Known, "rejected",
                                           Model_Runner.Framework.Transitions.Ordinary_Only, Moved,
                                           Actor => "bootstrap");
                              if E.Is_Ok (Moved) then
                                 Result.Stale.Append
                                   (Why & "; it was a candidate, and is rejected with it");
                                 goto Next_Known;
                              end if;
                           end;
                        end if;
                        Said :=
                          (Kind       => Results.Diagnostic,
                           Producer   => To_Unbounded_String ("bootstrap"),
                           Summary    => To_Unbounded_String
                                           (if Successor /= ""
                                            then Why & "; /decision supersede " & Known & " " & Successor
                                                 & " records it replaced by " & Successor
                                                 & ", the decision made of that record -- or keep it as it is,"
                                                 & " and /result dismiss ID takes this off the list"
                                            else Why & "; "
                                            & (if Intent."=" (Kind, Intent.Decision) then "/decision "
                                               elsif Intent."=" (Kind, Intent.Specification) then "/spec "
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
               <<Next_Known>>
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
