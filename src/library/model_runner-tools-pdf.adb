with Ada.Strings.Unbounded;

with Zlib;

with Model_Runner.Tools.Text_Util;

package body Model_Runner.Tools.PDF is

   package U renames Ada.Strings.Unbounded;
   use type Zlib.Status_Code;

   --  As much text as one call hands back. A search wants the words, not the
   --  whole book, and a bound keeps a large PDF from filling memory.
   Max_Output : constant := 512 * 1024;

   --  The index of Needle in Hay at or after From, or zero when it is not
   --  there. Plain bytes, no case folding.
   function Index_Of
     (Hay : String; Needle : String; From : Positive) return Natural
   is
   begin
      if Needle'Length = 0 or else Hay'Length < Needle'Length then
         return 0;
      end if;
      for I in From .. Hay'Last - Needle'Length + 1 loop
         if Hay (I .. I + Needle'Length - 1) = Needle then
            return I;
         end if;
      end loop;
      return 0;
   end Index_Of;

   --  Whether Slice contains Needle.
   function Has (Slice : String; Needle : String) return Boolean
   is (Index_Of (Slice, Needle, Slice'First) /= 0);

   --  Inflate a zlib (FlateDecode) payload, or return the empty string when
   --  it will not inflate -- which is how a stream that is not really
   --  compressed, or is compressed some other way, is passed over.
   function Inflate (Data : String) return String is
      Input  : Zlib.Byte_Array (0 .. Data'Length - 1);
      Status : Zlib.Status_Code;
   begin
      if Data'Length = 0 then
         return "";
      end if;
      for I in Input'Range loop
         Input (I) := Zlib.Byte (Character'Pos (Data (Data'First + I)));
      end loop;
      declare
         Output : constant Zlib.Byte_Array := Zlib.Inflate (Input, Status);
         Result : String (1 .. Output'Length);
      begin
         if Status /= Zlib.Ok then
            return "";
         end if;
         for I in Output'Range loop
            Result (Result'First + (I - Output'First)) :=
              Character'Val (Integer (Output (I)));
         end loop;
         return Result;
      end;
   end Inflate;

   --  Read the strings a content stream shows -- the parenthesised and hex
   --  strings, which in a content stream are the text of the text operators
   --  -- into Into, a space between them, stopping at the output bound.
   procedure Append_Content_Text (S : String; Into : in out U.Unbounded_String)
   is
      I : Integer := S'First;

      function Room return Boolean is (U.Length (Into) < Max_Output);

      procedure Put (C : Character) is
      begin
         if Room then
            U.Append (Into, C);
         end if;
      end Put;

      procedure Octal (From : in out Integer) is
         Value  : Integer := 0;
         Ndig : Natural := 0;
      begin
         while Ndig < 3 and then From <= S'Last
           and then S (From) in '0' .. '7'
         loop
            Value := Value * 8 + (Character'Pos (S (From)) - Character'Pos ('0'));
            From := From + 1;
            Ndig := Ndig + 1;
         end loop;
         Put (Character'Val (Value mod 256));
      end Octal;
   begin
      while I <= S'Last and then Room loop
         if S (I) = '(' then
            --  A literal string, to its balanced close, escapes honoured.
            declare
               Depth : Natural := 1;
               J     : Integer := I + 1;
            begin
               while J <= S'Last and then Depth > 0 loop
                  if S (J) = '\' and then J < S'Last then
                     case S (J + 1) is
                        when 'n' => Put (ASCII.LF); J := J + 2;
                        when 'r' => Put (ASCII.CR); J := J + 2;
                        when 't' => Put (ASCII.HT); J := J + 2;
                        when 'b' | 'f' => J := J + 2;
                        when '(' => Put ('('); J := J + 2;
                        when ')' => Put (')'); J := J + 2;
                        when '\' => Put ('\'); J := J + 2;
                        when '0' .. '7' =>
                           J := J + 1;
                           Octal (J);
                        when ASCII.LF => J := J + 2;
                        when ASCII.CR =>
                           J := J + 2;
                           if J <= S'Last and then S (J) = ASCII.LF then
                              J := J + 1;
                           end if;
                        when others => Put (S (J + 1)); J := J + 2;
                     end case;
                  elsif S (J) = '(' then
                     Depth := Depth + 1;
                     Put ('(');
                     J := J + 1;
                  elsif S (J) = ')' then
                     Depth := Depth - 1;
                     if Depth > 0 then
                        Put (')');
                     end if;
                     J := J + 1;
                  else
                     Put (S (J));
                     J := J + 1;
                  end if;
               end loop;
               Put (' ');
               I := J;
            end;

         elsif S (I) = '<' and then I < S'Last and then S (I + 1) = '<' then
            --  A dictionary opener, not a string. Step over both angles.
            I := I + 2;

         elsif S (I) = '<' then
            --  A hex string: pairs of hex digits to bytes, to the '>'.
            declare
               J    : Integer := I + 1;
               High : Integer := -1;

               function Nibble (C : Character) return Integer is
               begin
                  case C is
                     when '0' .. '9' =>
                        return Character'Pos (C) - Character'Pos ('0');
                     when 'a' .. 'f' =>
                        return 10 + Character'Pos (C) - Character'Pos ('a');
                     when 'A' .. 'F' =>
                        return 10 + Character'Pos (C) - Character'Pos ('A');
                     when others =>
                        return -1;
                  end case;
               end Nibble;
            begin
               while J <= S'Last and then S (J) /= '>' loop
                  declare
                     N : constant Integer := Nibble (S (J));
                  begin
                     if N >= 0 then
                        if High < 0 then
                           High := N;
                        else
                           Put (Character'Val (High * 16 + N));
                           High := -1;
                        end if;
                     end if;
                  end;
                  J := J + 1;
               end loop;
               if High >= 0 then
                  Put (Character'Val (High * 16));
               end if;
               Put (' ');
               I := J + 1;
            end;

         else
            I := I + 1;
         end if;
      end loop;
   end Append_Content_Text;

   ------------------
   -- Extract_Text --
   ------------------

   function Extract_Text (Raw : String) return String is
      Out_Buf : U.Unbounded_String;
      Cursor  : Integer := Raw'First;
      Guard   : constant String := "stream";
      Ender    : constant String := "endstream";
   begin
      while Cursor <= Raw'Last and then U.Length (Out_Buf) < Max_Output loop
         declare
            S_At : constant Natural := Index_Of (Raw, Guard, Cursor);
         begin
            exit when S_At = 0;

            --  Skip a "stream" that is the tail of "endstream".
            if S_At >= Raw'First + 3
              and then Raw (S_At - 3 .. S_At - 1) = "end"
            then
               Cursor := S_At + Guard'Length;
            else
               declare
                  --  The dictionary just before the keyword, to tell a
                  --  FlateDecode stream from a plain one.
                  Dict_From : constant Positive :=
                    Integer'Max (Raw'First, S_At - 400);
                  Flate     : constant Boolean :=
                    Has (Raw (Dict_From .. S_At - 1), "/FlateDecode");

                  --  Data begins after the keyword and one EOL.
                  Data_From : Integer := S_At + Guard'Length;
                  End_At    : Natural;
               begin
                  if Data_From <= Raw'Last and then Raw (Data_From) = ASCII.CR
                  then
                     Data_From := Data_From + 1;
                  end if;
                  if Data_From <= Raw'Last and then Raw (Data_From) = ASCII.LF
                  then
                     Data_From := Data_From + 1;
                  end if;

                  End_At := Index_Of (Raw, Ender, Data_From);
                  exit when End_At = 0;

                  declare
                     Data : constant String :=
                       (if End_At - 1 >= Data_From
                        then Raw (Data_From .. End_At - 1) else "");
                     Text : constant String :=
                       (if Flate then Inflate (Data) else Data);
                  begin
                     --  Only a stream that opens a text block carries text;
                     --  an image or a font would only add noise.
                     if Has (Text, "BT") then
                        Append_Content_Text (Text, Out_Buf);
                     end if;
                  end;

                  Cursor := End_At + Ender'Length;
               end;
            end if;
         end;
      end loop;

      return Model_Runner.Tools.Text_Util.Collapse_Blanks
        (U.To_String (Out_Buf));
   end Extract_Text;

end Model_Runner.Tools.PDF;
