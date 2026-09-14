with Ada.Strings.Unbounded;

with Model_Runner.Tools.Text_Util;

package body Model_Runner.Tools.RTF is

   package U renames Ada.Strings.Unbounded;

   Max_Output : constant := 512 * 1024;
   Max_Depth  : constant := 256;

   --  Groups whose text is not document text and is skipped whole.
   function Is_Destination (Word : String) return Boolean
   is (Word = "fonttbl" or else Word = "colortbl"
       or else Word = "stylesheet" or else Word = "info"
       or else Word = "pict" or else Word = "fldinst"
       or else Word = "themedata" or else Word = "colorschememapping"
       or else Word = "latentstyles" or else Word = "datastore"
       or else Word = "listtable" or else Word = "listoverridetable");

   ------------------
   -- Extract_Text --
   ------------------

   function Extract_Text (Raw : String) return String is
      Out_Buf : U.Unbounded_String;
      I       : Integer := Raw'First;

      Depth   : Natural := 0;
      Ignore  : array (0 .. Max_Depth) of Boolean := [others => False];
      Fresh   : Boolean := False;   --  at the first token of a new group

      function Room return Boolean is (U.Length (Out_Buf) < Max_Output);

      procedure Put (C : Character) is
      begin
         if Room and then not Ignore (Depth) then
            U.Append (Out_Buf, C);
         end if;
      end Put;

      function Hex (C : Character) return Integer
      is (case C is
             when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
             when 'a' .. 'f' => 10 + Character'Pos (C) - Character'Pos ('a'),
             when 'A' .. 'F' => 10 + Character'Pos (C) - Character'Pos ('A'),
             when others     => -1);
   begin
      if Raw'Length < 5
        or else Raw (Raw'First .. Raw'First + 4) /= "{\rtf"
      then
         return "";
      end if;

      while I <= Raw'Last and then Room loop
         case Raw (I) is
            when '{' =>
               if Depth < Max_Depth then
                  Depth := Depth + 1;
                  Ignore (Depth) := Ignore (Depth - 1);
               end if;
               Fresh := True;
               I := I + 1;

            when '}' =>
               if Depth > 0 then
                  Depth := Depth - 1;
               end if;
               I := I + 1;

            when '\' =>
               if I + 1 > Raw'Last then
                  I := I + 1;
               elsif Raw (I + 1) = '*' then
                  Ignore (Depth) := True;
                  Fresh := False;
                  I := I + 2;
               elsif Raw (I + 1) in '\' | '{' | '}' then
                  Put (Raw (I + 1));
                  Fresh := False;
                  I := I + 2;
               elsif Raw (I + 1) = ''' and then I + 3 <= Raw'Last then
                  declare
                     Hi : constant Integer := Hex (Raw (I + 2));
                     Lo : constant Integer := Hex (Raw (I + 3));
                  begin
                     if Hi >= 0 and then Lo >= 0 then
                        Put (Character'Val (Hi * 16 + Lo));
                     end if;
                  end;
                  Fresh := False;
                  I := I + 4;
               elsif Raw (I + 1) in 'a' .. 'z' | 'A' .. 'Z' then
                  --  A control word: letters, then an optional signed number.
                  declare
                     Name_From : constant Integer := I + 1;
                     J         : Integer := I + 1;
                     Has_Param : Boolean := False;
                     Neg       : Boolean := False;
                     Param     : Integer := 0;
                  begin
                     while J <= Raw'Last
                       and then Raw (J) in 'a' .. 'z' | 'A' .. 'Z'
                     loop
                        J := J + 1;
                     end loop;
                     declare
                        Word : constant String := Raw (Name_From .. J - 1);
                     begin
                        if J <= Raw'Last and then Raw (J) = '-' then
                           Neg := True;
                           J := J + 1;
                        end if;
                        while J <= Raw'Last and then Raw (J) in '0' .. '9' loop
                           Has_Param := True;
                           Param := Param * 10
                             + (Character'Pos (Raw (J)) - Character'Pos ('0'));
                           J := J + 1;
                        end loop;
                        if Neg then
                           Param := -Param;
                        end if;

                        --  One space after a control word is its delimiter
                        --  and is not text.
                        if J <= Raw'Last and then Raw (J) = ' ' then
                           J := J + 1;
                        end if;

                        if Fresh and then Is_Destination (Word) then
                           Ignore (Depth) := True;
                        end if;

                        if Word = "par" or else Word = "line"
                          or else Word = "sect" or else Word = "page"
                        then
                           Put (ASCII.LF);
                        elsif Word = "tab" or else Word = "cell"
                          or else Word = "row"
                        then
                           Put (' ');
                        elsif Word = "u" and then Has_Param then
                           if Param in 1 .. 127 then
                              Put (Character'Val (Param));
                           else
                              Put (' ');
                           end if;
                           --  Skip the fallback character that follows a \u.
                           if J <= Raw'Last
                             and then Raw (J) not in '\' | '{' | '}'
                           then
                              J := J + 1;
                           end if;
                        end if;

                        Fresh := False;
                        I := J;
                     end;
                  end;
               else
                  --  A control symbol other than the ones above; skip it.
                  Fresh := False;
                  I := I + 2;
               end if;

            when ASCII.CR | ASCII.LF =>
               --  Line breaks in the source are not text.
               I := I + 1;

            when others =>
               Put (Raw (I));
               Fresh := False;
               I := I + 1;
         end case;
      end loop;

      return Model_Runner.Tools.Text_Util.Collapse_Blanks
        (U.To_String (Out_Buf));
   end Extract_Text;

end Model_Runner.Tools.RTF;
