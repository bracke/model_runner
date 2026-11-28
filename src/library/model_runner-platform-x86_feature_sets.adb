package body Model_Runner.Platform.X86_Feature_Sets is

   function Supports_V3 (Item : Feature_Set) return Boolean is
     (Item.OS_XMM_YMM
      and then Item.LAHF_SAHF
      and then Item.SSE3
      and then Item.SSSE3
      and then Item.CMPXCHG16B
      and then Item.SSE4_1
      and then Item.SSE4_2
      and then Item.POPCNT
      and then Item.AVX
      and then Item.FMA
      and then Item.MOVBE
      and then Item.XSAVE
      and then Item.F16C
      and then Item.BMI1
      and then Item.AVX2
      and then Item.BMI2
      and then Item.LZCNT);

   function Supports_V4_VNNI (Item : Feature_Set) return Boolean is
     (Supports_V3 (Item)
      and then Item.OS_ZMM
      and then Item.AVX512F
      and then Item.AVX512DQ
      and then Item.AVX512CD
      and then Item.AVX512BW
      and then Item.AVX512VL
      and then Item.AVX512VNNI);

   function Supports_BF16 (Item : Feature_Set) return Boolean is
     (Supports_V3 (Item) and then Item.OS_ZMM and then Item.AVX512F
      and then Item.AVX512DQ and then Item.AVX512BW and then Item.AVX512VL
      and then Item.AVX512BF16);
end Model_Runner.Platform.X86_Feature_Sets;
