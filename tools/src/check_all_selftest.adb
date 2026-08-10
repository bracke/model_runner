with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Processes;
with Project_Tools.Text;

procedure Check_All_Selftest is
   use Ada.Text_IO;

   function Project_Root return String is
      Here : constant String := Ada.Directories.Current_Directory;
   begin
      if Ada.Directories.Exists (Here & "/model_runner.gpr") then
         return Here;
      elsif Ada.Directories.Exists (Here & "/../model_runner.gpr") then
         return Ada.Directories.Full_Name (Here & "/..");
      else
         return Here;
      end if;
   end Project_Root;

   Root       : constant String := Project_Root;
   Check_All  : constant String := Root & "/tools/bin/check_all";
   Bad_Root   : constant String := "/tmp/terminal-styles-check-all-selftest";
   Bad_Status : Integer;
   Said       : Ada.Strings.Unbounded.Unbounded_String;
begin
   if not Ada.Directories.Exists (Check_All) then
      Put_Line (Standard_Error, "build tools/bin/check_all before running check_all_selftest");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   if Ada.Directories.Exists (Bad_Root) then
      Ada.Directories.Delete_Tree (Bad_Root);
   end if;
   Ada.Directories.Create_Directory (Bad_Root);

   --  A non-zero status is not enough on its own. Run outside a
   --  model_runner tree, check_all has more than one way to fail -- the
   --  toolchain check runs before anything else and fails there too -- so
   --  asking only whether it failed would pass on a build that had lost the
   --  refusal entirely. Taking the guard out was tried, and this passed.
   --  What is asked is that it refused for the reason it exists to refuse
   --  for, which is the message.
   --
   --  Standard error merged in, because the refusal is a diagnostic and goes
   --  there; Run_Status captures only standard output, so the first version
   --  of this looked for the message in an empty string. Capture_Command
   --  takes no working directory, so this walks into the bad one and back.
   declare
      Here : constant String := Ada.Directories.Current_Directory;
      Args : Project_Tools.Processes.Argument_Vectors.Vector;
   begin
      Ada.Directories.Set_Directory (Bad_Root);

      declare
         Ran : constant Project_Tools.Processes.Captured_Process :=
           Project_Tools.Processes.Capture_Command
             (Command    => Check_All,
              Arguments  => Args,
              Err_To_Out => True);
      begin
         Bad_Status := Ran.Status;
         Said := Ran.Output;
      end;

      Ada.Directories.Set_Directory (Here);
   end;

   if Bad_Status = 0 then
      Put_Line (Standard_Error, "check_all unexpectedly accepted an invalid working directory");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   if not Project_Tools.Text.Contains
            (Ada.Strings.Unbounded.To_String (Said),
             "must be run from the model_runner root")
   then
      Put_Line
        (Standard_Error,
         "check_all failed outside a model_runner tree for some other "
         & "reason than refusing the directory: "
         & Ada.Strings.Unbounded.To_String (Said));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Put_Line ("model_runner aggregate checker self-test passed");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when E : others =>
      Put_Line
        (Standard_Error,
         "model_runner aggregate checker self-test failed: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Check_All_Selftest;
