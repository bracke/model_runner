with Ada.Directories;
with Ada.Text_IO;

with Model_Runner.Platform.X86_Features;

--  What the processor and Linux together allow this process to execute.
--  CPUID plus XGETBV is the authority for multiversioned x86 code.  Kernel
--  flag text is retained only for MONITORX/MWAITX, which has no separately
--  compiled ISA-level unit and is hidden by common hypervisors.
package body Model_Runner.Platform.Instructions is

   function Wide_Vectors return Boolean is
     (Model_Runner.Platform.X86_Features.Wide_Vectors);

   function Byte_Products return Boolean is
     (Model_Runner.Platform.X86_Features.Byte_Products);

   function Brain_Products return Boolean is
     (Model_Runner.Platform.X86_Features.Brain_Products);

   ----------------------
   -- Low_Power_Waits --
   ----------------------

   function Low_Power_Waits return Boolean is
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

      --  The kernel's name for MONITORX and MWAITX together: AMD's, from
      --  CPUID 8000_0001h ECX bit 29, and cleared where a hypervisor hides
      --  the pair -- which KVM does by default.
      Waits : Boolean := False;
   begin
      if not Ada.Directories.Exists (Path) then
         return False;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path, Form => "shared=no");

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : String (1 .. 4096);
            Last : Natural;
         begin
            Ada.Text_IO.Get_Line (File, Line, Last);

            if Last >= 5 and then Line (1 .. 5) = "flags" then
               Waits := Names (Line (1 .. Last), "mwaitx");
               exit;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return Waits;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         return False;
   end Low_Power_Waits;

end Model_Runner.Platform.Instructions;
