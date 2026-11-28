with Model_Runner.Backend.CPU;
with Model_Runner.CLI.Project_Commands;
with Ada.Directories;
with Ada.Environment_Variables;

package body Tests.Fresh_Cases is

   overriding procedure Set_Up (T : in out Fresh_Case) is
      Typed_Before : constant Boolean := Model_Runner.CLI.Project_Commands.Typed_During_Work;
      pragma Unreferenced (Typed_Before);
   begin
      T.Directory := Ada.Strings.Unbounded.To_Unbounded_String (Ada.Directories.Current_Directory);
      T.Had_Config := Ada.Environment_Variables.Exists ("MODEL_RUNNER_CONFIG");
      T.Config := Ada.Strings.Unbounded.To_Unbounded_String
        (if T.Had_Config then Ada.Environment_Variables.Value ("MODEL_RUNNER_CONFIG") else "");
      Model_Runner.Backend.CPU.Use_Integer_Activations
        (Model_Runner.Backend.CPU.No_Role);
   end Set_Up;

   overriding procedure Tear_Down (T : in out Fresh_Case) is
   begin
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (T.Directory));
      if T.Had_Config then
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CONFIG", Ada.Strings.Unbounded.To_String (T.Config));
      else
         Ada.Environment_Variables.Clear ("MODEL_RUNNER_CONFIG");
      end if;
   end Tear_Down;

end Tests.Fresh_Cases;
