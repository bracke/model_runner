with Ada.Directories;
with Ada.Text_IO;

with Hostkit.Host;

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

      --  Which processors this process may run on, where the host says:
      --  a core is counted only where one of its processors is usable,
      --  so a run held to four processors by `taskset` or a cpuset counts
      --  the cores of those four, not of the machine.
      Usable : Hostkit.Host.Processor_Set;
      Known  : constant Boolean := Hostkit.Host.Usable_Processors (Usable);

      --  A core is named by the first processor its sibling list names.
      Counted : array (Hostkit.Host.Processor_Set'Range) of Boolean :=
        [others => False];
      Found : Natural := 0;
   begin
      for Index in Hostkit.Host.Processor_Set'Range loop
         if not Known or else Usable (Index) then
            declare
               Path : constant String :=
                 Root & Model_Runner.Text.Trim (Integer'Image (Index)) & Tail;
               File : Ada.Text_IO.File_Type;
            begin
               --  Absent where the processor is offline, or past the last:
               --  skipped, not taken for an answer of nought -- a machine
               --  with one core offline counted its threads instead.
               if Ada.Directories.Exists (Path) then
                  Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

                  declare
                     --  Bounded. A line longer than this is not a sibling
                     --  list this understands, and an answer not understood
                     --  is no answer.
                     Line  : String (1 .. 512);
                     Last  : Natural;
                     Named : Integer;
                  begin
                     Ada.Text_IO.Get_Line (File, Line, Last);
                     Ada.Text_IO.Close (File);

                     --  The first processor the line names. The rule itself
                     --  lives in Model_Runner.Text, where a test can hand it
                     --  a string; here there is only a file no test can
                     --  write.
                     Named := Model_Runner.Text.Leading_Number
                                (Line (Line'First .. Last));

                     if Named not in Counted'Range then
                        return 0;
                     end if;

                     if not Counted (Named) then
                        Counted (Named) := True;
                        Found := Found + 1;
                     end if;
                  end;
               elsif Known then
                  --  A processor the process may use with no topology to
                  --  read: an answer this does not understand.
                  return 0;
               end if;
            exception
               when others =>
                  if Ada.Text_IO.Is_Open (File) then
                     Ada.Text_IO.Close (File);
                  end if;
                  return 0;
            end;
         end if;
      end loop;

      return (if Found in 1 .. Processors then Found else 0);
   exception
      when others =>
         return 0;
   end Physical_Cores;

   ------------------
   -- Meminfo_Line --
   ------------------

   --  A line of /proc/meminfo, in kilobytes, as bytes: the file the kernel
   --  publishes, and zero for anything unexpected.
   function Meminfo_Line (Name : String) return Interfaces.Unsigned_64 is
      use type Interfaces.Unsigned_64;

      Path : constant String := "/proc/meminfo";
      File : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Path) then
         return 0;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

      declare
         Line : String (1 .. 512);
         Last : Natural;
      begin
         while not Ada.Text_IO.End_Of_File (File) loop
            Ada.Text_IO.Get_Line (File, Line, Last);

            if Last > Name'Length
              and then Line (1 .. Name'Length) = Name
            then
               declare
                  Named : constant Integer :=
                    Model_Runner.Text.Leading_Number
                      (Model_Runner.Text.Trim
                         (Line (Name'Length + 1 .. Last)));
               begin
                  Ada.Text_IO.Close (File);
                  return (if Named > 0
                          then Interfaces.Unsigned_64 (Named) * 1024
                          else 0);
               end;
            end if;
         end loop;
      end;

      Ada.Text_IO.Close (File);
      return 0;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return 0;
   end Meminfo_Line;

   ---------------------
   -- Physical_Memory --
   ---------------------

   --  MemTotal, the first line.
   function Physical_Memory return Interfaces.Unsigned_64 is
     (Meminfo_Line ("MemTotal:"));

   ----------------------
   -- Available_Memory --
   ----------------------

   --  MemAvailable: the kernel's own estimate of what can be handed out
   --  without swapping, reclaimable cache included.
   function Available_Memory return Interfaces.Unsigned_64 is
     (Meminfo_Line ("MemAvailable:"));

end Model_Runner.Platform.Topology;
