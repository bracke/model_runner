with Ada.Strings.Unbounded;

with Model_Runner.UTF8;

package body Model_Runner.Tools.Text_Util is

   package U renames Ada.Strings.Unbounded;

   Max_Output : constant := 512 * 1024;

   function Collapse_Blanks (S : String) return String is
      R          : String (1 .. S'Length);
      N          : Natural := 0;
      Prev_Blank : Boolean := True;   --  true so leading blanks are dropped

      function Blank (C : Character) return Boolean
      is (C = ' ' or else C = ASCII.HT
          or else C = ASCII.CR or else C = ASCII.LF);
   begin
      for C of S loop
         if Blank (C) then
            if not Prev_Blank then
               N := N + 1;
               R (N) := ' ';
               Prev_Blank := True;
            end if;
         else
            N := N + 1;
            R (N) := C;
            Prev_Blank := False;
         end if;
      end loop;

      if N > 0 and then R (N) = ' ' then
         N := N - 1;
      end if;
      return R (1 .. N);
   end Collapse_Blanks;

   ----------------
   -- Strip_Tags --
   ----------------

   function Strip_Tags (S : String) return String is
      Out_Buf : U.Unbounded_String;
      I       : Integer := S'First;

      function Room return Boolean is (U.Length (Out_Buf) < Max_Output);

      procedure Put (C : Character) is
      begin
         if Room then
            U.Append (Out_Buf, C);
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
               J : Integer := I + 1;
            begin
               while J <= S'Last and then J < I + 12
                 and then S (J) /= ';'
               loop
                  J := J + 1;
               end loop;
               if J <= S'Last and then S (J) = ';' then
                  declare
                     Name : constant String := S (I + 1 .. J - 1);
                  begin
                     if Name = "amp" then
                        Put ('&');
                     elsif Name = "lt" then
                        Put ('<');
                     elsif Name = "gt" then
                        Put ('>');
                     elsif Name = "quot" then
                        Put ('"');
                     elsif Name = "apos" or else Name = "#39" then
                        Put (''');
                     elsif Name = "nbsp" then
                        Put (' ');
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
                  I := J + 1;
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

      return Collapse_Blanks (U.To_String (Out_Buf));
   end Strip_Tags;

   -------------------
   -- To_Valid_Utf8 --
   -------------------

   function To_Valid_Utf8 (S : String) return String is
      R    : String (1 .. S'Length);
      N    : Natural := 0;
      I    : Integer := S'First;
      Code : Natural;
      Len  : Natural;
   begin
      while I <= S'Last loop
         Model_Runner.UTF8.Decode_First (S (I .. S'Last), Code, Len);
         if Len > 0 then
            R (N + 1 .. N + Len) := S (I .. I + Len - 1);
            N := N + Len;
            I := I + Len;
         else
            --  A byte that begins no valid sequence: a space in its place.
            N := N + 1;
            R (N) := ' ';
            I := I + 1;
         end if;
      end loop;
      return R (1 .. N);
   end To_Valid_Utf8;

end Model_Runner.Tools.Text_Util;
