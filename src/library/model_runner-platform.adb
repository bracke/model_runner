with Ada.Directories;
with Ada.Text_IO;
with Ada.Environment_Variables;
with System.Multiprocessors;

with Hostkit.Fs;
with Hostkit.Host;

with Model_Runner.Text;

package body Model_Runner.Platform is


   -----------------
   -- Is_Terminal --
   -----------------

   --  Asked through hostkit rather than by importing isatty here. The C name
   --  is spelled _isatty on Windows and the console is asked about through
   --  GetConsoleMode instead, so an import by that name is a POSIX assumption
   --  wearing a portable-looking coat. hostkit keeps one body per host.
   function Is_Terminal (Descriptor : Natural) return Boolean is
   begin
      return Hostkit.Host.Is_Terminal
        (case Descriptor is
            when 0 => Hostkit.Host.Standard_Input,
            when 1 => Hostkit.Host.Standard_Output,
            when others => Hostkit.Host.Standard_Error);
   end Is_Terminal;

   ---------------------------
   -- No_Color_Requested --
   ---------------------------

   function No_Color_Requested return Boolean
   is (Environment_Exists ("NO_COLOR"));

   -------------------------
   -- Environment_Value --
   -------------------------

   function Environment_Value (Name : String) return String is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         return Ada.Environment_Variables.Value (Name);
      else
         return "";
      end if;
   exception
      when others =>
         return "";
   end Environment_Value;

   --------------------------
   -- Environment_Exists --
   --------------------------

   function Environment_Exists (Name : String) return Boolean is
   begin
      return Ada.Environment_Variables.Exists (Name);
   exception
      when others =>
         return False;
   end Environment_Exists;

   -----------------
   -- Host_Locale --
   -----------------

   function Host_Locale return String is
      All_Locales : constant String := Environment_Value ("LC_ALL");
      Language    : constant String := Environment_Value ("LANG");
   begin
      --  The environment first, because a variable somebody set is a
      --  statement about what they want, and on POSIX it is the only answer
      --  there is.
      if All_Locales /= "" then
         return All_Locales;
      elsif Language /= "" then
         return Language;
      end if;

      --  Then the host itself. Windows keeps a user locale and answers it;
      --  POSIX has no such call and hostkit says so with an empty string,
      --  meaning "ask the environment" rather than "no locale" -- which is
      --  what was just done. Reading only LC_ALL and LANG meant this crate
      --  never found a Windows user's locale at all: neither is set there, so
      --  it fell through to the default and their own language was never
      --  looked for.
      return Hostkit.Host.Native_Locale;
   exception
      when others =>
         return "";
   end Host_Locale;

   ---------------
   -- Host_Name --
   ---------------

   function Host_Name return String
   is (Model_Runner.Text.To_Lower
         (Hostkit.Host.Kind'Image (Hostkit.Host.Current)));

   ---------------------------
   -- Executable_Directory --
   ---------------------------

   function Executable_Directory return String is
   begin
      --  Asked of hostkit, which knows both where each host keeps the answer
      --  -- /proc/self/exe, _NSGetExecutablePath, GetModuleFileName -- and
      --  how to take the directory off it. Taking it off here would be this
      --  crate deciding what a path looks like, which is the question hostkit
      --  exists to answer.
      --
      --  Empty is hostkit declining to guess rather than an error; the caller
      --  falls back to looking beside the working directory.
      return Hostkit.Fs.Own_Executable_Directory;
   exception
      when others =>
         return "";
   end Executable_Directory;

   function Catalog_Path return String is
      Directory : constant String := Executable_Directory;

      --  Joined by hostkit, which writes the separator this host writes.
      --  Concatenating one here worked on the hosts it was tried on and was
      --  still this crate deciding what a path looks like.
      function Under (Base : String; Part : String) return String
        renames Hostkit.Fs.Join;

      function Existing (Path : String) return String is
      begin
         if Path /= "" and then Ada.Directories.Exists (Path) then
            return Path;
         else
            return "";
         end if;
      end Existing;

      --  Where the repository keeps the catalog, and where an installation
      --  keeps it: <prefix>/share/model_runner/messages/catalog.txt.
      Conventional : constant String :=
        Under (Under ("resources", "messages"), "catalog.txt");

      Installed_Tail : constant String :=
        Under (Under (Under ("share", Model_Runner.Program_Name), "messages"),
               "catalog.txt");

      Shared_Tail : constant String :=
        Under (Under ("share", Model_Runner.Program_Name), Conventional);
   begin
      if Directory /= "" then
         declare
            --  The prefix is the directory above the one holding the program,
            --  which is Containing_Directory rather than a ".." segment
            --  spelled by hand.
            Prefix : constant String :=
              Ada.Directories.Containing_Directory (Directory);

            Installed   : constant String :=
              Existing (Under (Prefix, Installed_Tail));
            Shared      : constant String :=
              Existing (Under (Prefix, Shared_Tail));
            Development : constant String :=
              Existing (Under (Prefix, Conventional));
         begin
            if Installed /= "" then
               return Installed;
            elsif Shared /= "" then
               return Shared;
            elsif Development /= "" then
               return Development;
            end if;
         end;
      end if;

      declare
         Local : constant String := Existing (Conventional);
         Above : constant String :=
           Existing
             (Under (Ada.Directories.Containing_Directory
                       (Ada.Directories.Current_Directory),
                     Conventional));
      begin
         if Local /= "" then
            return Local;
         elsif Above /= "" then
            return Above;
         end if;
      end;

      return Conventional;
   exception
      when others =>
         return Conventional;
   end Catalog_Path;

   ---------------------
   -- Processor_Count --
   ---------------------

   function Processor_Count return Positive is
      use type System.Multiprocessors.CPU_Range;
      Count : constant System.Multiprocessors.CPU_Range :=
        System.Multiprocessors.Number_Of_CPUs;
   begin
      return (if Count < 1 then 1 else Positive (Count));
   exception
      when others =>
         return 1;
   end Processor_Count;

   ----------------
   -- Core_Count --
   ----------------

   function Core_Count return Positive is
      Processors : constant Positive := Processor_Count;

      --  The host describes its topology under this directory, one entry per
      --  processor, each naming every processor that shares its core. The
      --  entry for processor three of a pair reading "2,3" is the same text
      --  as the entry for processor two, so counting the entries that begin
      --  with their own number counts each core exactly once.
      --
      --  This is where Linux keeps it. Everywhere else the directory is
      --  absent, the first read fails, and the processor count stands -- the
      --  same answer this returned before the directory was consulted.
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
               return Processors;
            end if;

            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

            declare
               --  Bounded: a line longer than this is not a sibling list this
               --  understands, and is treated as a host that did not answer.
               Line : String (1 .. 512);
               Last : Natural;
               Stop : Natural;
            begin
               Ada.Text_IO.Get_Line (File, Line, Last);
               Ada.Text_IO.Close (File);

               --  The leading number, which is the lowest processor sharing
               --  this core.
               Stop := Line'First - 1;
               for Position in Line'First .. Last loop
                  exit when Line (Position) not in '0' .. '9';
                  Stop := Position;
               end loop;

               if Stop < Line'First then
                  return Processors;
               end if;

               if Integer'Value (Line (Line'First .. Stop)) = Index then
                  Found := Found + 1;
               end if;
            end;
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               return Processors;
         end;
      end loop;

      --  A count of zero, or one above the processor count, means the reading
      --  was not understood rather than that the machine is unusual.
      if Found < 1 or else Found > Processors then
         return Processors;
      end if;

      return Found;
   exception
      when others =>
         return Processor_Count;
   end Core_Count;

end Model_Runner.Platform;
