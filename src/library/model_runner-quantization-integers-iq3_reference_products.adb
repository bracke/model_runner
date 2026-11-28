--  Native IQ3_S products for one to sixteen queries. Compressed
--  blocks and the existing reference integer lanes/FMA fold are retained;
--  a decoded block serves every live query, preserving its original fold.
with System.Machine_Code;
with System.Storage_Elements;
separate (Model_Runner.Quantization.Integers)
procedure IQ3_Reference_Products
  (Data : Model_Runner.Bytes.Byte_Array; Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
   Rows, Blocks : Element_Count; Values : Signed_Array; Scales : N.Real_Array;
   First, Stride, Count : Element_Count; Target : access N.Real_Array;
   Result_First, Result_Stride : Element_Count; Ok : out Boolean;
   Result_Members, Input_Members : Model_Runner.Shares.Member_Rows)
is
   package B renames Model_Runner.Bytes;
   package GI renames Model_Runner.Quantization.Grid_Integers;
   use type B.Byte_Count;
   use type N.Wide_Real;
   use type Interfaces.Unsigned_32;
   subtype U32 is Interfaces.Unsigned_32;
   LF : constant Character := ASCII.LF;
   Columns : Element_Count;
   type Lane_Sums is array (0 .. 7) of N.Real with Alignment => 32;
   type Carries is array (0 .. 15) of Lane_Sums with Alignment => 32;
   Carry : Carries;
   type Address_Table is array (0 .. 15) of System.Address;
   Inputs, Factors, Outputs : Address_Table;
   type Argument_Table is array (0 .. 10) of System.Address;
   Arguments : aliased Argument_Table;
   Clobbers : constant String :=
     "rax,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,"
     & "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,"
     & "ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,ymm24,ymm25,ymm26,ymm27,ymm28,ymm29,ymm30,ymm31,"
     & "cc,memory";
   Native_8 : constant String :=
     "movq 8(%0), %%r15" & LF &
     "movq 40(%0), %%r8" & LF &
     "movq 48(%0), %%r9" & LF &
     "xorq %%rdi, %%rdi" & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
     "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
     "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
     "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
     "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
     "vpxord %%ymm25, %%ymm25, %%ymm25" & LF &
     "vpxord %%ymm26, %%ymm26, %%ymm26" & LF &
     "2:" & LF &
     "movq 0(%0), %%rax" & LF &
     "vpbroadcastw (%%rax), %%xmm7" & LF &
     "vcvtph2ps %%xmm7, %%ymm7" & LF &
     "movl $1065353216, %%edx" & LF &
     "vpbroadcastd %%edx, %%ymm3" & LF &
     "vmulps %%ymm3, %%ymm7, %%ymm7" & LF &
     "vmovd 106(%%rax), %%xmm20" & LF &
     "vpsrlw $4, %%xmm20, %%xmm21" & LF &
     "vpunpcklbw %%xmm21, %%xmm20, %%xmm20" & LF &
     "movl $15, %%edx" & LF &
     "vpbroadcastb %%edx, %%xmm22" & LF &
     "vpandq %%xmm22, %%xmm20, %%xmm20" & LF &
     "vpmovzxbw %%xmm20, %%xmm20" & LF &
     "vinserti32x4 $1, %%xmm20, %%ymm20, %%ymm20" & LF &
     "vpsllw $1, %%ymm20, %%ymm20" & LF &
     "movl $1, %%edx" & LF &
     "vpbroadcastw %%edx, %%ymm22" & LF &
     "vpaddw %%ymm22, %%ymm20, %%ymm20" & LF &
     "movl $16843009, %%edx" & LF &
     "vpbroadcastd %%edx, %%ymm3" & LF &
     "leaq 2(%%rax), %%rsi" & LF &
     "leaq 66(%%rax), %%r11" & LF &
     "leaq 74(%%rax), %%r13" & LF &
     "movq 24(%0), %%r12" & LF &
     "movq $8, %%r10" & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
     "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
     "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
     "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
     "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
     "vpxord %%ymm29, %%ymm29, %%ymm29" & LF &
     "vpxord %%ymm30, %%ymm30, %%ymm30" & LF &
     "1:" & LF &
     "movzbl (%%r11), %%ecx" & LF &
     "movabsq $0x00FF00FF00FF00FF, %%rdx" & LF &
     "movl (%%rsi), %%eax" & LF &
     "pdepq %%rdx, %%rax, %%rax" & LF &
     "movl 4(%%rsi), %%r14d" & LF &
     "pdepq %%rdx, %%r14, %%r14" & LF &
     "movabsq $0x0100010001000100, %%rdx" & LF &
     "pdepq %%rdx, %%rcx, %%rdx" & LF &
     "orq %%rdx, %%rax" & LF &
     "shrl $4, %%ecx" & LF &
     "movabsq $0x0100010001000100, %%rdx" & LF &
     "pdepq %%rdx, %%rcx, %%rdx" & LF &
     "orq %%rdx, %%r14" & LF &
     "movzwl %%ax, %%edx" & LF &
     "vmovd (%%r15,%%rdx,4), %%xmm0" & LF &
     "shrq $16, %%rax" & LF &
     "movzwl %%ax, %%edx" & LF &
     "vpinsrd $1, (%%r15,%%rdx,4), %%xmm0, %%xmm0" & LF &
     "shrq $16, %%rax" & LF &
     "movzwl %%ax, %%edx" & LF &
     "vpinsrd $2, (%%r15,%%rdx,4), %%xmm0, %%xmm0" & LF &
     "shrq $16, %%rax" & LF &
     "vpinsrd $3, (%%r15,%%rax,4), %%xmm0, %%xmm0" & LF &
     "movzwl %%r14w, %%edx" & LF &
     "vmovd (%%r15,%%rdx,4), %%xmm1" & LF &
     "shrq $16, %%r14" & LF &
     "movzwl %%r14w, %%edx" & LF &
     "vpinsrd $1, (%%r15,%%rdx,4), %%xmm1, %%xmm1" & LF &
     "shrq $16, %%r14" & LF &
     "movzwl %%r14w, %%edx" & LF &
     "vpinsrd $2, (%%r15,%%rdx,4), %%xmm1, %%xmm1" & LF &
     "shrq $16, %%r14" & LF &
     "vpinsrd $3, (%%r15,%%r14,4), %%xmm1, %%xmm1" & LF &
     "vinserti128 $1, %%xmm1, %%ymm0, %%ymm0" & LF &
     "movq 16(%0), %%rcx" & LF &
     "vpbroadcastd (%%r13), %%ymm2" & LF &
     "vpshufb (%%rcx), %%ymm2, %%ymm2" & LF &
     "vpand 32(%%rcx), %%ymm2, %%ymm2" & LF &
     "vpcmpeqb 32(%%rcx), %%ymm2, %%ymm2" & LF &
     "vpor %%ymm3, %%ymm2, %%ymm2" & LF &
     "vpshufb (%%r12), %%ymm20, %%ymm5" & LF &
     "movq 0(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm16" & LF &
     "movq 8(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm17" & LF &
     "movq 16(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm18" & LF &
     "movq 24(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm19" & LF &
     "movq 32(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm27" & LF &
     "movq 40(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm28" & LF &
     "movq 48(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm29" & LF &
     "movq 56(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm30" & LF &
     "addq $32, %%rdi" & LF &
     "addq $8, %%rsi" & LF &
     "incq %%r11" & LF &
     "addq $4, %%r13" & LF &
     "addq $32, %%r12" & LF &
     "decq %%r10" & LF &
     "jnz 1b" & LF &
     "movq %%rdi, %%rcx" & LF &
     "shrq $3, %%rcx" & LF &
     "subq $32, %%rcx" & LF &
     "movq 0(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm16, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm6" & LF &
     "movq 8(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm17, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm12" & LF &
     "movq 16(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm18, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm14" & LF &
     "movq 24(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm19, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm15" & LF &
     "movq 32(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm27, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm23" & LF &
     "movq 40(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm28, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm24" & LF &
     "movq 48(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm29, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm25" & LF &
     "movq 56(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm30, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm26" & LF &
     "addq $110, 0(%0)" & LF &
     "decq 64(%0)" & LF &
     "jnz 2b" & LF &
     "movq 56(%0), %%rdx" & LF &
     "vmovaps %%ymm6, 0(%%rdx)" & LF &
     "vmovaps %%ymm12, 32(%%rdx)" & LF &
     "vmovaps %%ymm14, 64(%%rdx)" & LF &
     "vmovaps %%ymm15, 96(%%rdx)" & LF &
     "vmovaps %%ymm23, 128(%%rdx)" & LF &
     "vmovaps %%ymm24, 160(%%rdx)" & LF &
     "vmovaps %%ymm25, 192(%%rdx)" & LF &
     "vmovaps %%ymm26, 224(%%rdx)" & LF &
     "vzeroupper";
   --  Small groups have only live integer/FMA chains and stores. Shared
   --  decode instructions are identical to Native_8; no unused input is read.
   Small_Start : constant String :=
     "movq 8(%0), %%r15" & LF &
     "movq 40(%0), %%r8" & LF &
     "movq 48(%0), %%r9" & LF &
     "xorq %%rdi, %%rdi";
   Small_Block : constant String :=
     "2:" & LF &
     "movq 0(%0), %%rax" & LF &
     "vpbroadcastw (%%rax), %%xmm7" & LF &
     "vcvtph2ps %%xmm7, %%ymm7" & LF &
     "movl $1065353216, %%edx" & LF &
     "vpbroadcastd %%edx, %%ymm3" & LF &
     "vmulps %%ymm3, %%ymm7, %%ymm7" & LF &
     "vmovd 106(%%rax), %%xmm20" & LF &
     "vpsrlw $4, %%xmm20, %%xmm21" & LF &
     "vpunpcklbw %%xmm21, %%xmm20, %%xmm20" & LF &
     "movl $15, %%edx" & LF &
     "vpbroadcastb %%edx, %%xmm22" & LF &
     "vpandq %%xmm22, %%xmm20, %%xmm20" & LF &
     "vpmovzxbw %%xmm20, %%xmm20" & LF &
     "vinserti32x4 $1, %%xmm20, %%ymm20, %%ymm20" & LF &
     "vpsllw $1, %%ymm20, %%ymm20" & LF &
     "movl $1, %%edx" & LF &
     "vpbroadcastw %%edx, %%ymm22" & LF &
     "vpaddw %%ymm22, %%ymm20, %%ymm20" & LF &
     "movl $16843009, %%edx" & LF &
     "vpbroadcastd %%edx, %%ymm3" & LF &
     "leaq 2(%%rax), %%rsi" & LF &
     "leaq 66(%%rax), %%r11" & LF &
     "leaq 74(%%rax), %%r13" & LF &
     "movq 24(%0), %%r12" & LF &
     "movq $8, %%r10";
   Small_Decode : constant String :=
     "1:" & LF &
     "movzbl (%%r11), %%ecx" & LF &
     "movabsq $0x00FF00FF00FF00FF, %%rdx" & LF &
     "movl (%%rsi), %%eax" & LF &
     "pdepq %%rdx, %%rax, %%rax" & LF &
     "movl 4(%%rsi), %%r14d" & LF &
     "pdepq %%rdx, %%r14, %%r14" & LF &
     "movabsq $0x0100010001000100, %%rdx" & LF &
     "pdepq %%rdx, %%rcx, %%rdx" & LF &
     "orq %%rdx, %%rax" & LF &
     "shrl $4, %%ecx" & LF &
     "movabsq $0x0100010001000100, %%rdx" & LF &
     "pdepq %%rdx, %%rcx, %%rdx" & LF &
     "orq %%rdx, %%r14" & LF &
     "movzwl %%ax, %%edx" & LF &
     "vmovd (%%r15,%%rdx,4), %%xmm0" & LF &
     "shrq $16, %%rax" & LF &
     "movzwl %%ax, %%edx" & LF &
     "vpinsrd $1, (%%r15,%%rdx,4), %%xmm0, %%xmm0" & LF &
     "shrq $16, %%rax" & LF &
     "movzwl %%ax, %%edx" & LF &
     "vpinsrd $2, (%%r15,%%rdx,4), %%xmm0, %%xmm0" & LF &
     "shrq $16, %%rax" & LF &
     "vpinsrd $3, (%%r15,%%rax,4), %%xmm0, %%xmm0" & LF &
     "movzwl %%r14w, %%edx" & LF &
     "vmovd (%%r15,%%rdx,4), %%xmm1" & LF &
     "shrq $16, %%r14" & LF &
     "movzwl %%r14w, %%edx" & LF &
     "vpinsrd $1, (%%r15,%%rdx,4), %%xmm1, %%xmm1" & LF &
     "shrq $16, %%r14" & LF &
     "movzwl %%r14w, %%edx" & LF &
     "vpinsrd $2, (%%r15,%%rdx,4), %%xmm1, %%xmm1" & LF &
     "shrq $16, %%r14" & LF &
     "vpinsrd $3, (%%r15,%%r14,4), %%xmm1, %%xmm1" & LF &
     "vinserti128 $1, %%xmm1, %%ymm0, %%ymm0" & LF &
     "movq 16(%0), %%rcx" & LF &
     "vpbroadcastd (%%r13), %%ymm2" & LF &
     "vpshufb (%%rcx), %%ymm2, %%ymm2" & LF &
     "vpand 32(%%rcx), %%ymm2, %%ymm2" & LF &
     "vpcmpeqb 32(%%rcx), %%ymm2, %%ymm2" & LF &
     "vpor %%ymm3, %%ymm2, %%ymm2" & LF &
     "vpshufb (%%r12), %%ymm20, %%ymm5";
   Small_Advance : constant String :=
     "addq $32, %%rdi" & LF &
     "addq $8, %%rsi" & LF &
     "incq %%r11" & LF &
     "addq $4, %%r13" & LF &
     "addq $32, %%r12" & LF &
     "decq %%r10" & LF &
     "jnz 1b" & LF &
     "movq %%rdi, %%rcx" & LF &
     "shrq $3, %%rcx" & LF &
     "subq $32, %%rcx";
   Small_Finish : constant String :=
     "addq $110, 0(%0)" & LF &
     "decq 64(%0)" & LF &
     "jnz 2b" & LF &
     "movq 56(%0), %%rdx";
   Dot_1 : constant String :=
     "movq 0(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm16";
   FMA_1 : constant String :=
     "movq 0(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm16, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm6";
   Dot_2 : constant String :=
     "movq 8(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm17";
   FMA_2 : constant String :=
     "movq 8(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm17, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm12";
   Dot_3 : constant String :=
     "movq 16(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm18";
   FMA_3 : constant String :=
     "movq 16(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm18, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm14";
   Dot_4 : constant String :=
     "movq 24(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm19";
   FMA_4 : constant String :=
     "movq 24(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm19, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm15";
   --  Fold each query in the same eight-lane binary64 order, then write
   --  directly to its validated destination. Widening four floats at once
   --  is exact; additions remain sequential, starting at positive zero.
   Store_1 : constant String :=
     "vcvtps2pd %%xmm6, %%ymm0" & LF &
     "vextractf128 $1, %%ymm6, %%xmm2" & LF &
     "vcvtps2pd %%xmm2, %%ymm2" & LF &
     "vxorpd %%xmm1, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm0, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm2, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vcvtsd2ss %%xmm1, %%xmm1, %%xmm1" & LF &
     "movq 0(%%rdx), %%rax" & LF &
     "vmovss %%xmm1, (%%rax)" & LF &
     "addq $4, 0(%%rdx)";
   Store_2 : constant String :=
     "vcvtps2pd %%xmm12, %%ymm0" & LF &
     "vextractf128 $1, %%ymm12, %%xmm2" & LF &
     "vcvtps2pd %%xmm2, %%ymm2" & LF &
     "vxorpd %%xmm1, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm0, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm2, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vcvtsd2ss %%xmm1, %%xmm1, %%xmm1" & LF &
     "movq 8(%%rdx), %%rax" & LF &
     "vmovss %%xmm1, (%%rax)" & LF &
     "addq $4, 8(%%rdx)";
   Store_3 : constant String :=
     "vcvtps2pd %%xmm14, %%ymm0" & LF &
     "vextractf128 $1, %%ymm14, %%xmm2" & LF &
     "vcvtps2pd %%xmm2, %%ymm2" & LF &
     "vxorpd %%xmm1, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm0, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm2, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vcvtsd2ss %%xmm1, %%xmm1, %%xmm1" & LF &
     "movq 16(%%rdx), %%rax" & LF &
     "vmovss %%xmm1, (%%rax)" & LF &
     "addq $4, 16(%%rdx)";
   Store_4 : constant String :=
     "vcvtps2pd %%xmm15, %%ymm0" & LF &
     "vextractf128 $1, %%ymm15, %%xmm2" & LF &
     "vcvtps2pd %%xmm2, %%ymm2" & LF &
     "vxorpd %%xmm1, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm0, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm2, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vcvtsd2ss %%xmm1, %%xmm1, %%xmm1" & LF &
     "movq 24(%%rdx), %%rax" & LF &
     "vmovss %%xmm1, (%%rax)" & LF &
     "addq $4, 24(%%rdx)";
   Dot_5 : constant String :=
     "movq 32(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm27";
   FMA_5 : constant String :=
     "movq 32(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm27, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm23";
   Store_5 : constant String :=
     "vcvtps2pd %%xmm23, %%ymm0" & LF &
     "vextractf32x4 $1, %%ymm23, %%xmm2" & LF &
     "vcvtps2pd %%xmm2, %%ymm2" & LF &
     "vxorpd %%xmm1, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm0, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm2, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vcvtsd2ss %%xmm1, %%xmm1, %%xmm1" & LF &
     "movq 32(%%rdx), %%rax" & LF &
     "vmovss %%xmm1, (%%rax)" & LF &
     "addq $4, 32(%%rdx)";
   Dot_6 : constant String :=
     "movq 40(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "vpmaddubsw %%ymm4, %%ymm0, %%ymm1" & LF &
     "vpdpwssd %%ymm5, %%ymm1, %%ymm28";
   FMA_6 : constant String :=
     "movq 40(%%r9), %%rax" & LF &
     "vcvtdq2ps %%ymm28, %%ymm1" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "vmulps %%ymm7, %%ymm8, %%ymm8" & LF &
     "vfmadd231ps %%ymm8, %%ymm1, %%ymm24";
   Store_6 : constant String :=
     "vcvtps2pd %%xmm24, %%ymm0" & LF &
     "vextractf32x4 $1, %%ymm24, %%xmm2" & LF &
     "vcvtps2pd %%xmm2, %%ymm2" & LF &
     "vxorpd %%xmm1, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm0, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm0, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vaddsd %%xmm2, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vextractf128 $1, %%ymm2, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vpermilpd $1, %%xmm3, %%xmm3" & LF &
     "vaddsd %%xmm3, %%xmm1, %%xmm1" & LF &
     "vcvtsd2ss %%xmm1, %%xmm1, %%xmm1" & LF &
     "movq 40(%%rdx), %%rax" & LF &
     "vmovss %%xmm1, (%%rax)" & LF &
     "addq $4, 40(%%rdx)";
   Next_Row : constant String :=
     "decq 80(%0)" & LF &
     "jz 4f" & LF &
     "movq 72(%0), %%rax" & LF &
     "movq %%rax, 64(%0)" & LF &
     "jmp 3b" & LF &
     "4:" & LF &
     "vzeroupper";
   Native_1 : constant String :=
     "3:" & LF &
     Small_Start & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     Small_Block & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     Small_Decode & LF &
     Dot_1 & LF &
     Small_Advance & LF &
     FMA_1 & LF &
     Small_Finish & LF &
     Store_1 & LF &
     Next_Row;
   Native_2 : constant String :=
     "3:" & LF &
     Small_Start & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
     Small_Block & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
     Small_Decode & LF &
     Dot_1 & LF &
     Dot_2 & LF &
     Small_Advance & LF &
     FMA_1 & LF &
     FMA_2 & LF &
     Small_Finish & LF &
     Store_1 & LF &
     Store_2 & LF &
     Next_Row;
   Native_3 : constant String :=
     "3:" & LF &
     Small_Start & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
     "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
     Small_Block & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
     "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
     Small_Decode & LF &
     Dot_1 & LF &
     Dot_2 & LF &
     Dot_3 & LF &
     Small_Advance & LF &
     FMA_1 & LF &
     FMA_2 & LF &
     FMA_3 & LF &
     Small_Finish & LF &
     Store_1 & LF &
     Store_2 & LF &
     Store_3 & LF &
     Next_Row;
   Native_4 : constant String :=
     "3:" & LF &
     Small_Start & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
     "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
     "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
     Small_Block & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
     "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
     "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
     Small_Decode & LF &
     Dot_1 & LF &
     Dot_2 & LF &
     Dot_3 & LF &
     Dot_4 & LF &
     Small_Advance & LF &
     FMA_1 & LF &
     FMA_2 & LF &
     FMA_3 & LF &
     FMA_4 & LF &
     Small_Finish & LF &
     Store_1 & LF &
     Store_2 & LF &
     Store_3 & LF &
     Store_4 & LF &
     Next_Row;

   Native_5 : constant String :=
     "3:" & LF &
     Small_Start & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
     "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
     "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
     "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
     Small_Block & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
     "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
     "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
     "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
     Small_Decode & LF &
     Dot_1 & LF &
     Dot_2 & LF &
     Dot_3 & LF &
     Dot_4 & LF &
     Dot_5 & LF &
     Small_Advance & LF &
     FMA_1 & LF &
     FMA_2 & LF &
     FMA_3 & LF &
     FMA_4 & LF &
     FMA_5 & LF &
     Small_Finish & LF &
     Store_1 & LF &
     Store_2 & LF &
     Store_3 & LF &
     Store_4 & LF &
     Store_5 & LF &
     Next_Row;
   Native_6 : constant String :=
     "3:" & LF &
     Small_Start & LF &
     "vpxord %%ymm6, %%ymm6, %%ymm6" & LF &
     "vpxord %%ymm12, %%ymm12, %%ymm12" & LF &
     "vpxord %%ymm14, %%ymm14, %%ymm14" & LF &
     "vpxord %%ymm15, %%ymm15, %%ymm15" & LF &
     "vpxord %%ymm23, %%ymm23, %%ymm23" & LF &
     "vpxord %%ymm24, %%ymm24, %%ymm24" & LF &
     Small_Block & LF &
     "vpxord %%ymm16, %%ymm16, %%ymm16" & LF &
     "vpxord %%ymm17, %%ymm17, %%ymm17" & LF &
     "vpxord %%ymm18, %%ymm18, %%ymm18" & LF &
     "vpxord %%ymm19, %%ymm19, %%ymm19" & LF &
     "vpxord %%ymm27, %%ymm27, %%ymm27" & LF &
     "vpxord %%ymm28, %%ymm28, %%ymm28" & LF &
     Small_Decode & LF &
     Dot_1 & LF &
     Dot_2 & LF &
     Dot_3 & LF &
     Dot_4 & LF &
     Dot_5 & LF &
     Dot_6 & LF &
     Small_Advance & LF &
     FMA_1 & LF &
     FMA_2 & LF &
     FMA_3 & LF &
     FMA_4 & LF &
     FMA_5 & LF &
     FMA_6 & LF &
     Small_Finish & LF &
     Store_1 & LF &
     Store_2 & LF &
     Store_3 & LF &
     Store_4 & LF &
     Store_5 & LF &
     Store_6 & LF &
     Next_Row;

   --  A ZMM holds two independent original eight-lane accumulators.
   --  The second query is duplicated only for an unused padding lane;
   --  only live queries are folded and published by the caller.
   Native_16 : constant String :=
     "movq 8(%0), %%r15" & LF &
     "movq 40(%0), %%r8" & LF &
     "movq 48(%0), %%r9" & LF &
     "xorq %%rdi, %%rdi" & LF &
     "vpxord %%zmm6, %%zmm6, %%zmm6" & LF &
     "vpxord %%zmm12, %%zmm12, %%zmm12" & LF &
     "vpxord %%zmm14, %%zmm14, %%zmm14" & LF &
     "vpxord %%zmm15, %%zmm15, %%zmm15" & LF &
     "vpxord %%zmm23, %%zmm23, %%zmm23" & LF &
     "vpxord %%zmm24, %%zmm24, %%zmm24" & LF &
     "vpxord %%zmm25, %%zmm25, %%zmm25" & LF &
     "vpxord %%zmm26, %%zmm26, %%zmm26" & LF &
     Small_Block & LF &
     "vshufi32x4 $68, %%zmm7, %%zmm7, %%zmm7" & LF &
     "vpxord %%zmm16, %%zmm16, %%zmm16" & LF &
     "vpxord %%zmm17, %%zmm17, %%zmm17" & LF &
     "vpxord %%zmm18, %%zmm18, %%zmm18" & LF &
     "vpxord %%zmm19, %%zmm19, %%zmm19" & LF &
     "vpxord %%zmm27, %%zmm27, %%zmm27" & LF &
     "vpxord %%zmm28, %%zmm28, %%zmm28" & LF &
     "vpxord %%zmm29, %%zmm29, %%zmm29" & LF &
     "vpxord %%zmm30, %%zmm30, %%zmm30" & LF &
     Small_Decode & LF &
     "vshufi32x4 $68, %%zmm0, %%zmm0, %%zmm0" & LF &
     "vshufi32x4 $68, %%zmm5, %%zmm5, %%zmm5" & LF &
     "movq 0(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 8(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm16" & LF &
     "movq 16(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 24(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm17" & LF &
     "movq 32(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 40(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm18" & LF &
     "movq 48(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 56(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm19" & LF &
     "movq 64(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 72(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm27" & LF &
     "movq 80(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 88(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm28" & LF &
     "movq 96(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 104(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm29" & LF &
     "movq 112(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm4" & LF &
     "vpsignb %%ymm2, %%ymm4, %%ymm4" & LF &
     "movq 120(%%r8), %%rax" & LF &
     "vmovdqu (%%rax,%%rdi), %%ymm9" & LF &
     "vpsignb %%ymm2, %%ymm9, %%ymm9" & LF &
     "vinserti64x4 $1, %%ymm9, %%zmm4, %%zmm4" & LF &
     "vpmaddubsw %%zmm4, %%zmm0, %%zmm1" & LF &
     "vpdpwssd %%zmm5, %%zmm1, %%zmm30" & LF &
     Small_Advance & LF &
     "vcvtdq2ps %%zmm16, %%zmm1" & LF &
     "movq 0(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 8(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm6" & LF &
     "vcvtdq2ps %%zmm17, %%zmm1" & LF &
     "movq 16(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 24(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm12" & LF &
     "vcvtdq2ps %%zmm18, %%zmm1" & LF &
     "movq 32(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 40(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm14" & LF &
     "vcvtdq2ps %%zmm19, %%zmm1" & LF &
     "movq 48(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 56(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm15" & LF &
     "vcvtdq2ps %%zmm27, %%zmm1" & LF &
     "movq 64(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 72(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm23" & LF &
     "vcvtdq2ps %%zmm28, %%zmm1" & LF &
     "movq 80(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 88(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm24" & LF &
     "vcvtdq2ps %%zmm29, %%zmm1" & LF &
     "movq 96(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 104(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm25" & LF &
     "vcvtdq2ps %%zmm30, %%zmm1" & LF &
     "movq 112(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm8" & LF &
     "movq 120(%%r9), %%rax" & LF &
     "vbroadcastss (%%rax,%%rcx), %%ymm9" & LF &
     "vinsertf64x4 $1, %%ymm9, %%zmm8, %%zmm8" & LF &
     "vmulps %%zmm7, %%zmm8, %%zmm8" & LF &
     "vfmadd231ps %%zmm8, %%zmm1, %%zmm26" & LF &
     "addq $110, 0(%0)" & LF &
     "decq 64(%0)" & LF &
     "jnz 2b" & LF &
     "movq 56(%0), %%rax" & LF &
     "vmovups %%zmm6, 0(%%rax)" & LF &
     "vmovups %%zmm12, 64(%%rax)" & LF &
     "vmovups %%zmm14, 128(%%rax)" & LF &
     "vmovups %%zmm15, 192(%%rax)" & LF &
     "vmovups %%zmm23, 256(%%rax)" & LF &
     "vmovups %%zmm24, 320(%%rax)" & LF &
     "vmovups %%zmm25, 384(%%rax)" & LF &
     "vmovups %%zmm26, 448(%%rax)" & LF &
     "vzeroupper";

   function Source_Row (V : Element_Count) return Element_Count is
     (if Input_Members'Length = 0 then V
      else Element_Count (Input_Members (Input_Members'First + Natural (V))));
   function Destination_Row (V : Element_Count) return Element_Count is
     (if Result_Members'Length = 0 then V
      else Element_Count (Result_Members (Result_Members'First + Natural (V))));
   function Negatable (At_Index : Element_Count) return Boolean;
   pragma Machine_Attribute (Negatable, "target", "avx512f,avx512bw,avx512vl,avx2,fma,bmi2");
   pragma No_Inline (Negatable);
   function Negatable (At_Index : Element_Count) return Boolean is
      Found : U32;
   begin
      System.Machine_Code.Asm
        ("movq %1, %%rdi" & LF & "movq %2, %%rcx" & LF
         & "movl $128, %%eax" & LF & "vpbroadcastb %%eax, %%ymm0" & LF
         & "1:" & LF & "vpcmpeqb (%%rdi), %%ymm0, %%ymm1" & LF
         & "vpmovmskb %%ymm1, %%eax" & LF & "testl %%eax, %%eax" & LF
         & "jnz 2f" & LF & "addq $32, %%rdi" & LF & "subq $32, %%rcx" & LF
         & "jnz 1b" & LF & "2:" & LF & "vzeroupper",
         Outputs => U32'Asm_Output ("=a", Found),
         Inputs => [System.Address'Asm_Input ("r", Values (Values'First + At_Index)'Address),
                    Element_Count'Asm_Input ("r", Columns)],
         Clobber => "rdi,rcx,ymm0,ymm1,cc,memory", Volatile => True);
      return Found = 0;
   end Negatable;

   procedure Run;
   pragma Machine_Attribute (Run, "target", "avx512f,avx512bw,avx512vl,avx512vnni,avx2,fma,bmi2");
   pragma No_Inline (Run);
   procedure Run is
   begin
      case Count is
         when 1 =>
            System.Machine_Code.Asm (Native_1,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when 2 =>
            System.Machine_Code.Asm (Native_2,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when 3 =>
            System.Machine_Code.Asm (Native_3,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when 4 =>
            System.Machine_Code.Asm (Native_4,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when 5 =>
            System.Machine_Code.Asm (Native_5,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when 6 =>
            System.Machine_Code.Asm (Native_6,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when 7 | 8 =>
            System.Machine_Code.Asm (Native_8,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
         when others =>
            System.Machine_Code.Asm (Native_16,
              Inputs => System.Address'Asm_Input ("r", Arguments'Address), Clobber => Clobbers, Volatile => True);
      end case;
   end Run;
begin
   Ok := False;
   if Count not in 1 .. 16
     or else Target = null or else Rows = 0 or else Blocks = 0 or else Blocks > 64 or else Count = 0
     or else Stride < Blocks * 256 or else Stride mod 32 /= 0 or else First mod 32 /= 0
     or else Row_Bytes /= B.Byte_Count (Blocks) * 110 or else Offset > Data'Length
     or else B.Byte_Count (Rows) > (Data'Length - Offset) / Row_Bytes
     or else (Input_Members'Length /= 0 and then Input_Members'Length /= Count)
     or else (Result_Members'Length /= 0 and then Result_Members'Length /= Count)
     or else Result_Stride < Rows or else Result_First > Result_Stride - Rows
   then return; end if;
   Columns := Blocks * 256;
   if Values'Length < Columns or else First > Values'Length - Columns
     or else Target.all'Length < Rows or else Result_First > Target.all'Length - Rows
   then return; end if;
   for V in Element_Count range 0 .. Count - 1 loop
      if Source_Row (V) > (Values'Length - First - Columns) / Stride
        or else Destination_Row (V) > (Target.all'Length - Result_First - Rows) / Result_Stride
      then return; end if;
      declare
         Last_Value : constant Element_Count := First + Source_Row (V) * Stride + Columns;
      begin
         if Scales'Length < Last_Value / 32 then return; end if;
      end;
      if Result_Members'Length /= 0 then
         for Previous in Element_Count range 0 .. V - 1 loop
            if Destination_Row (Previous) = Destination_Row (V) then return; end if;
         end loop;
      end if;
      if not Negatable (First + Source_Row (V) * Stride) then return; end if;
   end loop;
   for Q in Natural range 0 .. (if Count <= 6 then Natural (Count) elsif Count <= 8 then 8 else 16) - 1 loop
      declare
         At_Input : constant Element_Count := First
           + Source_Row (Element_Count'Min (Element_Count (Q), Count - 1)) * Stride;
      begin
         Inputs (Q) := Values (Values'First + At_Input)'Address;
         Factors (Q) := Scales (Scales'First + At_Input / 32)'Address;
      end;
   end loop;
   if Count <= 6 then
      for Q in Element_Count range 0 .. Count - 1 loop
         Outputs (Natural (Q)) := Target.all
           (Target.all'First + Result_First + Destination_Row (Q) * Result_Stride)'Address;
      end loop;
      Arguments := [Data (Data'First + Offset)'Address,
        GI.Grid_Address (G.Type_IQ3_S), GI.Sign_Shuffle_Address, GI.Scale_Shuffle_Address,
        System.Null_Address, Inputs'Address, Factors'Address, Outputs'Address,
        System.Storage_Elements.To_Address (System.Storage_Elements.Integer_Address (Blocks)),
        System.Storage_Elements.To_Address (System.Storage_Elements.Integer_Address (Blocks)),
        System.Storage_Elements.To_Address (System.Storage_Elements.Integer_Address (Rows))];
      Run;
      Ok := True;
      return;
   end if;
   for Row in Element_Count range 0 .. Rows - 1 loop
      Arguments := [Data (Data'First + Offset + B.Byte_Count (Row) * Row_Bytes)'Address,
        GI.Grid_Address (G.Type_IQ3_S), GI.Sign_Shuffle_Address, GI.Scale_Shuffle_Address,
        System.Null_Address, Inputs'Address, Factors'Address, Carry'Address,
        System.Storage_Elements.To_Address (System.Storage_Elements.Integer_Address (Blocks)),
        System.Null_Address, System.Null_Address];
      Run;
      for Q in Element_Count range 0 .. Count - 1 loop
         declare
            Sum : N.Wide_Real := 0.0;
         begin
            for Lane in Natural range 0 .. 7 loop Sum := Sum + N.Wide_Real (Carry (Natural (Q)) (Lane)); end loop;
            Target.all (Target.all'First + Result_First + Row
              + Destination_Row (Q) * Result_Stride) := N.Real (Sum);
         end;
      end loop;
   end loop;
   Ok := True;
end IQ3_Reference_Products;
