with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Processes;
with Project_Tools.Release_Checks;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

procedure Check_All is
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

   Root   : constant String := Project_Root;
   Alr    : constant String := Project_Tools.Processes.Locate_Command ("alr");
   Checks : constant Project_Tools.Release_Checks.Checker :=
     Project_Tools.Release_Checks.Create (Root);

   procedure Require_Alire_GNAT_15 is
      Output : Ada.Strings.Unbounded.Unbounded_String;
      Status : Integer;
   begin
      Status :=
        Project_Tools.Processes.Run_Status
          ("verify Alire-selected GNAT 15 toolchain",
           Root,
           Alr,
           [new String'("exec"), new String'("--"), new String'("gnatls"), new String'("--version")],
           Output,
           Quiet => False);

      if Status /= 0 then
         Put_Line (Standard_Error, "alr exec -- gnatls --version failed");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      elsif Project_Tools.Text.Contains (Ada.Strings.Unbounded.To_String (Output), "GNATLS 15.") = False then
         Put_Line
           (Standard_Error,
            "model_runner must build with Alire-selected GNAT 15, got: "
            & Ada.Strings.Unbounded.To_String (Output));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Require_Alire_GNAT_15;
begin
   if not Ada.Directories.Exists (Root & "/model_runner.gpr") then
      Put_Line (Standard_Error, "check_all must be run from the model_runner root or tools directory");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Project_Tools.Processes.Require_Command
     ("alr", "alr executable not found on PATH");
   Require_Alire_GNAT_15;

   Project_Tools.Release_Checks.Require_File (Checks, "model_runner.gpr");
   Project_Tools.Release_Checks.Require_File (Checks, "tests/tests.gpr");
   Project_Tools.Release_Checks.Require_File
     (Checks, "tools/model_runner_check_all.gpr");
   Project_Tools.Release_Checks.Require_File
     (Checks, "resources/messages/catalog.txt");

   --  model_runner keeps its checks in the tests crate rather than a separate
   --  check_model_runner crate, because the specification this was built to
   --  requires every piece of project tooling to be Ada living there. The
   --  checks themselves are the same kind: repository structure, dependency
   --  boundaries, layering, and the documentation generated from the code.
   Project_Tools.Release_Checks.Run
     ("build the tests crate", Root & "/tests", Alr,
      [1 => new String'("build")]);

   Project_Tools.Release_Checks.Run
     ("repository, dependency and layering checks", Root & "/tests",
      "./bin/tests", [1 => new String'("check")]);

   Project_Tools.Release_Checks.Run
     ("test suite", Root & "/tests", "./bin/tests",
      [1 => new String'("test")]);

   --  The engine against an independently written forward pass. This is what
   --  says the arithmetic is right; the reference comparison against another
   --  runtime, which says the conventions are right, needs a model file and
   --  so cannot run here.
   Project_Tools.Release_Checks.Run
     ("conformance against the reference implementation", Root & "/tests",
      "./bin/tests", [1 => new String'("conformance")]);

   --  Malformed containers must produce controlled outcomes, never an escaped
   --  exception and never a wrongly accepted file.
   Project_Tools.Release_Checks.Run
     ("container fuzzing", Root & "/tests", "./bin/tests",
      [new String'("fuzz"), new String'("--seed"), new String'("1"),
       new String'("--cases"), new String'("2000")]);

   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/tests/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/tools/obj");

   Put_Line ("model_runner aggregate release checklist passed");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      null;
   when E : others =>
      Put_Line
        (Standard_Error,
         "model_runner aggregate release checklist failed: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Check_All;
