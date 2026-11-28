with Interfaces;
with System.Machine_Code;

with Model_Runner.Platform.X86_Feature_Sets;

package body Model_Runner.Platform.X86_Features is

   use type Interfaces.Unsigned_32;

   subtype U32 is Interfaces.Unsigned_32;

   procedure CPUID
     (Leaf, Subleaf : U32;
      A, B, C, D    : out U32)
   is
      Accumulator : U32 := Leaf;
      Counter     : U32 := Subleaf;
      Base        : U32;
      Data        : U32;
   begin
      System.Machine_Code.Asm
        ("cpuid",
         Outputs =>
           [U32'Asm_Output ("+a", Accumulator),
            U32'Asm_Output ("=b", Base),
            U32'Asm_Output ("+c", Counter),
            U32'Asm_Output ("=d", Data)],
         Volatile => True);
      A := Accumulator;
      B := Base;
      C := Counter;
      D := Data;
   end CPUID;

   function Has_Bit (Value : U32; Bit : Natural) return Boolean is
     ((Value and Interfaces.Shift_Left (U32 (1), Bit)) /= 0);

   function Extended_State return U32 is
      Low  : U32;
      High : U32;
   begin
      System.Machine_Code.Asm
        ("xgetbv",
         Outputs =>
           [U32'Asm_Output ("=a", Low),
            U32'Asm_Output ("=d", High)],
         Inputs => [U32'Asm_Input ("c", 0)],
         Volatile => True);
      return Low;
   end Extended_State;

   procedure Features
     (Wide : out Boolean;
      Deep : out Boolean;
      Brain : out Boolean)
   is
      package Sets renames Model_Runner.Platform.X86_Feature_Sets;

      A, B, C, D             : U32;
      Basic_C, Leaf_7_B      : U32;
      Leaf_7_C, Extended_C   : U32;
      State                  : U32 := 0;
      Leaf_7_1_A : U32 := 0;
      Found                  : Sets.Feature_Set := Sets.No_Features;
   begin
      Wide := False;
      Deep := False;
      Brain := False;

      CPUID (0, 0, A, B, C, D);
      if A < 7 then
         return;
      end if;

      CPUID (1, 0, A, B, C, D);
      Basic_C := C;
      if Has_Bit (Basic_C, 26)
        and then Has_Bit (Basic_C, 27)
        and then Has_Bit (Basic_C, 28)
      then
         State := Extended_State;
      end if;
      CPUID (7, 0, A, B, C, D);
      Leaf_7_B := B;
      Leaf_7_C := C;
      if A >= 1 then
         CPUID (7, 1, A, B, C, D);
         Leaf_7_1_A := A;
      end if;

      CPUID (16#8000_0000#, 0, A, B, C, D);
      if A < 16#8000_0001# then
         return;
      end if;
      CPUID (16#8000_0001#, 0, A, B, C, D);
      Extended_C := C;

      Found :=
        (OS_XMM_YMM => (State and 16#0000_0006#) = 16#0000_0006#,
         OS_ZMM     => (State and 16#0000_00E6#) = 16#0000_00E6#,
         LAHF_SAHF  => Has_Bit (Extended_C, 0),
         SSE3       => Has_Bit (Basic_C, 0),
         SSSE3      => Has_Bit (Basic_C, 9),
         CMPXCHG16B => Has_Bit (Basic_C, 13),
         SSE4_1     => Has_Bit (Basic_C, 19),
         SSE4_2     => Has_Bit (Basic_C, 20),
         POPCNT     => Has_Bit (Basic_C, 23),
         AVX        => Has_Bit (Basic_C, 28),
         FMA        => Has_Bit (Basic_C, 12),
         MOVBE      => Has_Bit (Basic_C, 22),
         XSAVE      => Has_Bit (Basic_C, 26),
         F16C       => Has_Bit (Basic_C, 29),
         BMI1       => Has_Bit (Leaf_7_B, 3),
         AVX2       => Has_Bit (Leaf_7_B, 5),
         BMI2       => Has_Bit (Leaf_7_B, 8),
         LZCNT      => Has_Bit (Extended_C, 5),
         AVX512F    => Has_Bit (Leaf_7_B, 16),
         AVX512DQ   => Has_Bit (Leaf_7_B, 17),
         AVX512CD   => Has_Bit (Leaf_7_B, 28),
         AVX512BW   => Has_Bit (Leaf_7_B, 30),
         AVX512VL   => Has_Bit (Leaf_7_B, 31),
         AVX512VNNI => Has_Bit (Leaf_7_C, 11),
         AVX512BF16 => Has_Bit (Leaf_7_1_A, 5));

      Wide := Sets.Supports_V3 (Found);
      Deep := Sets.Supports_V4_VNNI (Found);
      Brain := Sets.Supports_BF16 (Found);
   exception
      when others =>
         Wide := False;
         Deep := False;
      Brain := False;
   end Features;

   function Wide_Vectors return Boolean is
      Wide, Deep, Brain : Boolean;
   begin
      Features (Wide, Deep, Brain);
      return Wide;
   end Wide_Vectors;

   function Byte_Products return Boolean is
      Wide, Deep, Brain : Boolean;
   begin
      Features (Wide, Deep, Brain);
      return Deep;
   end Byte_Products;

   function Brain_Products return Boolean is
      Wide, Deep, Brain : Boolean;
   begin
      Features (Wide, Deep, Brain);
      return Brain;
   end Brain_Products;

end Model_Runner.Platform.X86_Features;
