with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository.Languages;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Repository is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package Dirs renames Ada.Directories;
   use type Dirs.File_Kind;

   package Sorting is new Name_Lists.Generic_Sorting;

   Index_Name : constant String := "repository";
   Tab        : constant Character := ASCII.HT;

   --  Files larger than this are recorded and not read.
   Largest_Read : constant := 4 * 1024 * 1024;

   --  A file's size and when it last changed, as seconds since the epoch.
   function Stamp_Of (Full : String) return String is
      use type Ada.Calendar.Time;
      Seconds : constant Duration :=
        Dirs.Modification_Time (Full) - Ada.Calendar.Time_Of (1970, 1, 1);
   begin
      return Ada.Strings.Fixed.Trim (Dirs.File_Size'Image (Dirs.Size (Full)), Ada.Strings.Both)
        & ":" & Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Long_Long_Integer (Seconds)),
                                        Ada.Strings.Both);
   exception
      when others =>
         return "";
   end Stamp_Of;

   --  Whether a stamp says a file changed so lately that one of the same
   --  second could still follow unseen.
   function Recent (Stamp : String) return Boolean is
      use type Ada.Calendar.Time;
      Colon : constant Natural := Ada.Strings.Fixed.Index (Stamp, ":");
      Now   : constant Long_Long_Integer :=
        Long_Long_Integer (Ada.Calendar.Clock - Ada.Calendar.Time_Of (1970, 1, 1));
   begin
      return Colon = 0
        or else Now - Long_Long_Integer'Value (Stamp (Colon + 1 .. Stamp'Last)) < 2;
   exception
      when others =>
         return True;
   end Recent;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  The words of a list, parted by spaces, commas or lines.
   function Split (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ' ' | ',' | ASCII.LF | ASCII.CR | ASCII.HT then
            if Index > Start then
               Result.Append (Text (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split;

   --  A path without the slashes around it.
   function Trim_Slashes (Path : String) return String
   is (Ada.Strings.Fixed.Trim
         (Path, Ada.Strings.Maps.To_Set ("/"), Ada.Strings.Maps.To_Set ("/")));

   function Six (Value : Natural) return String is
      Plain : constant String := Image (Value);
   begin
      return [1 .. Integer'Max (0, 6 - Plain'Length) => '0'] & Plain;
   end Six;

   function Sorted (Items : Name_Lists.Vector) return Name_Lists.Vector is
      Result : Name_Lists.Vector := Items;
   begin
      Sorting.Sort (Result);
      return Result;
   end Sorted;

   ---------------------------------------------------------------------------
   --  Building a graph.
   ---------------------------------------------------------------------------

   procedure Add_File (Into : in out Graph; Item : File_Entry) is
   begin
      Into.Files.Append (Item);
   end Add_File;

   procedure Add_Symbol (Into : in out Graph; Item : Symbol) is
      Full : constant String := To_String (Item.Name);
      Dot  : constant Natural :=
        Ada.Strings.Fixed.Index (Full, ".", Ada.Strings.Backward);
   begin
      Into.Symbols.Append (Item);

      --  A symbol inside a unit is that unit's declaration.
      if Dot > 0 then
         Into.Relations.Append
           (Relation'(Kind   => Declares,
                      From   => To_Unbounded_String (Full (Full'First .. Dot - 1)),
                      To     => Item.Name,
                      Source => Explicit,
                      Sure   => Certain,
                      Where  => To_Unbounded_String
                                  (To_String (Item.Path) & ":"
                                   & Image (Item.Line)),
                      Origin => Item.Path));
      end if;
   end Add_Symbol;

   procedure Add_Relation (Into : in out Graph; Item : Relation) is
      Made : Relation := Item;
   begin
      if Made.Origin = Null_Unbounded_String then
         Made.Origin := Into.Reading;
      end if;
      Into.Relations.Append (Made);
   end Add_Relation;

   function File_Count (From : Graph) return Natural
   is (Natural (From.Files.Length));

   function File_At (From : Graph; Index : Positive) return File_Entry
   is (From.Files (Index));

   function Symbol_Count (From : Graph) return Natural
   is (Natural (From.Symbols.Length));

   function Symbol_At (From : Graph; Index : Positive) return Symbol
   is (From.Symbols (Index));

   function Relation_Count (From : Graph) return Natural
   is (Natural (From.Relations.Length));

   function Relation_At (From : Graph; Index : Positive) return Relation
   is (From.Relations (Index));

   -----------------------
   -- Graph_Fingerprint --
   -----------------------

   function Graph_Fingerprint (From : Graph) return String is
      Text : Unbounded_String;
   begin
      for Item of From.Files loop
         Append (Text, Item.Path & Tab & Item.Fingerprint & ASCII.LF);
      end loop;
      return Fingerprint (To_String (Text));
   end Graph_Fingerprint;

   -----------------
   -- Language_Of --
   -----------------

   function Language_Of (Path : String) return String is
      Name : constant String := Lower (Path);

      function Ends (Suffix : String) return Boolean
      is (Name'Length > Suffix'Length
          and then Name (Name'Last - Suffix'Length + 1 .. Name'Last) = Suffix);
   begin
      if Ends (".ads") or else Ends (".adb") or else Ends (".ada") then
         return "Ada";
      elsif Ends (".gpr") then
         return "GPR";
      elsif Ends (".c") or else Ends (".h") then
         return "C";
      elsif Ends (".cpp") or else Ends (".hpp") or else Ends (".cc") or else Ends (".hh")
        or else Ends (".cxx") or else Ends (".hxx")
      then
         return "C++";
      elsif Ends (".rs") then
         return "Rust";
      elsif Ends (".py") then
         return "Python";
      elsif Ends (".md") then
         return "Markdown";
      elsif Ends (".toml") then
         return "TOML";
      elsif Ends (".json") then
         return "JSON";
      elsif Ends (".sh") then
         return "Shell";
      elsif Ends (".txt") then
         return "Text";
      end if;
      return "";
   end Language_Of;

   -------------
   -- Role_Of --
   -------------

   -------------------
   -- Default_Roots --
   -------------------

   function Default_Roots return Roots
   is (Skip          => Split ("obj bin lib alire node_modules target build _build"),
       Tests         => Split ("test tests testsuite *_test."),
       Documentation => Split ("doc docs"),
       Generated     => Split ("generated *.pb.go *_pb2.py *.pb.h *.pb.cc"));

   --------------
   -- Roots_Of --
   --------------

   function Roots_Of (Item : Stores.Store) return Roots is
      Result : Roots := Default_Roots;
      Config : Records.Item;
      Status : E.Error_Info;

      procedure Take (Name : String; Into : in out Name_Lists.Vector) is
         Given : constant Name_Lists.Vector :=
           Split (Records.Get (Config, "set.repository." & Name));
      begin
         if not Given.Is_Empty then
            Into := Given;
         end if;
      end Take;
   begin
      Configurations.Read (Item, Config, Status);
      if E.Is_Ok (Status) then
         Take ("skip", Result.Skip);
         Take ("tests", Result.Tests);
         Take ("documentation", Result.Documentation);
         Take ("generated", Result.Generated);
      end if;
      return Result;
   end Roots_Of;

   --  Whether a path within the project is one a root names.
   function Named_By (Listed : Name_Lists.Vector; Path : String) return Boolean is
      Name : constant String := "/" & Lower (Path) & "/";
   begin
      for Root of Listed loop
         declare
            Given : constant String := Lower (Root);
         begin
            if Given'Length > 1 and then Given (Given'First) = '*' then
               if Ada.Strings.Fixed.Index (Name, Given (Given'First + 1 .. Given'Last)) > 0 then
                  return True;
               end if;
            elsif Given /= ""
              and then Ada.Strings.Fixed.Index (Name, "/" & Trim_Slashes (Given) & "/") > 0
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Named_By;

   function Role_Of (Path : String; Within : Roots := Default_Roots) return File_Role is
      Name : constant String := "/" & Lower (Path);

      function Has (Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Name, Part) > 0);

      Language : constant String := Language_Of (Path);
   begin
      if Named_By (Within.Generated, Path) then
         return Generated;
      elsif Named_By (Within.Tests, Path) then
         return Test;
      elsif Language = "Markdown" or else Named_By (Within.Documentation, Path)
      then
         return Documentation;
      elsif Language in "GPR" | "TOML" | "JSON" | "Shell"
        or else Has ("/makefile") or else Has ("/cmakelists.txt")
      then
         return Build;
      elsif Language /= "" and then Language /= "Text" then
         return Source;
      end if;
      return Other;
   end Role_Of;

   --------------------
   -- Says_Generated --
   --------------------

   function Says_Generated (Text : String) return Boolean is
      Lines : Natural := 0;
      Stop  : Natural := Text'First - 1;
   begin
      while Stop < Text'Last and then Lines < 5 loop
         Stop := Stop + 1;
         if Text (Stop) = ASCII.LF then
            Lines := Lines + 1;
         end if;
      end loop;
      declare
         Head : constant String := Lower (Text (Text'First .. Stop));

         function Has (Part : String) return Boolean
         is (Ada.Strings.Fixed.Index (Head, Part) > 0);
      begin
         return Has ("@generated") or else Has ("automatically generated")
           or else (Has ("generated") and then (Has ("do not edit") or else Has ("don't edit")));
      end;
   end Says_Generated;

   ---------------------------------------------------------------------------
   --  The generic adapter.
   ---------------------------------------------------------------------------

   overriding function Language (Self : Generic_Adapter) return String
   is ("generic");

   overriding procedure Read
     (Self : Generic_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is
   begin
      --  The file is in the graph already; nothing in it is read.
      null;
   end Read;

   ---------------------------------------------------------------------------
   --  Reading Ada.
   ---------------------------------------------------------------------------

   type Token_Kind is (Word, Symbol_Mark, Text_Literal);

   type Token is record
      Kind : Token_Kind := Word;
      Text : Unbounded_String;
      Line : Positive := 1;
   end record;

   package Token_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Token);

   --  The tokens of Ada text: words, and each other mark on its own, with
   --  comments left out and literals kept whole.
   function Tokens_Of (Text : String) return Token_Vectors.Vector is
      Result : Token_Vectors.Vector;
      Index  : Natural := Text'First;
      Line   : Positive := 1;
   begin
      while Index <= Text'Last loop
         declare
            Char : constant Character := Text (Index);
         begin
            if Char = ASCII.LF then
               Line := Line + 1;
               Index := Index + 1;
            elsif Char = '-' and then Index < Text'Last
              and then Text (Index + 1) = '-'
            then
               while Index <= Text'Last and then Text (Index) /= ASCII.LF loop
                  Index := Index + 1;
               end loop;
            elsif Char = '"' then
               declare
                  Start : constant Positive := Index;
               begin
                  Index := Index + 1;
                  loop
                     exit when Index > Text'Last or else Text (Index) = ASCII.LF;
                     if Text (Index) = '"' then
                        if Index < Text'Last and then Text (Index + 1) = '"' then
                           Index := Index + 2;
                        else
                           Index := Index + 1;
                           exit;
                        end if;
                     else
                        Index := Index + 1;
                     end if;
                  end loop;
                  Result.Append
                    (Token'(Text_Literal,
                      To_Unbounded_String (Text (Start .. Index - 1)), Line));
               end;
            elsif Char = ''' and then Index + 2 <= Text'Last
              and then Text (Index + 2) = '''
              and then (Result.Is_Empty
                        or else Result.Last_Element.Kind /= Word)
            then
               --  A character literal; after a word the tick is an
               --  attribute's.
               Result.Append
                 (Token'(Text_Literal,
                   To_Unbounded_String (Text (Index .. Index + 2)), Line));
               Index := Index + 3;
            elsif Ada.Characters.Handling.Is_Letter (Char)
              or else Character'Pos (Char) >= 128
            then
               declare
                  Start : constant Positive := Index;
               begin
                  while Index <= Text'Last
                    and then (Ada.Characters.Handling.Is_Alphanumeric
                                (Text (Index))
                              or else Text (Index) = '_'
                              or else Character'Pos (Text (Index)) >= 128)
                  loop
                     Index := Index + 1;
                  end loop;
                  Result.Append
                    (Token'(Word, To_Unbounded_String (Text (Start .. Index - 1)),
                      Line));
               end;
            elsif Char in ' ' | ASCII.HT | ASCII.CR | ASCII.FF | ASCII.VT then
               Index := Index + 1;
            elsif Ada.Characters.Handling.Is_Digit (Char) then
               while Index <= Text'Last
                 and then (Ada.Characters.Handling.Is_Alphanumeric (Text (Index))
                           or else Text (Index) in '_' | '.' | '#')
               loop
                  Index := Index + 1;
               end loop;
            else
               Result.Append (Token'(Symbol_Mark, To_Unbounded_String ([1 => Char]), Line));
               Index := Index + 1;
            end if;
         end;
      end loop;
      return Result;
   end Tokens_Of;

   function Is_Word (Item : Token; Word_Text : String) return Boolean
   is (Item.Kind = Word and then Lower (To_String (Item.Text)) = Word_Text);

   function Is_Mark (Item : Token; Mark : Character) return Boolean
   is (Item.Kind = Symbol_Mark and then To_String (Item.Text) = [1 => Mark]);

   --  A dotted name starting at a token, and the token after it.
   procedure Name_At
     (Tokens : Token_Vectors.Vector;
      Start  : Positive;
      Name   : out Unbounded_String;
      Next   : out Positive)
   is
      Index : Positive := Start;
   begin
      Name := Null_Unbounded_String;
      Next := Start;
      if Start > Natural (Tokens.Length) or else Tokens (Start).Kind /= Word then
         return;
      end if;
      Name := Tokens (Index).Text;
      Index := Index + 1;
      while Index + 1 <= Natural (Tokens.Length)
        and then Is_Mark (Tokens (Index), '.')
        and then Tokens (Index + 1).Kind = Word
      loop
         Append (Name, "." & Tokens (Index + 1).Text);
         Index := Index + 2;
      end loop;
      Next := Index;
   end Name_At;

   --  The unit a file holds, as its first declaration names it.
   function Unit_Of (Tokens : Token_Vectors.Vector) return String is
      Name : Unbounded_String;
      Next : Positive;
   begin
      for Index in 1 .. Natural (Tokens.Length) loop
         if Is_Word (Tokens (Index), "package") or else Is_Word (Tokens (Index), "procedure")
           or else Is_Word (Tokens (Index), "function")
         then
            declare
               At_Name : constant Positive :=
                 (if Index < Natural (Tokens.Length)
                    and then Is_Word (Tokens (Index + 1), "body")
                  then Index + 2 else Index + 1);
            begin
               Name_At (Tokens, At_Name, Name, Next);
               return To_String (Name);
            end;
         elsif Is_Word (Tokens (Index), "separate") then
            --  A subunit is part of its parent.
            Name_At (Tokens, Index + 2, Name, Next);
            return To_String (Name);
         end if;
      end loop;
      return "";
   end Unit_Of;

   overriding function Language (Self : Ada_Adapter) return String
   is ("Ada");

   overriding procedure Read
     (Self : Ada_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph)
   is
      Tokens : constant Token_Vectors.Vector := Tokens_Of (Text);
      Count  : constant Natural := Natural (Tokens.Length);
      Unit   : constant String := Unit_Of (Tokens);
      Is_Body : constant Boolean :=
        Lower (Path) (Path'Last - 3 .. Path'Last) = ".adb"
        or else (for some Index in 1 .. Count - 1 =>
                   Is_Word (Tokens (Index), "package")
                   and then Is_Word (Tokens (Index + 1), "body"));
      Index  : Positive := 1;
      Depth  : Integer := 0;
      Name   : Unbounded_String;
      Next   : Positive;
   begin
      if Unit = "" then
         return;
      end if;

      Add_Relation
        (Into,
         (Kind => Contains, From => To_Unbounded_String (Path),
          To => To_Unbounded_String (Unit), Source => Explicit, Sure => Certain,
          Where => Null_Unbounded_String, Origin => <>));

      if Is_Body then
         Add_Relation
           (Into,
            (Kind => Implements, From => To_Unbounded_String (Path),
             To => To_Unbounded_String (Unit), Source => Explicit,
             Sure => Certain, Where => Null_Unbounded_String, Origin => <>));
      end if;

      --  The context clause: what this unit withs.
      while Index <= Count loop
         exit when Is_Word (Tokens (Index), "package")
           or else Is_Word (Tokens (Index), "procedure")
           or else Is_Word (Tokens (Index), "function")
           or else Is_Word (Tokens (Index), "generic")
           or else Is_Word (Tokens (Index), "separate");
         if Is_Word (Tokens (Index), "with") then
            Index := Index + 1;
            loop
               Name_At (Tokens, Index, Name, Next);
               exit when Name = Null_Unbounded_String;
               Add_Relation
                 (Into,
                  (Kind => Depends_On, From => To_Unbounded_String (Unit),
                   To => Name, Source => Explicit, Sure => Certain,
                   Where => To_Unbounded_String
                              (Path & ":" & Image (Tokens (Index).Line)), Origin => <>));
               Index := Next;
               exit when Index > Count or else not Is_Mark (Tokens (Index), ',');
               Index := Index + 1;
            end loop;
         else
            Index := Index + 1;
         end if;
      end loop;

      --  What is made from what, anywhere in the unit: instantiations,
      --  derivations and the interfaces they take on, and overriding.
      for At_Index in Index .. Count loop
         declare
            Here : constant Token := Tokens (At_Index);
         begin
            if Here.Kind = Word
              and then Lower (To_String (Here.Text)) in "package" | "procedure" | "function"
              and then At_Index + 4 <= Count
              and then Tokens (At_Index + 1).Kind = Word
              and then Is_Word (Tokens (At_Index + 2), "is")
              and then Is_Word (Tokens (At_Index + 3), "new")
            then
               declare
                  Made : Unbounded_String;
                  Past : Positive;
               begin
                  Name_At (Tokens, At_Index + 4, Made, Past);
                  if Made /= Null_Unbounded_String then
                     Add_Relation
                       (Into,
                        (Kind => Instantiates,
                         From => To_Unbounded_String
                                   (Unit & "." & To_String (Tokens (At_Index + 1).Text)),
                         --  Said in the text; what the name names is not
                         --  resolved -- a use clause or a renaming could
                         --  make it another -- so probable.
                         To => Made, Source => Explicit, Sure => Probable,
                         Where => To_Unbounded_String (Path & ":" & Image (Here.Line)), Origin => <>));
                  end if;
               end;
            elsif Is_Word (Here, "type") and then At_Index + 1 <= Count
              and then Tokens (At_Index + 1).Kind = Word
            then
               declare
                  Typed : constant String :=
                    Unit & "." & To_String (Tokens (At_Index + 1).Text);
                  Ahead : Positive := At_Index + 2;
                  Seen_Is : Boolean := False;
               begin
                  while Ahead <= Count and then not Is_Mark (Tokens (Ahead), ';') loop
                     if Is_Word (Tokens (Ahead), "is") then
                        Seen_Is := True;
                     elsif Seen_Is
                       and then (Is_Word (Tokens (Ahead), "new")
                                 or else Is_Word (Tokens (Ahead), "and"))
                     then
                        declare
                           Other : Unbounded_String;
                           Past  : Positive;
                        begin
                           Name_At (Tokens, Ahead + 1, Other, Past);
                           if Other /= Null_Unbounded_String
                             and then Lower (To_String (Other)) not in "with" | "record"
                           then
                              Add_Relation
                                (Into,
                                 (Kind => (if Is_Word (Tokens (Ahead), "new") then Extends
                                           else Implements_Interface),
                                  From => To_Unbounded_String (Typed), To => Other,
                                  Source => Explicit, Sure => Probable,
                                  Where => To_Unbounded_String
                                             (Path & ":" & Image (Tokens (Ahead).Line)), Origin => <>));
                           end if;
                        end;
                     elsif Seen_Is and then Is_Word (Tokens (Ahead), "record") then
                        exit;
                     end if;
                     Ahead := Ahead + 1;
                  end loop;
               end;
            elsif Is_Word (Here, "overriding") and then At_Index + 2 <= Count
              and then Tokens (At_Index + 2).Kind = Word
            then
               Add_Relation
                 (Into,
                  (Kind => Overrides,
                   From => To_Unbounded_String
                             (Unit & "." & To_String (Tokens (At_Index + 2).Text)),
                   --  That it overrides is said; which ancestor's
                   --  operation it overrides is not worked out, so the
                   --  name alone, and uncertain.
                   To => Tokens (At_Index + 2).Text, Source => Explicit, Sure => Uncertain,
                   Where => To_Unbounded_String (Path & ":" & Image (Here.Line)), Origin => <>));
            end if;
         end;
      end loop;

      --  The unit itself is a symbol, and in a spec so is everything it
      --  declares at its outer level.
      if not Is_Body or else not (for some Index in 1 .. Count =>
                                     Is_Word (Tokens (Index), "package"))
      then
         Add_Symbol
           (Into,
            (Name => To_Unbounded_String (Unit),
             Kind => To_Unbounded_String
                       (if Index <= Count then Lower (To_String (Tokens (Index).Text))
                        else "unit"),
             Path => To_Unbounded_String (Path),
             Line => (if Index <= Count then Tokens (Index).Line else 1)));
      end if;

      if Is_Body then
         return;
      end if;

      while Index <= Count loop
         declare
            Here : constant Token := Tokens (Index);
            Spelled : constant String :=
              (if Here.Kind = Word then Lower (To_String (Here.Text)) else "");
         begin
            if Spelled = "record" and then not
              (Index > 1 and then Is_Word (Tokens (Index - 1), "null"))
            then
               Depth := Depth + 1;
            elsif Spelled = "end" then
               if Index < Count and then Is_Word (Tokens (Index + 1), "record") then
                  Depth := Depth - 1;
                  Index := Index + 1;
               elsif Depth > 0 then
                  Depth := Depth - 1;
               end if;
            elsif Depth = 1
              and then Spelled in "procedure" | "function" | "type" | "subtype"
                             | "package" | "task" | "protected" | "entry"
            then
               declare
                  At_Name : Positive := Index + 1;
               begin
                  if At_Name <= Count
                    and then (Is_Word (Tokens (At_Name), "type")
                              or else Is_Word (Tokens (At_Name), "body"))
                  then
                     At_Name := At_Name + 1;
                  end if;
                  if At_Name <= Count and then Tokens (At_Name).Kind = Word then
                     Add_Symbol
                       (Into,
                        (Name => To_Unbounded_String
                                   (Unit & "." & To_String (Tokens (At_Name).Text)),
                         Kind => To_Unbounded_String (Spelled),
                         Path => To_Unbounded_String (Path),
                         Line => Tokens (At_Name).Line));
                  end if;

                  --  A nested package, task or protected unit opens a
                  --  scope of its own whose declarations are not the
                  --  unit's.
                  if Spelled in "package" | "task" | "protected" then
                     for Ahead in At_Name .. Count loop
                        exit when Is_Mark (Tokens (Ahead), ';');
                        if Is_Word (Tokens (Ahead), "is") then
                           if Ahead < Count
                             and then not Is_Word (Tokens (Ahead + 1), "new")
                             and then not Is_Word (Tokens (Ahead + 1), "separate")
                           then
                              Depth := Depth + 1;
                           end if;
                           exit;
                        end if;
                     end loop;
                  end if;
               end;
            elsif Depth = 1 and then Here.Kind = Word and then Index + 2 <= Count
              and then Is_Mark (Tokens (Index + 1), ':')
              and then (Is_Word (Tokens (Index + 2), "constant")
                        or else Is_Word (Tokens (Index + 2), "exception"))
            then
               Add_Symbol
                 (Into,
                  (Name => To_Unbounded_String
                             (Unit & "." & To_String (Here.Text)),
                   Kind => To_Unbounded_String
                             (Lower (To_String (Tokens (Index + 2).Text))),
                   Path => To_Unbounded_String (Path),
                   Line => Here.Line));
            elsif Depth = 0 and then Spelled = "is" then
               --  The unit's own declarations begin.
               Depth := 1;
            end if;
         end;
         Index := Index + 1;
      end loop;
   end Read;

   --  The references a file makes to the symbols of the units it withs
   --  and its own: every word that is such a symbol's last name.
   procedure Find_References
     (Path : String;
      Text : String;
      Into : in out Graph)
   is
      Tokens : constant Token_Vectors.Vector := Tokens_Of (Text);
      Unit   : constant String := Unit_Of (Tokens);
      Seen   : Name_Lists.Vector;
   begin
      if Unit = "" then
         return;
      end if;

      --  The units whose names this file can use.
      Seen.Append (Unit);
      for Link of Into.Relations loop
         if Link.Kind = Depends_On and then To_String (Link.From) = Unit then
            Seen.Append (To_String (Link.To));
         end if;
      end loop;

      for Item of Into.Symbols loop
         declare
            Full  : constant String := To_String (Item.Name);
            Dot   : constant Natural :=
              Ada.Strings.Fixed.Index (Full, ".", Ada.Strings.Backward);
            Owner : constant String :=
              (if Dot = 0 then Full else Full (Full'First .. Dot - 1));
            Last  : constant String :=
              Lower (if Dot = 0 then Full else Full (Dot + 1 .. Full'Last));
         begin
            if Seen.Contains (Owner) and then To_String (Item.Path) /= Path then
               for At_Index in 1 .. Natural (Tokens.Length) loop
                  declare
                     Here : constant Token := Tokens (At_Index);
                  begin
                     if Here.Kind = Word and then Lower (To_String (Here.Text)) = Last
                     then
                        Add_Relation
                          (Into,
                           (Kind  => References,
                            From  => To_Unbounded_String (Path),
                            To    => Item.Name,
                            Source => Heuristic,
                            Sure   => Probable,
                            Where  => To_Unbounded_String
                                        (Path & ":" & Image (Here.Line)), Origin => <>));

                        --  A subprogram's name followed by its arguments or
                        --  the end of a statement is a call of it.
                        if To_String (Item.Kind) in "procedure" | "function"
                          and then At_Index < Natural (Tokens.Length)
                          and then (Is_Mark (Tokens (At_Index + 1), '(')
                                    or else Is_Mark (Tokens (At_Index + 1), ';'))
                          and then not (At_Index > 1
                                        and then (Is_Word (Tokens (At_Index - 1), "procedure")
                                                  or else Is_Word (Tokens (At_Index - 1),
                                                                   "function")
                                                  or else Is_Word (Tokens (At_Index - 1), "end")))
                        then
                           Add_Relation
                             (Into,
                              (Kind  => Calls,
                               From  => To_Unbounded_String (Unit),
                               To    => Item.Name,
                               Source => Heuristic,
                               Sure   => Probable,
                               Where  => To_Unbounded_String
                                           (Path & ":" & Image (Here.Line)), Origin => <>));
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
   end Find_References;

   overriding procedure Read_References
     (Self : Ada_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is
   begin
      Find_References (Path, Text, Into);
   end Read_References;

   ---------------------------------------------------------------------------
   --  Scanning.
   ---------------------------------------------------------------------------

   --  Whether a file's adapter finds references once every file is read.
   function Reads_References (Path : String) return Boolean
   is (Language_Of (Path) in "Ada" | "C" | "C++" | "Rust" | "Python");

   --  Whether a scan leaves a file or directory out: a hidden one, or one
   --  the roots skip.
   function Skipped (Name, Relative : String; Within : Roots) return Boolean
   is (Name'Length = 0 or else Name (Name'First) = '.'
       or else Named_By (Within.Skip, Relative));

   ----------
   -- Scan --
   ----------

   function Scan
     (Project_Directory : String;
      Within            : Roots := Default_Roots) return Graph
   is
      Result   : Graph;
      Texts    : Name_Lists.Vector;
      Paths    : Name_Lists.Vector;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Names  : Name_Lists.Vector;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            if not Skipped
              (Dirs.Simple_Name (Found),
               (if Prefix = "" then "" else Prefix & "/") & Dirs.Simple_Name (Found), Within)
            then
               Names.Append (Dirs.Simple_Name (Found));
            end if;
         end loop;
         Dirs.End_Search (Search);

         --  In order, so that two scans of the same tree are one graph.
         for Name of Sorted (Names) loop
            declare
               Full     : constant String := Hostkit.Fs.Join (Directory, Name);
               Relative : constant String :=
                 (if Prefix = "" then Name else Prefix & "/" & Name);
            begin
               if Dirs.Kind (Full) = Dirs.Directory then
                  Walk (Full, Relative);
               elsif Dirs.Kind (Full) = Dirs.Ordinary_File then
                  declare
                     Text   : Unbounded_String;
                     Status : E.Error_Info;
                     Size   : constant Dirs.File_Size := Dirs.Size (Full);
                     use type Dirs.File_Size;
                  begin
                     if Size <= Largest_Read then
                        Files.Read_Text (Full, Text, Status);
                     end if;
                     Result.Reading := To_Unbounded_String (Relative);
                     Add_File
                       (Result,
                        (Path        => To_Unbounded_String (Relative),
                         Language    => To_Unbounded_String (Language_Of (Relative)),
                         Role        => (if Says_Generated (To_String (Text)) then Generated
                                         else Role_Of (Relative, Within)),
                         Fingerprint => To_Unbounded_String
                                          (Fingerprint (To_String (Text))),
                         Stamp       => To_Unbounded_String (Stamp_Of (Full))));
                     declare
                        Reader : constant Adapter'Class :=
                          Languages.Adapter_For (Language_Of (Relative));
                     begin
                        Reader.Read (Relative, To_String (Text), Result);
                        if Reads_References (Relative) then
                           Paths.Append (Relative);
                           Texts.Append (To_String (Text));
                        end if;
                     end;
                  end;
               end if;
            exception
               when others =>
                  null;
            end;
         end loop;
      exception
         when others =>
            null;
      end Walk;
   begin
      Walk (Project_Directory, "");

      --  References need every symbol, so they come after every file.
      for Index in 1 .. Natural (Paths.Length) loop
         Result.Reading := To_Unbounded_String (Paths (Index));
         Languages.Adapter_For (Language_Of (Paths (Index))).Read_References
           (Paths (Index), Texts (Index), Result);
      end loop;
      Result.Reading := Null_Unbounded_String;
      return Result;
   end Scan;

   -------------
   -- Refresh --
   -------------

   function Refresh
     (Project_Directory : String;
      Kept              : Graph;
      Read_Again        : out Natural;
      Within            : Roots := Default_Roots) return Graph
   is
      Result   : Graph;

      --  The files there are now, in the order Scan walks them, with their
      --  stamps.
      Now_Paths  : Name_Lists.Vector;
      Now_Stamps : Name_Lists.Vector;

      --  What was read again, and the text of every Ada file whose
      --  references may have to be found again.
      Changed : Name_Lists.Vector;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Names  : Name_Lists.Vector;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            if not Skipped
              (Dirs.Simple_Name (Found),
               (if Prefix = "" then "" else Prefix & "/") & Dirs.Simple_Name (Found), Within)
            then
               Names.Append (Dirs.Simple_Name (Found));
            end if;
         end loop;
         Dirs.End_Search (Search);
         for Name of Sorted (Names) loop
            declare
               Full     : constant String := Hostkit.Fs.Join (Directory, Name);
               Relative : constant String :=
                 (if Prefix = "" then Name else Prefix & "/" & Name);
            begin
               if Dirs.Kind (Full) = Dirs.Directory then
                  Walk (Full, Relative);
               elsif Dirs.Kind (Full) = Dirs.Ordinary_File then
                  Now_Paths.Append (Relative);
                  Now_Stamps.Append (Stamp_Of (Full));
               end if;
            exception
               when others =>
                  null;
            end;
         end loop;
      exception
         when others =>
            null;
      end Walk;

      function Kept_Index (Path : String) return Natural is
      begin
         for Index in 1 .. Natural (Kept.Files.Length) loop
            if To_String (Kept.Files (Index).Path) = Path then
               return Index;
            end if;
         end loop;
         return 0;
      end Kept_Index;

      --  The text of a file, and whether it could be read.
      function Text_Of (Path : String) return String is
         Text   : Unbounded_String;
         Status : E.Error_Info;
         Full   : constant String := Hostkit.Fs.Join (Project_Directory, Path);
         use type Dirs.File_Size;
      begin
         if Dirs.Size (Full) <= Largest_Read then
            Files.Read_Text (Full, Text, Status);
         end if;
         return To_String (Text);
      exception
         when others =>
            return "";
      end Text_Of;

      function Is_Reference (Kind : Relation_Kind) return Boolean
      is (Kind in References | Calls);

      --  The units a set of files hold, from a graph.
      function Units_Of (From : Graph; Paths : Name_Lists.Vector) return Name_Lists.Vector is
         Units : Name_Lists.Vector;
      begin
         for Link of From.Relations loop
            if Link.Kind = Contains and then Paths.Contains (To_String (Link.From))
              and then not Units.Contains (To_String (Link.To))
            then
               Units.Append (To_String (Link.To));
            end if;
         end loop;
         return Units;
      end Units_Of;

      --  Whether the roots now place a kept file otherwise. One generated
      --  by what it says, not where it is, stays so while it is unchanged.
      function Role_Moved (Was : File_Role; Path : String) return Boolean
      is (if Was = Generated
          then not Named_By (Within.Generated, Path) and then not Says_Generated (Text_Of (Path))
          else Was /= Role_Of (Path, Within));

      Gone : Name_Lists.Vector;
   begin
      Read_Again := 0;
      Walk (Project_Directory, "");

      --  What changed, and what went.
      for Index in 1 .. Natural (Now_Paths.Length) loop
         declare
            Held : constant Natural := Kept_Index (Now_Paths (Index));
         begin
            if Held = 0 or else Length (Kept.Files (Held).Stamp) = 0
              or else To_String (Kept.Files (Held).Stamp) /= Now_Stamps (Index)
              or else Recent (Now_Stamps (Index))
              or else Role_Moved (Kept.Files (Held).Role, Now_Paths (Index))
            then
               Changed.Append (Now_Paths (Index));
            end if;
         end;
      end loop;
      for Item of Kept.Files loop
         if not Now_Paths.Contains (To_String (Item.Path)) then
            Gone.Append (To_String (Item.Path));
         end if;
      end loop;
      if Changed.Is_Empty and then Gone.Is_Empty then
         return Kept;
      end if;

      --  Each file in order: as it was, or read again.
      for Index in 1 .. Natural (Now_Paths.Length) loop
         declare
            Path : constant String := Now_Paths (Index);
         begin
            Result.Reading := To_Unbounded_String (Path);
            if Changed.Contains (Path) then
               declare
                  Text : constant String := Text_Of (Path);
               begin
                  Read_Again := Read_Again + 1;
                  Add_File
                    (Result,
                     (Path        => To_Unbounded_String (Path),
                      Language    => To_Unbounded_String (Language_Of (Path)),
                      Role        => (if Says_Generated (Text) then Generated
                                      else Role_Of (Path, Within)),
                      Fingerprint => To_Unbounded_String (Fingerprint (Text)),
                      Stamp       => To_Unbounded_String (Now_Stamps (Index))));
                  Languages.Adapter_For (Language_Of (Path)).Read (Path, Text, Result);
               end;
            else
               Add_File (Result, Kept.Files (Kept_Index (Path)));
               for Named of Kept.Symbols loop
                  if To_String (Named.Path) = Path then
                     Result.Symbols.Append (Named);
                  end if;
               end loop;
               for Link of Kept.Relations loop
                  if To_String (Link.Origin) = Path and then not Is_Reference (Link.Kind) then
                     Result.Relations.Append (Link);
                  end if;
               end loop;
            end if;
         end;
      end loop;

      --  References: found again for a changed file and for every file
      --  that can see a changed or removed unit; taken as they were for
      --  the rest.
      declare
         Moved   : Name_Lists.Vector := Units_Of (Result, Changed);
         Removed : constant Name_Lists.Vector := Units_Of (Kept, Gone);
      begin
         for Unit of Removed loop
            if not Moved.Contains (Unit) then
               Moved.Append (Unit);
            end if;
         end loop;
         for Path of Now_Paths loop
            if Reads_References (Path) then
               declare
                  Own    : constant Name_Lists.Vector :=
                    Units_Of (Result, Name_Lists.To_Vector (Path, 1));
                  Sees   : Boolean := Changed.Contains (Path);
               begin
                  for Link of Result.Relations loop
                     if not Sees and then Own.Contains (To_String (Link.From))
                       and then Link.Kind = Depends_On
                       and then Moved.Contains (To_String (Link.To))
                     then
                        Sees := True;
                     end if;
                  end loop;
                  Sees := Sees or else (for some Unit of Own => Moved.Contains (Unit));
                  Result.Reading := To_Unbounded_String (Path);
                  if Sees then
                     if not Changed.Contains (Path) then
                        Read_Again := Read_Again + 1;
                     end if;
                     Languages.Adapter_For (Language_Of (Path)).Read_References
                       (Path, Text_Of (Path), Result);
                  else
                     for Link of Kept.Relations loop
                        if To_String (Link.Origin) = Path and then Is_Reference (Link.Kind) then
                           Result.Relations.Append (Link);
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end loop;
      end;
      Result.Reading := Null_Unbounded_String;
      return Result;
   end Refresh;

   ---------
   -- Now --
   ---------

   function Now (Item : Stores.Store) return Graph is
      Kept       : Graph;
      Read       : E.Error_Info;
      Read_Again : Natural;
   begin
      Load (Item, Kept, Read);
      return Refresh (Ada.Directories.Containing_Directory (Stores.Root (Item)), Kept, Read_Again,
                      Roots_Of (Item));
   end Now;

   -------------
   -- Current --
   -------------

   procedure Current
     (Item   : in out Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Kept       : Graph;
      Read       : E.Error_Info;
      Read_Again : Natural;
      Change     : Stores.Transaction;
   begin
      Status := E.Success;
      Load (Item, Kept, Read);
      Found := Refresh (Ada.Directories.Containing_Directory (Stores.Root (Item)), Kept,
                        Read_Again, Roots_Of (Item));
      if Read_Again > 0 or else E.Is_Error (Read)
        or else Natural (Found.Files.Length) /= Natural (Kept.Files.Length)
      then
         Keep (Item, Change, Found, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
      end if;
   end Current;

   ---------------------------------------------------------------------------
   --  Keeping.
   ---------------------------------------------------------------------------

   function Split_Tabs (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = Tab then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split_Tabs;

   ----------
   -- Keep --
   ----------

   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item :=
        Records.Create
          (Schemas.Repository_Schema, 1, "REPOSITORY",
           Stores.Current_Revision (Item, Indexes_Area, Index_Name) + 1);
   begin
      Status := E.Success;
      for Index in 1 .. Natural (Found.Files.Length) loop
         declare
            File : File_Entry renames Found.Files (Index);
         begin
            Records.Set
              (Value, "file." & Six (Index),
               To_String (File.Path) & Tab & To_String (File.Language) & Tab
               & Lower (File_Role'Image (File.Role)) & Tab
               & To_String (File.Fingerprint) & Tab & To_String (File.Stamp));
         end;
      end loop;
      for Index in 1 .. Natural (Found.Symbols.Length) loop
         declare
            Named : Symbol renames Found.Symbols (Index);
         begin
            Records.Set
              (Value, "symbol." & Six (Index),
               To_String (Named.Name) & Tab & To_String (Named.Kind) & Tab
               & To_String (Named.Path) & Tab & Image (Named.Line));
         end;
      end loop;
      for Index in 1 .. Natural (Found.Relations.Length) loop
         declare
            Link : Relation renames Found.Relations (Index);
         begin
            Records.Set
              (Value, "relation." & Six (Index),
               Lower (Relation_Kind'Image (Link.Kind)) & Tab
               & To_String (Link.From) & Tab & To_String (Link.To) & Tab
               & Lower (Derivation'Image (Link.Source)) & Tab
               & Lower (Confidence'Image (Link.Sure)) & Tab
               & To_String (Link.Where) & Tab & To_String (Link.Origin));
         end;
      end loop;
      Records.Set (Value, "fingerprint", Graph_Fingerprint (Found));
      Stores.Put (Change, Indexes_Area, Index_Name, Value);
   end Keep;

   ----------
   -- Load --
   ----------

   procedure Load
     (Item   : Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Found := (others => <>);
      Stores.Read (Item, Indexes_Area, Index_Name, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Parts : constant Name_Lists.Vector :=
              Split_Tabs (Records.Get (Value, Field));
         begin
            if Ada.Strings.Fixed.Index (Field, "file.") = Field'First
              and then Natural (Parts.Length) in 4 .. 5
            then
               Found.Files.Append
                 (File_Entry'
                  (Path        => To_Unbounded_String (Parts (1)),
                   Language    => To_Unbounded_String (Parts (2)),
                   Role        => File_Role'Value (Parts (3)),
                   Fingerprint => To_Unbounded_String (Parts (4)),
                   Stamp       => To_Unbounded_String
                                    (if Natural (Parts.Length) = 5 then Parts (5) else "")));
            elsif Ada.Strings.Fixed.Index (Field, "symbol.") = Field'First
              and then Natural (Parts.Length) = 4
            then
               Found.Symbols.Append
                 (Symbol'
                  (Name => To_Unbounded_String (Parts (1)),
                   Kind => To_Unbounded_String (Parts (2)),
                   Path => To_Unbounded_String (Parts (3)),
                   Line => Natural'Value (Parts (4))));
            elsif Ada.Strings.Fixed.Index (Field, "relation.") = Field'First
              and then Natural (Parts.Length) in 6 .. 7
            then
               Found.Relations.Append
                 (Relation'
                  (Kind   => Relation_Kind'Value (Parts (1)),
                   From   => To_Unbounded_String (Parts (2)),
                   To     => To_Unbounded_String (Parts (3)),
                   Source => Derivation'Value (Parts (4)),
                   Sure   => Confidence'Value (Parts (5)),
                   Where  => To_Unbounded_String (Parts (6)),
                   Origin => To_Unbounded_String
                               (if Natural (Parts.Length) = 7 then Parts (7) else "")));
            end if;
         end;
      end loop;
   exception
      when Constraint_Error =>
         Found := (others => <>);
         Status := E.Make (E.Framework_Record_Malformed);
         E.Add_Text (Status, "path", "indexes/" & Index_Name, E.Param_Path);
         E.Add_Text (Status, "detail", "a line of the graph is not one");
   end Load;

   ---------------------------------------------------------------------------
   --  Queries.
   ---------------------------------------------------------------------------

   ------------------
   -- Find_Symbols --
   ------------------

   function Find_Symbols (From : Graph; Name : String) return Name_Lists.Vector
   is
      Wanted : constant String := Lower (Name);
      Result : Name_Lists.Vector;
   begin
      for Item of From.Symbols loop
         declare
            Full : constant String := Lower (To_String (Item.Name));
         begin
            if (Full = Wanted
                or else (Full'Length > Wanted'Length
                         and then Full (Full'Last - Wanted'Length .. Full'Last)
                                  = "." & Wanted))
              and then not Result.Contains (To_String (Item.Name))
            then
               Result.Append (To_String (Item.Name));
            end if;
         end;
      end loop;
      return Sorted (Result);
   end Find_Symbols;

   ---------------
   -- Symbol_Of --
   ---------------

   function Symbol_Of
     (From  : Graph;
      Name  : String;
      Found : out Boolean) return Symbol is
   begin
      for Item of From.Symbols loop
         if To_String (Item.Name) = Name then
            Found := True;
            return Item;
         end if;
      end loop;
      Found := False;
      return (others => <>);
   end Symbol_Of;

   -------------------
   -- References_To --
   -------------------

   function References_To
     (From : Graph;
      Name : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Link of From.Relations loop
         if Link.Kind = References and then To_String (Link.To) = Name
           and then not Result.Contains (To_String (Link.Where))
         then
            Result.Append (To_String (Link.Where));
         end if;
      end loop;
      return Sorted (Result);
   end References_To;

   ---------------------
   -- Dependencies_Of --
   ---------------------

   function Dependencies_Of
     (From : Graph;
      Unit : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Link of From.Relations loop
         if Link.Kind = Depends_On
           and then Lower (To_String (Link.From)) = Lower (Unit)
           and then not Result.Contains (To_String (Link.To))
         then
            Result.Append (To_String (Link.To));
         end if;
      end loop;
      return Sorted (Result);
   end Dependencies_Of;

   -------------------
   -- Dependents_Of --
   -------------------

   function Dependents_Of
     (From : Graph;
      Unit : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Link of From.Relations loop
         if Link.Kind = Depends_On
           and then Lower (To_String (Link.To)) = Lower (Unit)
           and then not Result.Contains (To_String (Link.From))
         then
            Result.Append (To_String (Link.From));
         end if;
      end loop;
      return Sorted (Result);
   end Dependents_Of;

end Model_Runner.Framework.Repository;
