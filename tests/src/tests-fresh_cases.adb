with Model_Runner.Backend.CPU;

package body Tests.Fresh_Cases is

   overriding procedure Set_Up (T : in out Fresh_Case) is
      pragma Unreferenced (T);
   begin
      Model_Runner.Backend.CPU.Use_Integer_Activations
        (Model_Runner.Backend.CPU.No_Role);
   end Set_Up;

end Tests.Fresh_Cases;
