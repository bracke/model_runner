package body Model_Runner.Platform.X86_Features is

   --  The optimized instantiations are an optional x86-64 implementation
   --  detail.  Every other architecture uses the ordinary portable kernels.
   function Wide_Vectors return Boolean is (False);

   function Byte_Products return Boolean is (False);

end Model_Runner.Platform.X86_Features;
