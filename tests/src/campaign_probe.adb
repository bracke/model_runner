with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;

package body Campaign_Probe is

   function Write (Path : String) return Boolean is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, "overwritten by probe");
      Ada.Text_IO.Close (File);
      return True;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return False;
   end Write;

   function Run (Write_Only : Boolean; Writable, Guarded, Outside : String) return Natural is
      use Ada.Strings.Unbounded;
      Ran : Hostkit.Process.Process_Outcome;
   begin
      if Write_Only then
         return (if Write (Guarded) then 0 else 9);
      end if;
      if Ada.Directories.Exists (Guarded) then
         return 4;
      end if;
      if Ada.Environment_Variables.Value ("XDG_CACHE_HOME", "") /= Writable & "/obj" then
         return 2;
      end if;
      Ada.Directories.Create_Path (Writable & "/obj/model_runner/panels");
      if not Write (Writable & "/obj/model_runner/panels/cache-marker") then
         return 3;
      end if;
      if not Write (Writable & "/allowed.txt") or else Write (Guarded) or else Write (Outside) then
         return 1;
      end if;
      if not Hostkit.Fs.Create_Link (Outside, Writable & "/escape")
        or else Write (Writable & "/escape")
      then
         return 1;
      end if;
      Ran := Hostkit.Process.Run_Captured
        (Hostkit.Fs.Own_Executable,
         [To_Unbounded_String ("probe"), To_Unbounded_String ("campaign-write"), To_Unbounded_String (Outside)],
         Stdout_Path => Writable & "/descendant.txt", Stderr_Path => Writable & "/descendant-errors.txt",
         Timeout_Ms => 10_000);
      return (if Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 9 then 0 else 1);
   end Run;

end Campaign_Probe;
