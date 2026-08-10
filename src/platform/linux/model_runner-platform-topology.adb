with Ada.Directories;
with Ada.Text_IO;

with Model_Runner.Text;

--  Core count on Linux, from the topology the kernel publishes.
--
--  Each processor has a file naming every processor that shares its core.
--  The file for the second processor of a pair holds the same text as the
--  file for the first, so counting the ones that name themselves first counts
--  each core exactly once. That works whether the machine is uniform or has
--  cores of different kinds, which counting siblings once and dividing would
--  not.
package body Model_Runner.Platform.Topology is

   ---------------------
   -- Physical_Cores --
   ---------------------

   function Physical_Cores (Processors : Positive) return Natural is
      Root : constant String := "/sys/devices/system/cpu/cpu";
      Tail : constant String := "/topology/thread_siblings_list";

      Found : Natural := 0;
   begin
      for Index in 0 .. Processors - 1 loop
         declare
            Path : constant String :=
              Root & Model_Runner.Text.Trim (Integer'Image (Index)) & Tail;
            File : Ada.Text_IO.File_Type;
         begin
            if not Ada.Directories.Exists (Path) then
               return 0;
            end if;

            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

            declare
               --  Bounded. A line longer than this is not a sibling list
               --  this understands, and an answer not understood is no
               --  answer.
               Line  : String (1 .. 512);
               Last  : Natural;
               Named : Integer;
            begin
               Ada.Text_IO.Get_Line (File, Line, Last);
               Ada.Text_IO.Close (File);

               --  The first processor the line names. The rule itself
               --  lives in Model_Runner.Text, where a test can hand it a
               --  string; here there is only a file no test can write.
               Named := Model_Runner.Text.Leading_Number
                          (Line (Line'First .. Last));

               if Named < 0 then
                  return 0;
               end if;

               if Named = Index then
                  Found := Found + 1;
               end if;
            end;
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               return 0;
         end;
      end loop;

      return (if Found in 1 .. Processors then Found else 0);
   exception
      when others =>
         return 0;
   end Physical_Cores;

end Model_Runner.Platform.Topology;
