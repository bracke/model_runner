with Model_Runner.UTF8;

package body Model_Runner.Tools.Builtin is

   package E renames Model_Runner.Errors;

   --  The definitions, written once. The grammar and the answers below both
   --  read the same names and the same shapes from here, so a tool added to
   --  one and forgotten in the other cannot happen: there is one list.
   Definitions : constant String :=
     "["
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""calculator"", "
     & """description"": ""Evaluate a binary arithmetic operation on two "
     & "integers."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """a"": {""type"": ""integer""}, "
     & """op"": {""type"": ""string"", ""enum"": [""+"", ""-"", ""*"", "
     & """/""]}, "
     & """b"": {""type"": ""integer""}}, "
     & """required"": [""a"", ""op"", ""b""]}}}, "
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""string_length"", "
     & """description"": ""Return the number of characters in a string."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """text"": {""type"": ""string""}}, "
     & """required"": [""text""]}}}, "
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""reverse_text"", "
     & """description"": ""Return a string with its characters reversed."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """text"": {""type"": ""string""}}, "
     & """required"": [""text""]}}}, "
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""lookup"", "
     & """description"": ""Look up a fact by its key."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """key"": {""type"": ""string"", ""enum"": ["
     & """capital_of_france"", ""speed_of_light"", ""ada_year""]}}, "
     & """required"": [""key""]}}}"
     & "]";

   ---------------------
   -- Definitions_Text --
   ---------------------

   function Definitions_Text return String is (Definitions);

   ---------------------------------------------------------------------------
   --  Reading arguments
   --
   --  The arguments arrive as one line of JSON the engine has already
   --  rewritten in its own spelling: a space after every colon and comma,
   --  escapes decoded to the characters they stand for and re-escaped only
   --  where JSON requires it. So a reader here need not be a JSON parser --
   --  it walks the top level of one object and reads the value beside a key.
   ---------------------------------------------------------------------------

   --  Advance past a JSON string, whose opening quote is at Index. Returns
   --  the index just after the closing quote, or Text'Last + 1 when the
   --  string is unterminated.
   function After_String (Text : String; Index : Positive) return Positive is
      I : Natural := Index + 1;
   begin
      while I <= Text'Last loop
         if Text (I) = '\' then
            I := I + 2;                --  an escape and the byte it escapes
         elsif Text (I) = '"' then
            return I + 1;
         else
            I := I + 1;
         end if;
      end loop;
      return Text'Last + 1;
   end After_String;

   --  The content of a JSON string whose opening quote is at Index, with the
   --  escapes JSON requires decoded to the characters they stand for.
   function String_Content (Text : String; Index : Positive) return String is
      Room : String (1 .. Text'Length);
      Used : Natural := 0;
      I    : Natural := Index + 1;

      procedure Put (C : Character) is
      begin
         Used := Used + 1;
         Room (Used) := C;
      end Put;
   begin
      while I <= Text'Last and then Text (I) /= '"' loop
         if Text (I) = '\' and then I < Text'Last then
            case Text (I + 1) is
               when 'n'    => Put (ASCII.LF);
               when 't'    => Put (ASCII.HT);
               when 'r'    => Put (ASCII.CR);
               when 'b'    => Put (ASCII.BS);
               when 'f'    => Put (ASCII.FF);
               when others => Put (Text (I + 1));  --  \" \\ \/ and the rest
            end case;
            I := I + 2;
         else
            Put (Text (I));
            I := I + 1;
         end if;
      end loop;
      return Room (1 .. Used);
   end String_Content;

   --  The raw value beside Key at the top level of the object in Args: the
   --  slice as it stands, quotes and all for a string. Found is false when
   --  the object has no such key.
   procedure Locate
     (Args  : String;
      Key   : String;
      First : out Natural;
      Last  : out Natural;
      Found : out Boolean)
   is
      I     : Natural := Args'First;
      Depth : Natural := 0;
   begin
      First := 0;
      Last  := 0;
      Found := False;

      --  To the opening brace.
      while I <= Args'Last and then Args (I) /= '{' loop
         I := I + 1;
      end loop;
      if I > Args'Last then
         return;
      end if;
      I := I + 1;

      loop
         --  Whitespace before a key or the closing brace.
         while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
           | ASCII.LF | ASCII.CR
         loop
            I := I + 1;
         end loop;
         exit when I > Args'Last or else Args (I) = '}';

         --  A member begins with a key, which is a string.
         if Args (I) /= '"' then
            return;                    --  not the object shape this reads
         end if;

         declare
            Key_First : constant Positive := I;
            Key_After : constant Positive := After_String (Args, I);
            This_Key  : constant String :=
              String_Content (Args, Key_First);
         begin
            I := Key_After;
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last or else Args (I) /= ':';
            I := I + 1;                --  past the colon
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last;

            --  The value. Its extent depends on its kind.
            declare
               Value_First : constant Positive := I;
            begin
               case Args (I) is
                  when '"' =>
                     I := After_String (Args, I);
                  when '{' | '[' =>
                     Depth := 1;
                     I := I + 1;
                     while I <= Args'Last and then Depth > 0 loop
                        case Args (I) is
                           when '"'       => I := After_String (Args, I);
                           when '{' | '[' => Depth := Depth + 1; I := I + 1;
                           when '}' | ']' => Depth := Depth - 1; I := I + 1;
                           when others    => I := I + 1;
                        end case;
                     end loop;
                  when others =>
                     while I <= Args'Last
                       and then Args (I) not in ',' | '}' | ']'
                       | ' ' | ASCII.HT | ASCII.LF | ASCII.CR
                     loop
                        I := I + 1;
                     end loop;
               end case;

               if This_Key = Key then
                  First := Value_First;
                  Last  := I - 1;
                  Found := True;
                  return;
               end if;
            end;

            --  Past whitespace to the comma between members, if any.
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last or else Args (I) /= ',';
            I := I + 1;
         end;
      end loop;
   end Locate;

   --  A string argument's decoded content. Found is false when the key is
   --  absent or its value is not a string.
   procedure String_Argument
     (Args  : String;
      Key   : String;
      Value : out String;
      Last  : out Natural;
      Found : out Boolean)
   is
      From, To : Natural;
      Present  : Boolean;
   begin
      Last  := 0;
      Found := False;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From or else Args (From) /= '"' then
         return;
      end if;
      declare
         Content : constant String := String_Content (Args, From);
      begin
         if Content'Length > Value'Length then
            return;                    --  the caller sized it; do not overrun
         end if;
         Value (Value'First .. Value'First + Content'Length - 1) := Content;
         Last  := Value'First + Content'Length - 1;
         Found := True;
      end;
   end String_Argument;

   --  An integer argument. Found is false when the key is absent or its
   --  value is not something this reads as a whole number.
   procedure Integer_Argument
     (Args  : String;
      Key   : String;
      Value : out Long_Long_Integer;
      Found : out Boolean)
   is
      From, To : Natural;
      Present  : Boolean;
   begin
      Value := 0;
      Found := False;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From then
         return;
      end if;

      declare
         Raw   : String renames Args (From .. To);
         Sign  : Long_Long_Integer := 1;
         Acc   : Long_Long_Integer := 0;
         I     : Natural := Raw'First;
         Seen  : Boolean := False;
      begin
         if I <= Raw'Last and then Raw (I) = '-' then
            Sign := -1;
            I := I + 1;
         end if;
         while I <= Raw'Last and then Raw (I) in '0' .. '9' loop
            Acc := Acc * 10
              + Long_Long_Integer (Character'Pos (Raw (I)) - Character'Pos ('0'));
            Seen := True;
            I := I + 1;
         end loop;
         --  A whole number and nothing after it. A value like 1.5 is a
         --  number the calculator was not offered, so it is refused here
         --  rather than truncated silently.
         if Seen and then I > Raw'Last then
            Value := Sign * Acc;
            Found := True;
         end if;
      end;
   end Integer_Argument;

   ---------------------------------------------------------------------------
   --  Writing the answer
   ---------------------------------------------------------------------------

   --  A decimal image without Ada's leading space on non-negatives.
   function Image (Value : Long_Long_Integer) return String is
      Raw : constant String := Long_Long_Integer'Image (Value);
   begin
      if Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      else
         return Raw;
      end if;
   end Image;

   ---------------------------------------------------------------------------
   --  The tools
   ---------------------------------------------------------------------------

   function Calculator (Args : String) return String is
      A, B : Long_Long_Integer;
      Op   : String (1 .. 8);
      Op_Last : Natural;
      Found_A, Found_B, Found_Op : Boolean;
   begin
      Integer_Argument (Args, "a", A, Found_A);
      Integer_Argument (Args, "b", B, Found_B);
      String_Argument (Args, "op", Op, Op_Last, Found_Op);
      if not (Found_A and then Found_B and then Found_Op) then
         return "error: calculator needs integers a and b and an op";
      end if;
      declare
         Operator : constant String := Op (Op'First .. Op_Last);
      begin
         if Operator = "+" then
            return Image (A + B);
         elsif Operator = "-" then
            return Image (A - B);
         elsif Operator = "*" then
            return Image (A * B);
         elsif Operator = "/" then
            if B = 0 then
               return "error: division by zero";
            else
               return Image (A / B);
            end if;
         else
            return "error: op must be one of + - * /";
         end if;
      end;
   end Calculator;

   function String_Length (Args : String) return String is
      Room : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
      Last : Natural;
      Have : Boolean;
   begin
      String_Argument (Args, "text", Room, Last, Have);
      if not Have then
         return "error: string_length needs a string text";
      end if;
      return Image
        (Long_Long_Integer
           (Model_Runner.UTF8.Code_Point_Count (Room (Room'First .. Last))));
   end String_Length;

   function Reverse_Text (Args : String) return String is
      Room : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
      Last : Natural;
      Have : Boolean;
   begin
      String_Argument (Args, "text", Room, Last, Have);
      if not Have then
         return "error: reverse_text needs a string text";
      end if;

      --  Reversed by code point, not by byte: reversing the bytes of a
      --  multi-byte character makes a sequence that is not that character
      --  and may not be UTF-8 at all.
      declare
         Text   : String renames Room (Room'First .. Last);
         Output : String (1 .. Last - Room'First + 1);
         Fill   : Natural := Output'Last;
         I      : Natural := Text'First;
         Point  : Natural;
         Width  : Natural;
      begin
         while I <= Text'Last loop
            Model_Runner.UTF8.Decode_First (Text (I .. Text'Last), Point, Width);
            exit when Width = 0;
            Output (Fill - Width + 1 .. Fill) := Text (I .. I + Width - 1);
            Fill := Fill - Width;
            I := I + Width;
         end loop;
         return Output;
      end;
   end Reverse_Text;

   function Lookup (Args : String) return String is
      Room : String (1 .. 256);
      Last : Natural;
      Have : Boolean;
   begin
      String_Argument (Args, "key", Room, Last, Have);
      if not Have then
         return "error: lookup needs a string key";
      end if;
      declare
         Key : constant String := Room (Room'First .. Last);
      begin
         if Key = "capital_of_france" then
            return "Paris";
         elsif Key = "speed_of_light" then
            return "299792458 metres per second";
         elsif Key = "ada_year" then
            return "1983";
         else
            return "error: no fact by that key";
         end if;
      end;
   end Lookup;

   ---------
   -- Run --
   ---------

   overriding procedure Run
     (Self      : in out Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      pragma Unreferenced (Self);

      function Answer return String is
      begin
         if Named = "calculator" then
            return Calculator (Arguments);
         elsif Named = "string_length" then
            return String_Length (Arguments);
         elsif Named = "reverse_text" then
            return Reverse_Text (Arguments);
         elsif Named = "lookup" then
            return Lookup (Arguments);
         else
            return "error: no tool by the name """ & Named & """";
         end if;
      end Answer;

      Text : constant String := Answer;
   begin
      Last   := 0;
      Status := E.Success;
      if Text'Length > Result'Length then
         Status := E.Make (E.Tools_Too_Large);
         return;
      end if;
      Result (Result'First .. Result'First + Text'Length - 1) := Text;
      Last := Result'First + Text'Length - 1;
   end Run;

end Model_Runner.Tools.Builtin;
