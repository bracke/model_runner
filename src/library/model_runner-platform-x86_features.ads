--  Architected x86 feature queries shared by the native desktop hosts.
--
--  CPUID says what the processor implements; XGETBV says whether the
--  operating system saves the vector state needed to execute it.  Both are
--  required.  A failed or incomplete query deliberately selects the scalar
--  implementation.
private package Model_Runner.Platform.X86_Features is

   --  True for the complete x86-64-v3 set used by the wide kernels.
   --  @return True only when CPU and operating-system state support it.
   function Wide_Vectors return Boolean;

   --  True for complete x86-64-v4 plus VNNI, used by the byte-product
   --  kernels.
   --  @return True only when CPU and operating-system state support it.
   function Byte_Products return Boolean;

   --  Whether native BF16 conversion/dot instructions and their vector state are available.
   --  @return False on an incomplete CPU or operating-system feature set.
   function Brain_Products return Boolean;

end Model_Runner.Platform.X86_Features;
