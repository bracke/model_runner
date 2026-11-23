with Ada.Directories;
with Ada.Strings.Unbounded;
with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Process;

package body Trial_Confinement is

   use Ada.Strings.Unbounded;
   use type Hostkit.Host.Kind;

   function Executable return String is
     (if Hostkit.Host.Current = Hostkit.Host.Linux then Hostkit.Process.Locate ("bwrap") else "");

   function Wrap
     (Program : String; Arguments : Hostkit.String_Vectors.Vector;
      Writable : String; Hidden : String := "";
      Readable : Hostkit.String_Vectors.Vector := Hostkit.String_Vectors.Empty_Vector)
      return Hostkit.String_Vectors.Vector
   is
      Words : Hostkit.String_Vectors.Vector;
      Root : constant String := Ada.Directories.Full_Name (Writable);
      procedure Add (Text : String) is
      begin
         Words.Append (To_Unbounded_String (Text));
      end Add;
      procedure Input (Path : String) is
         Full : constant String := Ada.Directories.Full_Name (Path);
      begin
         Add ("--ro-bind");
         Add (Full);
         Add (Full);
      end Input;
   begin
      for Word of Hostkit.String_Vectors.Vector'
        ([To_Unbounded_String ("--unshare-all"), To_Unbounded_String ("--die-with-parent"),
          To_Unbounded_String ("--new-session"), To_Unbounded_String ("--cap-drop"),
          To_Unbounded_String ("ALL"), To_Unbounded_String ("--ro-bind"),
          To_Unbounded_String ("/"), To_Unbounded_String ("/"),
          To_Unbounded_String ("--proc"), To_Unbounded_String ("/proc"),
          To_Unbounded_String ("--dev"), To_Unbounded_String ("/dev"),
          To_Unbounded_String ("--dev-bind-try"), To_Unbounded_String ("/dev/dri"),
          To_Unbounded_String ("/dev/dri"), To_Unbounded_String ("--dev-bind-try"),
          To_Unbounded_String ("/dev/kfd"), To_Unbounded_String ("/dev/kfd"),
          To_Unbounded_String ("--tmpfs"), To_Unbounded_String ("/tmp"),
          To_Unbounded_String ("--tmpfs"), To_Unbounded_String ("/run")])
      loop
         Words.Append (Word);
      end loop;
      if Hidden /= "" then
         Add ("--tmpfs");
         Add (Ada.Directories.Full_Name (Hidden));
      end if;
      Input (Program);
      for Path of Readable loop
         Input (To_String (Path));
      end loop;
      Add ("--bind");
      Add (Root);
      Add (Root);
      if Hidden /= "" then
         Add ("--remount-ro");
         Add (Ada.Directories.Full_Name (Hidden));
      end if;
      for Name of Hostkit.String_Vectors.Vector'
        ([To_Unbounded_String ("HOME"), To_Unbounded_String ("XDG_CONFIG_HOME"),
          To_Unbounded_String ("XDG_CACHE_HOME"), To_Unbounded_String ("XDG_DATA_HOME"),
          To_Unbounded_String ("XDG_RUNTIME_DIR")])
      loop
         Add ("--setenv");
         Add (To_String (Name));
         Add (Root & (if To_String (Name) = "XDG_CACHE_HOME" then "/obj" else ""));
      end loop;
      Add ("--setenv");
      Add ("TMPDIR");
      Add ("/tmp");
      Add ("--chdir");
      Add (Root);
      Add ("--");
      Add (Program);
      Words.Append_Vector (Arguments);
      return Words;
   end Wrap;

   function Ready (Directory : String) return Boolean is
      Ran : Hostkit.Process.Process_Outcome;
      Program : constant String := Hostkit.Process.Locate ("true");
   begin
      if Executable = "" or else Program = "" then
         return False;
      end if;
      Ran := Hostkit.Process.Run_Captured
        (Executable, Wrap (Program, Hostkit.String_Vectors.Empty_Vector, Directory),
         Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Directory & "/isolation-preflight.txt",
         Timeout_Ms => 10_000);
      return Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0;
   exception
      when others => return False;
   end Ready;

end Trial_Confinement;
