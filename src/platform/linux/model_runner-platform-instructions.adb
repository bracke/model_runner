with Ada.Directories;
with Ada.Text_IO;

--  What the processor offers, from the flags the kernel publishes.
--
--  /proc/cpuinfo carries a flags line per processor, and the two names this
--  looks for are the two the four formats want: avx2 for the wide lanes and
--  the gather, bmi2 for the per-lane variable shift. Both or neither: a
--  processor with one and not the other is not one this has seen, and half
--  an answer is not an answer.
package body Model_Runner.Platform.Instructions is

   -------------------
   -- Wide_Vectors --
   -------------------

   function Wide_Vectors return Boolean is
      Path : constant String := "/proc/cpuinfo";
      File : Ada.Text_IO.File_Type;

      --  Whether Named stands in Line as a word of its own. The flags are
      --  space separated and one is a prefix of another -- avx and avx2 --
      --  so a substring search answers the wrong question.
      function Names (Line : String; Named : String) return Boolean is
      begin
         for First in Line'Range loop
            if First + Named'Length - 1 <= Line'Last
              and then Line (First .. First + Named'Length - 1) = Named
              and then (First = Line'First
                        or else Line (First - 1) = ' ')
              and then (First + Named'Length > Line'Last
                        or else Line (First + Named'Length) = ' ')
            then
               return True;
            end if;
         end loop;

         return False;
      end Names;

      Wide, Shifts : Boolean := False;
   begin
      if not Ada.Directories.Exists (Path) then
         return False;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            --  Bounded. A flags line runs to a few hundred characters on the
            --  widest processor this has met; a longer one is not a line
            --  this understands, and it is read and ignored rather than
            --  allowed to decide anything.
            Line : String (1 .. 4096);
            Last : Natural;
         begin
            Ada.Text_IO.Get_Line (File, Line, Last);

            if Last >= 5 and then Line (1 .. 5) = "flags" then
               Wide := Wide or else Names (Line (1 .. Last), "avx2");
               Shifts := Shifts or else Names (Line (1 .. Last), "bmi2");

               --  The first processor's line is enough: this program runs
               --  its workers wherever the operating system puts them, so a
               --  machine whose processors differ in what they offer is one
               --  where the baseline is the only safe answer -- and every
               --  such machine this has met reports the same flags on all of
               --  them anyway.
               exit;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return Wide and then Shifts;
   exception
      when others =>
         --  A host that cannot be read is a host that said nothing.
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         return False;
   end Wide_Vectors;

   --------------------
   -- Byte_Products --
   --------------------

   function Byte_Products return Boolean is
      Path : constant String := "/proc/cpuinfo";
      File : Ada.Text_IO.File_Type;

      function Names (Line : String; Named : String) return Boolean is
      begin
         for First in Line'Range loop
            if First + Named'Length - 1 <= Line'Last
              and then Line (First .. First + Named'Length - 1) = Named
              and then (First = Line'First
                        or else Line (First - 1) = ' ')
              and then (First + Named'Length > Line'Last
                        or else Line (First + Named'Length) = ' ')
            then
               return True;
            end if;
         end loop;

         return False;
      end Names;

      --  All four, or none. The byte dot product is an AVX-512 instruction
      --  and the compilation that uses it is built for x86-64-v4, which is
      --  the whole of that set rather than the one instruction: a processor
      --  answering yes to the dot product and no to the rest is one that
      --  compilation would fault on.
      Base, Wide, Length, Dots : Boolean := False;
   begin
      if not Ada.Directories.Exists (Path) then
         return False;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : String (1 .. 4096);
            Last : Natural;
         begin
            Ada.Text_IO.Get_Line (File, Line, Last);

            if Last >= 5 and then Line (1 .. 5) = "flags" then
               Base := Names (Line (1 .. Last), "avx512f");
               Wide := Names (Line (1 .. Last), "avx512bw");
               Length := Names (Line (1 .. Last), "avx512vl");
               Dots := Names (Line (1 .. Last), "avx512_vnni");
               exit;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return Base and then Wide and then Length and then Dots;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         return False;
   end Byte_Products;

end Model_Runner.Platform.Instructions;
