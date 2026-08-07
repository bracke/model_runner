with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with System.Multiprocessors;

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
      if All_Locales /= "" then
         return All_Locales;
      else
         return Language;
      end if;
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
      --  Asked of hostkit, which knows where each host keeps the answer:
      --  /proc/self/exe, _NSGetExecutablePath, GetModuleFileName. This used
      --  to read procfs directly, which is Linux and not even macOS, so on
      --  every other host it fell through to the command name and an
      --  installed catalog beside the executable was never found.
      declare
         Target : constant String := Hostkit.Host.Executable_Path;
      begin
         if Target /= "" and then Ada.Directories.Exists (Target) then
            return Ada.Directories.Containing_Directory (Target);
         end if;
      end;

      --  Empty is hostkit declining to guess, not an error; the command name
      --  is the honest fallback.

      declare
         Command : constant String := Ada.Command_Line.Command_Name;
      begin
         if Command = "" then
            return "";
         else
            return Ada.Directories.Containing_Directory
              (Ada.Directories.Full_Name (Command));
         end if;
      end;
   exception
      when others =>
         return "";
   end Executable_Directory;

   -------------------
   -- Catalog_Path --
   -------------------

   function Catalog_Path return String is
      Directory : constant String := Executable_Directory;

      function Joined (Parts : String) return String
      is (Parts);

      function Existing (Path : String) return String is
      begin
         if Path /= "" and then Ada.Directories.Exists (Path) then
            return Path;
         else
            return "";
         end if;
      end Existing;

      Conventional : constant String := "resources/messages/catalog.txt";
   begin
      if Directory /= "" then
         --  Installed layout: <prefix>/bin/model_runner alongside
         --  <prefix>/share/model_runner/messages/catalog.txt.
         declare
            Installed : constant String :=
              Existing
                (Directory & "/../share/" & Model_Runner.Program_Name
                 & "/messages/catalog.txt");
         begin
            if Installed /= "" then
               return Installed;
            end if;
         end;

         declare
            Shared : constant String :=
              Existing
                (Directory & "/../share/" & Model_Runner.Program_Name
                 & "/resources/messages/catalog.txt");
         begin
            if Shared /= "" then
               return Shared;
            end if;
         end;

         --  Development layout: bin/model_runner alongside resources/.
         declare
            Development : constant String :=
              Existing (Directory & "/../" & Conventional);
         begin
            if Development /= "" then
               return Development;
            end if;
         end;
      end if;

      declare
         Local : constant String := Existing (Conventional);
      begin
         if Local /= "" then
            return Local;
         end if;
      end;

      declare
         Above : constant String := Existing ("../" & Conventional);
      begin
         if Above /= "" then
            return Above;
         end if;
      end;

      return Joined (Conventional);
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

end Model_Runner.Platform;
