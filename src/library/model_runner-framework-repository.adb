with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;
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

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

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
                                   & Image (Item.Line))));
      end if;
   end Add_Symbol;

   procedure Add_Relation (Into : in out Graph; Item : Relation) is
   begin
      Into.Relations.Append (Item);
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
      elsif Ends (".cpp") or else Ends (".hpp") or else Ends (".cc") then
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

   function Role_Of (Path : String) return File_Role is
      Name : constant String := "/" & Lower (Path);

      function Has (Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Name, Part) > 0);

      Language : constant String := Language_Of (Path);
   begin
      if Has ("/test/") or else Has ("/tests/") or else Has ("_test.")
        or else Has ("/testsuite/")
      then
         return Test;
      elsif Language = "Markdown" or else Has ("/docs/") or else Has ("/doc/")
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
          Where => Null_Unbounded_String));

      if Is_Body then
         Add_Relation
           (Into,
            (Kind => Implements, From => To_Unbounded_String (Path),
             To => To_Unbounded_String (Unit), Source => Explicit,
             Sure => Certain, Where => Null_Unbounded_String));
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
                              (Path & ":" & Image (Tokens (Index).Line))));
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
                         To => Made, Source => Explicit, Sure => Certain,
                         Where => To_Unbounded_String (Path & ":" & Image (Here.Line))));
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
                                  Source => Explicit, Sure => Certain,
                                  Where => To_Unbounded_String
                                             (Path & ":" & Image (Tokens (Ahead).Line))));
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
                   To => Tokens (At_Index + 2).Text, Source => Explicit, Sure => Certain,
                   Where => To_Unbounded_String (Path & ":" & Image (Here.Line))));
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
                                        (Path & ":" & Image (Here.Line))));

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
                                           (Path & ":" & Image (Here.Line))));
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
   end Find_References;

   ---------------------------------------------------------------------------
   --  Scanning.
   ---------------------------------------------------------------------------

   function Skipped (Name : String) return Boolean
   is (Name'Length = 0 or else Name (Name'First) = '.'
       or else Name in "obj" | "bin" | "lib" | "alire" | "node_modules"
                     | "target" | "build" | "_build");

   ----------
   -- Scan --
   ----------

   function Scan (Project_Directory : String) return Graph is
      Result   : Graph;
      Ada_Read : Ada_Adapter;
      Plain    : Generic_Adapter;
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
            if not Skipped (Dirs.Simple_Name (Found)) then
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
                     Add_File
                       (Result,
                        (Path        => To_Unbounded_String (Relative),
                         Language    => To_Unbounded_String (Language_Of (Relative)),
                         Role        => Role_Of (Relative),
                         Fingerprint => To_Unbounded_String
                                          (Fingerprint (To_String (Text)))));
                     if Language_Of (Relative) = "Ada" then
                        Read (Ada_Read, Relative, To_String (Text), Result);
                        Paths.Append (Relative);
                        Texts.Append (To_String (Text));
                     else
                        Read (Plain, Relative, To_String (Text), Result);
                     end if;
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
         Find_References (Paths (Index), Texts (Index), Result);
      end loop;
      return Result;
   end Scan;

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
               & To_String (File.Fingerprint));
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
               & To_String (Link.Where));
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
              and then Natural (Parts.Length) = 4
            then
               Found.Files.Append
                 (File_Entry'
                  (Path        => To_Unbounded_String (Parts (1)),
                   Language    => To_Unbounded_String (Parts (2)),
                   Role        => File_Role'Value (Parts (3)),
                   Fingerprint => To_Unbounded_String (Parts (4))));
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
              and then Natural (Parts.Length) = 6
            then
               Found.Relations.Append
                 (Relation'
                  (Kind   => Relation_Kind'Value (Parts (1)),
                   From   => To_Unbounded_String (Parts (2)),
                   To     => To_Unbounded_String (Parts (3)),
                   Source => Derivation'Value (Parts (4)),
                   Sure   => Confidence'Value (Parts (5)),
                   Where  => To_Unbounded_String (Parts (6))));
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
