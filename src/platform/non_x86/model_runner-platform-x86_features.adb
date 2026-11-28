package body Model_Runner.Platform.X86_Features is

   --  Keep conservative bodies so the unit compiles during the repository's
   --  cross-platform source checks.  Elaboration still refuses execution:
   --  shared inference units contain x86 machine code, so returning False is
   --  not enough to make a non-x86 process safe.
   function Wide_Vectors return Boolean is (False);

   function Byte_Products return Boolean is (False);

   function Brain_Products return Boolean is (False);

begin
   raise Program_Error with
     "model_runner requires x86_64; shared inference kernels still contain "
     & "x86 machine-code implementations";
end Model_Runner.Platform.X86_Features;
