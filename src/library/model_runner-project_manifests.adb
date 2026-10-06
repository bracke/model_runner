with Ada.Characters.Handling;

package body Model_Runner.Project_Manifests is

   use Ada.Characters.Handling;

   function Is_Blank (C : Character) return Boolean
   is (C in ' ' | ASCII.HT | ASCII.CR | ASCII.LF);

   -----------------------------
   -- Alire_Names_Executables --
   -----------------------------

   function Alire_Names_Executables (Text : String) return Boolean is
      I        : Natural := Text'First;
      At_Start : Boolean := True;   --  at the first non-blank of a line
      In_Table : Boolean := False;  --  past a [table] header

      --  Past a comment to the end of its line.
      procedure Skip_Comment is
      begin
         while I <= Text'Last and then Text (I) /= ASCII.LF loop
            I := I + 1;
         end loop;
      end Skip_Comment;

      --  Past a string beginning at I, its escapes in a basic one.
      procedure Skip_String is
         Quote : constant Character := Text (I);
      begin
         I := I + 1;
         while I <= Text'Last and then Text (I) /= Quote loop
            if Quote = '"' and then Text (I) = '\' then
               I := I + 1;
            end if;
            I := I + 1;
         end loop;
         I := I + 1;
      end Skip_String;

      --  The key beginning at I on a line, bare or quoted; empty when the
      --  line holds none.
      function Key_Here return String is
         First : constant Natural := I;
      begin
         if Text (I) in '"' | ''' then
            Skip_String;
            return Text (First + 1 .. I - 2);
         end if;
         while I <= Text'Last
           and then (Is_Alphanumeric (Text (I)) or else Text (I) in '_' | '-')
         loop
            I := I + 1;
         end loop;
         return Text (First .. I - 1);
      end Key_Here;

      --  Whether the array value beginning at I holds a string.
      function Array_Holds_String return Boolean is
         Depth : Natural := 0;
      begin
         while I <= Text'Last loop
            case Text (I) is
               when '#' =>
                  Skip_Comment;
               when '"' | ''' =>
                  return Depth > 0;
               when '[' =>
                  Depth := Depth + 1;
                  I := I + 1;
               when ']' =>
                  Depth := Depth - 1;
                  I := I + 1;
                  exit when Depth = 0;
               when others =>
                  I := I + 1;
            end case;
         end loop;
         return False;
      end Array_Holds_String;
   begin
      while I <= Text'Last loop
         if Text (I) = ASCII.LF then
            At_Start := True;
            I := I + 1;
         elsif Is_Blank (Text (I)) then
            I := I + 1;
         elsif Text (I) = '#' then
            Skip_Comment;
         elsif At_Start and then Text (I) = '[' then
            --  A table header: every key after it is the table's.
            In_Table := True;
            Skip_Comment;
         elsif At_Start and then not In_Table then
            At_Start := False;
            declare
               Key : constant String := Key_Here;
            begin
               while I <= Text'Last and then Text (I) in ' ' | ASCII.HT loop
                  I := I + 1;
               end loop;
               if Key = "executables" and then I <= Text'Last and then Text (I) = '=' then
                  I := I + 1;
                  while I <= Text'Last and then Is_Blank (Text (I)) loop
                     I := I + 1;
                  end loop;
                  return I <= Text'Last and then Text (I) = '[' and then Array_Holds_String;
               end if;
               --  Any other key's value, to the end of its line or of its
               --  array, strings and all.
               declare
                  Depth : Natural := 0;
               begin
                  while I <= Text'Last and then (Depth > 0 or else Text (I) /= ASCII.LF) loop
                     case Text (I) is
                        when '"' | ''' =>
                           Skip_String;
                        when '#' =>
                           Skip_Comment;
                        when '[' | '{' =>
                           Depth := Depth + 1;
                           I := I + 1;
                        when ']' | '}' =>
                           Depth := Natural'Max (Depth, 1) - 1;
                           I := I + 1;
                        when others =>
                           I := I + 1;
                     end case;
                  end loop;
               end;
            end;
         else
            At_Start := False;
            I := I + 1;
         end if;
      end loop;
      return False;
   end Alire_Names_Executables;

   --------------------
   -- Gpr_Names_Main --
   --------------------

   function Gpr_Names_Main (Text : String) return Boolean is
      I : Natural := Text'First;

      type Token_Kind is (Word, Literal, Symbol, Finished);
      Kind  : Token_Kind := Finished;
      First : Natural := 0;
      Last  : Natural := 0;

      --  The next token: a word, a string literal or one character.
      procedure Next is
      begin
         loop
            while I <= Text'Last and then Is_Blank (Text (I)) loop
               I := I + 1;
            end loop;
            exit when I + 1 > Text'Last or else Text (I .. I + 1) /= "--";
            while I <= Text'Last and then Text (I) /= ASCII.LF loop
               I := I + 1;
            end loop;
         end loop;
         if I > Text'Last then
            Kind := Finished;
            return;
         end if;
         First := I;
         if Text (I) = '"' then
            I := I + 1;
            loop
               exit when I > Text'Last;
               if Text (I) = '"' then
                  exit when I = Text'Last or else Text (I + 1) /= '"';
                  I := I + 1;
               end if;
               I := I + 1;
            end loop;
            I := I + 1;
            Kind := Literal;
         elsif Is_Letter (Text (I)) then
            while I <= Text'Last
              and then (Is_Alphanumeric (Text (I)) or else Text (I) in '_' | '.')
            loop
               I := I + 1;
            end loop;
            Kind := Word;
         else
            I := I + 1;
            Kind := Symbol;
         end if;
         Last := I - 1;
      end Next;

      function Is_Word (Wanted : String) return Boolean
      is (Kind = Word and then To_Lower (Text (First .. Last)) = Wanted);
   begin
      Next;
      while Kind /= Finished loop
         if Is_Word ("for") then
            Next;
            if Is_Word ("main") then
               Next;
               if Is_Word ("use") then
                  Next;
                  --  A list: a main where it holds a string. Anything else
                  --  -- another project's Main -- names one too.
                  if Kind = Symbol and then Text (First) = '(' then
                     loop
                        Next;
                        exit when Kind = Finished
                          or else (Kind = Symbol and then Text (First) = ')');
                        if Kind = Literal then
                           return True;
                        end if;
                     end loop;
                  elsif Kind /= Finished then
                     return True;
                  end if;
               end if;
            end if;
         else
            Next;
         end if;
      end loop;
      return False;
   end Gpr_Names_Main;

end Model_Runner.Project_Manifests;
