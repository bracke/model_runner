with Ada.Characters.Handling;
with Ada.Strings.Unbounded;

with Zlib;

with Model_Runner.Tools.Text_Util;

package body Model_Runner.Tools.OOXML is

   package U renames Ada.Strings.Unbounded;
   use type Zlib.Status_Code;

   Max_Output : constant := 512 * 1024;

   function Low (S : String) return String
     renames Ada.Characters.Handling.To_Lower;

   function Ends_With (S, Suffix : String) return Boolean
   is (S'Length >= Suffix'Length
       and then Low (S (S'Last - Suffix'Length + 1 .. S'Last)) = Suffix);

   function Starts_With (S, Prefix : String) return Boolean
   is (S'Length >= Prefix'Length
       and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   -------------
   -- Kind_Of --
   -------------

   function Kind_Of
     (Name : String; Found : out Boolean) return Document_Kind is
   begin
      Found := True;
      if Ends_With (Name, ".docx") then
         return Word;
      elsif Ends_With (Name, ".xlsx") then
         return Excel;
      elsif Ends_With (Name, ".pptx") then
         return Powerpoint;
      elsif Ends_With (Name, ".odt")
        or else Ends_With (Name, ".ods")
        or else Ends_With (Name, ".odp")
      then
         return Open_Document;
      elsif Ends_With (Name, ".epub") then
         return Epub;
      else
         Found := False;
         return Word;
      end if;
   end Kind_Of;

   --  Little-endian integers out of the archive bytes, zero when the field
   --  would run off the end.
   function U16 (S : String; Base : Integer) return Natural is
   begin
      if Base < S'First or else Base + 1 > S'Last then
         return 0;
      end if;
      return Character'Pos (S (Base)) + 256 * Character'Pos (S (Base + 1));
   end U16;

   function U32 (S : String; Base : Integer) return Long_Long_Integer is
      V : Long_Long_Integer := 0;
   begin
      if Base < S'First or else Base + 3 > S'Last then
         return 0;
      end if;
      for K in 0 .. 3 loop
         V := V + Long_Long_Integer (Character'Pos (S (Base + K)))
                  * (256 ** K);
      end loop;
      return V;
   end U32;

   --  A four-byte signature "PK" & B3 & B4 at Base.
   function Sig (S : String; Base : Integer; B3, B4 : Character) return Boolean
   is (Base >= S'First and then Base + 3 <= S'Last
       and then S (Base) = Character'Val (16#50#)
       and then S (Base + 1) = Character'Val (16#4B#)
       and then S (Base + 2) = B3
       and then S (Base + 3) = B4);

   --  Inflate a raw Deflate payload (a ZIP member), empty on failure.
   function Inflate_Raw (Data : String) return String is
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
         Output : constant Zlib.Byte_Array := Zlib.Inflate_Raw (Input, Status);
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
   end Inflate_Raw;

   --  Whether an archive entry holds text for this kind of document.
   function Wanted (Kind : Document_Kind; Name : String) return Boolean is
   begin
      case Kind is
         when Word          => return Name = "word/document.xml";
         when Excel         => return Name = "xl/sharedStrings.xml";
         when Powerpoint    =>
            return Starts_With (Name, "ppt/slides/slide")
              and then Ends_With (Name, ".xml");
         when Open_Document => return Name = "content.xml";
         when Epub          =>
            return Ends_With (Name, ".xhtml")
              or else Ends_With (Name, ".html")
              or else Ends_With (Name, ".htm");
      end case;
   end Wanted;

   --  Strip XML to the text between its tags: a tag becomes a space so words
   --  in neighbouring elements do not run together, and the handful of named
   --  and numeric entities become their characters.
   procedure Strip_XML (S : String; Into : in out U.Unbounded_String) is
      I : Integer := S'First;

      function Room return Boolean is (U.Length (Into) < Max_Output);

      procedure Put (C : Character) is
      begin
         if Room then
            U.Append (Into, C);
         end if;
      end Put;
   begin
      while I <= S'Last and then Room loop
         if S (I) = '<' then
            while I <= S'Last and then S (I) /= '>' loop
               I := I + 1;
            end loop;
            I := I + 1;
            Put (' ');

         elsif S (I) = '&' then
            declare
               J    : Integer := I + 1;
               Stop : Integer;
            begin
               while J <= S'Last and then J < I + 12
                 and then S (J) /= ';'
               loop
                  J := J + 1;
               end loop;
               if J <= S'Last and then S (J) = ';' then
                  Stop := J;
                  declare
                     Name : constant String := S (I + 1 .. Stop - 1);
                  begin
                     if Name = "amp" then
                        Put ('&');
                     elsif Name = "lt" then
                        Put ('<');
                     elsif Name = "gt" then
                        Put ('>');
                     elsif Name = "quot" then
                        Put ('"');
                     elsif Name = "apos" then
                        Put (''');
                     elsif Name'Length >= 2 and then Name (Name'First) = '#'
                     then
                        declare
                           Code : Integer := 0;
                        begin
                           if Name (Name'First + 1) in 'x' | 'X' then
                              for K in Name'First + 2 .. Name'Last loop
                                 case Name (K) is
                                    when '0' .. '9' =>
                                       Code := Code * 16
                                         + (Character'Pos (Name (K))
                                            - Character'Pos ('0'));
                                    when 'a' .. 'f' =>
                                       Code := Code * 16 + 10
                                         + (Character'Pos (Name (K))
                                            - Character'Pos ('a'));
                                    when 'A' .. 'F' =>
                                       Code := Code * 16 + 10
                                         + (Character'Pos (Name (K))
                                            - Character'Pos ('A'));
                                    when others => null;
                                 end case;
                              end loop;
                           else
                              for K in Name'First + 1 .. Name'Last loop
                                 if Name (K) in '0' .. '9' then
                                    Code := Code * 10
                                      + (Character'Pos (Name (K))
                                         - Character'Pos ('0'));
                                 end if;
                              end loop;
                           end if;
                           if Code in 1 .. 127 then
                              Put (Character'Val (Code));
                           else
                              Put (' ');
                           end if;
                        end;
                     else
                        Put (' ');
                     end if;
                  end;
                  I := Stop + 1;
               else
                  Put ('&');
                  I := I + 1;
               end if;
            end;

         else
            Put (S (I));
            I := I + 1;
         end if;
      end loop;
   end Strip_XML;

   ------------------
   -- Extract_Text --
   ------------------

   function Extract_Text (Raw : String; Kind : Document_Kind) return String is
      Out_Buf : U.Unbounded_String;

      --  Find the end-of-central-directory record, scanning back from the
      --  end over the range it may lie in (its own 22 bytes plus a comment).
      function Find_EOCD return Natural is
         Lowest : constant Integer :=
           Integer'Max (Raw'First, Raw'Last - 66_000);
      begin
         if Raw'Length < 22 then
            return 0;
         end if;
         for P in reverse Lowest .. Raw'Last - 3 loop
            if Sig (Raw, P, Character'Val (5), Character'Val (6)) then
               return P;
            end if;
         end loop;
         return 0;
      end Find_EOCD;

      EOCD : constant Natural := Find_EOCD;
   begin
      if EOCD = 0 then
         return "";
      end if;

      declare
         Count    : constant Natural := U16 (Raw, EOCD + 10);
         CD_Off   : constant Long_Long_Integer := U32 (Raw, EOCD + 16);
         CD_Start : constant Long_Long_Integer :=
           Long_Long_Integer (Raw'First) + CD_Off;
         C : Integer;
      begin
         if CD_Start < Long_Long_Integer (Raw'First)
           or else CD_Start > Long_Long_Integer (Raw'Last)
         then
            return "";
         end if;
         C := Integer (CD_Start);

         for Index in 1 .. Count loop
            exit when U.Length (Out_Buf) >= Max_Output;
            exit when C + 45 > Raw'Last;
            exit when not Sig (Raw, C, Character'Val (1), Character'Val (2));

            declare
               Method    : constant Natural := U16 (Raw, C + 10);
               Comp_Size : constant Long_Long_Integer := U32 (Raw, C + 20);
               Name_Len  : constant Natural := U16 (Raw, C + 28);
               Extra_Len : constant Natural := U16 (Raw, C + 30);
               Cmt_Len   : constant Natural := U16 (Raw, C + 32);
               Local_Off : constant Long_Long_Integer := U32 (Raw, C + 42);
               Name_From : constant Integer := C + 46;
               Name_To   : constant Integer := C + 46 + Name_Len - 1;
            begin
               if Name_To <= Raw'Last
                 and then Wanted (Kind, Raw (Name_From .. Name_To))
                 and then Local_Off >= 0
                 and then Local_Off < Long_Long_Integer (Raw'Last)
               then
                  declare
                     Lp : constant Integer :=
                       Integer (Long_Long_Integer (Raw'First) + Local_Off);
                  begin
                     if Sig (Raw, Lp, Character'Val (3), Character'Val (4))
                     then
                        declare
                           LN : constant Natural := U16 (Raw, Lp + 26);
                           LE : constant Natural := U16 (Raw, Lp + 28);
                           Data_From : constant Integer := Lp + 30 + LN + LE;
                           Data_To   : constant Long_Long_Integer :=
                             Long_Long_Integer (Data_From) + Comp_Size - 1;
                        begin
                           if Comp_Size > 0
                             and then Data_From >= Raw'First
                             and then Data_To <= Long_Long_Integer (Raw'Last)
                           then
                              declare
                                 Data : String renames
                                   Raw (Data_From .. Integer (Data_To));
                                 XML  : constant String :=
                                   (if Method = 0 then Data
                                    elsif Method = 8 then Inflate_Raw (Data)
                                    else "");
                              begin
                                 Strip_XML (XML, Out_Buf);
                                 U.Append (Out_Buf, ' ');
                              end;
                           end if;
                        end;
                     end if;
                  end;
               end if;

               C := C + 46 + Name_Len + Extra_Len + Cmt_Len;
            end;
         end loop;
      end;

      return Model_Runner.Tools.Text_Util.Collapse_Blanks
        (U.To_String (Out_Buf));
   end Extract_Text;

end Model_Runner.Tools.OOXML;
