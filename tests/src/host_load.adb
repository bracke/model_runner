with Ada.Directories;
with Ada.Text_IO;

package body Host_Load is

   Where : constant String := "/proc/loadavg";

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
