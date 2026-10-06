separate (Model_Runner.Templates.Render)
function Params_Of (Src : String; Qwen : Boolean := False) return String is
   Buf : String (1 .. 8 * Src'Length + 256);
   N   : Natural := 0;
   I   : Natural := Src'First;

   procedure Put (S : String) is
   begin
      if N + S'Length <= Buf'Length then
         Buf (N + 1 .. N + S'Length) := S;
         N := N + S'Length;
      end if;
   end Put;

   procedure Skip_Blanks is
   begin
      while I <= Src'Last
        and then Src (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
      loop
         I := I + 1;
      end loop;
   end Skip_Blanks;

   --  A JSON string at I ("...") decoded to its characters, I left past
   --  the closing quote.
   function Read_String return String is
      R : String (1 .. Src'Length);
      M : Natural := 0;
   begin
      I := I + 1;
      while I <= Src'Last and then Src (I) /= '"' loop
         if Src (I) = '\' and then I < Src'Last then
            I := I + 1;
            M := M + 1;
            case Src (I) is
               when 'n'    => R (M) := ASCII.LF;
               when 't'    => R (M) := ASCII.HT;
               when 'r'    => R (M) := ASCII.CR;
               when others => R (M) := Src (I);
            end case;
         else
            M := M + 1;
            R (M) := Src (I);
         end if;
         I := I + 1;
      end loop;
      if I <= Src'Last then
         I := I + 1;
      end if;
      return R (1 .. M);
   end Read_String;

   --  A bare JSON value at I (number, true/false/null, object, array)
   --  as its own text, I left at the following ',' or '}'.
   function Read_Bare return String is
      First : constant Natural := I;
      Depth : Natural := 0;
   begin
      while I <= Src'Last loop
         case Src (I) is
            when '{' | '[' => Depth := Depth + 1;
            when '}' | ']' =>
               exit when Depth = 0;
               Depth := Depth - 1;
            when ',' => exit when Depth = 0;
            when others => null;
         end case;
         I := I + 1;
      end loop;
      return Model_Runner.Text.Trim (Src (First .. I - 1));
   end Read_Bare;
begin
   Skip_Blanks;
   if I <= Src'Last and then Src (I) = '{' then
      I := I + 1;
   end if;
   loop
      Skip_Blanks;
      exit when I > Src'Last or else Src (I) = '}' or else Src (I) /= '"';
      declare
         Key : constant String := Read_String;
      begin
         Skip_Blanks;
         if I <= Src'Last and then Src (I) = ':' then
            I := I + 1;
         end if;
         Skip_Blanks;
         declare
            Quoted_One : constant Boolean :=
              I <= Src'Last and then Src (I) = '"';
            Raw : constant String :=
              (if Quoted_One then Read_String else Read_Bare);

            --  A value that is not a string is written as both
            --  templates write it, printed by the language they are
            --  written in: true as True, null as None, a mapping or
            --  a list as Python spells one.
            Val : constant String :=
              (if Quoted_One then Raw
               elsif Raw = "true" then "True"
               elsif Raw = "false" then "False"
               elsif Raw = "null" then "None"
               elsif Raw'Length > 0 and then Raw (Raw'First) in '{' | '['
               then Pythonic (Raw)
               else Raw);
            CDATA : constant Boolean :=
              Quoted_One
              and then (for some C of Val =>
                          C = '<' or else C = '&' or else C = ASCII.LF);
         begin
            if Qwen then
               --  Qwen3-Coder: <parameter=k>, the value on its own
               --  line, then </parameter>, no CDATA.
               Put ("<parameter=");
               Put (Key);
               Put (">" & ASCII.LF);
               Put (Val);
               Put (ASCII.LF & "</parameter>" & ASCII.LF);
            else
               --  MiniCPM: <param name="k">v</param>, a string that
               --  holds a '<', an '&' or a line break in a CDATA
               --  block; a value that is not a string is never
               --  wrapped, because its template asks "is string"
               --  before it asks what is in it.
               Put ("<param name=""");
               Put (Key);
               Put (""">");
               if CDATA then
                  Put ("<![CDATA[");
                  Put (Val);
                  Put ("]]>");
               else
                  Put (Val);
               end if;
               Put ("</param>");
            end if;
         end;
      end;
      Skip_Blanks;
      if I <= Src'Last and then Src (I) = ',' then
         I := I + 1;
      end if;
   end loop;
   return Buf (1 .. N);
end Params_Of;
