with Ada.Unchecked_Deallocation;

package body Model_Runner.Tools is

   package E renames Model_Runner.Errors;

   --  How deeply a value may nest. A tool's parameters are a schema and a
   --  schema nests as deeply as its author wrote it; this is where a file
   --  that nests without end stops being read.
   Max_Depth : constant := 32;

   --  What opens and closes a call in a reply. The template tells the model
   --  to write these, so they are the convention rather than a guess: a
   --  model that answers in another one wrote no call this can read.
   Call_Opens  : constant String := "<tool_call>";
   Call_Closes : constant String := "</tool_call>";

   procedure Free_Storage is
     new Ada.Unchecked_Deallocation (String, Storage_Access);

   ---------------------------------------------------------------------------
   --  Reading and writing JSON
   ---------------------------------------------------------------------------

   --  Whether a character may stand inside a number, which is the only
   --  value written back exactly as the file spells it.
   function Is_Number_Character (Letter : Character) return Boolean
   is (Letter in '0' .. '9' | '-' | '+' | '.' | 'e' | 'E');

   --  Skip whitespace, as JSON means it: the four characters and nothing
   --  else, so a file with a stray byte in it is refused rather than read
   --  past.
   function Blanks_Skipped (Text : String; From : Natural) return Natural is
      Index : Natural := From;
   begin
      while Index <= Text'Last
        and then (Text (Index) = ' '
                  or else Text (Index) = ASCII.HT
                  or else Text (Index) = ASCII.LF
                  or else Text (Index) = ASCII.CR)
      loop
         Index := Index + 1;
      end loop;
      return Index;
   end Blanks_Skipped;

   --  Fail at a position, keeping the first failure. The reader wants to
   --  know where the text stopped being JSON, not where a second reader
   --  gave up afterwards.
   procedure Fail
     (Status : in out E.Error_Info;
      Code   : E.Error_Code;
      Text   : String;
      Where  : Natural) is
   begin
      if E.Is_Error (Status) then
         return;
      end if;
      Status := E.Make (Code);
      E.Add_Integer
        (Status, "offset", Long_Long_Integer (Where - Text'First),
         E.Param_Offset);
   end Fail;

   --  One code point, as UTF-8. Written here rather than taken from the
   --  text package because what arrives is a number a \u escape spelled and
   --  not a character anybody has.
   function As_UTF8 (Code : Natural) return String is
   begin
      if Code < 16#80# then
         return [1 => Character'Val (Code)];
      elsif Code < 16#800# then
         return [Character'Val (16#C0# + Code / 16#40#),
                 Character'Val (16#80# + Code mod 16#40#)];
      elsif Code < 16#1_0000# then
         return [Character'Val (16#E0# + Code / 16#1000#),
                 Character'Val (16#80# + (Code / 16#40#) mod 16#40#),
                 Character'Val (16#80# + Code mod 16#40#)];
      else
         return [Character'Val (16#F0# + Code / 16#4_0000#),
                 Character'Val (16#80# + (Code / 16#1000#) mod 16#40#),
                 Character'Val (16#80# + (Code / 16#40#) mod 16#40#),
                 Character'Val (16#80# + Code mod 16#40#)];
      end if;
   end As_UTF8;

   --  The value of four hexadecimal digits, or -1 when they are not four
   --  hexadecimal digits.
   function Hex_Value (Text : String; From : Natural) return Integer is
      Result : Integer := 0;
   begin
      if From + 3 > Text'Last then
         return -1;
      end if;

      for Index in From .. From + 3 loop
         case Text (Index) is
            when '0' .. '9' =>
               Result := Result * 16
                 + (Character'Pos (Text (Index)) - Character'Pos ('0'));
            when 'a' .. 'f' =>
               Result := Result * 16
                 + (Character'Pos (Text (Index)) - Character'Pos ('a')) + 10;
            when 'A' .. 'F' =>
               Result := Result * 16
                 + (Character'Pos (Text (Index)) - Character'Pos ('A')) + 10;
            when others =>
               return -1;
         end case;
      end loop;
      return Result;
   end Hex_Value;

   --  Write one value back in the spelling this engine uses, advancing From
   --  past it.
   --
   --  Recursive, and bounded by Depth: a value nests as deeply as its author
   --  wrote it, and this is where a file that nests without end stops.
   procedure Write_Value
     (Text   : String;
      From   : in out Natural;
      Target : in out String;
      Last   : in out Natural;
      Depth  : Natural;
      Status : in out E.Error_Info)
   is
      --  Append to the target, reporting the one bound this has.
      procedure Emit (Value : String) is
      begin
         if E.Is_Error (Status) then
            return;
         elsif Last + Value'Length > Target'Length then
            Status := E.Make (E.Tools_Too_Large);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Target'Length),
               E.Param_Bytes);
            return;
         end if;
         Target (Target'First + Last .. Target'First + Last + Value'Length - 1)
           := Value;
         Last := Last + Value'Length;
      end Emit;

      --  A quoted string, written back with its escapes decoded to the
      --  characters they stand for and only the ones JSON requires written
      --  again. That is what the implementation these templates were
      --  written for produces, and a prompt differing from it in an escape
      --  is a prompt the model was not trained on.
      procedure Write_String is
         Index : Natural := From + 1;
      begin
         Emit ("""");
         while Index <= Text'Last and then Text (Index) /= '"' loop
            if Text (Index) = '\' then
               if Index = Text'Last then
                  Fail (Status, E.Tools_Invalid_JSON, Text, Index);
                  return;
               end if;

               case Text (Index + 1) is
                  when '"'  => Emit ("\""");
                  when '\'  => Emit ("\\");
                  when '/'  => Emit ("/");
                  when 'b'  => Emit ("\b");
                  when 'f'  => Emit ("\f");
                  when 'n'  => Emit ("\n");
                  when 'r'  => Emit ("\r");
                  when 't'  => Emit ("\t");
                  when 'u'  =>
                     declare
                        Code : Integer := Hex_Value (Text, Index + 2);
                        Pair : Integer;
                     begin
                        if Code < 0 then
                           Fail (Status, E.Tools_Invalid_JSON, Text, Index);
                           return;
                        end if;

                        Index := Index + 4;

                        --  A character outside the first plane is written
                        --  as two escapes, and the two are one character.
                        --  Either half on its own is no character at all,
                        --  which is a file this refuses rather than writes
                        --  bytes nobody can decode.
                        if Code in 16#D800# .. 16#DBFF# then
                           if Index + 7 <= Text'Last
                             and then Text (Index + 1 .. Index + 2) = "\u"
                           then
                              Pair := Hex_Value (Text, Index + 3);
                           else
                              Pair := -1;
                           end if;

                           if Pair not in 16#DC00# .. 16#DFFF# then
                              Fail (Status, E.Tools_Invalid_JSON, Text, Index);
                              return;
                           end if;

                           Code := 16#1_0000#
                             + (Code - 16#D800#) * 16#400#
                             + (Pair - 16#DC00#);
                           Index := Index + 6;
                        elsif Code in 16#DC00# .. 16#DFFF# then
                           Fail (Status, E.Tools_Invalid_JSON, Text, Index);
                           return;
                        end if;

                        --  A control character has to stay an escape
                        --  whatever it was written as, because JSON has no
                        --  way to write one plainly.
                        if Code < 16#20# then
                           declare
                              Digits_16 : constant String :=
                                "0123456789abcdef";
                           begin
                              Emit ("\u00"
                                    & Digits_16 (Digits_16'First + Code / 16)
                                    & Digits_16
                                        (Digits_16'First + Code mod 16));
                           end;
                        elsif Code = Character'Pos ('"') then
                           Emit ("\""");
                        elsif Code = Character'Pos ('\') then
                           Emit ("\\");
                        else
                           Emit (As_UTF8 (Code));
                        end if;
                     end;

                  when others =>
                     Fail (Status, E.Tools_Invalid_JSON, Text, Index);
                     return;
               end case;

               Index := Index + 2;
            elsif Text (Index) < ' ' then
               --  A raw control character is not a string JSON allows, and
               --  reading one anyway would accept a file this cannot write
               --  back unchanged.
               Fail (Status, E.Tools_Invalid_JSON, Text, Index);
               return;
            else
               Emit (Text (Index .. Index));
               Index := Index + 1;
            end if;

            if E.Is_Error (Status) then
               return;
            end if;
         end loop;

         if Index > Text'Last then
            Fail (Status, E.Tools_Invalid_JSON, Text, Text'Last);
            return;
         end if;

         Emit ("""");
         From := Index + 1;
      end Write_String;

      Index : Natural;
   begin
      if E.Is_Error (Status) then
         return;
      end if;

      if Depth > Max_Depth then
         Fail (Status, E.Tools_Nesting_Too_Deep, Text, From);
         return;
      end if;

      From := Blanks_Skipped (Text, From);
      if From > Text'Last then
         Fail (Status, E.Tools_Invalid_JSON, Text, Text'Last + 1);
         return;
      end if;

      case Text (From) is
         when '"' =>
            Write_String;

         when '{' | '[' =>
            declare
               Object : constant Boolean := Text (From) = '{';
               Shut   : constant Character := (if Object then '}' else ']');
            begin
               Emit (Text (From .. From));
               From := Blanks_Skipped (Text, From + 1);

               if From <= Text'Last and then Text (From) = Shut then
                  Emit (Text (From .. From));
                  From := From + 1;
                  return;
               end if;

               loop
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  if Object then
                     From := Blanks_Skipped (Text, From);
                     if From > Text'Last or else Text (From) /= '"' then
                        Fail (Status, E.Tools_Invalid_JSON, Text,
                              Natural'Min (From, Text'Last));
                        return;
                     end if;

                     Write_String;
                     if E.Is_Error (Status) then
                        return;
                     end if;

                     From := Blanks_Skipped (Text, From);
                     if From > Text'Last or else Text (From) /= ':' then
                        Fail (Status, E.Tools_Invalid_JSON, Text,
                              Natural'Min (From, Text'Last));
                        return;
                     end if;

                     Emit (": ");
                     From := From + 1;
                  end if;

                  Write_Value (Text, From, Target, Last, Depth + 1, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  From := Blanks_Skipped (Text, From);
                  if From > Text'Last then
                     Fail (Status, E.Tools_Invalid_JSON, Text, Text'Last + 1);
                     return;
                  elsif Text (From) = ',' then
                     Emit (", ");
                     From := From + 1;
                  elsif Text (From) = Shut then
                     Emit (Text (From .. From));
                     From := From + 1;
                     return;
                  else
                     Fail (Status, E.Tools_Invalid_JSON, Text, From);
                     return;
                  end if;
               end loop;
            end;

         when 't' | 'f' | 'n' =>
            --  The three words, matched whole. A file that says "tru" says
            --  nothing, and reading the first letter alone would let it.
            declare
               function Says (Word : String) return Boolean
               is (From + Word'Length - 1 <= Text'Last
                   and then Text (From .. From + Word'Length - 1) = Word);
            begin
               if Says ("true") then
                  Emit ("true");
                  From := From + 4;
               elsif Says ("false") then
                  Emit ("false");
                  From := From + 5;
               elsif Says ("null") then
                  Emit ("null");
                  From := From + 4;
               else
                  Fail (Status, E.Tools_Invalid_JSON, Text, From);
               end if;
            end;

         when '-' | '0' .. '9' =>
            --  Written back as the file spells it. Rewriting a number means
            --  choosing a spelling for every number a file could hold, and
            --  the bound in a tool's schema is read as text either way.
            Index := From;
            while Index <= Text'Last
              and then Is_Number_Character (Text (Index))
            loop
               Index := Index + 1;
            end loop;
            Emit (Text (From .. Index - 1));
            From := Index;

         when others =>
            Fail (Status, E.Tools_Invalid_JSON, Text, From);
      end case;
   end Write_Value;

   -------------
   -- Rewrite --
   -------------

   procedure Rewrite
     (Text   : String;
      Target : out String;
      Last   : out Natural;
      Status : out E.Error_Info)
   is
      From : Natural := Text'First;
   begin
      Target := [others => ' '];
      Last := 0;
      Status := E.Success;

      Write_Value (Text, From, Target, Last, 0, Status);
      if E.Is_Error (Status) then
         Last := 0;
         return;
      end if;

      --  Text after the value is text this did not read, and a caller whose
      --  file holds two values wrote a file this cannot answer about.
      From := Blanks_Skipped (Text, From);
      if From <= Text'Last then
         Fail (Status, E.Tools_Invalid_JSON, Text, From);
         Last := 0;
      end if;
   end Rewrite;

   ---------------------------------------------------------------------------
   --  Reading what was written back
   ---------------------------------------------------------------------------

   --  Where the value at From ends, in text this engine wrote. Brackets are
   --  counted outside strings, which is enough here because what is being
   --  walked is not a caller's file but the spelling above.
   function Value_Ends (Text : String; From : Natural) return Natural is
      Index  : Natural := From;
      Opened : Natural := 0;
      Inside : Boolean := False;
   begin
      if From > Text'Last then
         return Text'Last;
      end if;

      case Text (From) is
         when '"' =>
            Index := From + 1;
            while Index <= Text'Last loop
               if Text (Index) = '\' then
                  Index := Index + 1;
               elsif Text (Index) = '"' then
                  return Index;
               end if;
               Index := Index + 1;
            end loop;
            return Text'Last;

         when '{' | '[' =>
            while Index <= Text'Last loop
               if Inside then
                  if Text (Index) = '\' then
                     Index := Index + 1;
                  elsif Text (Index) = '"' then
                     Inside := False;
                  end if;
               else
                  case Text (Index) is
                     when '"' =>
                        Inside := True;
                     when '{' | '[' =>
                        Opened := Opened + 1;
                     when '}' | ']' =>
                        Opened := Opened - 1;
                        if Opened = 0 then
                           return Index;
                        end if;
                     when others =>
                        null;
                  end case;
               end if;
               Index := Index + 1;
            end loop;
            return Text'Last;

         when others =>
            --  A number or one of the three words: it ends where the thing
            --  holding it goes on.
            while Index <= Text'Last
              and then Text (Index) /= ','
              and then Text (Index) /= '}'
              and then Text (Index) /= ']'
            loop
               Index := Index + 1;
            end loop;
            return Index - 1;
      end case;
   end Value_Ends;

   --  The value of one member of an object, as text. An empty string when
   --  the object does not carry it, which is what a caller asking after an
   --  optional member wants to hear.
   function Member (Object : String; Key : String) return String is
      Index : Natural := Blanks_Skipped (Object, Object'First);
   begin
      if Index > Object'Last or else Object (Index) /= '{' then
         return "";
      end if;

      Index := Blanks_Skipped (Object, Index + 1);
      while Index <= Object'Last and then Object (Index) = '"' loop
         declare
            Name_Ends : constant Natural := Value_Ends (Object, Index);
            Named     : constant String := Object (Index + 1 .. Name_Ends - 1);
            After     : Natural := Blanks_Skipped (Object, Name_Ends + 1);
         begin
            exit when After > Object'Last or else Object (After) /= ':';

            After := Blanks_Skipped (Object, After + 1);
            exit when After > Object'Last;

            declare
               Ends : constant Natural := Value_Ends (Object, After);
            begin
               if Named = Key then
                  return Object (After .. Ends);
               end if;
               Index := Blanks_Skipped (Object, Ends + 1);
               exit when Index > Object'Last or else Object (Index) /= ',';
               Index := Blanks_Skipped (Object, Index + 1);
            end;
         end;
      end loop;

      return "";
   end Member;

   --  A string as its characters rather than as JSON wrote them. The text
   --  this walks is text this engine wrote, so the escapes it can meet are
   --  the ones it writes.
   function Unquoted (Value : String) return String is
      Room  : String (1 .. Value'Length);
      Used  : Natural := 0;
      Index : Natural := Value'First + 1;
   begin
      if Value'Length < 2 or else Value (Value'First) /= '"' then
         return "";
      end if;

      while Index < Value'Last loop
         if Value (Index) = '\' and then Index + 1 <= Value'Last then
            Used := Used + 1;
            case Value (Index + 1) is
               when 'n'    => Room (Used) := ASCII.LF;
               when 't'    => Room (Used) := ASCII.HT;
               when 'r'    => Room (Used) := ASCII.CR;
               when 'b'    => Room (Used) := ASCII.BS;
               when 'f'    => Room (Used) := ASCII.FF;
               when others => Room (Used) := Value (Index + 1);
            end case;
            Index := Index + 2;
         else
            Used := Used + 1;
            Room (Used) := Value (Index);
            Index := Index + 1;
         end if;
      end loop;

      return Room (1 .. Used);
   end Unquoted;

   --  The name a definition or a call gives the function it is about, as
   --  either shape writes it: at the top level, or inside the "function"
   --  member that the shape callers usually write puts it in.
   function Named_Function (Object : String) return String is
      Inner : constant String := Member (Object, "function");
   begin
      if Inner /= "" and then Inner (Inner'First) = '{' then
         return Unquoted (Member (Inner, "name"));
      end if;
      return Unquoted (Member (Object, "name"));
   end Named_Function;

   -------------------
   -- Spoken_Length --
   -------------------

   function Spoken_Length (Reply : String) return Natural is
      Last : Natural := Reply'Last;
   begin
      for Start in Reply'First .. Reply'Last - Call_Opens'Length + 1 loop
         if Reply (Start .. Start + Call_Opens'Length - 1) = Call_Opens then
            Last := Start - 1;

            --  The newline a model writes between what it said and the
            --  first block it wrote belongs to neither: the template puts
            --  one there itself when there is something to separate.
            while Last >= Reply'First
              and then Reply (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
            loop
               Last := Last - 1;
            end loop;

            return Last - Reply'First + 1;
         end if;
      end loop;

      --  A reply that called nothing is what it is, trailing space and all:
      --  this is not the place that decides what a plain answer looks like.
      return Reply'Length;
   end Spoken_Length;

   ---------------------------------------------------------------------------
   --  Definitions
   ---------------------------------------------------------------------------

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Definitions) is
   begin
      if Item.Pool /= null then
         Item.Pool.all := [others => ' '];
         Free_Storage (Item.Pool);
      end if;
      Item.Rows := [others => <>];
      Item.Used := 0;
      Item.Filled := 0;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Definitions) is
   begin
      Close (Item);
   end Finalize;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : in out Definitions;
      Text   : String;
      Status : out E.Error_Info)
   is
      From : Natural;

      --  Write one definition into the pool and record where it went.
      procedure Take_One is
         Before : constant Natural := Item.Filled;
         First  : constant Natural := Blanks_Skipped (Text, From);
      begin
         if Item.Used = Max_Definitions then
            Status := E.Make (E.Tools_Too_Many);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Max_Definitions));
            return;
         end if;

         if First > Text'Last or else Text (First) /= '{' then
            Fail (Status, E.Tools_Not_An_Object, Text,
                  Natural'Min (First, Text'Last));
            return;
         end if;

         From := First;
         Write_Value (Text, From, Item.Pool.all, Item.Filled, 0, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         declare
            Written : constant String :=
              Item.Pool.all (Before + 1 .. Item.Filled);
            Called  : constant String := Named_Function (Written);
         begin
            if Called = "" then
               Status := E.Make (E.Tools_Missing_Name);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            --  The name is kept beside the definition rather than found
            --  again every time a call is matched against it.
            if Item.Filled + Called'Length > Item.Pool.all'Length then
               Status := E.Make (E.Tools_Too_Large);
               E.Add_Integer
                 (Status, "limit", Long_Long_Integer (Max_Definition_Bytes),
                  E.Param_Bytes);
               return;
            end if;

            Item.Pool.all (Item.Filled + 1 .. Item.Filled + Called'Length) :=
              Called;
            Item.Used := Item.Used + 1;
            Item.Rows (Item.Used) :=
              (Text => (Offset => Before, Length => Item.Filled - Before),
               Name => (Offset => Item.Filled, Length => Called'Length));
            Item.Filled := Item.Filled + Called'Length;
         end;
      end Take_One;

   begin
      Close (Item);
      Status := E.Success;

      Item.Pool := new String (1 .. Max_Definition_Bytes);
      Item.Pool.all := [others => ' '];

      From := Blanks_Skipped (Text, Text'First);
      if From > Text'Last then
         Status := E.Make (E.Tools_Invalid_JSON);
         E.Add_Integer (Status, "offset", 0, E.Param_Offset);
         return;
      end if;

      if Text (From) /= '[' then
         --  One object rather than a list of them, which is what a caller
         --  with one tool writes and what refusing would make them wrap.
         Take_One;
         if E.Is_Ok (Status) then
            From := Blanks_Skipped (Text, From);
            if From <= Text'Last then
               Fail (Status, E.Tools_Invalid_JSON, Text, From);
            end if;
         end if;

         if E.Is_Error (Status) then
            Close (Item);
         end if;
         return;
      end if;

      From := Blanks_Skipped (Text, From + 1);
      if From <= Text'Last and then Text (From) = ']' then
         --  A list with nothing in it offers nothing, which is a thing a
         --  caller may say and not a file to refuse.
         return;
      end if;

      loop
         Take_One;
         exit when E.Is_Error (Status);

         From := Blanks_Skipped (Text, From);
         if From > Text'Last then
            Fail (Status, E.Tools_Invalid_JSON, Text, Text'Last + 1);
            exit;
         elsif Text (From) = ',' then
            From := From + 1;
         elsif Text (From) = ']' then
            From := Blanks_Skipped (Text, From + 1);
            if From <= Text'Last then
               Fail (Status, E.Tools_Invalid_JSON, Text, From);
            end if;
            exit;
         else
            Fail (Status, E.Tools_Invalid_JSON, Text, From);
            exit;
         end if;
      end loop;

      if E.Is_Error (Status) then
         Close (Item);
      end if;
   exception
      when others =>
         Close (Item);
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "tools.read");
   end Read;

   -----------
   -- Count --
   -----------

   function Count (Item : Definitions) return Natural is (Item.Used);

   ----------------
   -- Definition --
   ----------------

   function Definition (Item : Definitions; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Text.Offset + 1
         .. Item.Rows (Index).Text.Offset + Item.Rows (Index).Text.Length);
   end Definition;

   ---------------
   -- Tool_Name --
   ---------------

   function Tool_Name (Item : Definitions; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Name.Offset + 1
         .. Item.Rows (Index).Name.Offset + Item.Rows (Index).Name.Length);
   end Tool_Name;

   ------------
   -- Offers --
   ------------

   function Offers (Item : Definitions; Called : String) return Boolean is
   begin
      for Index in 1 .. Item.Used loop
         if Tool_Name (Item, Index) = Called then
            return True;
         end if;
      end loop;
      return False;
   end Offers;

   ---------------------------------------------------------------------------
   --  Calls
   ---------------------------------------------------------------------------

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Calls) is
   begin
      if Item.Pool /= null then
         Item.Pool.all := [others => ' '];
         Free_Storage (Item.Pool);
      end if;
      Item.Rows := [others => <>];
      Item.Used := 0;
      Item.Filled := 0;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Calls) is
   begin
      Close (Item);
   end Finalize;

   ----------------
   -- Read_Calls --
   ----------------

   procedure Read_Calls
     (Item   : in out Calls;
      Reply  : String;
      Status : out E.Error_Info)
   is
      Index : Natural;

      --  Whether the reply carries Marker at Position.
      function Marks (Position : Natural; Marker : String) return Boolean
      is (Position + Marker'Length - 1 <= Reply'Last
          and then Reply (Position .. Position + Marker'Length - 1) = Marker);

      --  Keep one piece of text in the pool, answering where it went.
      procedure Keep (Value : String; Where : out Span) is
      begin
         Where := (Offset => Item.Filled, Length => Value'Length);
         if Item.Filled + Value'Length > Item.Pool.all'Length then
            Status := E.Make (E.Tools_Too_Large);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Max_Call_Bytes),
               E.Param_Bytes);
            return;
         end if;
         Item.Pool.all (Item.Filled + 1 .. Item.Filled + Value'Length) := Value;
         Item.Filled := Item.Filled + Value'Length;
      end Keep;

      --  Read what one block holds.
      procedure Take_One (Inner : String) is
         Room    : String (1 .. Max_Call_Bytes);
         Written : Natural;
         Reading : E.Error_Info;
      begin
         if Item.Used = Max_Calls then
            Status := E.Make (E.Tools_Too_Many);
            E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Calls));
            return;
         end if;

         Rewrite (Inner, Room, Written, Reading);
         if E.Is_Error (Reading) then
            Status := E.Make (E.Tools_Call_Malformed);
            E.Add_Integer
              (Status, "index", Long_Long_Integer (Item.Used + 1));
            return;
         end if;

         declare
            Object    : constant String := Room (1 .. Written);
            Called    : constant String := Named_Function (Object);
            Given     : constant String := Member (Object, "arguments");
            Name_At   : Span;
            Where     : Span;
         begin
            if Called = "" then
               Status := E.Make (E.Tools_Call_Malformed);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            Keep (Called, Name_At);
            if E.Is_Error (Status) then
               return;
            end if;

            if Given = "" then
               --  A call with no arguments is a call, and the model that
               --  wrote it meant an empty object.
               Keep ("{}", Where);
            elsif Given (Given'First) = '"' then
               --  Arguments written as a string holding JSON, which is how
               --  some models answer. Read back out of the string and
               --  written the one way, so that a caller sees the arguments
               --  and not the quoting.
               declare
                  Plain   : constant String := Unquoted (Given);
                  Room_2  : String (1 .. Max_Call_Bytes);
                  Used_2  : Natural;
                  Second  : E.Error_Info;
               begin
                  Rewrite (Plain, Room_2, Used_2, Second);
                  if E.Is_Error (Second) then
                     Status := E.Make (E.Tools_Call_Malformed);
                     E.Add_Integer
                       (Status, "index", Long_Long_Integer (Item.Used + 1));
                     return;
                  end if;
                  Keep (Room_2 (1 .. Used_2), Where);
               end;
            elsif Given (Given'First) = '{' then
               Keep (Given, Where);
            else
               Status := E.Make (E.Tools_Call_Malformed);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            if E.Is_Error (Status) then
               return;
            end if;

            Item.Used := Item.Used + 1;
            Item.Rows (Item.Used) := (Name => Name_At, Arguments => Where);
         end;
      end Take_One;

   begin
      Close (Item);
      Status := E.Success;

      Item.Pool := new String (1 .. Max_Call_Bytes);
      Item.Pool.all := [others => ' '];

      Index := Reply'First;
      while Index <= Reply'Last loop
         if Marks (Index, Call_Opens) then
            declare
               First : constant Natural := Index + Call_Opens'Length;
               Shut  : Natural := First;
            begin
               while Shut <= Reply'Last and then not Marks (Shut, Call_Closes)
               loop
                  Shut := Shut + 1;
               end loop;

               if Shut > Reply'Last then
                  --  A block that never closes is a reply that stopped in
                  --  the middle of a call, which is worth saying rather
                  --  than reading as no call at all.
                  Status := E.Make (E.Tools_Call_Malformed);
                  E.Add_Integer
                    (Status, "index", Long_Long_Integer (Item.Used + 1));
                  return;
               end if;

               Take_One (Reply (First .. Shut - 1));
               if E.Is_Error (Status) then
                  return;
               end if;

               Index := Shut + Call_Closes'Length;
            end;
         else
            Index := Index + 1;
         end if;
      end loop;
   exception
      when others =>
         Close (Item);
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "tools.read_calls");
   end Read_Calls;

   -----------
   -- Count --
   -----------

   function Count (Item : Calls) return Natural is (Item.Used);

   ------------
   -- Called --
   ------------

   function Called (Item : Calls; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Name.Offset + 1
         .. Item.Rows (Index).Name.Offset + Item.Rows (Index).Name.Length);
   end Called;

   ---------------
   -- Arguments --
   ---------------

   function Arguments (Item : Calls; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Arguments.Offset + 1
         .. Item.Rows (Index).Arguments.Offset
            + Item.Rows (Index).Arguments.Length);
   end Arguments;

end Model_Runner.Tools;
