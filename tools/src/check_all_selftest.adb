with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Project_Tools.Processes;

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

   Bad_Status := Project_Tools.Processes.Run_Status
     ("check_all rejects invalid working directory", Bad_Root, Check_All,
      GNAT.OS_Lib.Argument_List'[], Quiet => True);

   if Bad_Status = 0 then
      Put_Line (Standard_Error, "check_all unexpectedly accepted an invalid working directory");
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
