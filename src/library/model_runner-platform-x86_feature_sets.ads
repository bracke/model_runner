--  The architected inputs to the x86 multiversioning decision.
--
--  Kept separate from CPUID so the complete predicates can be tested with
--  synthetic feature sets.  A missing member is always a refusal: entering a
--  unit compiled for an ISA level is safe only when every inherited feature
--  of that level and the operating-system vector state are present.
package Model_Runner.Platform.X86_Feature_Sets is
   type Feature_Set is record
      OS_XMM_YMM : Boolean := False;
      OS_ZMM     : Boolean := False;

      LAHF_SAHF  : Boolean := False;
      SSE3       : Boolean := False;
      SSSE3      : Boolean := False;
      CMPXCHG16B : Boolean := False;
      SSE4_1     : Boolean := False;
      SSE4_2     : Boolean := False;
      POPCNT     : Boolean := False;

      AVX        : Boolean := False;
      FMA        : Boolean := False;
      MOVBE      : Boolean := False;
      XSAVE      : Boolean := False;
      F16C       : Boolean := False;
      BMI1       : Boolean := False;
      AVX2       : Boolean := False;
      BMI2       : Boolean := False;
      LZCNT      : Boolean := False;

      AVX512F    : Boolean := False;
      AVX512DQ   : Boolean := False;
      AVX512CD   : Boolean := False;
      AVX512BW   : Boolean := False;
      AVX512VL   : Boolean := False;
      AVX512VNNI : Boolean := False;
   end record;

   No_Features : constant Feature_Set := (others => False);

   --  Whether Item contains the complete x86-64-v3 feature set and the
   --  operating-system state required by AVX instructions.
   --
   --  @param Item Feature and operating-system state to evaluate.
   --  @return True only when every x86-64-v3 prerequisite is present.
   function Supports_V3 (Item : Feature_Set) return Boolean;

   --  Whether Item contains x86-64-v4, its inherited v3 set, and VNNI used
   --  by the byte-product kernel.  VNNI is an additional kernel requirement,
   --  not part of the architectural v4 level itself.
   --
   --  @param Item Feature and operating-system state to evaluate.
   --  @return True only when every x86-64-v4 and VNNI prerequisite is present.
   function Supports_V4_VNNI (Item : Feature_Set) return Boolean;

end Model_Runner.Platform.X86_Feature_Sets;
