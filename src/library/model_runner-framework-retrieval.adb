with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Generic_Array_Sort;
with Ada.Directories;
with Ada.Numerics.Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Maps;

with Hostkit.Fs;

with Model_Runner.Framework.Files;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Observations;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Tasks;

package body Model_Runner.Framework.Retrieval is

   use Ada.Strings.Unbounded;
   use type Repository.File_Role;
   use type Repository.Relation_Kind;
   use type Repository.Confidence;
   use type Ada.Directories.File_Size;

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

   function Before (Left, Right : Posting) return Boolean
   is (Left.Term < Right.Term);

   procedure Sort is new Ada.Containers.Generic_Array_Sort (Positive, Posting, Posting_Array, Before);

   --  One file's words, sorted by term, held in the entry itself so that
   --  replacing or deleting the entry frees them; the print the graph gave
   --  and the file's own stamp when they were read.
   type File_Words (Count : Natural) is record
      Print : Unbounded_String;
      Stamp : Unbounded_String;
      Words : Posting_Array (1 .. Count);
   end record;

   package Term_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Positive, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   package Word_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => File_Words, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  Each term's number, for every file; and each file's words, by its
   --  tree and path. Held under Lock.
   Dictionary : Term_Maps.Map;
   Index      : Word_Maps.Map;
   Read_Count : Natural := 0;

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

   function Key_Of (Root, Path : String) return String
   is (Root & ASCII.NUL & Path);

   --  A file's words, counted.
   function Words_Of (Text : String) return Posting_Array is
      package Count_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type => String, Element_Type => Posting, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
      Counted : Count_Maps.Map;

      procedure Take (Word : String; Line : Positive) is
         Position : constant Count_Maps.Cursor := Counted.Find (Word);
      begin
         if Count_Maps.Has_Element (Position) then
            Counted.Reference (Position).Count := Counted.Reference (Position).Count + 1;
         else
            if not Dictionary.Contains (Word) then
               Dictionary.Insert (Word, Natural (Dictionary.Length) + 1);
            end if;
            Counted.Insert (Word, (Term => Dictionary.Element (Word), Count => 1, Line => Line));
         end if;
      end Take;
   begin
      Each_Word (Text, Take'Access);
      declare
         Result : Posting_Array (1 .. Natural (Counted.Length));
         At_Index : Natural := 0;
      begin
         for Held of Counted loop
            At_Index := At_Index + 1;
            Result (At_Index) := Held;
         end loop;
         Sort (Result);
         return Result;
      end;
   end Words_Of;

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
   procedure Read_In
     (Root   : String;
      Path   : String;
      Text   : out Unbounded_String;
      Status : out E.Error_Info)
   is
      use type Hostkit.Fs.Read_Beneath_Outcome;
      Outcome : Hostkit.Fs.Read_Beneath_Outcome;
   begin
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
      Hostkit.Fs.Read_Beneath (Root, Path, Records.Max_Bytes, Text, Outcome);
      case Outcome is
         when Hostkit.Fs.Read_Done =>
            Status := E.Success;
         when Hostkit.Fs.Read_Too_Large =>
            Status := E.Make (E.IO_File_Too_Large);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            E.Add_Integer (Status, "limit", Long_Long_Integer (Records.Max_Bytes), E.Param_Bytes);
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
                  Files.Read_Text (Full, Text, Status);
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

   --  The index brought up to the graph and to the files as they are: a
   --  file read again where the graph's print for it changed, or its own
   --  stamp did -- size, change time to the nanosecond, file number -- so
   --  a graph made before an edit still finds the edit; one gone dropped.
   --  Which files there are is the graph's to say. Called with Lock held.
   procedure Bring_Up (Graph : Rp.Graph; Root : String) is
      Present : Name_Sets.Set;
   begin
      for Index_At in 1 .. Rp.File_Count (Graph) loop
         declare
            File : constant Rp.File_Entry := Rp.File_At (Graph, Index_At);
            Path : constant String := To_String (File.Path);
            Key  : constant String := Key_Of (Root, Path);
         begin
            if Indexed (File) then
               Present.Include (Key);
               declare
                  Now : constant String := Rp.Stamp_Of (Hostkit.Fs.Join (Root, Path));
               begin
                  if not Index.Contains (Key) or else Index.Constant_Reference (Key).Print /= File.Fingerprint
                    or else Now = "" or else Index.Constant_Reference (Key).Stamp /= Now
                  then
                     declare
                        Text   : Unbounded_String;
                        Status : E.Error_Info;
                        Size_Ok : Boolean := True;
                     begin
                        begin
                           Size_Ok := Ada.Directories.Size (Hostkit.Fs.Join (Root, Path))
                                        <= Ada.Directories.File_Size (Indexed_Most);
                        exception
                           when others =>
                              Size_Ok := False;
                        end;
                        if Size_Ok then
                           Read_In (Root, Path, Text, Status);
                        else
                           Status := E.Make (E.Framework_Not_Found);
                        end if;
                        declare
                           Words : constant Posting_Array :=
                             (if E.Is_Ok (Status) then Words_Of (To_String (Text)) else [1 .. 0 => <>]);
                        begin
                           Index.Include
                             (Key, (Count => Words'Length, Print => File.Fingerprint,
                                    Stamp => To_Unbounded_String (Now), Words => Words));
                           Read_Count := Read_Count + 1;
                        end;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      --  What the tree no longer holds -- deleted, or renamed to a path
      --  read above -- is no longer indexed.
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
            Index.Delete (Key);
         end loop;
      end;
   end Bring_Up;

   ------------
   -- Forget --
   ------------

   procedure Forget is
   begin
      Lock.Seize;
      Index.Clear;
      Dictionary.Clear;
      Read_Count := 0;
      Lock.Release;
   end Forget;

   -------------------
   -- Indexed_Reads --
   -------------------

   function Indexed_Reads return Natural is
      Count : Natural;
   begin
      Lock.Seize;
      Count := Read_Count;
      Lock.Release;
      return Count;
   end Indexed_Reads;

   ----------------
   -- Indexed_Held --
   ----------------

   function Indexed_Held return Natural is
      Count : Natural;
   begin
      Lock.Seize;
      Count := Natural (Index.Length);
      Lock.Release;
      return Count;
   end Indexed_Held;

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
      Tree    : constant String :=
        (if Root /= "" then Root else Ada.Directories.Containing_Directory (Stores.Root (Store)));
      Wholes  : constant Name_Lists.Vector := Wholes_Of (Query);
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

      --  Symbols.
      for Index_At in 1 .. Rp.Symbol_Count (Graph) loop
         declare
            One   : constant Rp.Symbol := Rp.Symbol_At (Graph, Index_At);
            Path  : constant String := To_String (One.Path);
            Full  : constant String := Lower (To_String (One.Name));
            Short : constant String := Lower (Last_Part (To_String (One.Name)));
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
               if Full = Word then
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
               elsif Name = Word or else Ada.Directories.Base_Name (Name) = Word then
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
         Files  : Natural := 0;
         Candidates : Hit_Lists.Vector;
      begin
         Lock.Seize;
         begin
            Bring_Up (Graph, Tree);
            for At_Term in Ids'Range loop
               if Dictionary.Contains (Terms (At_Term)) then
                  Ids (At_Term) := Dictionary.Element (Terms (At_Term));
               end if;
            end loop;
            for Index_At in 1 .. Rp.File_Count (Graph) loop
               declare
                  File : constant Rp.File_Entry := Rp.File_At (Graph, Index_At);
                  Key  : constant String := Key_Of (Tree, To_String (File.Path));
               begin
                  if Index.Contains (Key) then
                     Files := Files + 1;
                     for At_Term in Ids'Range loop
                        if Ids (At_Term) > 0
                          and then Find (Index.Constant_Reference (Key).Words, Ids (At_Term)).Count > 0
                        then
                           Spread (At_Term) := Spread (At_Term) + 1;
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
            for Index_At in 1 .. Rp.File_Count (Graph) loop
               declare
                  File  : constant Rp.File_Entry := Rp.File_At (Graph, Index_At);
                  Key   : constant String := Key_Of (Tree, To_String (File.Path));
                  Score : Float := 0.0;
                  Line  : Positive := Positive'Last;
                  Rarest : Natural := Natural'Last;
                  Held  : Natural := 0;
               begin
                  if Index.Contains (Key) and then Shown (To_String (File.Path)) then
                     for At_Term in Ids'Range loop
                        if Ids (At_Term) > 0 then
                           declare
                              One : constant Posting := Find (Index.Constant_Reference (Key).Words, Ids (At_Term));
                           begin
                              if One.Count > 0 then
                                 Held := Held + 1;
                                 Score := Score + Float (Natural'Min (8, One.Count))
                                   * 10.0 * Ada.Numerics.Elementary_Functions.Log
                                              (1.0 + Float (Files) / Float (Spread (At_Term)), 2.0);
                                 --  The line shown, until the text is read: where the
                                 --  rarest of its words first is.
                                 if Spread (At_Term) < Rarest then
                                    Rarest := Spread (At_Term);
                                    Line := One.Line;
                                 end if;
                              end if;
                           end;
                        end if;
                     end loop;
                     if Held > 0 then
                        Candidates.Append
                          (Hit'(Kind => Text_Hit, Name => File.Path, What => Null_Unbounded_String, Path => File.Path,
                            Line => Line, Score => Natural'Min (500, Natural (Float'Floor (Score / 4.0))),
                            Why => To_Unbounded_String (Image (Held) & " of the words"),
                            Authority => To_Unbounded_String ("the file as it is")));
                     end if;
                  end if;
               end;
            end loop;
            Lock.Release;
         exception
            when others =>
               Lock.Release;
               raise;
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
            end loop;
         end;
      end;

      Hit_Sorting.Sort (Found);
      while Natural (Found.Length) > Most loop
         Found.Delete_Last;
      end loop;
      return Found;
   end Search;

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
