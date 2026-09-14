with Ada.Strings.Unbounded;

package body Model_Runner.Tools.DOC is

   package U renames Ada.Strings.Unbounded;

   Max_Output : constant := 512 * 1024;
   Min_Run    : constant := 4;   --  shortest run kept, to shed short noise

   --  The eight-byte signature every OLE2 compound file opens with.
   Magic : constant String :=
     Character'Val (16#D0#) & Character'Val (16#CF#)
     & Character'Val (16#11#) & Character'Val (16#E0#)
     & Character'Val (16#A1#) & Character'Val (16#B1#)
     & Character'Val (16#1A#) & Character'Val (16#E1#);

   function Printable (C : Character) return Boolean
   is (C in ' ' .. '~' or else C = ASCII.HT);

   ------------------
   -- Extract_Text --
   ------------------

   function Extract_Text (Raw : String) return String is
      Out_Buf : U.Unbounded_String;
      I       : Integer := Raw'First;

      function Room return Boolean is (U.Length (Out_Buf) < Max_Output);
   begin
      if Raw'Length < Magic'Length
        or else Raw (Raw'First .. Raw'First + Magic'Length - 1) /= Magic
      then
         return "";
      end if;

      while I <= Raw'Last and then Room loop
         if Printable (Raw (I)) then
            --  How far a single-byte printable run reaches from here.
            declare
               Ascii_Len : Natural := 0;
               J         : Integer := I;
            begin
               while J <= Raw'Last and then Printable (Raw (J)) loop
                  Ascii_Len := Ascii_Len + 1;
                  J := J + 1;
               end loop;

               --  And how far a UTF-16LE run reaches: a printable byte, then
               --  a zero, repeating.
               declare
                  Wide_Len : Natural := 0;
                  K        : Integer := I;
               begin
                  while K + 1 <= Raw'Last
                    and then Printable (Raw (K))
                    and then Raw (K + 1) = ASCII.NUL
                  loop
                     Wide_Len := Wide_Len + 1;
                     K := K + 2;
                  end loop;

                  if Wide_Len >= Ascii_Len and then Wide_Len >= Min_Run then
                     for N in 0 .. Wide_Len - 1 loop
                        if Room then
                           U.Append (Out_Buf, Raw (I + 2 * N));
                        end if;
                     end loop;
                     U.Append (Out_Buf, ' ');
                     I := I + 2 * Wide_Len;
                  elsif Ascii_Len >= Min_Run then
                     for N in 0 .. Ascii_Len - 1 loop
                        if Room then
                           U.Append (Out_Buf, Raw (I + N));
                        end if;
                     end loop;
                     U.Append (Out_Buf, ' ');
                     I := I + Ascii_Len;
                  else
                     I := I + 1;
                  end if;
               end;
            end;
         else
            I := I + 1;
         end if;
      end loop;

      return U.To_String (Out_Buf);
   end Extract_Text;

end Model_Runner.Tools.DOC;
