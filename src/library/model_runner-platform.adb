with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Strings.Fixed;
with GNAT.OS_Lib;
with Ada.Strings.Unbounded;
with Ada.Directories;
with Ada.Environment_Variables;
with System.Multiprocessors;

with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Metadata;

with Model_Runner.Platform.Instructions;
with Model_Runner.Platform.Topology;
with Model_Runner.Text;

with Ada.Containers;
with Ada.Strings.Hash;

with Model_Runner.Config;

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

   --  One of the base directories the XDG specification names, as it says
   --  to read it: a relative value is invalid and is ignored, so that the
   --  default under HOME is used -- one relative to wherever the program
   --  happened to start put a cache there, and a trim that compared names
   --  never found the file it was keeping.
   function XDG_Value (Name : String) return String is
      Value : constant String := Environment_Value (Name);
   begin
      return (if Value /= "" and then GNAT.OS_Lib.Is_Absolute_Path (Value)
              then Value else "");
   end XDG_Value;

   --------------------------
   -- Environment_Exists --
   --------------------------

   function Search_Path return String
   is (if Environment_Exists ("PATH") then Environment_Value ("PATH") else "");

   function Environment_Exists (Name : String) return Boolean is
   begin
      return Ada.Environment_Variables.Exists (Name);
   exception
      when others =>
         return False;
   end Environment_Exists;

   ---------------
   -- Hub_Token --
   ---------------

   function Hub_Token return String is
   begin
      return Environment_Value ("HF_TOKEN");
   end Hub_Token;

   ---------------
   -- Hub_Proxy --
   ---------------

   function Hub_Proxy return String is
      Upper_Name : constant String := Environment_Value ("HTTPS_PROXY");
      Lower_Name : constant String := Environment_Value ("https_proxy");
      Every      : constant String := Environment_Value ("ALL_PROXY");
   begin
      return (if Upper_Name /= "" then Upper_Name
              elsif Lower_Name /= "" then Lower_Name
              else Every);
   end Hub_Proxy;

   ------------------
   -- Proxy_Bypass --
   ------------------

   function Proxy_Bypass return String is
      Upper_Name : constant String := Environment_Value ("NO_PROXY");
   begin
      return (if Upper_Name /= "" then Upper_Name
              else Environment_Value ("no_proxy"));
   end Proxy_Bypass;

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

   ------------------------
   -- Passed_Environment --
   ------------------------

   function Passed_Environment (Names : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Start  : Natural := Names'First;

      --  The search path's absolute directories alone: an empty entry or
      --  a relative one is wherever the check runs, which is the work's.
      function Absolute_Only (Search : String) return String is
         Kept : Ada.Strings.Unbounded.Unbounded_String;
         From : Positive := Search'First;
      begin
         for Index in Search'First .. Search'Last + 1 loop
            if Index > Search'Last or else Search (Index) = GNAT.OS_Lib.Path_Separator then
               declare
                  Folder : constant String := Search (From .. Index - 1);
               begin
                  if Folder /= "" and then GNAT.OS_Lib.Is_Absolute_Path (Folder) then
                     if Ada.Strings.Unbounded.Length (Kept) > 0 then
                        Ada.Strings.Unbounded.Append (Kept, GNAT.OS_Lib.Path_Separator);
                     end if;
                     Ada.Strings.Unbounded.Append (Kept, Folder);
                  end if;
               end;
               From := Index + 1;
            end if;
         end loop;
         return Ada.Strings.Unbounded.To_String (Kept);
      end Absolute_Only;

      procedure Pass (Name : String) is
      begin
         if Name /= "" and then Environment_Exists (Name) then
            Ada.Strings.Unbounded.Append
              (Result, Name & "="
                 & (if Name = "PATH" then Absolute_Only (Environment_Value (Name))
                    else Environment_Value (Name))
                 & ASCII.LF);
         end if;
      end Pass;
   begin
      Pass ("PATH");
      Pass ("HOME");
      for Index in Names'First .. Names'Last + 1 loop
         if Index > Names'Last or else Names (Index) = ',' then
            declare
               Name : constant String :=
                 Ada.Strings.Fixed.Trim (Names (Start .. Index - 1), Ada.Strings.Both);
            begin
               if Name not in "PATH" | "HOME" then
                  Pass (Name);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Passed_Environment;

   -----------------------------------
   -- Installed_Templates_Directory --
   -----------------------------------

   function Installed_Templates_Directory return String is
      Messages : constant String :=
        Ada.Directories.Containing_Directory (Catalog_Path);
   begin
      return Hostkit.Fs.Join
               (Ada.Directories.Containing_Directory (Messages), "templates");
   exception
      when others =>
         return Hostkit.Fs.Join ("resources", "templates");
   end Installed_Templates_Directory;

   ------------------------------
   -- User_Templates_Directory --
   ------------------------------

   function User_Templates_Directory return String is
      Settings : constant String := Config_File;
   begin
      if Settings = "" then
         return "";
      end if;
      return Hostkit.Fs.Join
               (Ada.Directories.Containing_Directory (Settings), "templates");
   exception
      when others =>
         return "";
   end User_Templates_Directory;

   -----------------
   -- Config_File --
   -----------------

   function Config_File return String is
      function Under (Base : String; Part : String) return String
        renames Hostkit.Fs.Join;

      Override    : constant String := Environment_Value ("MODEL_RUNNER_CONFIG");
      Config_Home : constant String := XDG_Value ("XDG_CONFIG_HOME");
      Home        : constant String := Environment_Value ("HOME");
   begin
      if Override /= "" then
         return Override;
      elsif Config_Home /= "" then
         return Under (Under (Config_Home, Model_Runner.Program_Name), "config");
      elsif Home /= "" then
         return Under
                  (Under (Under (Home, ".config"), Model_Runner.Program_Name),
                   "config");
      else
         return "";
      end if;
   exception
      when others =>
         return "";
   end Config_File;

   ---------------------
   -- Cache_Directory --
   ---------------------

   function Cache_Directory return String is
      function Under (Base : String; Part : String) return String
        renames Hostkit.Fs.Join;

      Cache_Home : constant String := XDG_Value ("XDG_CACHE_HOME");
      Home       : constant String := Environment_Value ("HOME");
   begin
      if Cache_Home /= "" then
         return Under (Under (Cache_Home, Model_Runner.Program_Name), "prefill");
      elsif Home /= "" then
         return Under
                  (Under (Under (Home, ".cache"), Model_Runner.Program_Name),
                   "prefill");
      else
         return "";
      end if;
   exception
      when others =>
         return "";
   end Cache_Directory;

   ----------------
   -- Cache_File --
   ----------------

   function Cache_File (Key : String) return String is
      Dir : constant String := Cache_Directory;
   begin
      if Dir = "" then
         return "";
      end if;
      declare
         Image : constant String :=
           Ada.Containers.Hash_Type'Image (Ada.Strings.Hash (Key));
      begin
         return Hostkit.Fs.Join
                  (Dir, Image (Image'First + 1 .. Image'Last) & ".kv");
      end;
   exception
      when others =>
         return "";
   end Cache_File;

   ----------------
   -- Panel_File --
   ----------------

   function Panel_File (Key : String) return String is
      Prefill : constant String := Cache_Directory;
   begin
      if Prefill = "" then
         return "";
      end if;
      declare
         Image : constant String :=
           Ada.Containers.Hash_Type'Image (Ada.Strings.Hash (Key));
      begin
         return Hostkit.Fs.Join
                  (Hostkit.Fs.Join
                     (Ada.Directories.Containing_Directory (Prefill),
                      "panels"),
                   Image (Image'First + 1 .. Image'Last) & ".panels");
      end;
   exception
      when others =>
         return "";
   end Panel_File;

   ---------------
   -- Mark_Used --
   ---------------

   procedure Mark_Used (Path : String) is
      use type Ada.Calendar.Time;

      Now : constant Long_Long_Integer :=
        Long_Long_Integer
          (Ada.Calendar.Clock
           - Ada.Calendar.Formatting.Time_Of
               (1970, 1, 1, 0, 0, 0, Time_Zone => 0));
   begin
      --  Not set is no worse than before: the file is merely trimmed as
      --  if it had not been used.
      if Path /= ""
        and then not Hostkit.Metadata.Set_File_Times (Path, Now, Now)
      then
         return;
      end if;
   exception
      when others =>
         null;
   end Mark_Used;

   --------------------
   -- Trim_Directory --
   --------------------

   procedure Trim_Directory
     (Folder  : String;
      Pattern : String;
      Most    : Long_Long_Integer;
      Keep    : String := "";
      Settled : Duration := 0.0)
   is
      use Ada.Directories;
      Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      use type Ada.Calendar.Time;

      type Found is record
         Name : Ada.Strings.Unbounded.Unbounded_String;
         Used : Ada.Calendar.Time;
         Size : Long_Long_Integer;
      end record;

      Most_Files : constant := 4_096;
      List  : array (1 .. Most_Files) of Found;
      Held  : Natural := 0;
      Total : Long_Long_Integer := 0;
      Look  : Search_Type;
      Item  : Directory_Entry_Type;

      --  The file kept, and each the search finds, named in full, every
      --  doubled separator and dot gone. Compared as given, a cache under a
      --  relative folder, or one with a doubled separator, never matched
      --  what it was, and the file just written was the first to go.
      function Full (Path : String) return String is
      begin
         return (if Path = "" then "" else Full_Name (Path));
      exception
         when others =>
            return Path;
      end Full;
      Kept : constant String := Full (Keep);
   begin
      if Folder = "" or else not Exists (Folder) then
         return;
      end if;

      Start_Search
        (Look, Folder, Pattern, [Ordinary_File => True, others => False]);
      while More_Entries (Look) and then Held < Most_Files loop
         Get_Next_Entry (Look, Item);
         declare
            Name : constant String := Full_Name (Item);
         begin
            if Name'Length < 5
              or else Name (Name'Last - 4 .. Name'Last) /= ".part"
            then
               Held := Held + 1;
               List (Held) :=
                 (Ada.Strings.Unbounded.To_Unbounded_String (Name),
                  Modification_Time (Item),
                  Long_Long_Integer (Size (Item)));
               Total := Total + List (Held).Size;
            end if;
         end;
      end loop;
      End_Search (Look);

      --  Used longest ago first.
      for I in 2 .. Held loop
         for J in reverse 2 .. I loop
            exit when List (J - 1).Used <= List (J).Used;
            declare
               Swap : constant Found := List (J);
            begin
               List (J) := List (J - 1);
               List (J - 1) := Swap;
            end;
         end loop;
      end loop;

      for I in 1 .. Held loop
         exit when Total <= Most;
         declare
            Name : constant String :=
              Ada.Strings.Unbounded.To_String (List (I).Name);
         begin
            --  Aged only where an age was asked: Mark_Used stamps a whole
            --  second, which can be half of one ahead of the clock.
            if Full (Name) /= Kept
              and then (Settled = 0.0 or else Now - List (I).Used >= Settled)
            then
               Delete_File (Name);
               Total := Total - List (I).Size;
            end if;
         exception
            when others =>
               null;
         end;
      end loop;
   exception
      when others =>
         null;
   end Trim_Directory;

   ---------------------
   -- Data_Directory --
   ---------------------

   --  A directory under model_runner's data home, named by an override
   --  variable when it is set, else <XDG_DATA_HOME or ~/.local/share>/
   --  model_runner/<Leaf>. Empty when neither the override nor a home is
   --  known.
   function Data_Directory
     (Override_Var : String; Config_Key : String; Leaf : String)
      return String
   is
      function Under (Base : String; Part : String) return String
        renames Hostkit.Fs.Join;

      Override   : constant String := Environment_Value (Override_Var);
      From_Config : constant String := Model_Runner.Config.Value (Config_Key);
      Data       : constant String := XDG_Value ("XDG_DATA_HOME");
      Home       : constant String := Environment_Value ("HOME");
   begin
      if Override /= "" then
         return Override;
      elsif From_Config /= "" then
         return From_Config;
      elsif Data /= "" then
         return Under (Under (Data, Model_Runner.Program_Name), Leaf);
      elsif Home /= "" then
         return Under
                  (Under
                     (Under (Under (Home, ".local"), "share"),
                      Model_Runner.Program_Name),
                   Leaf);
      else
         return "";
      end if;
   exception
      when others =>
         return "";
   end Data_Directory;

   -----------------
   -- Resolve_In --
   -----------------

   --  A name to read: itself where it exists as given, else a bare name
   --  found in Directory, else itself so the failure names it.
   function Resolve_In (Named : String; Directory : String) return String is
   begin
      if Named = "" or else Ada.Directories.Exists (Named) then
         return Named;
      end if;

      if Directory /= ""
        and then Ada.Directories.Simple_Name (Named) = Named
      then
         declare
            Candidate : constant String := Hostkit.Fs.Join (Directory, Named);
         begin
            if Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end if;

      return Named;
   exception
      when others =>
         return Named;
   end Resolve_In;

   -----------------------
   -- Models_Directory --
   -----------------------

   function Models_Directory return String
   is (Data_Directory ("MODEL_RUNNER_MODELS", "models-dir", "models"));

   -------------------------
   -- Sessions_Directory --
   -------------------------

   function Sessions_Directory return String
   is (Data_Directory ("MODEL_RUNNER_SESSIONS", "sessions-dir", "sessions"));

   -------------------------
   -- Resolve_Model_Path --
   -------------------------

   function Resolve_Model_Path (Named : String) return String is
      --  ~/ as the shell takes it: the home directory.
      Expanded : constant String :=
        (if Named'Length > 2 and then Named (Named'First .. Named'First + 1) = "~/"
           and then Hostkit.Fs.Home_Directory /= ""
         then Hostkit.Fs.Join (Hostkit.Fs.Home_Directory, Named (Named'First + 2 .. Named'Last))
         else Named);
      Found    : constant String := Resolve_In (Expanded, Models_Directory);
   begin
      --  A model named without its .gguf, as the models are listed.
      if not Ada.Directories.Exists (Found) and then Expanded'Length > 0
        and then Ada.Directories.Exists (Resolve_In (Expanded & ".gguf", Models_Directory))
      then
         return Resolve_In (Expanded & ".gguf", Models_Directory);
      end if;
      return Found;
   exception
      when others =>
         return Named;
   end Resolve_Model_Path;

   ------------------
   -- Models_File --
   ------------------

   function Models_File (Name : String) return String is
      Directory : constant String := Models_Directory;
   begin
      if Directory = "" then
         return "";
      else
         return Hostkit.Fs.Join (Directory, Name);
      end if;
   exception
      when others =>
         return "";
   end Models_File;

   ---------------------------
   -- Resolve_Session_Path --
   ---------------------------

   function Resolve_Session_Path
     (Named : String; For_Saving : Boolean) return String is
   begin
      --  Loading: a bare name is read from the sessions directory first,
      --  where saving by that name wrote it -- a file of the name in the
      --  current directory was read instead, and the session just saved
      --  was not the one loaded.
      if not For_Saving then
         if Named /= ""
           and then Ada.Directories.Simple_Name (Named) = Named
           and then Sessions_Directory /= ""
           and then Ada.Directories.Exists (Hostkit.Fs.Join (Sessions_Directory, Named))
         then
            return Hostkit.Fs.Join (Sessions_Directory, Named);
         end if;
         return Resolve_In (Named, Sessions_Directory);
      end if;

      --  Saving: a bare name is written into the sessions directory, so
      --  what is saved by name is loaded by the same name. A name that
      --  carries a path is written where it says.
      if Named /= ""
        and then Ada.Directories.Simple_Name (Named) = Named
      then
         declare
            Directory : constant String := Sessions_Directory;
         begin
            if Directory /= "" then
               return Hostkit.Fs.Join (Directory, Named);
            end if;
         end;
      end if;

      return Named;
   exception
      when others =>
         return Named;
   end Resolve_Session_Path;

   -------------------------------
   -- Ensure_Parent_Directory --
   -------------------------------

   procedure Ensure_Parent_Directory (Path : String) is
      Parent : constant String := Ada.Directories.Containing_Directory (Path);
   begin
      if Parent /= "" and then not Ada.Directories.Exists (Parent) then
         Ada.Directories.Create_Path (Parent);
      end if;
   exception
      when others =>
         null;
   end Ensure_Parent_Directory;

   ---------------------
   -- Processor_Count --
   ---------------------

   function Processor_Count return Positive is
      use type System.Multiprocessors.CPU_Range;
      Count : constant System.Multiprocessors.CPU_Range :=
        System.Multiprocessors.Number_Of_CPUs;
      Online : constant Positive := (if Count < 1 then 1 else Positive (Count));

      --  Fewer where the process is held to fewer -- `taskset`, a cpuset, a
      --  container: the processors online counted eight to sixteen workers
      --  spinning on four, every product waiting for one descheduled.
      Usable : Hostkit.Host.Processor_Set;
      Held   : Natural := 0;
   begin
      if Hostkit.Host.Usable_Processors (Usable) then
         for May of Usable loop
            if May then
               Held := Held + 1;
            end if;
         end loop;
      end if;
      return (if Held in 1 .. Online then Held else Online);
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

   ---------------------
   -- Low_Power_Waits --
   ---------------------

   function Low_Power_Waits return Boolean is
   begin
      return Model_Runner.Platform.Instructions.Low_Power_Waits;
   exception
      when others =>
         return False;
   end Low_Power_Waits;

   ---------------------
   -- Physical_Memory --
   ---------------------

   function Physical_Memory return Interfaces.Unsigned_64 is
   begin
      return Model_Runner.Platform.Topology.Physical_Memory;
   exception
      when others =>
         return 0;
   end Physical_Memory;

   ----------------------
   -- Available_Memory --
   ----------------------

   function Available_Memory return Interfaces.Unsigned_64 is
   begin
      return Model_Runner.Platform.Topology.Available_Memory;
   end Available_Memory;

   ---------------------
   -- Free_Disk_Space --
   ---------------------

   function Free_Disk_Space (Path : String) return Interfaces.Unsigned_64 is

      --  The host answers about a path that exists. A file about to be
      --  written does not yet, and its directory may not either on a first
      --  download, so the query walks up to the nearest ancestor that does
      --  -- the same volume -- and gives up where a path has none above it.
      function Ascend (Location : String) return Interfaces.Unsigned_64 is
         Capacity : constant Hostkit.Metadata.Volume_Capacity :=
           Hostkit.Metadata.Volume_Capacity_Of (Location);
      begin
         if Capacity.Available and then Capacity.Free_Bytes > 0 then
            return Interfaces.Unsigned_64 (Capacity.Free_Bytes);
         end if;

         declare
            Parent : constant String :=
              Ada.Directories.Containing_Directory (Location);
         begin
            if Parent'Length = 0 or else Parent = Location then
               return 0;
            end if;
            return Ascend (Parent);
         end;
      exception
         when others =>
            return 0;
      end Ascend;

   begin
      if Path = "" then
         return 0;
      end if;
      return Ascend (Path);
   end Free_Disk_Space;

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
