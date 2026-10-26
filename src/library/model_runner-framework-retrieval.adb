with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Generic_Array_Sort;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Ordered_Maps;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Numerics.Elementary_Functions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Maps;

with Hostkit.Fs;

with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Observations;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Tasks;
with Model_Runner.Race_Points;

package body Model_Runner.Framework.Retrieval is

   use Ada.Strings.Unbounded;
   use type Repository.File_Role;
   use type Repository.Relation_Kind;
   use type Repository.Confidence;

   package E renames Model_Runner.Errors;
   package Rp renames Repository;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Has (Text, Part : String) return Boolean
   is (Part'Length > 0 and then Ada.Strings.Fixed.Index (Text, Part) > 0);

   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type => String, Hash => Ada.Strings.Hash, Equivalent_Elements => "=");

   --  Words a query says that name nothing: left out of what is matched,
   --  so "make it fold case" is fold and case.
   function Says_Nothing (Word : String) return Boolean
   is (Word in "a" | "an" | "the" | "of" | "to" | "in" | "on" | "at" | "for" | "and" | "or" | "is" | "it"
             | "its" | "be" | "by" | "as" | "with" | "from" | "this" | "that" | "should" | "also" | "make"
             | "not" | "too" | "only" | "per" | "give" | "do" | "does" | "so" | "if" | "when" | "where"
             | "what" | "which" | "into" | "than" | "then" | "there" | "they" | "them" | "their");

   function Identifier_Char (Char : Character) return Boolean
   is (Ada.Characters.Handling.Is_Alphanumeric (Char) or else Char = '_');

   --  The whole words of a query, lowered: names, dotted names, paths.
   function Wholes_Of (Query : String) return Name_Lists.Vector is
      Said   : constant String := Query (Query'First .. Query'First - 1 + Natural'Min (Query'Length, Query_Most));
      Result : Name_Lists.Vector;
      Start  : Positive := Said'First;
   begin
      for Index in Said'First .. Said'Last + 1 loop
         if Index > Said'Last or else Said (Index) in ' ' | ',' | ';' | '"' | ''' | '`' | '(' | ')' | ASCII.HT
                                                      | ASCII.LF | ASCII.CR | '?' | '!'
         then
            declare
               Word : constant String :=
                 Lower (Ada.Strings.Fixed.Trim (Said (Start .. Index - 1), Ada.Strings.Maps.To_Set (".:"),
                                                Ada.Strings.Maps.To_Set (".:")));
            begin
               if Word'Length >= 2 and then not Says_Nothing (Word) and then not Result.Contains (Word) then
                  Result.Append (Word);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Wholes_Of;

   --  The words a query of three or more says in small letters, as it
   --  says them: words of a sentence, not names, where a name is written
   --  otherwise -- "the context" is not the package Context.
   --  And the first word of a query of four or more, where it is written
   --  as a sentence begins -- one capital, then small letters: "Read a
   --  binary32 weight as a binary32" asks for no symbol named Read, and
   --  took its name's points over every file the rest of it was about.
   function Plain_Words (Query : String) return Name_Sets.Set is
      Result : Name_Sets.Set;
      Said   : Natural := 0;
      Start  : Natural := 0;
      Opener : Unbounded_String;
   begin
      for Index in Query'First .. Query'Last + 1 loop
         if Index <= Query'Last and then Identifier_Char (Query (Index)) then
            if Start = 0 then
               Start := Index;
            end if;
         elsif Start > 0 then
            Said := Said + 1;
            if (for all Char of Query (Start .. Index - 1) => Char in 'a' .. 'z') then
               Result.Include (Query (Start .. Index - 1));
            elsif Said = 1 and then Index - Start >= 2 and then Query (Start) in 'A' .. 'Z'
              and then (for all Char of Query (Start + 1 .. Index - 1) => Char in 'a' .. 'z')
            then
               Opener := To_Unbounded_String (Lower (Query (Start .. Index - 1)));
            end if;
            Start := 0;
         end if;
      end loop;
      if Said < 3 then
         Result.Clear;
      elsif Said >= 4 and then Length (Opener) > 0 then
         Result.Include (To_String (Opener));
      end if;
      return Result;
   end Plain_Words;

   --  The identifiers of a text and their parts, as an index takes them.
   procedure Each_Word
     (Text : String;
      Take : not null access procedure (Word : String; Line : Positive))
   is
      Line  : Positive := 1;
      Index : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         if Text (Index) = ASCII.LF then
            Line := Line + 1;
            Index := Index + 1;
         elsif Ada.Characters.Handling.Is_Letter (Text (Index)) then
            declare
               Start : constant Positive := Index;
            begin
               while Index <= Text'Last and then Identifier_Char (Text (Index)) loop
                  Index := Index + 1;
               end loop;
               declare
                  Word : constant String := Lower (Text (Start .. Index - 1));
                  Part : Positive := Word'First;
               begin
                  if Word'Length >= 2 and then Word'Length <= 64 then
                     Take (Word, Line);
                     if Ada.Strings.Fixed.Index (Word, "_") > 0 then
                        for At_Char in Word'First .. Word'Last + 1 loop
                           if At_Char > Word'Last or else Word (At_Char) = '_' then
                              if At_Char - Part >= 2 then
                                 Take (Word (Part .. At_Char - 1), Line);
                              end if;
                              Part := At_Char + 1;
                           end if;
                        end loop;
                     end if;
                  end if;
               end;
            end;
         else
            Index := Index + 1;
         end if;
      end loop;
   end Each_Word;

   --------------
   -- Terms_Of --
   --------------

   function Terms_Of (Query : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;

      procedure Take (Word : String; Line : Positive) is
         pragma Unreferenced (Line);
      begin
         if not Says_Nothing (Word) and then not Result.Contains (Word) then
            Result.Append (Word);
         end if;
      end Take;
   begin
      Each_Word (Query (Query'First .. Query'First - 1 + Natural'Min (Query'Length, Query_Most)), Take'Access);
      return Result;
   end Terms_Of;

   ---------------------------------------------------------------------------
   --  The index of the files' words.
   ---------------------------------------------------------------------------

   --  A word's occurrences in one file: how often, and the first line.
   type Posting is record
      Term  : Positive := 1;
      Count : Natural := 0;
      Line  : Positive := 1;
   end record;

   type Posting_Array is array (Positive range <>) of Posting;

   package Number_Lists is new Ada.Containers.Vectors (Positive, Positive);

   function Before (Left, Right : Posting) return Boolean
   is (Left.Term < Right.Term);

   procedure Sort is new Ada.Containers.Generic_Array_Sort (Positive, Posting, Posting_Array, Before);

   --  What a comment just before a declaration says -- the declaration
   --  on the line after it -- or a Python docstring just after one: its
   --  words up to the first @param or @return, which name the
   --  declaration's parts rather than what it does.
   type Description is record
      Describes : Positive := 1;
      Words     : Name_Lists.Vector;
   end record;

   package Description_Lists is new Ada.Containers.Vectors (Positive, Description);

   --  How a line of a language's source opens a comment: the length of
   --  the mark; nought where the line is none; Natural'Last for a line
   --  inside a C-like block comment opened on an earlier line, which has
   --  no mark of its own.
   function Comment_Mark (Trimmed, Language : String; In_Block : Boolean) return Natural is
      function Opens (Mark : String) return Boolean
      is (Trimmed'Length >= Mark'Length and then Trimmed (Trimmed'First .. Trimmed'First + Mark'Length - 1) = Mark);
   begin
      if Language in "Ada" | "GPR" then
         return (if Opens ("--") then 2 else 0);
      elsif Language in "Python" | "Shell" | "TOML" then
         return (if Opens ("#") then 1 else 0);
      elsif Language in "C" | "C++" | "Go" | "Rust" then
         if Opens ("///") or else Opens ("//!") or else Opens ("/**") then
            return 3;
         elsif Opens ("//") or else Opens ("/*") or else Opens ("*/") then
            return 2;
         elsif In_Block and then Opens ("*") then
            return 1;
         elsif In_Block then
            return Natural'Last;
         end if;
      end if;
      return 0;
   end Comment_Mark;

   --  The descriptions of a file's declarations, as Description says them.
   function Descriptions_Of (Text, Language : String) return Description_Lists.Vector is
      Triple   : constant String := """""""";
      Result   : Description_Lists.Vector;
      Current  : Description;
      Open     : Boolean := False;
      Cut      : Boolean := False;
      In_Block : Boolean := False;
      In_Doc   : Boolean := False;
      Doc_Of   : Positive := 1;
      Quote    : String (1 .. 3) := Triple;
      Previous : Unbounded_String;
      Start    : Positive := Text'First;
      Row      : Positive := 1;

      procedure Take (Word : String; Line : Positive) is
         pragma Unreferenced (Line);
      begin
         if not Says_Nothing (Word) and then not Current.Words.Contains (Word) then
            Current.Words.Append (Word);
         end if;
      end Take;

      procedure Said (Words : String) is
         Plain : constant String := Ada.Strings.Fixed.Trim (Words, Ada.Strings.Both);
      begin
         if Plain'Length > 0 and then Plain (Plain'First) = '@' then
            Cut := True;
         elsif not Cut then
            Each_Word (Words, Take'Access);
         end if;
      end Said;

      procedure Reset is
      begin
         Current := (others => <>);
         Open := False;
         Cut := False;
      end Reset;

      procedure Close (Describes : Positive) is
      begin
         if not Current.Words.Is_Empty then
            Current.Describes := Describes;
            Result.Append (Current);
         end if;
         Reset;
      end Close;
   begin
      for At_Char in Text'First .. Text'Last + 1 loop
         if At_Char > Text'Last or else Text (At_Char) = ASCII.LF then
            declare
               Blank   : constant Ada.Strings.Maps.Character_Set :=
                 Ada.Strings.Maps.To_Set (" " & ASCII.HT & ASCII.CR);
               Trimmed : constant String := Ada.Strings.Fixed.Trim (Text (Start .. At_Char - 1), Blank, Blank);
               Mark    : constant Natural := Comment_Mark (Trimmed, Language, In_Block);
               Before  : constant String := To_String (Previous);
            begin
               if In_Doc then
                  if Has (Trimmed, Quote) then
                     Said (Trimmed (Trimmed'First .. Ada.Strings.Fixed.Index (Trimmed, Quote) - 1));
                     In_Doc := False;
                     Close (Doc_Of);
                  else
                     Said (Trimmed);
                  end if;
               elsif Language = "Python" and then Trimmed'Length >= 3
                 and then (Trimmed (Trimmed'First .. Trimmed'First + 2) = Triple
                           or else Trimmed (Trimmed'First .. Trimmed'First + 2) = "'''")
                 and then (Has (Before, "def ") or else Has (Before, "class "))
               then
                  --  A docstring: what the def or class on the line before is.
                  Reset;
                  Doc_Of := Row - 1;
                  Quote := Trimmed (Trimmed'First .. Trimmed'First + 2);
                  declare
                     Rest : constant String := Trimmed (Trimmed'First + 3 .. Trimmed'Last);
                  begin
                     if Has (Rest, Quote) then
                        Said (Rest (Rest'First .. Ada.Strings.Fixed.Index (Rest, Quote) - 1));
                        Close (Doc_Of);
                     else
                        Said (Rest);
                        In_Doc := True;
                     end if;
                  end;
               elsif Mark > 0 then
                  Open := True;
                  if Mark = Natural'Last then
                     Said (Trimmed);
                  else
                     Said (Trimmed (Trimmed'First + Mark .. Trimmed'Last));
                  end if;
                  if Language in "C" | "C++" | "Go" | "Rust" then
                     if Trimmed'Length >= 2 and then Trimmed (Trimmed'First .. Trimmed'First + 1) = "/*" then
                        In_Block := True;
                     end if;
                     if Has (Trimmed, "*/") then
                        In_Block := False;
                     end if;
                  end if;
               elsif Open then
                  --  The line after a comment: what it describes, where
                  --  anything is there; a blank line describes nothing.
                  if Trimmed'Length > 0 then
                     Close (Row);
                  else
                     Reset;
                  end if;
               end if;
               Previous := To_Unbounded_String (Trimmed);
            end;
            Row := Row + 1;
            Start := At_Char + 1;
         end if;
      end loop;
      return Result;
   end Descriptions_Of;

   --  Whether a word of a query and one of a description are the same
   --  word said two ways: the same, or one beginning the other where the
   --  shorter has four letters or more -- unit and units, depend and
   --  dependents, edit and edited.
   function Alike (Term, Word : String) return Boolean
   is (Term = Word
       or else (Natural'Min (Term'Length, Word'Length) >= 4
                and then (if Term'Length < Word'Length
                          then Word (Word'First .. Word'First + Term'Length - 1) = Term
                          else Term (Term'First .. Term'First + Word'Length - 1) = Word)));

   --  One file's words, sorted by term, held in the entry itself so that
   --  replacing or deleting the entry frees them; the print the graph gave
   --  when they were read; and the file's number in the lists of the files
   --  each term is in; and what its declarations' comments say: each
   --  description's line and how many words it has, by its number, and
   --  its words as postings sorted by term, a posting's count the number
   --  of the description holding it, its line the line described.
   type File_Words (Count, Said_Count : Natural) is record
      Print   : Unbounded_String;
      Doc     : Positive := 1;
      Lengths : Number_Lists.Vector;
      Words   : Posting_Array (1 .. Count);
      Said    : Posting_Array (1 .. Said_Count);
   end record;

   --  The dictionary's words in order, for the words a word begins.
   package Word_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   package Term_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Positive, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   package Word_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => File_Words, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   package Doc_List_Vectors is new Ada.Containers.Vectors (Positive, Number_Lists.Vector, Number_Lists."=");

   --  The index, held under Lock. Each term's number, and the files it is
   --  in by their numbers -- what a search visits, not every file -- and
   --  the term each number is; each file's words by its tree and path, and
   --  the key each file number is. A term no file holds any more leaves
   --  the dictionary and its number is given to the next new one, as a
   --  file's is: what the index holds is what the files hold, however
   --  long a session edits them. A live number is never renumbered, so no
   --  posting names a term it did not.
   Dictionary : Term_Maps.Map;
   Spelled    : Word_Sets.Set;
   Term_Names : Name_Lists.Vector;
   Term_Docs  : Doc_List_Vectors.Vector;
   Free_Terms : Number_Lists.Vector;
   Index      : Word_Maps.Map;
   Doc_Keys   : Name_Lists.Vector;
   Free_Docs  : Number_Lists.Vector;
   Read_Count : Natural := 0;

   --  When each file's entry last changed -- installed or dropped -- as a
   --  count of the index's changes, kept after a drop: a pass that read a
   --  file installs what it read only where nothing changed the entry
   --  since it chose to, so a slower pass with an older read does not put
   --  back what a faster one replaced or dropped. An entry not in Changed
   --  last changed at Floor. Only a pass under way can hold a change it
   --  saw, so when none is, Changed is emptied and Floor moved past every
   --  change: what is kept for files gone is kept only while passes run.
   package Change_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Positive, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
   Changed : Change_Maps.Map;
   Changes : Natural := 0;
   Floor   : Natural := 0;
   Passes  : Natural := 0;

   package Change_Lists is new Ada.Containers.Vectors (Positive, Natural);

   --  The files of the index's trees that a search does not search, by
   --  key, and why: too large, held with no words; could not be read, not
   --  held; another search's pass was reading it and had not installed it
   --  when this one stopped waiting; or this one's work was stopped before
   --  it was read. Each goes once the file is read in.
   type Unsearched_Why is (Too_Large, Unreadable, Being_Read, Stopped);
   package Unsearched_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Unsearched_Why, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
   Unsearched : Unsearched_Maps.Map;

   --  A file whose reading in failed -- the counting of its words, or its
   --  install, raised: the print it had, how often it failed at that
   --  print, when it may be tried again, and what failed, as the stage
   --  and the exception's name. Memory run out is a want of room, which
   --  passes and is tried again; any other exception is a fault of this
   --  program's own -- no file's text should raise one -- which comes
   --  back each time: not tried again at that print, and said with the
   --  first of its message, which names where it was raised.
   type Failure is record
      Print  : Unbounded_String;
      Tries  : Positive := 1;
      Next   : Ada.Real_Time.Time;
      Stage  : Unbounded_String;
      Name   : Unbounded_String;
      Fault  : Boolean := False;
      Detail : Unbounded_String;
   end record;

   --  The files whose reading in failed, by key. One is tried again once
   --  its wait is over -- Retry_Wait, doubled each time it fails again --
   --  and given up after Most_Tries at the same print, until the print
   --  changes: a fault that passes, memory short for a moment, is got
   --  over, and one that comes back costs a few tries a version, not
   --  every search. Kept when the index is let go, which is what an
   --  install's fault does.
   package Failed_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Failure, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
   Failed     : Failed_Maps.Map;
   Most_Tries : constant := 4;
   Retry_Wait : Duration := 30.0;

   --  The longest first wait Retry_Indexing_After takes: doubled three
   --  times, eight hours, well inside what a time span holds.
   Longest_Wait : constant Duration := 3_600.0;

   --  Whether a file that failed is to be read in now, at the graph's
   --  print. Called with Lock held.
   function Due (Was : Failure; Print : String) return Boolean is
      use type Ada.Real_Time.Time;
   begin
      return To_String (Was.Print) /= Print
        or else (Was.Tries < Most_Tries and then Ada.Real_Time.Clock >= Was.Next);
   end Due;

   --  An entry's last change. Called with Lock held.
   function Change_Of (Key : String) return Natural
   is (if Changed.Contains (Key) then Changed.Element (Key) else Floor);

   --  Every change forgotten, none a pass under way saw matching what
   --  comes after. Called with Lock held.
   procedure Raise_Floor is
   begin
      Changed.Clear;
      Changes := Changes + 1;
      Floor := Changes;
   end Raise_Floor;

   --  An entry changed. Called with Lock held.
   procedure Mark_Changed (Key : String) is
   begin
      Changes := Changes + 1;
      Changed.Include (Key, Changes);
   end Mark_Changed;

   protected Lock is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Lock;

   protected body Lock is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Lock;

   --  Lock held for as long as one of these lives: seized as it is made,
   --  released however its scope is left -- an exception raised while it
   --  is held, in a handler among others, does not leave it held, so no
   --  later search waits on it for good.
   type Holding is new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Initialize (Self : in out Holding);
   overriding procedure Finalize (Self : in out Holding);

   overriding procedure Initialize (Self : in out Holding) is
      pragma Unreferenced (Self);
   begin
      Lock.Seize;
   end Initialize;

   overriding procedure Finalize (Self : in out Holding) is
      pragma Unreferenced (Self);
   begin
      Lock.Release;
   end Finalize;

   --  What a declaration's description says of a query: its points, and
   --  how many of the query's words it holds.
   type Said_Of is record
      Score : Natural := 0;
      Held  : Natural := 0;
   end record;

   package Said_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Said_Of, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   function Key_Of (Root, Path : String) return String
   is (Root & ASCII.NUL & Path);

   --  A word of a file: how often, and its first line.
   type Occurrence is record
      Count : Natural := 0;
      Line  : Positive := 1;
   end record;

   package Count_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Occurrence, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  A file's words, counted: worked out without the lock, the index
   --  untouched until they are installed.
   function Words_Of (Text : String) return Count_Maps.Map is
      Counted : Count_Maps.Map;

      procedure Take (Word : String; Line : Positive) is
         Position : constant Count_Maps.Cursor := Counted.Find (Word);
      begin
         if Count_Maps.Has_Element (Position) then
            Counted.Reference (Position).Count := Counted.Reference (Position).Count + 1;
         else
            Counted.Insert (Word, (Count => 1, Line => Line));
         end if;
      end Take;
   begin
      Each_Word (Text, Take'Access);
      return Counted;
   end Words_Of;

   --  A file let go of a term; the term let go of where no file holds it.
   --  Called with Lock held.
   procedure Unlink (Term, Doc : Positive) is
      Docs : Number_Lists.Vector renames Term_Docs.Reference (Term).Element.all;
      At_Doc : constant Natural := Docs.Find_Index (Doc);
   begin
      if At_Doc > 0 then
         Docs.Replace_Element (At_Doc, Docs.Last_Element);
         Docs.Delete_Last;
      end if;
      if Docs.Is_Empty then
         Dictionary.Delete (Term_Names (Term));
         Spelled.Delete (Term_Names (Term));
         Term_Names.Replace_Element (Term, "");
         Free_Terms.Append (Term);
      end if;
   end Unlink;

   --  A file's words out of the index, its number given back. Called with
   --  Lock held.
   procedure Drop (Key : String) is
      Doc : constant Positive := Index.Constant_Reference (Key).Doc;
   begin
      for One of Index.Constant_Reference (Key).Words loop
         Unlink (One.Term, Doc);
      end loop;
      Index.Delete (Key);
      Doc_Keys.Replace_Element (Doc, "");
      Free_Docs.Append (Doc);
      Mark_Changed (Key);
   end Drop;

   --  A file's counted words into the index, in place of what it held of
   --  the file before. Called with Lock held.
   procedure Install
     (Key, Print : String;
      Counted    : Count_Maps.Map;
      Described  : Description_Lists.Vector)
   is
      Doc   : Positive;
      Words : Posting_Array (1 .. Natural (Counted.Length));
      At_Word : Natural := 0;

      function Term_Of (Word : String) return Positive is
         Position : constant Term_Maps.Cursor := Dictionary.Find (Word);
         Term     : Positive;
      begin
         if Term_Maps.Has_Element (Position) then
            return Term_Maps.Element (Position);
         elsif not Free_Terms.Is_Empty then
            Term := Free_Terms.Last_Element;
            Free_Terms.Delete_Last;
            Term_Names.Replace_Element (Term, Word);
         else
            Term_Names.Append (Word);
            Term_Docs.Append (Number_Lists.Empty_Vector);
            Term := Term_Names.Last_Index;
         end if;
         Dictionary.Insert (Word, Term);
         Spelled.Insert (Word);
         return Term;
      end Term_Of;
   begin
      if Index.Contains (Key) then
         Doc := Index.Constant_Reference (Key).Doc;
         for One of Index.Constant_Reference (Key).Words loop
            Unlink (One.Term, Doc);
         end loop;
      elsif not Free_Docs.Is_Empty then
         Doc := Free_Docs.Last_Element;
         Free_Docs.Delete_Last;
         Doc_Keys.Replace_Element (Doc, Key);
      else
         Doc_Keys.Append (Key);
         Doc := Doc_Keys.Last_Index;
      end if;
      Model_Runner.Race_Points.Here (Model_Runner.Race_Points.Index_Midway);
      for Position in Counted.Iterate loop
         declare
            Term : constant Positive := Term_Of (Count_Maps.Key (Position));
         begin
            Term_Docs.Reference (Term).Append (Doc);
            At_Word := At_Word + 1;
            Words (At_Word) :=
              (Term => Term, Count => Count_Maps.Element (Position).Count, Line => Count_Maps.Element (Position).Line);
         end;
      end loop;
      Sort (Words);
      declare
         Said_Count : Natural := 0;
      begin
         for One of Described loop
            Said_Count := Said_Count + Natural (One.Words.Length);
         end loop;
         declare
            Said    : Posting_Array (1 .. Said_Count);
            Lengths : Number_Lists.Vector;
            At_Said : Natural := 0;
         begin
            for At_Block in 1 .. Natural (Described.Length) loop
               Lengths.Append (Natural (Described (At_Block).Words.Length));
               for Word of Described (At_Block).Words loop
                  --  Every word a comment says is a word of its file.
                  At_Said := At_Said + 1;
                  Said (At_Said) :=
                    (Term => Dictionary.Element (Word), Count => At_Block, Line => Described (At_Block).Describes);
               end loop;
            end loop;
            Sort (Said);
            Index.Include
              (Key, (Count => Words'Length, Said_Count => Said'Length, Print => To_Unbounded_String (Print),
                     Doc => Doc, Lengths => Lengths, Words => Words, Said => Said));
         end;
      end;
      Mark_Changed (Key);
   end Install;

   --  What a file holds of a term: its posting, or a count of nought.
   function Find (Words : Posting_Array; Term : Positive) return Posting is
      Low  : Positive := Words'First;
      High : Natural := Words'Last;
   begin
      while Low <= High loop
         declare
            Middle : constant Positive := (Low + High) / 2;
         begin
            if Words (Middle).Term = Term then
               return Words (Middle);
            elsif Words (Middle).Term < Term then
               Low := Middle + 1;
            else
               High := Middle - 1;
            end if;
         end;
      end loop;
      return (Term => Term, Count => 0, Line => 1);
   end Find;

   --  Whether a file's words are indexed: its source, tests and documents
   --  that are small enough.
   function Indexed (File : Rp.File_Entry) return Boolean
   is (File.Role in Rp.Source | Rp.Test | Rp.Documentation);

   --  Whether a path, every link on the way followed, lies in a tree as
   --  the tree resolves: a directory on the way may be a link out of it
   --  where the file itself is none. Only for a host that cannot read
   --  beneath a root: a check before the read, which a link swapped in
   --  between the two still passes.
   function Resolves_Within (Root, Full : String) return Boolean is
      Base : constant String := Hostkit.Fs.Real_Path (if Root = "" then "." else Root);
      Real : constant String := Hostkit.Fs.Real_Path (Full);
   begin
      return Base /= "" and then Real'Length > Base'Length
        and then Real (Real'First .. Real'First + Base'Length - 1) = Base
        and then (Base (Base'Last) in '/' | '\' or else Real (Real'First + Base'Length) in '/' | '\');
   end Resolves_Within;

   --  A path within a tree read as text, refused where it reaches outside
   --  the tree or through a link: the file itself a link, or a directory on
   --  the way one, whenever it became one. The host walks the path from the
   --  tree a part at a time and follows no link, so no check can be passed
   --  by one path and the read made through another.
   --  How many files have been read, for a measure of what a search costs.
   protected Reads is
      procedure Count;
      function Total return Natural;
   private
      Done : Natural := 0;
   end Reads;

   protected body Reads is
      procedure Count is
      begin
         Done := Done + 1;
      end Count;

      function Total return Natural is (Done);
   end Reads;

   --  Read_In reads by the path, as where Read_Beneath is not had.
   By_Path : Boolean := False with Atomic;

   procedure Read_In
     (Root   : String;
      Path   : String;
      Text   : out Unbounded_String;
      Status : out E.Error_Info;
      Most   : Natural := Records.Max_Bytes)
   is
      use type Hostkit.Fs.Read_Beneath_Outcome;
      Outcome : Hostkit.Fs.Read_Beneath_Outcome;
   begin
      Reads.Count;
      Text := Null_Unbounded_String;
      if Path'Length = 0 or else Path (Path'First) in '/' | '\'
        or else Has ("/" & Path & "/", "/../") or else Has (Path, ":")
      then
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", "path");
         E.Add_Text (Status, "value", Path);
         E.Add_Text (Status, "detail", "a path within the project, as src/x.adb, is wanted");
         return;
      end if;
      if By_Path then
         Outcome := Hostkit.Fs.Read_Unsupported;
      else
         Hostkit.Fs.Read_Beneath (Root, Path, Most, Text, Outcome);
      end if;
      case Outcome is
         when Hostkit.Fs.Read_Done =>
            Status := E.Success;
         when Hostkit.Fs.Read_Too_Large =>
            Status := E.Make (E.IO_File_Too_Large);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            E.Add_Integer (Status, "limit", Long_Long_Integer (Most), E.Param_Bytes);
         when Hostkit.Fs.Read_Unsupported =>
            declare
               Full : constant String := Hostkit.Fs.Join (Root, Path);
            begin
               if not Ada.Directories.Exists (Full) or else Hostkit.Fs.Is_Link (Full)
                 or else Ada.Directories."/=" (Ada.Directories.Kind (Full), Ada.Directories.Ordinary_File)
                 or else not Resolves_Within (Root, Full)
               then
                  Status := E.Make (E.Framework_Not_Found);
                  E.Add_Text (Status, "name", Path);
               else
                  Files.Read_Text (Full, Text, Status, Most);
               end if;
            end;
         when Hostkit.Fs.Read_Outside | Hostkit.Fs.Read_Missing | Hostkit.Fs.Read_Not_File
            | Hostkit.Fs.Read_Failed =>
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Path);
      end case;
   exception
      when others =>
         Text := Null_Unbounded_String;
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", Path);
   end Read_In;

   --  The whole index let go, to be read anew: where a change to it was
   --  stopped part way -- memory run out in the middle of an install --
   --  its dictionary, postings and entries need not agree, and nothing of
   --  them is kept. A pass under way does not install over it. Called
   --  with Lock held.
   procedure Clear_Index is
   begin
      Index.Clear;
      Dictionary.Clear;
      Spelled.Clear;
      Term_Names.Clear;
      Term_Docs.Clear;
      Free_Terms.Clear;
      Doc_Keys.Clear;
      Free_Docs.Clear;
      Unsearched.Clear;
      Raise_Floor;
   end Clear_Index;

   --  The tree a key is of: what comes before its NUL.
   function Root_Of (Key : String) return String is
      At_Nul : constant Natural := Ada.Strings.Fixed.Index (Key, [1 => ASCII.NUL]);
   begin
      return (if At_Nul = 0 then Key else Key (Key'First .. At_Nul - 1));
   end Root_Of;

   --  Whether a tree is Root or one beneath it, both as full names.
   function Within (Tree, Root : String) return Boolean is
      Full : constant String := Ada.Directories.Full_Name (if Tree = "" then "." else Tree);
      Base : constant String := Ada.Directories.Full_Name (if Root = "" then "." else Root);
   begin
      return Full = Base
        or else (Full'Length > Base'Length and then Full (Full'First .. Full'First + Base'Length - 1) = Base
                 and then Full (Full'First + Base'Length) in '/' | '\');
   end Within;

   --  Every file of the trees Gone holds let go: its entry, and what is
   --  noted of it as not searched or failed. Called with Lock held.
   procedure Drop_Trees (Gone : Name_Sets.Set) is
      Keys : Name_Lists.Vector;
   begin
      if Gone.Is_Empty then
         return;
      end if;
      for Position in Index.Iterate loop
         if Gone.Contains (Root_Of (Word_Maps.Key (Position))) then
            Keys.Append (Word_Maps.Key (Position));
         end if;
      end loop;
      for Key of Keys loop
         Drop (Key);
      end loop;
      Keys.Clear;
      for Position in Unsearched.Iterate loop
         if Gone.Contains (Root_Of (Unsearched_Maps.Key (Position))) then
            Keys.Append (Unsearched_Maps.Key (Position));
         end if;
      end loop;
      for Key of Keys loop
         Unsearched.Delete (Key);
      end loop;
      Keys.Clear;
      for Position in Failed.Iterate loop
         if Gone.Contains (Root_Of (Failed_Maps.Key (Position))) then
            Keys.Append (Failed_Maps.Key (Position));
         end if;
      end loop;
      for Key of Keys loop
         Failed.Delete (Key);
      end loop;
   end Drop_Trees;

   --  The trees the index holds files of, other than Root, whose root is
   --  gone -- a workspace removed when its task ended, never searched
   --  again: let go, or every one would be held until the program ends.
   --  Called with Lock held.
   procedure Drop_Gone_Trees (Root : String) is
      Seen : Name_Sets.Set;
      Gone : Name_Sets.Set;

      procedure Look (Key : String) is
         Tree : constant String := Root_Of (Key);
      begin
         if Tree /= Root and then not Seen.Contains (Tree) then
            Seen.Include (Tree);
            if not Ada.Directories.Exists (if Tree = "" then "." else Tree) then
               Gone.Include (Tree);
            end if;
         end if;
      end Look;
   begin
      for Position in Index.Iterate loop
         Look (Word_Maps.Key (Position));
      end loop;
      for Position in Unsearched.Iterate loop
         Look (Unsearched_Maps.Key (Position));
      end loop;
      for Position in Failed.Iterate loop
         Look (Failed_Maps.Key (Position));
      end loop;
      Drop_Trees (Gone);
   end Drop_Gone_Trees;

   --  The files a pass under way has chosen to read, by key, with the
   --  print it chose each at: another pass that finds one of them stale
   --  at that print waits for its install rather than read it again --
   --  two searches of a tree not yet indexed read it once between them.
   --  One whose graph has another print reads it itself: that is newer
   --  work, not the same. Under Lock; kept when the index is let go, as
   --  the passes holding the claims are still under way.
   --  A claim names the pass that holds it, and only that pass releases
   --  it: a file claimed again at a newer print by another pass is that
   --  pass's to release, not the older one's, which would otherwise end
   --  the claim others are waiting on.
   type Claim is record
      Print : Unbounded_String;
      Owner : Positive;
   end record;
   package Claim_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Claim, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
   In_Flight : Claim_Maps.Map;
   Last_Pass : Natural := 0;

   --  How long a search waits on others' claims at most.
   Claim_Wait : Duration := 60.0;

   --  Told each time a claim is released: a search waiting on claims is
   --  woken to look again, rather than look every few milliseconds.
   protected Releases is
      procedure Signal;
      function Count return Natural;
      --  Return once a claim has been released since Count said After.
      entry Await (After : Natural);
   private
      entry Hold (After : Natural);
      Released  : Natural := 0;
      Releasing : Boolean := False;
   end Releases;

   protected body Releases is
      procedure Signal is
      begin
         Released := (if Released = Natural'Last then 0 else Released + 1);
         Releasing := Hold'Count > 0;
      end Signal;

      function Count return Natural is (Released);

      entry Await (After : Natural) when True is
      begin
         if Released = After then
            requeue Hold with abort;
         end if;
      end Await;

      entry Hold (After : Natural) when Releasing is
         pragma Unreferenced (After);
      begin
         if Hold'Count = 0 then
            Releasing := False;
         end if;
      end Hold;
   end Releases;

   --  A claim given up by the pass that holds it, and only by it. Called
   --  with Lock held.
   procedure Release_Claim (Key : String; Owner : Positive) is
      Position : constant Claim_Maps.Cursor := In_Flight.Find (Key);
   begin
      if Claim_Maps.Has_Element (Position) and then Claim_Maps.Element (Position).Owner = Owner then
         In_Flight.Delete (Key);
         Releases.Signal;
      end if;
   end Release_Claim;

   --  An indexing pass under way, from its count among Passes to the claims
   --  it holds: given back however Bring_Up is left -- an exception while a
   --  failure is noted among others -- so neither outlives the pass.
   type Pass_Hold is new Ada.Finalization.Limited_Controlled with record
      Id      : Positive := 1;
      Counted : Boolean := False;
      Claimed : Name_Sets.Set;
   end record;

   overriding procedure Finalize (Self : in out Pass_Hold);

   --  Nothing here allocates or reads: the lock is a protected entry, the
   --  claims and the count are let go in place. The handler is the last
   --  guard finalization must have -- an exception out of it is a program
   --  error where the pass's scope ends -- not a path in use.
   overriding procedure Finalize (Self : in out Pass_Hold) is
   begin
      if Self.Counted or else not Self.Claimed.Is_Empty then
         declare
            Locked : Holding;
            pragma Unreferenced (Locked);
         begin
            for Key of Self.Claimed loop
               Release_Claim (Key, Self.Id);
            end loop;
            Self.Claimed.Clear;
            if Self.Counted then
               Self.Counted := False;
               Passes := Passes - 1;
               if Passes = 0 and then not Changed.Is_Empty then
                  Raise_Floor;
               end if;
            end if;
         end;
      end if;
   exception
      when others =>
         null;
   end Finalize;

   --  The index brought up to the graph -- one brought up to the tree as
   --  it is now, by Search -- a file read again where its print changed,
   --  one gone dropped; and how many of the tree's files it holds. What is
   --  to be read is found under Lock, and what is gone dropped; each file
   --  is read and its words counted without it, and installed under it:
   --  a search of one tree does not wait on another's reading.
   --
   --  What is installed is what was read, under the print of what was
   --  read: a file changed since the graph was taken is held as it is
   --  now, not under the graph's older print. It is installed only where
   --  its entry has not changed since this pass chose to read it; another
   --  pass that installed or dropped it in between knew as much or more.
   --  A file too large is held with no words, as it is until it changes;
   --  one that could not be read is not held at all, so the next search
   --  reads it again rather than take it to have no words; both are
   --  noted, for Not_Searched. A change to the index raising part way
   --  lets the whole index go (Clear_Index), the next search reading it
   --  anew, and the pass reads in no more; a file whose words could not
   --  be counted is passed by and the pass goes on. Either file is noted
   --  (Failed) and tried again once its wait is over.
   procedure Bring_Up (Graph : Rp.Graph; Root : String; Files : out Natural) is
      Present : Name_Sets.Set;
      Stale   : Name_Lists.Vector;
      Prints  : Name_Lists.Vector;
      Seen    : Change_Lists.Vector;
      --  Whether this pass let the index go: it then reads in no more.
      Let_Go  : Boolean := False;
      Pass    : Pass_Hold;
      --  The files another pass claimed at the print this one found, and
      --  that print.
      Waiting : Name_Lists.Vector;
      Waited  : Name_Lists.Vector;
      --  Whether whoever this search is for has been stopped: no more is
      --  read for it, nor waited for.
      function Stop_Asked return Boolean
      is (Model_Runner.Framework.Execution.Cancel_Requested or else Model_Runner.Framework.Execution.Work_Withdrawn);
   begin
      declare
         Locked : Holding;
         pragma Unreferenced (Locked);
      begin
         Passes := Passes + 1;
         Pass.Counted := True;
         Last_Pass := (if Last_Pass = Natural'Last then 1 else Last_Pass + 1);
         Pass.Id := Last_Pass;
         for Index_At in 1 .. Rp.File_Count (Graph) loop
            declare
               File : constant Rp.File_Entry := Rp.File_At (Graph, Index_At);
               Path : constant String := To_String (File.Path);
               Key  : constant String := Key_Of (Root, Path);
            begin
               if Indexed (File) then
                  Present.Include (Key);
                  if (not Index.Contains (Key) or else Index.Constant_Reference (Key).Print /= File.Fingerprint)
                    and then (not Failed.Contains (Key)
                              or else Due (Failed.Element (Key), To_String (File.Fingerprint)))
                  then
                     if In_Flight.Contains (Key) and then In_Flight.Element (Key).Print = File.Fingerprint then
                        Waiting.Append (Key);
                        Waited.Append (To_String (File.Fingerprint));
                     else
                        Stale.Append (Path);
                        Prints.Append (To_String (File.Fingerprint));
                        Seen.Append (Change_Of (Key));
                        --  Kept among the pass's claims before it is
                        --  taken: one raising between leaves nothing
                        --  claimed that the pass would not give back.
                        Pass.Claimed.Include (Key);
                        Model_Runner.Race_Points.Here (Model_Runner.Race_Points.Index_Claims);
                        In_Flight.Include (Key, (Print => File.Fingerprint, Owner => Pass.Id));
                     end if;
                  end if;
               end if;
            end;
         end loop;

         Drop_Gone_Trees (Root);

         --  What the tree no longer holds -- deleted, or renamed to a path
         --  read below -- is no longer indexed.
         declare
            Gone : Name_Lists.Vector;
         begin
            for Position in Index.Iterate loop
               declare
                  Key : constant String := Word_Maps.Key (Position);
               begin
                  if Key'Length > Root'Length and then Key (Key'First .. Key'First + Root'Length) = Root & ASCII.NUL
                    and then not Present.Contains (Key)
                  then
                     Gone.Append (Key);
                  end if;
               end;
            end loop;
            for Key of Gone loop
               Drop (Key);
            end loop;
            Gone.Clear;
            for Position in Unsearched.Iterate loop
               declare
                  Key : constant String := Unsearched_Maps.Key (Position);
               begin
                  if Key'Length > Root'Length and then Key (Key'First .. Key'First + Root'Length) = Root & ASCII.NUL
                    and then not Present.Contains (Key)
                  then
                     Gone.Append (Key);
                  end if;
               end;
            end loop;
            for Key of Gone loop
               Unsearched.Delete (Key);
            end loop;
            Gone.Clear;
            for Position in Failed.Iterate loop
               declare
                  Key : constant String := Failed_Maps.Key (Position);
               begin
                  if Key'Length > Root'Length and then Key (Key'First .. Key'First + Root'Length) = Root & ASCII.NUL
                    and then not Present.Contains (Key)
                  then
                     Gone.Append (Key);
                  end if;
               end;
            end loop;
            for Key of Gone loop
               Failed.Delete (Key);
            end loop;
         end;
      exception
         when others =>
            Clear_Index;
            raise;
      end;
      Files := Natural (Present.Length);

      declare
         --  Stopped: what is left unread is said so, and its claims go
         --  with the pass.
         procedure Say_Stopped (From : Positive) is
            Locked : Holding;
            pragma Unreferenced (Locked);
         begin
            for Rest in From .. Natural (Stale.Length) loop
               Unsearched.Include (Key_Of (Root, Stale (Rest)), Stopped);
            end loop;
         end Say_Stopped;
      begin
         for At_Stale in 1 .. Natural (Stale.Length) loop
            if Stop_Asked then
               Say_Stopped (At_Stale);
               exit;
            end if;
            declare
               Path    : constant String := Stale (At_Stale);
               Text    : Unbounded_String;
               Status  : E.Error_Info;
               Stage   : Unbounded_String := To_Unbounded_String ("reading it");
            begin
               --  The size held to in the read itself: no look at the file by
               --  its path before it is opened.
               Read_In (Root, Path, Text, Status, Most => Indexed_Most);
               Model_Runner.Race_Points.Here (Model_Runner.Race_Points.Index_Installs);
               --  Stopped while it was read: its words are not counted.
               if Stop_Asked then
                  Say_Stopped (At_Stale);
                  exit;
               end if;
               Stage := To_Unbounded_String ("counting its words");
               declare
                  use type E.Error_Code;
                  Key       : constant String := Key_Of (Root, Path);
                  Oversized : constant Boolean := Status.Code = E.IO_File_Too_Large;
                  Counted   : constant Count_Maps.Map :=
                    (if E.Is_Ok (Status) then Words_Of (To_String (Text)) else Count_Maps.Empty_Map);
                  Described : constant Description_Lists.Vector :=
                    (if E.Is_Ok (Status) then Descriptions_Of (To_String (Text), Rp.Language_Of (Path))
                     else Description_Lists.Empty_Vector);
                  Print     : constant String :=
                    (if E.Is_Ok (Status) then Fingerprint (To_String (Text)) else Prints (At_Stale));
               begin
                  Stage := To_Unbounded_String ("installing it");
                  declare
                     Locked : Holding;
                     pragma Unreferenced (Locked);
                  begin
                     --  Installed only by the pass still holding the file's
                     --  claim: one whose claim another took at a newer print
                     --  read a file since changed, and leaves it to that one.
                     if Change_Of (Key) = Seen (At_Stale)
                       and then In_Flight.Contains (Key) and then In_Flight.Element (Key).Owner = Pass.Id
                     then
                        if E.Is_Ok (Status) or else Oversized then
                           Install (Key, Print, Counted, Described);
                           Read_Count := Read_Count + 1;
                        elsif Index.Contains (Key) then
                           Drop (Key);
                        end if;
                        if E.Is_Ok (Status) then
                           Unsearched.Exclude (Key);
                        else
                           Unsearched.Include (Key, (if Oversized then Too_Large else Unreadable));
                        end if;
                        Failed.Exclude (Key);
                     end if;
                     Release_Claim (Key, Pass.Id);
                     Pass.Claimed.Exclude (Key);
                  exception
                     when others =>
                        Clear_Index;
                        Let_Go := True;
                        raise;
                  end;
               end;
            exception
               --  This file's reading in failed: noted, to be tried again
               --  once its wait is over. A fault of this file's own -- its
               --  words could not be counted -- passes it by, and the pass
               --  goes on to the next; one that let the index go ends the
               --  pass, which has nothing left to install into.
               when Error : others =>
                  --  Noted as it can be: memory short again, or anything else
                  --  raised in the noting, leaves the file unnoted -- read
                  --  again by the next search -- and the pass as it was.
                  declare
                     use type Ada.Real_Time.Time;
                     use type Ada.Exceptions.Exception_Id;
                     Key     : constant String := Key_Of (Root, Path);
                     Fault   : constant Boolean := Ada.Exceptions.Exception_Identity (Error) /= Storage_Error'Identity;
                     Message : constant String := Ada.Exceptions.Exception_Message (Error);
                     Tries   : Positive := (if Fault then Most_Tries else 1);
                     Locked  : Holding;
                     pragma Unreferenced (Locked);
                  begin
                     Release_Claim (Key, Pass.Id);
                     Pass.Claimed.Exclude (Key);
                     --  The failure is what is said of it now: a waiting
                     --  search's "still being read" went on beside it, of a
                     --  file nobody was reading any more.
                     Unsearched.Exclude (Key);
                     Model_Runner.Race_Points.Here (Model_Runner.Race_Points.Index_Failure_Noted);
                     if not Fault and then Failed.Contains (Key)
                       and then To_String (Failed.Element (Key).Print) = Prints (At_Stale)
                     then
                        Tries := Natural'Min (Failed.Element (Key).Tries + 1, Most_Tries);
                     end if;
                     Failed.Include
                       (Key, (Print  => To_Unbounded_String (Prints (At_Stale)), Tries => Tries,
                              Next   => Ada.Real_Time.Clock
                                          + Ada.Real_Time.To_Time_Span (Retry_Wait * 2 ** (Tries - 1)),
                              Stage  => Stage,
                              Name   => To_Unbounded_String (Ada.Exceptions.Exception_Name (Error)),
                              Fault  => Fault,
                              Detail => To_Unbounded_String
                                          (if Fault then Message (Message'First .. Message'First
                                                                     + Natural'Min (Message'Length, 120) - 1)
                                           else "")));
                  exception
                     when others =>
                        null;
                  end;
                  exit when Let_Go;
            end;
         end loop;
      end;

      --  Files another pass claimed: waited for, not read again -- its
      --  install is what this search is to see. Woken each time a claim is
      --  released, and every quarter second to see whether this search's
      --  work was stopped. Not by a pass that let the index go, which has
      --  nothing to see them in; a minute at most. What is still claimed
      --  when the waiting ends is said by Not_Searched as being read, not
      --  taken to hold nothing.
      if not Waiting.Is_Empty and then not Let_Go then
         declare
            use type Ada.Real_Time.Time;
            Give_Up : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Claim_Wait);
            Busy    : Boolean := True;
            Heard   : Natural;

            function Still_Claimed (At_Wait : Positive) return Boolean
            is (In_Flight.Contains (Waiting (At_Wait))
                and then To_String (In_Flight.Element (Waiting (At_Wait)).Print) = Waited (At_Wait));
         begin
            loop
               Heard := Releases.Count;
               declare
                  Locked : Holding;
                  pragma Unreferenced (Locked);
               begin
                  Busy := (for some At_Wait in 1 .. Natural (Waiting.Length) => Still_Claimed (At_Wait));
               end;
               exit when not Busy or else Stop_Asked or else Ada.Real_Time.Clock >= Give_Up;
               declare
                  Look_Again : Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (250);
               begin
                  if Give_Up < Look_Again then
                     Look_Again := Give_Up;
                  end if;
                  select
                     Releases.Await (Heard);
                  or
                     delay until Look_Again;
                  end select;
               end;
            end loop;
            if Busy then
               declare
                  Locked : Holding;
                  pragma Unreferenced (Locked);
               begin
                  for At_Wait in 1 .. Natural (Waiting.Length) loop
                     if Still_Claimed (At_Wait) then
                        Unsearched.Include (Waiting (At_Wait), (if Stop_Asked then Stopped else Being_Read));
                     end if;
                  end loop;
               end;
            end if;
         end;
      end if;
   end Bring_Up;

   --------------------------
   -- Retry_Indexing_After --
   --------------------------

   procedure Retry_Indexing_After (Wait : Duration) is
      use type Ada.Real_Time.Time;
      Held_To : constant Duration := Duration'Max (0.0, Duration'Min (Wait, Longest_Wait));
      By      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Held_To);
      Locked  : Holding;
      pragma Unreferenced (Locked);
   begin
      Retry_Wait := Held_To;
      for Was of Failed loop
         if Was.Next > By then
            Was.Next := By;
         end if;
      end loop;
   end Retry_Indexing_After;

   -----------------------------
   -- Wait_For_Claims_At_Most --
   -----------------------------

   procedure Wait_For_Claims_At_Most (Most : Duration) is
      Locked : Holding;
      pragma Unreferenced (Locked);
   begin
      Claim_Wait := Duration'Max (0.0, Duration'Min (Most, 3_600.0));
   end Wait_For_Claims_At_Most;

   ------------------
   -- Read_By_Path --
   ------------------

   procedure Read_By_Path (On : Boolean) is
   begin
      By_Path := On;
   end Read_By_Path;

   -----------------
   -- Forget_Tree --
   -----------------

   procedure Forget_Tree (Root : String) is
      Seen : Name_Sets.Set;
      Gone : Name_Sets.Set;

      procedure Look (Key : String) is
         Tree : constant String := Root_Of (Key);
      begin
         if not Seen.Contains (Tree) then
            Seen.Include (Tree);
            if Within (Tree, Root) then
               Gone.Include (Tree);
            end if;
         end if;
      end Look;
   begin
      declare
         Locked : Holding;
         pragma Unreferenced (Locked);
      begin
         for Position in Index.Iterate loop
            Look (Word_Maps.Key (Position));
         end loop;
         for Position in Unsearched.Iterate loop
            Look (Unsearched_Maps.Key (Position));
         end loop;
         for Position in Failed.Iterate loop
            Look (Failed_Maps.Key (Position));
         end loop;
         Drop_Trees (Gone);
      exception
         when others =>
            Clear_Index;
            raise;
      end;
   end Forget_Tree;

   ------------------
   -- Not_Searched --
   ------------------

   function Not_Searched (Graph : Repository.Graph; Root : String) return Name_Lists.Vector is
      package Sorting is new Name_Lists.Generic_Sorting;
      Result : Name_Lists.Vector;
      Held   : Name_Lists.Vector;
   begin
      for Path of Rp.Unread_Paths (Graph) loop
         Result.Append (Path & ": could not be read");
      end loop;
      declare
         Locked : Holding;
         pragma Unreferenced (Locked);
      begin
         for Position in Unsearched.Iterate loop
            declare
               Key : constant String := Unsearched_Maps.Key (Position);
            begin
               if Key'Length > Root'Length and then Key (Key'First .. Key'First + Root'Length) = Root & ASCII.NUL then
                  Held.Append (Key (Key'First + Root'Length + 1 .. Key'Last)
                               & (case Unsearched_Maps.Element (Position) is
                                     when Too_Large  => ": too large to index",
                                     when Unreadable => ": could not be read",
                                     when Being_Read => ": still being read by another search",
                                     when Stopped    => ": not read, the work was stopped"));
               end if;
            end;
         end loop;
         for Position in Failed.Iterate loop
            declare
               Key : constant String := Failed_Maps.Key (Position);
            begin
               if Key'Length > Root'Length and then Key (Key'First .. Key'First + Root'Length) = Root & ASCII.NUL then
                  declare
                     use type Ada.Real_Time.Time;
                     Was  : constant Failure := Failed_Maps.Element (Position);
                     Left : constant Duration := Ada.Real_Time.To_Duration (Was.Next - Ada.Real_Time.Clock);
                  begin
                     Held.Append
                       (Key (Key'First + Root'Length + 1 .. Key'Last) & ": could not be indexed ("
                        & To_String (Was.Name) & " " & To_String (Was.Stage)
                        & (if Was.Fault
                           then ", a fault of the program's own"
                                & (if Length (Was.Detail) = 0 then "" else ": " & To_String (Was.Detail))
                                & "; not tried again until it changes"
                           else ", " & Image (Was.Tries) & (if Was.Tries = 1 then " time; " else " times; ")
                                & (if Was.Tries >= Most_Tries then "not tried again until it changes"
                                   elsif Left <= 0.0 then "tried again by the next search"
                                   else "tried again in" & Natural'Image (Natural (Float'Ceiling (Float (Left))))
                                        & " s"))
                        & ")");
                  end;
               end if;
            end;
         end loop;
      end;
      Result.Append (Held);
      Sorting.Sort (Result);
      return Result;
   end Not_Searched;

   ------------
   -- Forget --
   ------------

   procedure Forget is
      Locked : Holding;
      pragma Unreferenced (Locked);
   begin
      Clear_Index;
      Failed.Clear;
      Read_Count := 0;
   end Forget;

   ---------------------
   -- Indexed_Changes --
   ---------------------

   function Indexed_Changes return Natural is
      Locked : Holding;
      pragma Unreferenced (Locked);
   begin
      return Natural (Changed.Length);
   end Indexed_Changes;

   -------------------
   -- Indexed_Reads --
   -------------------

   function Indexed_Reads return Natural is
      Locked : Holding;
      pragma Unreferenced (Locked);
   begin
      return Read_Count;
   end Indexed_Reads;

   ----------------
   -- Indexed_Held --
   ----------------

   function Indexed_Held return Natural is
      Locked : Holding;
      pragma Unreferenced (Locked);
   begin
      return Natural (Index.Length);
   end Indexed_Held;

   ----------------
   -- Files_Read --
   ----------------

   function Files_Read return Natural is (Reads.Total);

   -------------------
   -- Indexed_Terms --
   -------------------

   function Indexed_Terms return Natural is
      Locked : Holding;
      pragma Unreferenced (Locked);
   begin
      return Natural (Dictionary.Length);
   end Indexed_Terms;

   ---------------------------------------------------------------------------
   --  Search.
   ---------------------------------------------------------------------------

   function "<" (Left, Right : Hit) return Boolean is
   begin
      if Left.Score /= Right.Score then
         return Left.Score > Right.Score;
      elsif Left.Kind /= Right.Kind then
         return Left.Kind < Right.Kind;
      elsif Left.Name /= Right.Name then
         return Left.Name < Right.Name;
      else
         return Left.Line < Right.Line;
      end if;
   end "<";

   package Hit_Sorting is new Hit_Lists.Generic_Sorting ("<");

   --  The parts of a name: split at dots, colons and underscores, lowered.
   function Parts_Of (Name : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Positive := Name'First;
   begin
      for Index_At in Name'First .. Name'Last + 1 loop
         if Index_At > Name'Last or else Name (Index_At) in '.' | ':' | '_' then
            if Index_At > Start then
               Result.Append (Lower (Name (Start .. Index_At - 1)));
            end if;
            Start := Index_At + 1;
         end if;
      end loop;
      return Result;
   end Parts_Of;

   --  The last part of a dotted or :: name.
   function Last_Part (Name : String) return String is
   begin
      for Index_At in reverse Name'Range loop
         if Name (Index_At) in '.' | ':' then
            return Name (Index_At + 1 .. Name'Last);
         end if;
      end loop;
      return Name;
   end Last_Part;

   function Ends_With (Text, Tail : String) return Boolean
   is (Text'Length > Tail'Length and then Text (Text'Last - Tail'Length + 1 .. Text'Last) = Tail);

   --  Search, the graph already brought up to the tree.
   function Search_Current
     (Store    : Stores.Store;
      Graph    : Repository.Graph;
      Tree     : String;
      Query    : String;
      Most     : Positive;
      Near     : Name_Lists.Vector;
      May_Read : Path_Check;
      Records  : Boolean) return Hit_Lists.Vector
   is
      Wholes  : constant Name_Lists.Vector := Wholes_Of (Query);
      --  The most words a query may have and a symbol's name still count
      --  whole (see the symbols' points); chosen on the dev set of commit
      --  subjects.
      Name_Reach : constant := 4;
      Plain   : constant Name_Sets.Set := Plain_Words (Query);
      Terms   : constant Name_Lists.Vector := Terms_Of (Query);
      Asks_Tests : constant Boolean := (for some Term of Terms => Term in "test" | "tests");
      Found   : Hit_Lists.Vector;

      function Shown (Path : String) return Boolean
      is (May_Read = null or else May_Read (Path));

      --  Each file's units, and the units close to those the work is about.
      Units_Of   : Name_Sets.Set;
      Near_Units : Name_Sets.Set;
      Surely     : Name_Sets.Set;
      Probably   : Name_Sets.Set;
      File_Units : Name_Lists.Vector;

      --  The test files, as the project's roots say them.
      Test_Files : Name_Sets.Set;

      --  The tree's indexed files, and what each declaration's comment
      --  says of the query, by path and line.
      Files     : Natural := 0;
      Described : Said_Maps.Map;

      function Closeness (Path : String) return Natural is
         Best : Natural := 0;
      begin
         if Near_Units.Is_Empty then
            return 0;
         end if;
         for Pair of File_Units loop
            declare
               Tab : constant Natural := Ada.Strings.Fixed.Index (Pair, [ASCII.HT]);
            begin
               if Pair (Pair'First .. Tab - 1) = Path then
                  declare
                     Unit : constant String := Pair (Tab + 1 .. Pair'Last);
                  begin
                     if Near_Units.Contains (Unit) then
                        return 100;
                     elsif Surely.Contains (Unit) then
                        Best := Natural'Max (Best, 60);
                     elsif Probably.Contains (Unit) then
                        Best := Natural'Max (Best, 30);
                     end if;
                  end;
               end if;
            end;
         end loop;
         return Best;
      end Closeness;

      procedure Add (Item : Hit) is
      begin
         Found.Append (Item);
      end Add;
   begin
      if Wholes.Is_Empty and then Terms.Is_Empty then
         return Found;
      end if;

      for Unit of Near loop
         Near_Units.Include (Unit);
      end loop;
      for Index_At in 1 .. Rp.File_Count (Graph) loop
         if Rp.File_At (Graph, Index_At).Role = Rp.Test then
            Test_Files.Include (To_String (Rp.File_At (Graph, Index_At).Path));
         end if;
      end loop;
      for Index_At in 1 .. Rp.Relation_Count (Graph) loop
         declare
            Link : constant Rp.Relation := Rp.Relation_At (Graph, Index_At);
         begin
            if Link.Kind = Rp.Contains then
               File_Units.Append (To_String (Link.From) & ASCII.HT & To_String (Link.To));
               Units_Of.Include (To_String (Link.To));
            elsif Link.Kind = Rp.Depends_On and then not Near_Units.Is_Empty then
               for Side in 1 .. 2 loop
                  declare
                     One   : constant String := To_String (if Side = 1 then Link.From else Link.To);
                     Other : constant String := To_String (if Side = 1 then Link.To else Link.From);
                  begin
                     if Near_Units.Contains (One) then
                        if Link.Sure in Rp.Authoritative | Rp.Certain then
                           Surely.Include (Other);
                        else
                           Probably.Include (Other);
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;

      --  The index brought up to the tree, and the declarations' comments
      --  weighed: for each query word a description holds -- the word, or
      --  one Alike it -- ten times the log2 of 1 + descriptions over those
      --  holding it; the sum twice, times the share of the query's words it
      --  holds, times 2 over 1 + its length over the mean length; at most
      --  350. One holding only one of two or more words is not counted. A
      --  search visits the files that hold the words, as the text's does.
      Bring_Up (Graph, Tree, Files);
      if not Terms.Is_Empty then
         declare
            Locked : Holding;
            pragma Unreferenced (Locked);
         begin
            declare
               Prefix   : constant String := Tree & ASCII.NUL;
               Count_Of : constant Positive := Natural (Terms.Length);
               Spread   : array (1 .. Count_Of) of Natural := [others => 0];
               Blocks   : Natural := 0;
               Words    : Natural := 0;

               --  A description's place, path and line, with its length and
               --  which of the query's words it holds.
               type Mark (Count : Positive) is record
                  Length : Natural := 0;
                  Holds  : String (1 .. Count);
               end record;
               type Place is record
                  Doc, Line : Positive := 1;
               end record;
               function "<" (Left, Right : Place) return Boolean
               is (Left.Doc < Right.Doc or else (Left.Doc = Right.Doc and then Left.Line < Right.Line));
               package Mark_Maps is new Ada.Containers.Indefinite_Ordered_Maps
                 (Key_Type => Place, Element_Type => Mark);
               Marks : Mark_Maps.Map;

               function In_Tree (Key : String) return Boolean
               is (Key'Length > Prefix'Length and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix);

               function Path_Of (Doc : Positive) return String is
                  Key : constant String := Doc_Keys (Doc);
               begin
                  return Key (Key'First + Prefix'Length .. Key'Last);
               end Path_Of;
            begin
               for Position in Index.Iterate loop
                  if In_Tree (Word_Maps.Key (Position)) then
                     for Length of Index.Constant_Reference (Position).Lengths loop
                        Blocks := Blocks + 1;
                        Words := Words + Length;
                     end loop;
                  end if;
               end loop;
               for At_Term in 1 .. Count_Of loop
                  declare
                     Term : constant String := Terms (At_Term);
                     Ids  : Number_Lists.Vector;
                  begin
                     --  The word itself, the words it begins, and those of
                     --  four letters or more that begin it.
                     if Term'Length >= 4 then
                        declare
                           Next : Word_Sets.Cursor := Spelled.Ceiling (Term);
                        begin
                           while Word_Sets.Has_Element (Next) and then Alike (Term, Word_Sets.Element (Next))
                             and then Word_Sets.Element (Next)'Length >= Term'Length
                           loop
                              Ids.Append (Dictionary.Element (Word_Sets.Element (Next)));
                              Word_Sets.Next (Next);
                           end loop;
                        end;
                        for Length in 4 .. Term'Length - 1 loop
                           if Dictionary.Contains (Term (Term'First .. Term'First + Length - 1)) then
                              Ids.Append (Dictionary.Element (Term (Term'First .. Term'First + Length - 1)));
                           end if;
                        end loop;
                     elsif Dictionary.Contains (Term) then
                        Ids.Append (Dictionary.Element (Term));
                     end if;
                     for Id of Ids loop
                        for Doc of Term_Docs (Id) loop
                           declare
                              Key : constant String := Doc_Keys (Doc);
                           begin
                              if In_Tree (Key) and then Shown (Key (Key'First + Prefix'Length .. Key'Last)) then
                                 declare
                                    Held : File_Words renames Index.Constant_Reference (Key).Element.all;
                                    Low  : Positive := Held.Said'First;
                                    High : Natural := Held.Said'Last;
                                 begin
                                    --  The first of the term's postings, then each.
                                    while Low <= High loop
                                       declare
                                          Middle : constant Positive := (Low + High) / 2;
                                       begin
                                          if Held.Said (Middle).Term < Id then
                                             Low := Middle + 1;
                                          else
                                             High := Middle - 1;
                                          end if;
                                       end;
                                    end loop;
                                    for At_Said in Low .. Held.Said'Last loop
                                       exit when Held.Said (At_Said).Term /= Id;
                                       declare
                                          One   : constant Posting := Held.Said (At_Said);
                                          Where : constant Place := (Doc => Doc, Line => One.Line);
                                          At_Mark  : Mark_Maps.Cursor := Marks.Find (Where);
                                          Inserted : Boolean;
                                       begin
                                          if not Mark_Maps.Has_Element (At_Mark) then
                                             Marks.Insert
                                               (Where, (Count => Count_Of, Length => Held.Lengths (One.Count),
                                                        Holds => [others => '0']), At_Mark, Inserted);
                                          end if;
                                          if Marks.Reference (At_Mark).Holds (At_Term) = '0' then
                                             Marks.Reference (At_Mark).Holds (At_Term) := '1';
                                             Spread (At_Term) := Spread (At_Term) + 1;
                                          end if;
                                       end;
                                    end loop;
                                 end;
                              end if;
                           end;
                        end loop;
                     end loop;
                  end;
               end loop;
               for Position in Marks.Iterate loop
                  declare
                     Got  : Mark renames Mark_Maps.Constant_Reference (Marks, Position).Element.all;
                     Held : constant Natural := Ada.Strings.Fixed.Count (Got.Holds, "1");
                     Mean : constant Float := Float (Words) / Float (Natural'Max (1, Blocks));
                     Sum  : Float := 0.0;
                  begin
                     if Held >= 2 or else Count_Of = 1 then
                        for At_Term in Got.Holds'Range loop
                           if Got.Holds (At_Term) = '1' then
                              Sum := Sum + 10.0 * Ada.Numerics.Elementary_Functions.Log
                                                    (1.0 + Float (Blocks) / Float (Spread (At_Term)), 2.0);
                           end if;
                        end loop;
                        Described.Include
                          (Path_Of (Mark_Maps.Key (Position).Doc) & ASCII.NUL & Image (Mark_Maps.Key (Position).Line),
                           (Score => Natural'Min
                                       (350, Natural (Float'Floor
                                                        (2.0 * Sum * Float (Held) / Float (Count_Of)
                                                         * 2.0 / (1.0 + Float (Got.Length) / Mean)))),
                            Held  => Held));
                     end if;
                  end;
               end loop;
            end;
         end;
      end if;

      --  Symbols.
      for Index_At in 1 .. Rp.Symbol_Count (Graph) loop
         declare
            One   : constant Rp.Symbol := Rp.Symbol_At (Graph, Index_At);
            Path  : constant String := To_String (One.Path);
            Full  : constant String := Lower (To_String (One.Name));
            Short : constant String := Lower (Last_Part (To_String (One.Name)));
            Spelt : constant String := Last_Part (To_String (One.Name));
            Parts : constant Name_Lists.Vector := Parts_Of (To_String (One.Name));
            Score : Natural := 0;
            Why   : Unbounded_String;
            Named : Boolean := False;

            procedure Count (Points : Natural; Said : String) is
            begin
               Score := Score + Points;
               Append (Why, (if Length (Why) = 0 then "" else "; ") & Said);
            end Count;
         begin
            for Word of Wholes loop
               if Plain.Contains (Word) and then Spelt /= Word then
                  --  A word of a sentence: its name's parts count, as below.
                  null;
               elsif Full = Word then
                  Count (1000, "its full name");
                  Named := True;
               elsif Ends_With (Full, "." & Word) or else Ends_With (Full, "::" & Word) then
                  Count (800, "the end of its name");
                  Named := True;
               elsif Short = Word then
                  Count (400, "its name");
                  Named := True;
               elsif Word'Length >= 3 and then Short'Length > Word'Length
                 and then Short (Short'First .. Short'First + Word'Length - 1) = Word
               then
                  Count (150, "its name begins " & Word);
                  Named := True;
               end if;
            end loop;
            for Term of Terms loop
               if Parts.Contains (Term) then
                  Count (60, Term & " in its name");
                  Named := True;
               end if;
            end loop;
            --  Its name's points as the share of the query its name is: a
            --  name a query of four words or fewer says counts whole, one
            --  word of a sentence of twenty a fifth -- a symbol named for
            --  one word of a described change outranked every file holding
            --  the rest of it.
            if Natural (Wholes.Length) > Name_Reach then
               Score := Score * Name_Reach / Natural (Wholes.Length);
            end if;
            declare
               Place : constant Said_Maps.Cursor := Described.Find (Path & ASCII.NUL & Image (One.Line));
            begin
               if Said_Maps.Has_Element (Place) and then Said_Maps.Element (Place).Score > 0 then
                  Count (Said_Maps.Element (Place).Score,
                         "its comment says " & Image (Said_Maps.Element (Place).Held) & " of the words");
                  Named := True;
               end if;
            end;
            if Named and then Shown (Path) then
               for Term of Terms loop
                  if Has (Lower (Path), Term) then
                     Score := Score + 20;
                  end if;
               end loop;
               if Rp.Language_Of (Path) = "Ada" and then Ends_With (Lower (Path), ".ads") then
                  Score := Score + 15;
               end if;
               if Test_Files.Contains (Path) and then not Asks_Tests then
                  Score := Natural'Max (0, Score - 20);
               end if;
               declare
                  Close : constant Natural := Closeness (Path);
               begin
                  if Close > 0 then
                     Count (Close, "close to the work");
                  end if;
               end;
               Add ((Kind => Symbol_Hit, Name => One.Name, What => One.Kind, Path => One.Path, Line => One.Line,
                     Score => Score, Why => Why, Authority => To_Unbounded_String ("derived from the code")));
            end if;
         end;
      end loop;

      --  Files, by their paths.
      for Index_At in 1 .. Rp.File_Count (Graph) loop
         declare
            File  : constant Rp.File_Entry := Rp.File_At (Graph, Index_At);
            Path  : constant String := Lower (To_String (File.Path));
            Name  : constant String := Ada.Directories.Simple_Name (Path);
            Score : Natural := 0;
            Why   : Unbounded_String;
         begin
            for Word of Wholes loop
               if Path = Word then
                  Score := Score + 900;
                  Append (Why, "its path");
               --  A word of a sentence is not a file's name: "Hold file
               --  streaming buffers on the heap" asks for no STREAMING.md.
               elsif (Name = Word or else Ada.Directories.Base_Name (Name) = Word)
                 and then not Plain.Contains (Word)
               then
                  Score := Score + 600;
                  Append (Why, "its name");
               end if;
            end loop;
            for Term of Terms loop
               if Has (Path, Term) then
                  Score := Score + 50;
               end if;
            end loop;
            if Score > 0 and then Shown (To_String (File.Path)) then
               Add ((Kind => File_Hit, Name => File.Path,
                     What => File.Language & " " & Lower (Rp.File_Role'Image (File.Role)),
                     Path => File.Path, Line => 0, Score => Score,
                     Why => (if Length (Why) = 0 then To_Unbounded_String ("words of its path") else Why),
                     Authority => To_Unbounded_String ("derived from the code")));
            end if;
         end;
      end loop;

      --  Records, by their identifiers and what they say.
      if Records then
         declare
            procedure Weigh
              (Kind, Id, Title, Text, State, Authority : String; Accepted, Historical : Boolean)
            is
               Score  : Natural := 0;
               Why    : Unbounded_String;
               Titled : constant String := Lower (Title);
               Said   : constant String := Lower (Text);
            begin
               for Word of Wholes loop
                  if Lower (Id) = Word then
                     Score := Score + 1000;
                     Append (Why, "its identifier");
                  end if;
               end loop;
               for Term of Terms loop
                  if Has (Titled, Term) then
                     Score := Score + 80;
                  elsif Has (Said, Term) then
                     Score := Score + 25;
                  end if;
               end loop;
               if Score > 0 then
                  if Accepted then
                     Score := Score + 30;
                  elsif Historical then
                     Score := Natural'Max (1, Score - 40);
                  end if;
                  Add ((Kind => Record_Hit, Name => To_Unbounded_String (Id),
                        What => To_Unbounded_String (Kind & (if State = "" then "" else " (" & State & ")")
                                                     & ": " & Title),
                        Path => Null_Unbounded_String, Line => 0, Score => Score,
                        Why => (if Length (Why) = 0 then To_Unbounded_String ("words of its text") else Why),
                        Authority => To_Unbounded_String (Authority)));
               end if;
            end Weigh;
         begin
            for Kind in Intent.Intent_Kind loop
               for Id of Intent.List (Store, Kind) loop
                  declare
                     Held : Intent.Entity;
                     Read : E.Error_Info;
                  begin
                     Intent.Read (Store, Kind, Id, Held, Read);
                     if E.Is_Ok (Read) then
                        declare
                           State : constant String := To_String (Held.State);
                           Old   : constant Boolean := State in "superseded" | "rejected" | "deprecated";
                        begin
                           Weigh (Lower (Intent.Intent_Kind'Image (Kind)), Id, To_String (Held.Title),
                                  To_String (Held.Text) & " " & To_String (Held.Criteria), State,
                                  (if State = "accepted" then "accepted"
                                   elsif Old then "historical: " & State
                                     & (if Length (Held.Superseded_By) > 0
                                        then ", replaced by " & To_String (Held.Superseded_By) else "")
                                   else "proposed, not yet authoritative"),
                                  Accepted => State = "accepted", Historical => Old);
                        end;
                     end if;
                  end;
               end loop;
            end loop;
            for Id of Tasks.List (Store) loop
               declare
                  Defined : Model_Runner.Framework.Records.Item;
                  Read    : E.Error_Info;
               begin
                  Tasks.Definition (Store, Id, Defined, Read);
                  if E.Is_Ok (Read) then
                     declare
                        State : constant String := Tasks.State_Of (Store, Id);
                     begin
                        Weigh ("task", Id, Model_Runner.Framework.Records.Get (Defined, "title"),
                               Model_Runner.Framework.Records.Get (Defined, "notes") & " "
                               & Model_Runner.Framework.Records.Get (Defined, "component"),
                               State, "the task's own record",
                               Accepted => False, Historical => State in "cancelled" | "rejected");
                     end;
                  end if;
               end;
            end loop;
            for Id of Observations.List (Store) loop
               declare
                  Held : Observations.Observation;
                  Read : E.Error_Info;
               begin
                  Observations.Read (Store, Id, Held, Read);
                  if E.Is_Ok (Read) then
                     declare
                        use type Observations.Lifecycle;
                        Old : constant Boolean := Held.Status in Observations.Superseded | Observations.Dismissed;
                     begin
                        Weigh ("observation", Id, To_String (Held.Summary), "",
                               Lower (Observations.Lifecycle'Image (Held.Status)),
                               (if Old then "historical, not authoritative" else "an observation, not authoritative"),
                               Accepted => False, Historical => Old);
                     end;
                  end if;
               end;
            end loop;
         end;
      end if;

      --  Lines of the files' text.
      declare
         type Term_Array is array (Positive range <>) of Natural;
         Ids    : Term_Array (1 .. Natural (Terms.Length)) := [others => 0];
         Spread : Term_Array (1 .. Natural (Terms.Length)) := [others => 0];
         Candidates : Hit_Lists.Vector;

         --  The files that may hold the query's words in a row: each word
         --  inside the phrase, with something else on both sides of it, is
         --  a whole word wherever the phrase is, so a file the index says
         --  lacks one does not hold it. Where the phrase has no such word,
         --  every file may.
         Inner_Known : Boolean := False;
         May_Hold    : Name_Sets.Set;
      begin
         declare
            Locked : Holding;
            pragma Unreferenced (Locked);
         begin
            for At_Term in Ids'Range loop
               if Dictionary.Contains (Terms (At_Term)) then
                  Ids (At_Term) := Dictionary.Element (Terms (At_Term));
               end if;
            end loop;

            --  Each term's files of this tree, from the term's own list: a
            --  search visits the files holding its words, not every file.
            --  Each file's sum is taken in the order of the query's words,
            --  as it was file by file, so the scores are the same.
            declare
               Prefix : constant String := Tree & ASCII.NUL;

               function In_Tree (Doc : Positive) return Boolean is
                  Key : constant String := Doc_Keys (Doc);
               begin
                  return Key'Length > Prefix'Length and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix;
               end In_Tree;

               type Tally is record
                  Score  : Float := 0.0;
                  Line   : Positive := Positive'Last;
                  Rarest : Natural := Natural'Last;
                  Held   : Natural := 0;
               end record;
               package Tally_Maps is new Ada.Containers.Ordered_Maps (Positive, Tally);
               Tallies : Tally_Maps.Map;

               --  A word's count in a file, saturating and taken against the
               --  file's length (BM25's k1 and b): a long file -- a log of
               --  measurements, a test suite -- holds most words of a long
               --  query somewhere, and outranked the source it is about.
               --  Scale keeps a file's sum where the counts' once was, so a
               --  text hit stands beside a symbol's points as before. A
               --  document's words count half: the change asked for is in
               --  the source. Chosen on the dev set of this repository's own
               --  commit subjects (tests/fixtures/retrieval-commits-dev.tsv).
               K1          : constant Float := 2.0;
               B           : constant Float := 0.75;
               Scale       : constant Float := 3.6;
               Document_Of : constant Float := 0.5;
               Mean        : Float := 1.0;
               Documents   : Name_Sets.Set;
            begin
               for At_File in 1 .. Rp.File_Count (Graph) loop
                  declare
                     File : constant Rp.File_Entry := Rp.File_At (Graph, At_File);
                  begin
                     if File.Role = Rp.Documentation then
                        Documents.Include (To_String (File.Path));
                     end if;
                  end;
               end loop;
               declare
                  Total, Count : Natural := 0;
               begin
                  for Position in Index.Iterate loop
                     declare
                        Key : constant String := Word_Maps.Key (Position);
                     begin
                        if Key'Length > Prefix'Length and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix
                        then
                           Total := Total + Index.Constant_Reference (Position).Count;
                           Count := Count + 1;
                        end if;
                     end;
                  end loop;
                  if Count > 0 then
                     Mean := Float'Max (1.0, Float (Total) / Float (Count));
                  end if;
               end;
               for At_Term in Ids'Range loop
                  if Ids (At_Term) > 0 then
                     for Doc of Term_Docs (Ids (At_Term)) loop
                        if In_Tree (Doc) then
                           Spread (At_Term) := Spread (At_Term) + 1;
                        end if;
                     end loop;
                  end if;
               end loop;
               for At_Term in Ids'Range loop
                  if Ids (At_Term) > 0 then
                     for Doc of Term_Docs (Ids (At_Term)) loop
                        declare
                           Key : constant String := Doc_Keys (Doc);
                        begin
                           if In_Tree (Doc) and then Shown (Key (Key'First + Prefix'Length .. Key'Last)) then
                              declare
                                 One : constant Posting := Find (Index.Constant_Reference (Key).Words, Ids (At_Term));
                                 Was : Tally := (if Tallies.Contains (Doc) then Tallies (Doc) else (others => <>));
                              begin
                                 Was.Held := Was.Held + 1;
                                 declare
                                    Len : constant Float := Float (Index.Constant_Reference (Key).Count);
                                    Tf  : constant Float := Float (One.Count);
                                 begin
                                    Was.Score := Was.Score
                                      + (if Documents.Contains (Key (Key'First + Prefix'Length .. Key'Last))
                                         then Document_Of else 1.0)
                                      * Scale * Tf * (K1 + 1.0) / (Tf + K1 * (1.0 - B + B * Len / Mean))
                                      * 10.0 * Ada.Numerics.Elementary_Functions.Log
                                                 (1.0 + Float (Files) / Float (Spread (At_Term)), 2.0);
                                 end;
                                 --  The line shown, until the text is read: where the
                                 --  rarest of its words first is.
                                 if Spread (At_Term) < Was.Rarest then
                                    Was.Rarest := Spread (At_Term);
                                    Was.Line := One.Line;
                                 end if;
                                 Tallies.Include (Doc, Was);
                              end;
                           end if;
                        end;
                     end loop;
                  end if;
               end loop;
               declare
                  Phrase : constant String := Lower (Ada.Strings.Fixed.Trim (Query, Ada.Strings.Both));
                  Inner  : Number_Lists.Vector;
                  Absent : Boolean := False;
                  Start  : Natural := 0;
               begin
                  for At_Char in Phrase'Range loop
                     if Identifier_Char (Phrase (At_Char)) then
                        if Start = 0 then
                           Start := At_Char;
                        end if;
                        if At_Char = Phrase'Last or else not Identifier_Char (Phrase (At_Char + 1)) then
                           if Start > Phrase'First and then At_Char < Phrase'Last
                             and then Ada.Characters.Handling.Is_Letter (Phrase (Start))
                             and then At_Char - Start + 1 in 2 .. 64
                           then
                              if Dictionary.Contains (Phrase (Start .. At_Char)) then
                                 Inner.Append (Dictionary.Element (Phrase (Start .. At_Char)));
                              else
                                 Absent := True;
                              end if;
                           end if;
                           Start := 0;
                        end if;
                     end if;
                  end loop;
                  Inner_Known := Absent or else not Inner.Is_Empty;
                  if not Absent and then not Inner.Is_Empty then
                     for Position in Tallies.Iterate loop
                        declare
                           Key : constant String := Doc_Keys (Tally_Maps.Key (Position));
                        begin
                           if (for all Term of Inner => Find (Index.Constant_Reference (Key).Words, Term).Count > 0)
                           then
                              May_Hold.Include (Key (Key'First + Prefix'Length .. Key'Last));
                           end if;
                        end;
                     end loop;
                  end if;
               end;
               for Position in Tallies.Iterate loop
                  declare
                     Key  : constant String := Doc_Keys (Tally_Maps.Key (Position));
                     Path : constant Unbounded_String :=
                       To_Unbounded_String (Key (Key'First + Prefix'Length .. Key'Last));
                     Got  : constant Tally := Tally_Maps.Element (Position);
                  begin
                     Candidates.Append
                       (Hit'(Kind => Text_Hit, Name => Path, What => Null_Unbounded_String, Path => Path,
                         Line => Got.Line,
                         --  Past 400 drawn toward 500 rather than cut at it:
                         --  a long query's words took many files to the cap,
                         --  and those at it were ranked by nothing.
                         Score => (if Got.Score / 4.0 > 400.0
                                   then 400 + Natural (Float'Floor (100.0 * (Got.Score / 4.0 - 400.0)
                                                                     / (Got.Score / 4.0 - 400.0 + 400.0)))
                                   else Natural (Float'Floor (Got.Score / 4.0))),
                         Why => To_Unbounded_String (Image (Got.Held) & " of the words"),
                         Authority => To_Unbounded_String ("the file as it is")));
                  end;
               end loop;
            end;
         end;

         --  The best of them read again for the line to show: the first
         --  holding most of the words, and a bonus where it holds them in
         --  a row. Every one the bonus could still lift among the first
         --  Most is read, not only the first Most: the words in a row may
         --  be in a file their counts ranked lower.
         Hit_Sorting.Sort (Candidates);
         declare
            Phrase : constant String := Lower (Ada.Strings.Fixed.Trim (Query, Ada.Strings.Both));
            Reach  : constant Natural := (if Natural (Terms.Length) >= 2 and then Phrase'Length >= 5 then 150 else 0);
            Kept   : Natural := 0;
            Floor  : Natural := 0;
         begin
            for Index_At in 1 .. Natural (Candidates.Length) loop
               exit when Kept >= Most and then (Reach = 0 or else Candidates (Index_At).Score + Reach < Floor);
               if Kept < Most or else not Inner_Known or else May_Hold.Contains (To_String (Candidates (Index_At).Path))
               then
                  declare
                     Item   : Hit renames Candidates (Index_At);
                     Text   : Unbounded_String;
                     Read   : E.Error_Info;
                  begin
                     Read_In (Tree, To_String (Item.Path), Text, Read);
                     --  Past the first Most, only one holding the words in a row
                     --  could take a place.
                     if E.Is_Ok (Read) and then (Kept < Most or else Has (Lower (To_String (Text)), Phrase)) then
                        Kept := Kept + 1;
                        if Kept = Most then
                           Floor := Item.Score;
                        end if;
                        declare
                           Whole   : constant String := To_String (Text);
                           Start   : Positive := Whole'First;
                           Row     : Positive := 1;
                           Best    : Natural := 0;
                           Rows    : constant Natural := Natural (Terms.Length);
                        begin
                           for At_Char in Whole'First .. Whole'Last + 1 loop
                              if At_Char > Whole'Last or else Whole (At_Char) = ASCII.LF then
                                 declare
                                    Said  : constant String := Lower (Whole (Start .. At_Char - 1));
                                    Holds : Natural := 0;
                                 begin
                                    for Term of Terms loop
                                       if Has (Said, Term) then
                                          Holds := Holds + 1;
                                       end if;
                                    end loop;
                                    if Holds > Best then
                                       Best := Holds;
                                       Item.Line := Row;
                                       Item.What := To_Unbounded_String
                                         (Ada.Strings.Fixed.Trim (Whole (Start .. At_Char - 1), Ada.Strings.Both));
                                    end if;
                                    if Rows >= 2 and then Phrase'Length >= 5 and then Has (Said, Phrase)
                                      and then Ada.Strings.Fixed.Index (To_String (Item.Why), "in a row") = 0
                                    then
                                       Item.Score := Natural'Min (500, Item.Score + 150);
                                       Item.Line := Row;
                                       Item.What := To_Unbounded_String
                                         (Ada.Strings.Fixed.Trim (Whole (Start .. At_Char - 1), Ada.Strings.Both));
                                       Append (Item.Why, "; the words in a row");
                                       Best := Natural'Last;
                                    end if;
                                 end;
                                 Row := Row + 1;
                                 Start := At_Char + 1;
                              end if;
                           end loop;
                        end;
                        if Length (Item.What) > 160 then
                           Item.What := Head (Item.What, 160);
                        end if;
                        Found.Append (Item);
                     end if;
                  end;
               end if;
            end loop;
         end;
      end;

      Hit_Sorting.Sort (Found);
      while Natural (Found.Length) > Most loop
         Found.Delete_Last;
      end loop;
      return Found;
   end Search_Current;

   ------------
   -- Search --
   ------------

   function Search
     (Store    : Stores.Store;
      Graph    : Repository.Graph;
      Root     : String;
      Query    : String;
      Most     : Positive := 20;
      Near     : Name_Lists.Vector := Name_Lists.Empty_Vector;
      May_Read : Path_Check := null;
      Records  : Boolean := True) return Hit_Lists.Vector
   is
      Tree : constant String :=
        (if Root /= "" then Root else Ada.Directories.Containing_Directory (Stores.Root (Store)));
   begin
      --  The graph handed over checked against the tree, and brought up to
      --  it where it is not the tree: a file added, changed or removed since
      --  it was made is searched as it is. Checked, not copied, where it is.
      if Rp.Is_Current (Tree, Graph) then
         return Search_Current (Store, Graph, Tree, Query, Most, Near, May_Read, Records);
      end if;
      return Search_Current (Store, Rp.Brought_Up (Tree, Graph), Tree, Query, Most, Near, May_Read, Records);
   end Search;

   ----------------
   -- Warm_Index --
   ----------------

   procedure Warm_Index (Item : Stores.Store; Found : Repository.Graph) is
      Hits : constant Hit_Lists.Vector :=
        Search (Item, Found, "", "index", Most => 1, Records => False);
      pragma Unreferenced (Hits);
   begin
      null;
   exception
      --  Made by the next search instead.
      when others =>
         null;
   end Warm_Index;

   ---------------------------------------------------------------------------
   --  Excerpts.
   ---------------------------------------------------------------------------

   --  The lines First .. Last of a text, at most Most of them around the
   --  line that matters, and whether that cut any.
   procedure Cut
     (Text   : String;
      Into   : in out Excerpt;
      Most   : Positive;
      Keep   : Positive)
   is
      Row     : Positive := 1;
      Start   : Positive := Text'First;
      Result  : Unbounded_String;
      Low     : Positive := Into.First;
      High    : Natural := Into.Last;
   begin
      if High - Low + 1 > Most then
         Into.Truncated := True;
         --  The line that matters kept in sight: the declaration's start,
         --  or the use it is shown for.
         --  Saturating: a line near the file's start leads with fewer.
         Low := Positive'Max
           (Into.First, Positive'Min ((if Keep > Most / 4 then Keep - Most / 4 else 1), Into.Last - Most + 1));
         High := Low + Most - 1;
      end if;
      for At_Char in Text'First .. Text'Last + 1 loop
         if At_Char > Text'Last or else Text (At_Char) = ASCII.LF then
            if Row in Low .. High then
               Append (Result, Text (Start .. At_Char - 1) & ASCII.LF);
            end if;
            exit when Row >= High;
            Row := Row + 1;
            Start := At_Char + 1;
         end if;
      end loop;
      Into.First := Low;
      Into.Last := High;
      Into.Text := Result;
   end Cut;

   --  Declaration, the graph already brought up to the tree.
   procedure Declaration_Current
     (Graph      : Repository.Graph;
      Root       : String;
      Name       : String;
      Most_Lines : Positive;
      Found      : out Excerpt_Lists.Vector;
      Status     : out Model_Runner.Errors.Error_Info;
      May_Read   : Path_Check)
   is
      Names : constant Name_Lists.Vector := Rp.Find_Symbols (Graph, Name);

      --  The symbols those names are, a spec before a body, then by path
      --  and line.
      type Place is record
         Name : Unbounded_String;
         Kind : Unbounded_String;
         Path : Unbounded_String;
         Line : Natural;

         --  Found in the text as it is, not by the graph: its line holds.
         Fresh : Boolean := False;
      end record;
      package Place_Lists is new Ada.Containers.Vectors (Positive, Place);
      function Earlier (Left, Right : Place) return Boolean
      is (if Ends_With (To_String (Left.Path), ".ads") /= Ends_With (To_String (Right.Path), ".ads")
          then Ends_With (To_String (Left.Path), ".ads")
          elsif Left.Path /= Right.Path then Left.Path < Right.Path
          else Left.Line < Right.Line);
      package Place_Sorting is new Place_Lists.Generic_Sorting (Earlier);
      Places : Place_Lists.Vector;
   begin
      Found.Clear;
      Status := E.Success;
      for Index_At in 1 .. Rp.Symbol_Count (Graph) loop
         declare
            One : constant Rp.Symbol := Rp.Symbol_At (Graph, Index_At);
         begin
            if Names.Contains (To_String (One.Name))
              and then (May_Read = null or else May_Read (To_String (One.Path)))
            then
               Places.Append (Place'(One.Name, One.Kind, One.Path, One.Line, False));
            end if;
         end;
      end loop;

      --  An Ada spec's subprogram, its body where the graph names none --
      --  an expression function, a body inside another -- found in the
      --  other half's text.
      declare
         Specs : constant Place_Lists.Vector := Places;
      begin
         for Held of Specs loop
            declare
               Path  : constant String := To_String (Held.Path);
               Other : constant String :=
                 (if Ends_With (Path, ".ads") then Path (Path'First .. Path'Last - 1) & "b" else "");
               Text  : Unbounded_String;
               Read  : E.Error_Info;
            begin
               if Other /= "" and then To_String (Held.Kind) in "procedure" | "function"
                 and then not (for some Known of Places =>
                                 Known.Name = Held.Name and then To_String (Known.Path) = Other)
                 and then (May_Read = null or else May_Read (Other))
               then
                  Read_In (Root, Other, Text, Read);
                  if E.Is_Ok (Read) then
                     for Line of Rp.Declared_Lines (To_String (Text), Last_Part (To_String (Held.Name))) loop
                        Places.Append (Place'(Held.Name, To_Unbounded_String ("body"),
                                              To_Unbounded_String (Other), Natural'Value (Line), True));
                     end loop;
                  end if;
               end if;
            end;
         end loop;
      end;
      Place_Sorting.Sort (Places);
      for Held of Places loop
         exit when Natural (Found.Length) = Declarations_Most;
         declare
            Path : constant String := To_String (Held.Path);
            Text : Unbounded_String;
            Read : E.Error_Info;
         begin
            Read_In (Root, Path, Text, Read);
            if E.Is_Ok (Read) then
               declare
                  Whole : constant String := To_String (Text);
                  Now   : constant Rp.Graph := Rp.Read_One (Path, Whole);
                  Line  : Natural := (if Held.Fresh then Held.Line else 0);
               begin
                  --  Where the file as it is declares it: the graph's line
                  --  where it still does, else the nearest of its name and
                  --  kind -- the file changed since the graph was made.
                  for At_Symbol in 1 .. Rp.Symbol_Count (Now) loop
                     declare
                        Again : constant Rp.Symbol := Rp.Symbol_At (Now, At_Symbol);
                     begin
                        if not Held.Fresh and then Again.Name = Held.Name and then Again.Kind = Held.Kind
                          and then (Line = 0 or else abs (Again.Line - Held.Line) < abs (Line - Held.Line))
                        then
                           Line := Again.Line;
                        end if;
                     end;
                  end loop;
                  if Line > 0 then
                     declare
                        Span : constant Rp.Extent := Rp.Extent_Of (Path, Whole, Line, Most_Lines);
                        Item : Excerpt :=
                          (Path        => Held.Path,
                           Language    => To_Unbounded_String (Rp.Language_Of (Path)),
                           Symbol      => Held.Name,
                           First       => Span.First,
                           Last        => Span.Last,
                           Structural  => Span.Structural,
                           Truncated   => False,
                           Moved       => Line /= Held.Line,
                           Fingerprint => To_Unbounded_String (Fingerprint (Whole)),
                           Reason      => To_Unbounded_String ("the " & To_String (Held.Kind) & " "
                                                               & To_String (Held.Name)),
                           Text        => Null_Unbounded_String);
                     begin
                        Cut (Whole, Item, Most_Lines, Line);
                        Found.Append (Item);
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      if Found.Is_Empty then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", Name);
      end if;
   end Declaration_Current;

   -----------------
   -- Declaration --
   -----------------

   procedure Declaration
     (Graph      : Repository.Graph;
      Root       : String;
      Name       : String;
      Most_Lines : Positive;
      Found      : out Excerpt_Lists.Vector;
      Status     : out Model_Runner.Errors.Error_Info;
      May_Read   : Path_Check := null)
   is
      Tree : constant String := (if Root = "" then "." else Root);
   begin
      --  A symbol in a file added since the graph was made is found too.
      if Rp.Is_Current (Tree, Graph) then
         Declaration_Current (Graph, Root, Name, Most_Lines, Found, Status, May_Read);
      else
         Declaration_Current (Rp.Brought_Up (Tree, Graph), Root, Name, Most_Lines, Found, Status, May_Read);
      end if;
   end Declaration;

   ------------
   -- Around --
   ------------

   procedure Around
     (Root       : String;
      Path       : String;
      Line       : Positive;
      Most_Lines : Positive;
      Result     : out Excerpt;
      Status     : out Model_Runner.Errors.Error_Info)
   is
      Text : Unbounded_String;
   begin
      Result := (others => <>);
      Read_In (Root, Path, Text, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         Whole : constant String := To_String (Text);
         Name  : Unbounded_String;
         Span  : constant Rp.Extent := Rp.Enclosing (Path, Whole, Line, Name);
      begin
         if Span.First = 0 then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Path & ":" & Image (Line));
            return;
         end if;
         Result :=
           (Path        => To_Unbounded_String (Path),
            Language    => To_Unbounded_String (Rp.Language_Of (Path)),
            Symbol      => Name,
            First       => Span.First,
            Last        => Span.Last,
            Structural  => Span.Structural,
            Truncated   => False,
            Moved       => False,
            Fingerprint => To_Unbounded_String (Fingerprint (Whole)),
            Reason      => (if Length (Name) > 0 then "in " & Name else To_Unbounded_String ("around line "
                                                                                          & Image (Line))),
            Text        => Null_Unbounded_String);
         Cut (Whole, Result, Most_Lines, Line);
      end;
   end Around;

   ---------------
   -- Reference --
   ---------------

   function Reference (From : Excerpt) return String
   is (To_String (From.Path) & ":" & Image (From.First) & "-" & Image (From.Last) & "@"
       & To_String (From.Fingerprint));

   ------------
   -- Expand --
   ------------

   procedure Expand
     (Root       : String;
      Named      : String;
      Most_Lines : Positive;
      Result     : out Excerpt;
      Status     : out Model_Runner.Errors.Error_Info)
   is
      At_Sign : constant Natural := Ada.Strings.Fixed.Index (Named, "@", Ada.Strings.Backward);
      Colon   : constant Natural :=
        (if At_Sign = 0 then 0 else Ada.Strings.Fixed.Index (Named (Named'First .. At_Sign - 1), ":",
                                                             Ada.Strings.Backward));
      Dash    : constant Natural :=
        (if Colon = 0 then 0 else Ada.Strings.Fixed.Index (Named (Colon + 1 .. At_Sign - 1), "-"));

      function Number (Text : String) return Natural
      is (if Text'Length in 1 .. 7 and then (for all C of Text => C in '0' .. '9') then Natural'Value (Text) else 0);

      procedure Invalid (Detail : String) is
      begin
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", "reference");
         E.Add_Text (Status, "value", Named);
         E.Add_Text (Status, "detail", Detail);
      end Invalid;
   begin
      Result := (others => <>);
      if Dash = 0 or else Number (Named (Colon + 1 .. Dash - 1)) = 0
        or else Number (Named (Dash + 1 .. At_Sign - 1)) < Number (Named (Colon + 1 .. Dash - 1))
      then
         Invalid ("a reference is PATH:FIRST-LAST@PRINT, as a search or an excerpt gives it");
         return;
      end if;
      declare
         Path  : constant String := Named (Named'First .. Colon - 1);
         First : constant Positive := Number (Named (Colon + 1 .. Dash - 1));
         Last  : constant Positive := Number (Named (Dash + 1 .. At_Sign - 1));
         Print : constant String := Named (At_Sign + 1 .. Named'Last);
         Text  : Unbounded_String;
      begin
         Read_In (Root, Path, Text, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         if Fingerprint (To_String (Text)) /= Print then
            --  Never other lines than the ones named, shown as if they were.
            Invalid (Path & " has changed since it was shown; search for it again");
            return;
         end if;
         Result :=
           (Path        => To_Unbounded_String (Path),
            Language    => To_Unbounded_String (Rp.Language_Of (Path)),
            Symbol      => Null_Unbounded_String,
            First       => First,
            Last        => Last,
            Structural  => False,
            Truncated   => False,
            Moved       => False,
            Fingerprint => To_Unbounded_String (Print),
            Reason      => To_Unbounded_String ("the lines named"),
            Text        => Null_Unbounded_String);
         Cut (To_String (Text), Result, Most_Lines, First);
         if Result.Text = Null_Unbounded_String then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Named);
         end if;
      end;
   end Expand;

   ----------------
   -- Provenance --
   ----------------

   function Provenance (From : Excerpt) return String
   is (To_String (From.Path) & " lines " & Image (From.First) & "-" & Image (From.Last)
       & (if Length (From.Language) > 0 then " (" & To_String (From.Language) & ")" else "")
       & ", " & To_String (From.Reason)
       & (if From.Truncated then ", cut to " & Image (From.Last - From.First + 1) & " lines"
          elsif From.Structural then ", whole"
          else ", lines only: its end was not found")
       & (if From.Moved then ", found where the file now has it" else "")
       & " -- ref " & Reference (From));

end Model_Runner.Framework.Retrieval;
