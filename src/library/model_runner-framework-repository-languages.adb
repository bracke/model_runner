with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Hash;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

package body Model_Runner.Framework.Repository.Languages is

   use Ada.Strings.Unbounded;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Ends (Text, Suffix : String) return Boolean
   is (Text'Length >= Suffix'Length
       and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function U (Text : String) return Unbounded_String renames To_Unbounded_String;

   ---------------------------------------------------------------------------
   --  Tokens.
   ---------------------------------------------------------------------------

   type Token_Kind is (Word, Mark, Literal);

   type Token is record
      Kind : Token_Kind := Word;
      Text : Unbounded_String;
      Line : Positive := 1;
   end record;

   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (String, Ada.Strings.Hash, "=");

   --  The units' last names, worked out once for a graph -- known by its
   --  symbols, which reading references does not add to -- not for every
   --  file it reads the references of.
   Known_Units   : Name_Sets.Set;
   Known_Symbols : Natural := Natural'Last;
   Known_Ends    : Ada.Strings.Unbounded.Unbounded_String;

   package Token_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Token);

   --  How a language writes what a reader skips.
   type Dialect is (C_Like, Rust_Like, Python_Like);

   function Is_Name_Start (Char : Character) return Boolean
   is (Ada.Characters.Handling.Is_Letter (Char) or else Char = '_'
       or else Character'Pos (Char) >= 128);

   function Is_Name_Part (Char : Character) return Boolean
   is (Is_Name_Start (Char) or else Ada.Characters.Handling.Is_Digit (Char));

   --  The tokens of a text: names, marks (:: as one) and literals, with
   --  comments left out -- and, for C, the preprocessor's lines, which are
   --  read as lines.
   function Tokens_Of (Text : String; Kind : Dialect) return Token_Vectors.Vector is
      Result : Token_Vectors.Vector;
      Index  : Natural := Text'First;
      Line   : Positive := 1;
      At_Line_Start : Boolean := True;

      procedure Skip_To_Line_End is
      begin
         while Index <= Text'Last and then Text (Index) /= ASCII.LF loop
            Index := Index + 1;
         end loop;
      end Skip_To_Line_End;

      function Next_Is (Offset : Natural; Char : Character) return Boolean
      is (Index + Offset <= Text'Last and then Text (Index + Offset) = Char);

      --  A quoted literal from Index, its quote given; a triple quote when
      --  Triple.
      procedure Quoted (Quote : Character; Triple : Boolean) is
         Start : constant Positive := Index;
      begin
         Index := Index + (if Triple then 3 else 1);
         while Index <= Text'Last loop
            if Text (Index) = '\' then
               Index := Index + 2;
            elsif Triple then
               if Text (Index) = Quote and then Next_Is (1, Quote) and then Next_Is (2, Quote)
               then
                  Index := Index + 3;
                  exit;
               end if;
               if Text (Index) = ASCII.LF then
                  Line := Line + 1;
               end if;
               Index := Index + 1;
            elsif Text (Index) = Quote then
               Index := Index + 1;
               exit;
            elsif Text (Index) = ASCII.LF then
               exit;
            else
               Index := Index + 1;
            end if;
         end loop;
         Result.Append
           (Token'(Literal, U (Text (Start .. Natural'Min (Index - 1, Text'Last))), Line));
      end Quoted;
   begin
      while Index <= Text'Last loop
         declare
            Char : constant Character := Text (Index);
         begin
            if Char = ASCII.LF then
               Line := Line + 1;
               Index := Index + 1;
               At_Line_Start := True;
            elsif Char in ' ' | ASCII.HT | ASCII.CR | ASCII.FF | ASCII.VT then
               Index := Index + 1;
            elsif Kind = C_Like and then Char = '#' and then At_Line_Start then
               --  A preprocessor line, with its continuations.
               loop
                  Skip_To_Line_End;
                  exit when Index > Text'Last or else Index - 1 < Text'First
                    or else Text (Index - 1) /= '\';
                  Line := Line + 1;
                  Index := Index + 1;
               end loop;
            elsif Kind = Python_Like and then Char = '#' then
               Skip_To_Line_End;
            elsif Kind /= Python_Like and then Char = '/' and then Next_Is (1, '/') then
               Skip_To_Line_End;
            elsif Kind /= Python_Like and then Char = '/' and then Next_Is (1, '*') then
               Index := Index + 2;
               while Index <= Text'Last
                 and then not (Text (Index) = '*' and then Next_Is (1, '/'))
               loop
                  if Text (Index) = ASCII.LF then
                     Line := Line + 1;
                  end if;
                  Index := Index + 1;
               end loop;
               Index := Index + 2;
            elsif Char = '"' then
               At_Line_Start := False;
               Quoted ('"', Kind = Python_Like and then Next_Is (1, '"') and then Next_Is (2, '"'));
            elsif Char = ''' and then Kind = Python_Like then
               At_Line_Start := False;
               Quoted (''', Next_Is (1, ''') and then Next_Is (2, '''));
            elsif Char = ''' and then (Next_Is (2, ''') or else (Next_Is (1, '\'))) then
               --  A character literal; in Rust a tick that is not one is a
               --  lifetime's, and a mark.
               At_Line_Start := False;
               Quoted (''', False);
            elsif Kind = Rust_Like and then Char = 'r'
              and then (Next_Is (1, '"') or else (Next_Is (1, '#') and then Next_Is (2, '"')))
            then
               --  A raw string: nothing in it is escaped.
               declare
                  Start  : constant Positive := Index;
                  Hashes : constant Natural := (if Next_Is (1, '#') then 1 else 0);
               begin
                  Index := Index + 2 + Hashes;
                  while Index <= Text'Last
                    and then not (Text (Index) = '"'
                                  and then (Hashes = 0 or else Next_Is (1, '#')))
                  loop
                     if Text (Index) = ASCII.LF then
                        Line := Line + 1;
                     end if;
                     Index := Index + 1;
                  end loop;
                  Index := Index + 1 + Hashes;
                  Result.Append
                    (Token'(Literal, U (Text (Start .. Natural'Min (Index - 1, Text'Last))), Line));
               end;
            elsif Is_Name_Start (Char) then
               At_Line_Start := False;
               declare
                  Start : constant Positive := Index;
               begin
                  while Index <= Text'Last and then Is_Name_Part (Text (Index)) loop
                     Index := Index + 1;
                  end loop;
                  Result.Append (Token'(Word, U (Text (Start .. Index - 1)), Line));
               end;
            elsif Ada.Characters.Handling.Is_Digit (Char) then
               At_Line_Start := False;
               while Index <= Text'Last
                 and then (Is_Name_Part (Text (Index)) or else Text (Index) = '.')
               loop
                  Index := Index + 1;
               end loop;
            elsif Char = ':' and then Next_Is (1, ':') then
               At_Line_Start := False;
               Result.Append (Token'(Mark, U ("::"), Line));
               Index := Index + 2;
            else
               At_Line_Start := False;
               Result.Append (Token'(Mark, U ([1 => Char]), Line));
               Index := Index + 1;
            end if;
         end;
      end loop;
      return Result;
   end Tokens_Of;

   function Is_Word (Item : Token; Text : String) return Boolean
   is (Item.Kind = Word and then To_String (Item.Text) = Text);

   function Is_Mark (Item : Token; Text : String) return Boolean
   is (Item.Kind = Mark and then To_String (Item.Text) = Text);

   ---------------------------------------------------------------------------
   --  What every adapter adds.
   ---------------------------------------------------------------------------

   function Where (Path : String; Line : Positive) return Unbounded_String
   is (U (Path & ":" & Image (Line)));

   procedure Relate
     (Into   : in out Graph;
      Kind   : Relation_Kind;
      From   : String;
      To     : String;
      Source : Derivation;
      Sure   : Confidence;
      Place  : Unbounded_String := Null_Unbounded_String) is
   begin
      if From /= "" and then To /= "" then
         Add_Relation
           (Into,
            (Kind => Kind, From => U (From), To => U (To), Source => Source,
             Sure => Sure, Where => Place, Origin => <>));
      end if;
   end Relate;

   procedure Declare_Symbol
     (Into : in out Graph;
      Name : String;
      Kind : String;
      Path : String;
      Line : Positive) is
   begin
      Add_Symbol (Into, (Name => U (Name), Kind => U (Kind), Path => U (Path), Line => Line));
   end Declare_Symbol;

   --  The file is its unit's.
   procedure Hold (Into : in out Graph; Path, Unit : String; Implementing : Boolean) is
   begin
      Relate (Into, Contains, Path, Unit, Naming_Convention, Certain);
      if Implementing then
         Relate (Into, Implements, Path, Unit, Naming_Convention, Probable);
      end if;
   end Hold;

   --  Words that are not a declaration's type when they come before a name
   --  and its arguments: what comes before a call.
   function Before_A_Call (Item : Token) return Boolean
   is (Item.Kind /= Word
       or else To_String (Item.Text) in "return" | "else" | "do" | "await" | "yield" | "not"
                                      | "and" | "or" | "in" | "case" | "if" | "while"
                                      | "elif" | "assert" | "throw" | "new" | "delete"
                                      | "print" | "lambda" | "is" | "move" | "match");

   --  Every use in a file of a name its unit can see: its own unit's, and
   --  those of the units it depends on and what is inside them. A name
   --  followed by its arguments, not declared there, is a call.
   --  Where a qualified name's last part starts, by . or by Rust's ::,
   --  whichever comes last; and the owner before it. 0 where unqualified.
   function Last_Part_At (Full : String) return Natural is
      Dot    : constant Natural := Ada.Strings.Fixed.Index (Full, ".", Ada.Strings.Backward);
      Colons : constant Natural := Ada.Strings.Fixed.Index (Full, "::", Ada.Strings.Backward);
   begin
      return (if Colons > Dot then Colons + 2 elsif Dot > 0 then Dot + 1 else 0);
   end Last_Part_At;

   function Last_Part (Full : String) return String
   is (if Last_Part_At (Full) = 0 then Full else Full (Last_Part_At (Full) .. Full'Last));

   function Owner_Part (Full : String) return String
   is (if Last_Part_At (Full) = 0 then ""
       elsif Last_Part_At (Full) >= Full'First + 2 and then Full (Last_Part_At (Full) - 1) = ':'
       then Full (Full'First .. Last_Part_At (Full) - 3)
       else Full (Full'First .. Last_Part_At (Full) - 2));

   procedure Find_Uses
     (Path   : String;
      Tokens : Token_Vectors.Vector;
      Unit   : String;
      Into   : in out Graph)
   is
      Seen  : Name_Lists.Vector;
      Count : constant Natural := Natural (Tokens.Length);

      function Visible (Owner : String) return Boolean is
      begin
         for One of Seen loop
            if Owner = One or else Starts (Owner, One & ".") or else Starts (Owner, One & "::") then
               return True;
            end if;
         end loop;
         return False;
      end Visible;

      Found : Relation_Vectors.Vector;

      --  Where this file declares a name, as NAME@LINE: a declaration is
      --  not a use of it, nor of another of the same name.
      Declared : Name_Lists.Vector;

      function Declaring (Name : String; Line : Positive) return Boolean
      is (Declared.Contains (Name & "@" & Image (Line)));

      --  The unit names the graph knows, by their last part: base64mime
      --  in base64mime.body_encode names that module.

      --  Whether a name qualified by a word that is some unit's name --
      --  base64mime.body_encode -- is that unit's: not every symbol of the
      --  same last name. A receiver that is no unit's name fits any.
      function Receiver_Fits (At_Index : Positive; Owner : String) return Boolean is
      begin
         if At_Index <= 2 or else not Is_Mark (Tokens (At_Index - 1), ".")
           or else Tokens (At_Index - 2).Kind /= Word
         then
            return True;
         end if;
         declare
            Receiver   : constant String := To_String (Tokens (At_Index - 2).Text);
            Owner_Last : constant String := Last_Part (Owner);
         begin
            return not Known_Units.Contains (Receiver) or else Owner_Last = Receiver;
         end;
      end Receiver_Fits;

      --  Whether a name stands on an import -- from m import name --
      --  which names it for certain, as the dependency does.
      function On_Import_Line (At_Index : Positive) return Boolean is
         First : Positive := At_Index;
      begin
         while First > 1 and then Tokens (First - 1).Line = Tokens (At_Index).Line loop
            First := First - 1;
         end loop;
         return Is_Word (Tokens (First), "from") or else Is_Word (Tokens (First), "import");
      end On_Import_Line;

      --  A method called on something, as x.name (: whatever x is, a
      --  probable use of every method so called.
      function Called_On (At_Index : Positive) return Boolean
      is (At_Index > 1 and then At_Index < Count and then Is_Mark (Tokens (At_Index - 1), ".")
          and then Is_Mark (Tokens (At_Index + 1), "("));
   begin
      if Unit = "" then
         return;
      end if;
      if Known_Symbols /= Natural (Into.Symbols.Length)
        or else (not Into.Symbols.Is_Empty
                 and then Known_Ends /= Into.Symbols.First_Element.Name & "|" & Into.Symbols.Last_Element.Name)
      then
         Known_Units.Clear;
         for Item of Into.Symbols loop
            if To_String (Item.Kind) in "module" | "unit" | "package" then
               declare
                  Full : constant String := To_String (Item.Name);
               begin
                  Known_Units.Include (Last_Part (Full));
               end;
            end if;
         end loop;
         for Link of Into.Relations loop
            if Link.Kind = Depends_On then
               declare
                  Full : constant String := To_String (Link.To);
               begin
                  Known_Units.Include (Last_Part (Full));
               end;
            end if;
         end loop;
         Known_Symbols := Natural (Into.Symbols.Length);
         Known_Ends := (if Into.Symbols.Is_Empty then Ada.Strings.Unbounded.Null_Unbounded_String
                        else Into.Symbols.First_Element.Name & "|" & Into.Symbols.Last_Element.Name);
      end if;
      for Item of Into.Symbols loop
         if To_String (Item.Path) = Path then
            declare
               Full : constant String := To_String (Item.Name);
            begin
               Declared.Append (Last_Part (Full) & "@" & Image (Item.Line));
            end;
         end if;
      end loop;
      Seen.Append (Unit);
      for Link of Into.Relations loop
         if Link.Kind = Depends_On and then To_String (Link.From) = Unit then
            Seen.Append (To_String (Link.To));
         end if;
      end loop;

      for Item of Into.Symbols loop
         declare
            Full  : constant String := To_String (Item.Name);
            Dot   : constant Natural := Last_Part_At (Full);
            Owner : constant String := Owner_Part (Full);
            Last  : constant String := Last_Part (Full);
         begin
            --  A module is used by importing it, which is a dependency:
            --  a variable of the same name is not a use of it.
            if Dot > 0 and then To_String (Item.Kind) not in "module" | "unit" then
               for At_Index in 1 .. Count loop
                  if Is_Word (Tokens (At_Index), Last)
                    and then not Declaring (Last, Tokens (At_Index).Line)
                    and then Receiver_Fits (At_Index, Owner)
                    and then (Visible (Owner) or else To_String (Item.Path) = Path
                              or else (To_String (Item.Kind) = "method" and then Called_On (At_Index)))
                  then
                     Found.Append
                       (Relation'(Kind => References, From => U (Path), To => Item.Name,
                         Source => (if On_Import_Line (At_Index) then Explicit else Heuristic),
                         Sure   => (if On_Import_Line (At_Index) then Certain else Probable),
                         Where => Where (Path, Tokens (At_Index).Line), Origin => <>));
                     if To_String (Item.Kind) in "function" | "method" | "macro"
                       and then At_Index < Count and then Is_Mark (Tokens (At_Index + 1), "(")
                       and then (At_Index = 1 or else Before_A_Call (Tokens (At_Index - 1)))
                     then
                        Found.Append
                          (Relation'(Kind => Calls, From => U (Unit), To => Item.Name,
                            Source => Heuristic, Sure => Probable,
                            Where => Where (Path, Tokens (At_Index).Line), Origin => <>));
                     end if;
                  end if;
               end loop;
            end if;
         end;
      end loop;
      for Link of Found loop
         Add_Relation (Into, Link);
      end loop;
   end Find_Uses;

   --  The last part of a path, without its extension.
   function Stem (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, Ada.Strings.Maps.To_Set ("/\"), Ada.Strings.Inside, Ada.Strings.Backward);
      Name  : constant String := (if Slash = 0 then Path else Path (Slash + 1 .. Path'Last));
      Dot   : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
   begin
      return (if Dot > Name'First then Name (Name'First .. Dot - 1) else Name);
   end Stem;

   ---------------------------------------------------------------------------
   --  C and C++.
   ---------------------------------------------------------------------------

   overriding function Language (Self : C_Adapter) return String is ("C");

   function C_Unit (Path : String) return String is (Stem (Path));

   function C_Is_Body (Path : String) return Boolean
   is (Ends (Lower (Path), ".c") or else Ends (Lower (Path), ".cc")
       or else Ends (Lower (Path), ".cpp") or else Ends (Lower (Path), ".cxx"));

   function Not_A_Name (Text : String) return Boolean
   is (Text in "if" | "while" | "for" | "switch" | "return" | "sizeof" | "catch" | "alignof"
              | "decltype" | "static_assert" | "defined" | "else" | "do" | "case");

   overriding procedure Read
     (Self : C_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph)
   is
      Unit    : constant String := C_Unit (Path);
      Is_Body : constant Boolean := C_Is_Body (Path);
      Tokens  : constant Token_Vectors.Vector := Tokens_Of (Text, C_Like);
      Count   : constant Natural := Natural (Tokens.Length);

      --  Open braces, each whether it is a namespace's or an extern "C"
      --  block's, which do not make what is in them inner.
      Opened  : Name_Lists.Vector;
      Inner   : Natural := 0;
      Index   : Positive := 1;
      Line    : Positive := 1;
      Start   : Positive := Text'First;
   begin
      Hold (Into, Path, Unit, Is_Body);
      if not Is_Body then
         Declare_Symbol (Into, Unit, "header", Path, 1);
      end if;

      --  The preprocessor's lines: what is included, and the macros.
      for At_Index in Text'First .. Text'Last + 1 loop
         if At_Index > Text'Last or else Text (At_Index) = ASCII.LF then
            declare
               Said : constant String :=
                 Ada.Strings.Fixed.Trim (Text (Start .. At_Index - 1), Ada.Strings.Both);
            begin
               if Starts (Said, "#") then
                  declare
                     Rest : constant String :=
                       Ada.Strings.Fixed.Trim (Said (Said'First + 1 .. Said'Last), Ada.Strings.Both);
                  begin
                     if Starts (Rest, "include") then
                        declare
                           Open  : constant Natural := Ada.Strings.Fixed.Index (Rest, """");
                           Close : constant Natural :=
                             (if Open = 0 then 0
                              else Ada.Strings.Fixed.Index (Rest (Open + 1 .. Rest'Last), """"));
                        begin
                           --  A <system> header is not the project's.
                           if Close > Open + 1 then
                              Relate (Into, Depends_On, Unit, Stem (Rest (Open + 1 .. Close - 1)),
                                      Naming_Convention, Probable, Where (Path, Line));
                           end if;
                        end;
                     elsif Starts (Rest, "define") then
                        declare
                           Name_Start : Natural := Rest'First + 6;
                           Name_End   : Natural;
                        begin
                           while Name_Start <= Rest'Last and then Rest (Name_Start) in ' ' | ASCII.HT loop
                              Name_Start := Name_Start + 1;
                           end loop;
                           Name_End := Name_Start;
                           while Name_End <= Rest'Last and then Is_Name_Part (Rest (Name_End)) loop
                              Name_End := Name_End + 1;
                           end loop;
                           if Name_End > Name_Start then
                              Declare_Symbol
                                (Into, Unit & "." & Rest (Name_Start .. Name_End - 1), "macro",
                                 Path, Line);
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
            Line := Line + 1;
            Start := At_Index + 1;
         end if;
      end loop;

      while Index <= Count loop
         declare
            Here : constant Token := Tokens (Index);
         begin
            if Is_Mark (Here, "{") then
               declare
                  Through : constant Boolean :=
                    (Index > 1 and then Is_Word (Tokens (Index - 1), "namespace"))
                    or else (Index > 2 and then Is_Word (Tokens (Index - 2), "namespace"))
                    or else (Index > 2 and then Tokens (Index - 1).Kind = Literal
                             and then Is_Word (Tokens (Index - 2), "extern"));
               begin
                  Opened.Append (if Through then "through" else "inner");
                  if not Through then
                     Inner := Inner + 1;
                  end if;
               end;
            elsif Is_Mark (Here, "}") then
               if not Opened.Is_Empty then
                  if Opened.Last_Element = "inner" then
                     Inner := Inner - 1;
                  end if;
                  Opened.Delete_Last;
               end if;
            elsif Inner = 0 and then Here.Kind = Word then
               declare
                  Said : constant String := To_String (Here.Text);
               begin
                  if Said in "struct" | "enum" | "union" | "class"
                    and then Index + 2 <= Count and then Tokens (Index + 1).Kind = Word
                    and then (Is_Mark (Tokens (Index + 2), "{") or else Is_Mark (Tokens (Index + 2), ":"))
                    and then not (Index > 1 and then Is_Word (Tokens (Index - 1), "typedef"))
                  then
                     declare
                        Typed : constant String := Unit & "." & To_String (Tokens (Index + 1).Text);
                     begin
                        Declare_Symbol (Into, Typed, "type", Path, Tokens (Index + 1).Line);
                        --  class A : public B, C -- what it extends.
                        if Is_Mark (Tokens (Index + 2), ":") then
                           for Ahead in Index + 3 .. Count loop
                              exit when Is_Mark (Tokens (Ahead), "{");
                              if Tokens (Ahead).Kind = Word
                                and then To_String (Tokens (Ahead).Text)
                                           not in "public" | "private" | "protected" | "virtual"
                                and then (Is_Mark (Tokens (Ahead + 1), "{")
                                          or else Is_Mark (Tokens (Ahead + 1), ","))
                              then
                                 Relate (Into, Extends, Typed, To_String (Tokens (Ahead).Text),
                                         Explicit, Probable, Where (Path, Tokens (Ahead).Line));
                              end if;
                           end loop;
                        end if;
                     end;
                  elsif Said = "typedef" then
                     --  The name is the last before the semicolon that ends
                     --  it, or the one a pointer to a function names.
                     declare
                        Braces : Natural := 0;
                        Ahead  : Positive := Index + 1;
                        Named  : Unbounded_String;
                        At_Line : Positive := Here.Line;
                     begin
                        while Ahead <= Count loop
                           if Is_Mark (Tokens (Ahead), "{") then
                              Braces := Braces + 1;
                           elsif Is_Mark (Tokens (Ahead), "}") then
                              Braces := Braces - 1;
                           elsif Braces = 0 and then Is_Mark (Tokens (Ahead), ";") then
                              exit;
                           elsif Braces = 0 and then Tokens (Ahead).Kind = Word
                             and then Named = Null_Unbounded_String
                             and then Ahead > 2 and then Is_Mark (Tokens (Ahead - 1), "*")
                             and then Is_Mark (Tokens (Ahead - 2), "(")
                           then
                              Named := Tokens (Ahead).Text;
                              At_Line := Tokens (Ahead).Line;
                           end if;
                           Ahead := Ahead + 1;
                        end loop;
                        if Named = Null_Unbounded_String and then Ahead - 1 > Index
                          and then Ahead - 1 <= Count and then Tokens (Ahead - 1).Kind = Word
                        then
                           Named := Tokens (Ahead - 1).Text;
                           At_Line := Tokens (Ahead - 1).Line;
                        end if;
                        if Named /= Null_Unbounded_String then
                           Declare_Symbol (Into, Unit & "." & To_String (Named), "type", Path, At_Line);
                        end if;
                        Index := Ahead;
                     end;
                  elsif Index + 1 <= Count and then Is_Mark (Tokens (Index + 1), "(")
                    and then not Not_A_Name (Said)
                    and then Index > 1
                    and then (Tokens (Index - 1).Kind = Word
                              or else Is_Mark (Tokens (Index - 1), "*")
                              or else Is_Mark (Tokens (Index - 1), "&")
                              or else Is_Mark (Tokens (Index - 1), "::"))
                    and then not Before_A_Call (Tokens (Index - 1))
                  then
                     --  A function: its arguments, then a body or a
                     --  semicolon.
                     declare
                        Depth : Natural := 0;
                        Ahead : Positive := Index + 1;
                     begin
                        while Ahead <= Count loop
                           if Is_Mark (Tokens (Ahead), "(") then
                              Depth := Depth + 1;
                           elsif Is_Mark (Tokens (Ahead), ")") then
                              Depth := Depth - 1;
                              exit when Depth = 0;
                           end if;
                           Ahead := Ahead + 1;
                        end loop;
                        if Ahead < Count then
                           declare
                              After : Positive := Ahead + 1;
                           begin
                              --  const, noexcept, override, -> T and the like.
                              while After <= Count and then not Is_Mark (Tokens (After), "{")
                                and then not Is_Mark (Tokens (After), ";")
                                and then not Is_Mark (Tokens (After), "=")
                                and then not Is_Mark (Tokens (After), ",")
                                and then After - Ahead < 8
                              loop
                                 After := After + 1;
                              end loop;
                              if After <= Count
                                and then (Is_Mark (Tokens (After), "{")
                                          or else Is_Mark (Tokens (After), ";"))
                              then
                                 Declare_Symbol (Into, Unit & "." & Said, "function", Path, Here.Line);
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
         Index := Index + 1;
      end loop;
   end Read;

   overriding procedure Read_References
     (Self : C_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is
   begin
      Find_Uses (Path, Tokens_Of (Text, C_Like), C_Unit (Path), Into);
   end Read_References;

   ---------------------------------------------------------------------------
   --  Rust.
   ---------------------------------------------------------------------------

   overriding function Language (Self : Rust_Adapter) return String is ("Rust");

   --  The module a file is: its path under src, lib.rs and main.rs the
   --  crate and mod.rs its directory; a file outside src is named by its
   --  path.
   function Rust_Unit (Path : String) return String is
      Under : constant Natural := Ada.Strings.Fixed.Index (Path, "src/", Ada.Strings.Backward);
      Rest  : constant String :=
        (if Starts (Path, "src/") then Path (Path'First + 4 .. Path'Last)
         elsif Under > 0 then Path (Under + 4 .. Path'Last)
         else Path);
      Plain : constant String :=
        (if Ends (Rest, ".rs") then Rest (Rest'First .. Rest'Last - 3) else Rest);
      --  A crate of a workspace -- crates/parse/src -- is named by its
      --  directory, so two crates' modules are not taken for one; a crate at
      --  the top is the crate.
      Member : constant String :=
        (if Under > Path'First + 1 then Path (Path'First .. Under - 2) else "");
      Slash  : constant Natural := Ada.Strings.Fixed.Index (Member, "/", Ada.Strings.Backward);
      Result : Unbounded_String :=
        U (if Member = "" then "crate"
           else Ada.Strings.Fixed.Translate ((if Slash = 0 then Member else Member (Slash + 1 .. Member'Last)),
                                            Ada.Strings.Maps.To_Mapping ("-", "_")));
      Base   : constant String :=
        (if Ends (Plain, "/mod") then Plain (Plain'First .. Plain'Last - 4)
         elsif Plain in "lib" | "main" then ""
         else Plain);
      Start  : Positive := Base'First;
   begin
      if Under = 0 and then not Starts (Path, "src/") then
         Result := Null_Unbounded_String;
      end if;
      for At_Index in Base'First .. Base'Last + 1 loop
         if At_Index > Base'Last or else Base (At_Index) = '/' then
            if At_Index > Start then
               if Result /= Null_Unbounded_String then
                  Append (Result, "::");
               end if;
               Append (Result, Base (Start .. At_Index - 1));
            end if;
            Start := At_Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Rust_Unit;

   --  The module a module is in.
   function Rust_Parent (Unit : String) return String is
      Last : constant Natural := Ada.Strings.Fixed.Index (Unit, "::", Ada.Strings.Backward);
   begin
      return (if Last = 0 then Unit else Unit (Unit'First .. Last - 1));
   end Rust_Parent;

   overriding procedure Read
     (Self : Rust_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph)
   is
      Unit   : constant String := Rust_Unit (Path);
      Tokens : constant Token_Vectors.Vector := Tokens_Of (Text, Rust_Like);
      Count  : constant Natural := Natural (Tokens.Length);

      --  Each open brace: a module's, an impl's (its type, and the trait
      --  when it takes one on) or anything else's.
      type Opening is record
         Kind  : Unbounded_String;
         Typed : Unbounded_String;
         Trait : Unbounded_String;
      end record;
      package Opening_Vectors is new Ada.Containers.Vectors (Positive, Opening);
      Opened : Opening_Vectors.Vector;
      Next   : Opening := (U ("other"), Null_Unbounded_String, Null_Unbounded_String);

      --  Where declarations count: at module level, or in an impl.
      function Outer return Boolean
      is (Opened.Is_Empty or else To_String (Opened.Last_Element.Kind) in "mod" | "impl");

      function In_Impl return Boolean
      is (not Opened.Is_Empty and then To_String (Opened.Last_Element.Kind) = "impl");

      --  A path as written, from a token, and the token after it.
      procedure Path_At (Start : Positive; Named : out Unbounded_String; After : out Positive) is
         At_Index : Positive := Start;
      begin
         Named := Null_Unbounded_String;
         --  A name, then :: and a name, and so on.
         while At_Index <= Count loop
            if Tokens (At_Index).Kind = Word
              and then (Named = Null_Unbounded_String or else Ends (To_String (Named), "::"))
            then
               Append (Named, Tokens (At_Index).Text);
            elsif Is_Mark (Tokens (At_Index), "::") and then Named /= Null_Unbounded_String then
               Append (Named, "::");
            else
               exit;
            end if;
            At_Index := At_Index + 1;
         end loop;
         After := At_Index;
      end Path_At;

      --  The modules this file declares: mod parser; is parser here.
      function Declared_Modules return Name_Lists.Vector is
         Found : Name_Lists.Vector;
      begin
         for At_Index in 1 .. Count - 1 loop
            if Is_Word (Tokens (At_Index), "mod") and then Tokens (At_Index + 1).Kind = Word then
               Found.Append (To_String (Tokens (At_Index + 1).Text));
            end if;
         end loop;
         return Found;
      end Declared_Modules;
      Modules : constant Name_Lists.Vector := Declared_Modules;

      --  A use path made absolute: self and super are this module's, a
      --  module this file declares is under it, and outside src -- a test,
      --  an example -- the crate's own name is the crate.
      --  The crate this file is of: crate, or a workspace member's name.
      Crate_Name : constant String :=
        (if Ada.Strings.Fixed.Index (Unit, "::") > 0 then Unit (Unit'First .. Ada.Strings.Fixed.Index (Unit, "::") - 1)
         else Unit);

      function Resolved (Said : String) return String is
         Cut   : constant Natural := Ada.Strings.Fixed.Index (Said, "::");
         First : constant String := (if Cut = 0 then Said else Said (Said'First .. Cut - 1));
      begin
         if Starts (Said, "crate::") and then Crate_Name /= "crate" and then Starts (Unit, Crate_Name) then
            return Crate_Name & Said (Said'First + 5 .. Said'Last);
         elsif Starts (Said, "self::") then
            return Unit & Said (Said'First + 4 .. Said'Last);
         elsif Starts (Said, "super::") then
            return Rust_Parent (Unit) & Said (Said'First + 5 .. Said'Last);
         elsif Cut > 0 and then Modules.Contains (First) then
            return Unit & "::" & Said;
         elsif Cut > 0 and then not Starts (Unit, "crate")
           and then First not in "crate" | "std" | "core" | "alloc"
         then
            return "crate" & Said (Cut .. Said'Last);
         end if;
         return Said;
      end Resolved;

      --  A use of Said: the module, when the last part is an item.
      procedure Used (Said : String; Line : Positive) is
         Full : constant String := Resolved (Said);
         Last : constant Natural := Ada.Strings.Fixed.Index (Full, "::", Ada.Strings.Backward);
         Item : constant String := (if Last = 0 then Full else Full (Last + 2 .. Full'Last));
      begin
         if Last = 0 then
            Relate (Into, Depends_On, Unit, Full, Explicit, Probable, Where (Path, Line));
         elsif Item /= "" and then Item (Item'First) in 'A' .. 'Z' then
            --  A type or a trait, by the convention: its module.
            Relate (Into, Depends_On, Unit, Full (Full'First .. Last - 1),
                    Naming_Convention, Probable, Where (Path, Line));
         else
            --  A module or a function: which, a name does not say.
            Relate (Into, Depends_On, Unit, Full, Heuristic, Uncertain, Where (Path, Line));
            Relate (Into, Depends_On, Unit, Full (Full'First .. Last - 1),
                    Heuristic, Uncertain, Where (Path, Line));
         end if;
      end Used;

      Index : Positive := 1;
   begin
      Hold (Into, Path, Unit, False);
      Declare_Symbol (Into, Unit, "module", Path, 1);

      while Index <= Count loop
         declare
            Here : constant Token := Tokens (Index);
            Said : constant String := (if Here.Kind = Word then To_String (Here.Text) else "");
         begin
            if Is_Mark (Here, "{") then
               Opened.Append (Next);
               Next := (U ("other"), Null_Unbounded_String, Null_Unbounded_String);
            elsif Is_Mark (Here, "}") then
               if not Opened.Is_Empty then
                  Opened.Delete_Last;
               end if;
            elsif Is_Mark (Here, ";") then
               Next := (U ("other"), Null_Unbounded_String, Null_Unbounded_String);
            elsif Said = "use" and then Outer then
               declare
                  Named : Unbounded_String;
                  After : Positive;
               begin
                  Path_At (Index + 1, Named, After);
                  if After <= Count and then Is_Mark (Tokens (After), "{") then
                     --  use a::b::{c, D}: each, under a::b.
                     declare
                        Base : constant String := To_String (Named);
                        Item : Unbounded_String;
                        Past : Positive;
                        Ahead : Positive := After + 1;
                     begin
                        while Ahead <= Count and then not Is_Mark (Tokens (Ahead), "}") loop
                           Path_At (Ahead, Item, Past);
                           if Item /= Null_Unbounded_String then
                              Used (Base & To_String (Item), Here.Line);
                              Ahead := Past;
                           else
                              Ahead := Ahead + 1;
                           end if;
                        end loop;
                        Index := Ahead;
                     end;
                  elsif Named /= Null_Unbounded_String then
                     Used (To_String (Named), Here.Line);
                     Index := After - 1;
                  end if;
               end;
            elsif Said = "mod" and then Outer and then Index + 1 <= Count
              and then Tokens (Index + 1).Kind = Word
            then
               Declare_Symbol
                 (Into, Unit & "::" & To_String (Tokens (Index + 1).Text), "module", Path,
                  Tokens (Index + 1).Line);
               Next := (U ("mod"), Null_Unbounded_String, Null_Unbounded_String);
               Index := Index + 1;
            elsif Said = "impl" and then Outer then
               --  impl<T> Trait for Type, or impl Type.
               declare
                  Ahead  : Positive := Index + 1;
                  Angles : Natural := 0;
                  First  : Unbounded_String;
                  Second : Unbounded_String;
                  After  : Positive;
               begin
                  while Ahead <= Count loop
                     if Is_Mark (Tokens (Ahead), "<") then
                        Angles := Angles + 1;
                     elsif Is_Mark (Tokens (Ahead), ">") and then Angles > 0 then
                        Angles := Angles - 1;
                     elsif Angles = 0 then
                        exit;
                     end if;
                     Ahead := Ahead + 1;
                  end loop;
                  Path_At (Ahead, First, After);
                  for Scan_At in After .. Count loop
                     exit when Is_Mark (Tokens (Scan_At), "{");
                     if Is_Word (Tokens (Scan_At), "for") then
                        Path_At (Scan_At + 1, Second, After);
                        exit;
                     end if;
                  end loop;
                  declare
                     function Last_Of (Said_Path : Unbounded_String) return String is
                        Full : constant String := To_String (Said_Path);
                        Cut  : constant Natural := Ada.Strings.Fixed.Index (Full, "::", Ada.Strings.Backward);
                     begin
                        return (if Cut = 0 then Full else Full (Cut + 2 .. Full'Last));
                     end Last_Of;
                  begin
                     if Second /= Null_Unbounded_String then
                        Relate (Into, Implements_Interface, Unit & "::" & Last_Of (Second),
                                To_String (First), Explicit, Probable, Where (Path, Here.Line));
                        Next := (U ("impl"), U (Last_Of (Second)), First);
                     elsif First /= Null_Unbounded_String then
                        Next := (U ("impl"), U (Last_Of (First)), Null_Unbounded_String);
                     end if;
                  end;
               end;
            elsif Outer and then Index + 1 <= Count and then Tokens (Index + 1).Kind = Word
              and then Said in "fn" | "struct" | "enum" | "trait" | "type" | "const" | "static"
                             | "union"
            then
               declare
                  Name : constant String := To_String (Tokens (Index + 1).Text);
                  Kind : constant String :=
                    (if Said = "fn" then (if In_Impl then "method" else "function")
                     elsif Said in "struct" | "enum" | "union" | "type" then "type"
                     elsif Said = "trait" then "trait"
                     else "constant");
                  Full : constant String :=
                    (if In_Impl then Unit & "::" & To_String (Opened.Last_Element.Typed) & "::" & Name
                     else Unit & "::" & Name);
               begin
                  if not (Said in "static" | "const" and then Name in "mut" | "fn") then
                     Declare_Symbol (Into, Full, Kind, Path, Tokens (Index + 1).Line);
                     if In_Impl and then Said = "fn"
                       and then Opened.Last_Element.Trait /= Null_Unbounded_String
                     then
                        Relate (Into, Overrides, Full, Name, Explicit, Uncertain,
                                Where (Path, Tokens (Index + 1).Line));
                     end if;
                  end if;
                  if Said = "trait" then
                     Next := (U ("other"), Null_Unbounded_String, Null_Unbounded_String);
                  end if;
                  Index := Index + 1;
               end;
            end if;
         end;
         Index := Index + 1;
      end loop;
      --  A module it declares is one it uses: mod sku; and sku::check (s),
      --  each a dependency of this unit on that module.
      for Name of Modules loop
         Relate (Into, Depends_On, Unit, Unit & "::" & Name, Explicit, Certain, Where (Path, 1));
      end loop;
      for At_Index in 1 .. Count - 2 loop
         if Tokens (At_Index).Kind = Word and then Is_Mark (Tokens (At_Index + 1), "::")
           and then Modules.Contains (To_String (Tokens (At_Index).Text))
           and then (At_Index = 1 or else not Is_Mark (Tokens (At_Index - 1), "::"))
         then
            Relate (Into, Depends_On, Unit, Unit & "::" & To_String (Tokens (At_Index).Text), Explicit, Certain,
                    Where (Path, Tokens (At_Index).Line));
         end if;
      end loop;
   end Read;

   overriding procedure Read_References
     (Self : Rust_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is
   begin
      Find_Uses (Path, Tokens_Of (Text, Rust_Like), Rust_Unit (Path), Into);
   end Read_References;

   ---------------------------------------------------------------------------
   --  Python.
   ---------------------------------------------------------------------------

   overriding function Language (Self : Python_Adapter) return String is ("Python");

   --  The module a file is: its path dotted, a leading src left out, an
   --  __init__ its package.
   function Python_Unit (Path : String) return String is
      Rest   : constant String :=
        (if Starts (Path, "src/") then Path (Path'First + 4 .. Path'Last) else Path);
      Plain  : constant String :=
        (if Ends (Rest, ".py") then Rest (Rest'First .. Rest'Last - 3) else Rest);
      Result : String := Plain;
   begin
      for Char of Result loop
         if Char in '/' | '\' then
            Char := '.';
         end if;
      end loop;
      if Ends (Result, ".__init__") then
         return Result (Result'First .. Result'Last - 9);
      elsif Result = "__init__" then
         return "";
      end if;
      return Result;
   end Python_Unit;

   overriding procedure Read
     (Self : Python_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph)
   is
      Unit    : constant String := Python_Unit (Path);
      Package_Of : constant String :=
        (if Ends (Path, "__init__.py") then Unit
         else (if Ada.Strings.Fixed.Index (Unit, ".", Ada.Strings.Backward) = 0 then ""
               else Unit (Unit'First .. Ada.Strings.Fixed.Index (Unit, ".", Ada.Strings.Backward) - 1)));

      --  What encloses a line: each a class or a def, at its indent.
      type Scope is record
         Indent : Natural := 0;
         Kind   : Unbounded_String;
         Name   : Unbounded_String;
      end record;
      package Scope_Vectors is new Ada.Containers.Vectors (Positive, Scope);
      Scopes : Scope_Vectors.Vector;

      Line_Number : Positive := 1;
      Start       : Positive := Text'First;
      In_String   : Unbounded_String;

      --  Where a name is declared: its module, or the classes around it.
      function Owner return String is
      begin
         if Scopes.Is_Empty then
            return Unit;
         end if;
         return To_String (Scopes.Last_Element.Name);
      end Owner;

      function Declarable return Boolean
      is (Scopes.Is_Empty or else To_String (Scopes.Last_Element.Kind) = "class");

      --  The name at the start of a text, and what follows.
      function Name_Of (Said : String) return String is
         Stop : Natural := Said'First;
      begin
         while Stop <= Said'Last and then (Is_Name_Part (Said (Stop)) or else Said (Stop) = '.') loop
            Stop := Stop + 1;
         end loop;
         return Said (Said'First .. Stop - 1);
      end Name_Of;

      --  A module a relative import names, made absolute.
      function Absolute (Said : String) return String is
         Dots : Natural := 0;
         Base : Unbounded_String := U (Package_Of);
      begin
         while Dots < Said'Length and then Said (Said'First + Dots) = '.' loop
            Dots := Dots + 1;
         end loop;
         if Dots = 0 then
            return Said;
         end if;
         for Level in 2 .. Dots loop
            declare
               Now : constant String := To_String (Base);
               Cut : constant Natural := Ada.Strings.Fixed.Index (Now, ".", Ada.Strings.Backward);
            begin
               Base := (if Cut = 0 then Null_Unbounded_String else U (Now (Now'First .. Cut - 1)));
            end;
         end loop;
         declare
            Rest : constant String := Said (Said'First + Dots .. Said'Last);
         begin
            if Base = Null_Unbounded_String then
               return Rest;
            elsif Rest = "" then
               return To_String (Base);
            end if;
            return To_String (Base) & "." & Rest;
         end;
      end Absolute;

      procedure One_Line (Raw : String) is
         Indent : Natural := 0;
         Said   : Unbounded_String;
      begin
         --  Inside a string that spans lines, until its closing quotes.
         if In_String /= Null_Unbounded_String then
            if Ada.Strings.Fixed.Index (Raw, To_String (In_String)) > 0 then
               In_String := Null_Unbounded_String;
            end if;
            return;
         end if;
         for Char of Raw loop
            exit when Char not in ' ' | ASCII.HT;
            Indent := Indent + (if Char = ASCII.HT then 8 else 1);
         end loop;
         Said := U (Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Both));
         if Said = Null_Unbounded_String or else Element (Said, 1) = '#' then
            return;
         end if;

         --  A string opened and not closed on this line.
         for Quote of Name_Lists.Vector'(["""""""", "'''"]) loop
            declare
               Line_Text : constant String := To_String (Said);
               First     : constant Natural := Ada.Strings.Fixed.Index (Line_Text, Quote);
            begin
               if First > 0
                 and then Ada.Strings.Fixed.Index
                            (Line_Text (First + 3 .. Line_Text'Last), Quote) = 0
               then
                  In_String := U (Quote);
               end if;
            end;
         end loop;

         while not Scopes.Is_Empty and then Scopes.Last_Element.Indent >= Indent loop
            Scopes.Delete_Last;
         end loop;

         declare
            Line_Text : constant String := To_String (Said);
            Plain     : constant String :=
              (if Starts (Line_Text, "async ") then Line_Text (Line_Text'First + 6 .. Line_Text'Last)
               else Line_Text);
         begin
            if Starts (Plain, "def ") or else Starts (Plain, "class ") then
               declare
                  Is_Class : constant Boolean := Starts (Plain, "class ");
                  Rest     : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Plain (Plain'First + (if Is_Class then 6 else 4) .. Plain'Last), Ada.Strings.Left);
                  Name     : constant String := Name_Of (Rest);
                  Full     : constant String := Owner & "." & Name;
               begin
                  if Name /= "" and then Declarable then
                     Declare_Symbol
                       (Into, Full,
                        (if Is_Class then "class"
                         elsif not Scopes.Is_Empty then "method" else "function"),
                        Path, Line_Number);
                     if Is_Class and then Rest'Length > Name'Length
                       and then Rest (Rest'First + Name'Length) = '('
                     then
                        --  Its bases.
                        declare
                           Close : constant Natural := Ada.Strings.Fixed.Index (Rest, ")");
                           Bases : constant String :=
                             (if Close = 0 then "" else Rest (Rest'First + Name'Length + 1 .. Close - 1));
                           Part  : Positive := Bases'First;
                        begin
                           for At_Index in Bases'First .. Bases'Last + 1 loop
                              if At_Index > Bases'Last or else Bases (At_Index) = ',' then
                                 declare
                                    Base : constant String :=
                                      Name_Of (Ada.Strings.Fixed.Trim
                                                 (Bases (Part .. At_Index - 1), Ada.Strings.Both));
                                 begin
                                    if Base /= "" and then Base not in "object" | "metaclass" then
                                       Relate (Into, Extends, Full, Base, Explicit, Probable,
                                               Where (Path, Line_Number));
                                    end if;
                                 end;
                                 Part := At_Index + 1;
                              end if;
                           end loop;
                        end;
                     end if;
                  end if;
                  Scopes.Append
                    (Scope'(Indent, U (if Is_Class then "class" else "def"),
                      U (if Declarable then Full else Owner & "." & Name)));
               end;
            elsif Starts (Plain, "import ") then
               declare
                  Rest : constant String := Plain (Plain'First + 7 .. Plain'Last);
                  Part : Positive := Rest'First;
               begin
                  for At_Index in Rest'First .. Rest'Last + 1 loop
                     if At_Index > Rest'Last or else Rest (At_Index) = ',' then
                        Relate (Into, Depends_On, Unit,
                                Name_Of (Ada.Strings.Fixed.Trim (Rest (Part .. At_Index - 1),
                                                                 Ada.Strings.Both)),
                                Explicit, Certain, Where (Path, Line_Number));
                        Part := At_Index + 1;
                     end if;
                  end loop;
               end;
            elsif Starts (Plain, "from ") then
               declare
                  Rest   : constant String :=
                    Ada.Strings.Fixed.Trim (Plain (Plain'First + 5 .. Plain'Last), Ada.Strings.Left);
                  Stop   : Natural := Rest'First;
               begin
                  while Stop <= Rest'Last and then Rest (Stop) /= ' ' loop
                     Stop := Stop + 1;
                  end loop;
                  declare
                     Module : constant String := Absolute (Rest (Rest'First .. Stop - 1));
                     Names  : constant Natural := Ada.Strings.Fixed.Index (Rest, " import ");
                  begin
                     if Rest (Rest'First .. Stop - 1) /= "" and then
                       (for all Char of Rest (Rest'First .. Stop - 1) => Char = '.')
                       and then Names > 0
                     then
                        --  from . import a, b: modules of the package.
                        declare
                           Listed : constant String := Rest (Names + 8 .. Rest'Last);
                           Part   : Positive := Listed'First;
                        begin
                           for At_Index in Listed'First .. Listed'Last + 1 loop
                              if At_Index > Listed'Last or else Listed (At_Index) = ',' then
                                 declare
                                    Name : constant String :=
                                      Name_Of (Ada.Strings.Fixed.Trim
                                                 (Listed (Part .. At_Index - 1), Ada.Strings.Both));
                                 begin
                                    if Name /= "" then
                                       Relate (Into, Depends_On, Unit,
                                               (if Module = "" then Name else Module & "." & Name),
                                               Explicit, Probable, Where (Path, Line_Number));
                                    end if;
                                 end;
                                 Part := At_Index + 1;
                              end if;
                           end loop;
                        end;
                     elsif Module /= "" then
                        Relate (Into, Depends_On, Unit, Module, Explicit, Certain,
                                Where (Path, Line_Number));
                        --  from pkg import mod: a module of the package, as
                        --  likely as not -- its users are found through it.
                        if Names > 0 then
                           declare
                              Listed : constant String := Rest (Names + 8 .. Rest'Last);
                              Part   : Positive := Listed'First;
                           begin
                              for At_Index in Listed'First .. Listed'Last + 1 loop
                                 if At_Index > Listed'Last or else Listed (At_Index) = ',' then
                                    declare
                                       Name : constant String :=
                                         Name_Of (Ada.Strings.Fixed.Trim
                                                    (Listed (Part .. At_Index - 1), Ada.Strings.Both));
                                    begin
                                       if Name /= "" and then Name (Name'First) in 'a' .. 'z' then
                                          Relate (Into, Depends_On, Unit, Module & "." & Name,
                                                  Explicit, Probable, Where (Path, Line_Number));
                                       end if;
                                    end;
                                    Part := At_Index + 1;
                                 end if;
                              end loop;
                           end;
                        end if;
                     end if;
                  end;
               end;
            elsif Scopes.Is_Empty and then Indent = 0 then
               --  NAME = value, in capitals: a constant.
               declare
                  Name : constant String := Name_Of (Plain);
               begin
                  if Name /= "" and then Name = Ada.Characters.Handling.To_Upper (Name)
                    and then (for some Char of Name => Char in 'A' .. 'Z')
                    and then Plain'Length > Name'Length
                    and then Ada.Strings.Fixed.Trim
                               (Plain (Plain'First + Name'Length .. Plain'Last), Ada.Strings.Left)'Length > 1
                    and then Starts (Ada.Strings.Fixed.Trim
                                       (Plain (Plain'First + Name'Length .. Plain'Last),
                                        Ada.Strings.Left), "=")
                    and then not Starts (Ada.Strings.Fixed.Trim
                                           (Plain (Plain'First + Name'Length .. Plain'Last),
                                            Ada.Strings.Left), "==")
                  then
                     Declare_Symbol (Into, Unit & "." & Name, "constant", Path, Line_Number);
                  end if;
               end;
            end if;
         end;
      end One_Line;
   begin
      if Unit = "" then
         return;
      end if;
      Hold (Into, Path, Unit, False);
      Declare_Symbol (Into, Unit, "module", Path, 1);
      for At_Index in Text'First .. Text'Last + 1 loop
         if At_Index > Text'Last or else Text (At_Index) = ASCII.LF then
            One_Line (Text (Start .. At_Index - 1));
            Line_Number := Line_Number + 1;
            Start := At_Index + 1;
         end if;
      end loop;
   end Read;

   overriding procedure Read_References
     (Self : Python_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is
   begin
      Find_Uses (Path, Tokens_Of (Text, Python_Like), Python_Unit (Path), Into);
   end Read_References;

   -----------------
   -- Adapter_For --
   -----------------

   function Adapter_For (Language : String) return Adapter'Class is
   begin
      if Language = "Ada" then
         return Ada_Adapter'(null record);
      elsif Language in "C" | "C++" then
         return C_Adapter'(null record);
      elsif Language = "Rust" then
         return Rust_Adapter'(null record);
      elsif Language = "Python" then
         return Python_Adapter'(null record);
      end if;
      return Generic_Adapter'(null record);
   end Adapter_For;

end Model_Runner.Framework.Repository.Languages;
