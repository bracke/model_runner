package body Model_Runner.Tools.Text_Util is

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

end Model_Runner.Tools.Text_Util;
