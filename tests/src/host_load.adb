with Ada.Directories;
with Ada.Text_IO;

package body Host_Load is

   Where : constant String := "/proc/loadavg";

   ------------------------
   -- Processor_Seconds --
   ------------------------

   function Processor_Seconds return Long_Float is
      Where : constant String := "/proc/self/stat";
      Handle : Ada.Text_IO.File_Type;

      --  User and system ticks are the fourteenth and fifteenth fields, and
      --  the ticks a second are a hundred on every host this runs on. The
      --  process name is the second field and can hold spaces inside its
      --  brackets, so the count starts after the closing bracket rather
      --  than at the beginning of the line.
      User_Field : constant := 14;
      Sys_Field  : constant := 15;
      Per_Second : constant := 100.0;
   begin
      if not Ada.Directories.Exists (Where) then
         return 0.0;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Where);

      declare
         Line : constant String := Ada.Text_IO.Get_Line (Handle);
         From : Natural := Line'First;
         Seen : Natural := 2;
         Ticks : Long_Float := 0.0;
      begin
         Ada.Text_IO.Close (Handle);

         --  Past the bracketed name.
         while From <= Line'Last and then Line (From) /= ')' loop
            From := From + 1;
         end loop;

         while From <= Line'Last loop
            while From <= Line'Last and then Line (From) = ' ' loop
               From := From + 1;
            end loop;
            exit when From > Line'Last;

            declare
               Stop : Natural := From;
            begin
               while Stop <= Line'Last and then Line (Stop) /= ' ' loop
                  Stop := Stop + 1;
               end loop;

               Seen := Seen + 1;
               if Seen = User_Field or else Seen = Sys_Field then
                  Ticks := Ticks
                    + Long_Float'Value (Line (From .. Stop - 1));
               end if;

               exit when Seen > Sys_Field;
               From := Stop;
            end;
         end loop;

         return Ticks / Per_Second;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return 0.0;
   end Processor_Seconds;

   ---------
   -- Now --
   ---------

   function Now return Long_Float is
      Handle : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Where) then
         return 0.0;
      end if;

      Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Where);

      declare
         Line : constant String := Ada.Text_IO.Get_Line (Handle);
         Stop : Natural := Line'First;
      begin
         Ada.Text_IO.Close (Handle);

         --  The first field, which is the minute's average. The rest of the
         --  line is the five and fifteen minute averages and a count of
         --  processes, none of which says anything about a run that takes
         --  seconds.
         while Stop <= Line'Last and then Line (Stop) /= ' ' loop
            Stop := Stop + 1;
         end loop;

         return Long_Float'Value (Line (Line'First .. Stop - 1));
      end;
   exception
      --  A host that has the file and will not give it up is a host that
      --  keeps no load average as far as this is concerned.
      when others =>
         if Ada.Text_IO.Is_Open (Handle) then
            Ada.Text_IO.Close (Handle);
         end if;
         return 0.0;
   end Now;

end Host_Load;
