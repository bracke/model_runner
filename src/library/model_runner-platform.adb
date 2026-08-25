with Ada.Directories;
with Ada.Environment_Variables;
with System.Multiprocessors;

with Hostkit.Fs;
with Hostkit.Host;

with Model_Runner.Platform.Instructions;
with Model_Runner.Platform.Topology;
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

   -------------------
   -- Wide_Vectors --
   -------------------

   function Wide_Vectors return Boolean is
   begin
      return Model_Runner.Platform.Instructions.Wide_Vectors;
   exception
      when others =>
         return False;
   end Wide_Vectors;

   ---------------------
   -- Byte_Products --
   ---------------------

   function Byte_Products return Boolean is
   begin
      return Model_Runner.Platform.Instructions.Byte_Products;
   exception
      when others =>
         return False;
   end Byte_Products;

   ----------------
   -- Core_Count --
   ----------------

   function Core_Count return Positive is
      Processors : constant Positive := Processor_Count;
      Cores      : constant Natural :=
        Model_Runner.Platform.Topology.Physical_Cores (Processors);
   begin
      --  Zero is what a host body returns when it cannot say, and the
      --  processor count is the answer this gave before any host was asked.
      --  The range is checked here as well as there, because a body that is
      --  wrong about its host should not be able to set a worker count.
      return (if Cores in 1 .. Processors then Cores else Processors);
   exception
      when others =>
         return Processor_Count;
   end Core_Count;

end Model_Runner.Platform;
