with System.Machine_Code;
package body Model_Runner.Tensors.Wide_Products is
   package B renames Model_Runner.Bytes;
   package N renames Model_Runner.Numerics;
   --  Keep eight rows' scales and minima in the extra AVX-512 registers.
   --  Four independent binary64 lanes per row retain their original order.
   --  Load four selected row blocks ahead of arithmetic, without packing
   --  pairs of unrelated rows into a wider accumulator.
   procedure Rows
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        (
           "vmovupd 0(%4), %%ymm0" & LF
         & "vmovupd 32(%4), %%ymm1" & LF
         & "vmovupd 64(%4), %%ymm2" & LF
         & "vmovupd 96(%4), %%ymm3" & LF
         & "vmovupd 128(%4), %%ymm4" & LF
         & "vmovupd 160(%4), %%ymm5" & LF
         & "vmovupd 192(%4), %%ymm6" & LF
         & "vmovupd 224(%4), %%ymm7" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r11" & LF
         & "leaq (%%r8, %%r10, 2), %%r12" & LF
         & "addq %%r10, %%r12" & LF
         & "leaq (%%r8, %%r10, 4), %%r13" & LF
         & "leaq (%%r13, %%r10, 2), %%r14" & LF
         & "addq %%r10, %%r14" & LF
         & "movl $4, %%r15d" & LF
         & "1:" & LF
         & "vbroadcastss 0(%%r11), %%ymm16" & LF
         & "vbroadcastss 4(%%r11), %%ymm24" & LF
         & "vbroadcastss 8(%%r11), %%ymm17" & LF
         & "vbroadcastss 12(%%r11), %%ymm25" & LF
         & "vbroadcastss 16(%%r11), %%ymm18" & LF
         & "vbroadcastss 20(%%r11), %%ymm26" & LF
         & "vbroadcastss 24(%%r11), %%ymm19" & LF
         & "vbroadcastss 28(%%r11), %%ymm27" & LF
         & "vbroadcastss 32(%%r11), %%ymm20" & LF
         & "vbroadcastss 36(%%r11), %%ymm28" & LF
         & "vbroadcastss 40(%%r11), %%ymm21" & LF
         & "vbroadcastss 44(%%r11), %%ymm29" & LF
         & "vbroadcastss 48(%%r11), %%ymm22" & LF
         & "vbroadcastss 52(%%r11), %%ymm30" & LF
         & "vbroadcastss 56(%%r11), %%ymm23" & LF
         & "vbroadcastss 60(%%r11), %%ymm31" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vpmovzxbd 0(%%r8), %%ymm12" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 0(%%r12), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 0(%%r13), %%ymm12" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 0(%%r14), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vcvtps2pd 48(%%r9), %%ymm9" & LF
         & "vpmovzxbd 8(%%r8), %%ymm12" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 8(%%r12), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 8(%%r13), %%ymm12" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 8(%%r14), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vpmovzxbd 16(%%r8), %%ymm12" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 16(%%r12), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 16(%%r13), %%ymm12" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 16(%%r14), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vcvtps2pd 112(%%r9), %%ymm9" & LF
         & "vpmovzxbd 24(%%r8), %%ymm12" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 24(%%r12), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 24(%%r13), %%ymm12" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 24(%%r14), %%ymm15" & LF
         & "vpslld $28, %%ymm12, %%ymm12" & LF
         & "vpsrld $28, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpslld $28, %%ymm13, %%ymm13" & LF
         & "vpsrld $28, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpslld $28, %%ymm15, %%ymm15" & LF
         & "vpsrld $28, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "vbroadcastss 0(%%r11), %%ymm16" & LF
         & "vbroadcastss 4(%%r11), %%ymm24" & LF
         & "vbroadcastss 8(%%r11), %%ymm17" & LF
         & "vbroadcastss 12(%%r11), %%ymm25" & LF
         & "vbroadcastss 16(%%r11), %%ymm18" & LF
         & "vbroadcastss 20(%%r11), %%ymm26" & LF
         & "vbroadcastss 24(%%r11), %%ymm19" & LF
         & "vbroadcastss 28(%%r11), %%ymm27" & LF
         & "vbroadcastss 32(%%r11), %%ymm20" & LF
         & "vbroadcastss 36(%%r11), %%ymm28" & LF
         & "vbroadcastss 40(%%r11), %%ymm21" & LF
         & "vbroadcastss 44(%%r11), %%ymm29" & LF
         & "vbroadcastss 48(%%r11), %%ymm22" & LF
         & "vbroadcastss 52(%%r11), %%ymm30" & LF
         & "vbroadcastss 56(%%r11), %%ymm23" & LF
         & "vbroadcastss 60(%%r11), %%ymm31" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vpmovzxbd 0(%%r8), %%ymm12" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 0(%%r12), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 0(%%r13), %%ymm12" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 0(%%r14), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vcvtps2pd 48(%%r9), %%ymm9" & LF
         & "vpmovzxbd 8(%%r8), %%ymm12" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 8(%%r12), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 8(%%r13), %%ymm12" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 8(%%r14), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vpmovzxbd 16(%%r8), %%ymm12" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 16(%%r12), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 16(%%r13), %%ymm12" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 16(%%r14), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vcvtps2pd 112(%%r9), %%ymm9" & LF
         & "vpmovzxbd 24(%%r8), %%ymm12" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm13" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 24(%%r12), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm16, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm24, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm0" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm17, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm25, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm1" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm18, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm26, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm2" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm19, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm27, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm3" & LF
         & "vpmovzxbd 24(%%r13), %%ymm12" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm13" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpmovzxbd 24(%%r14), %%ymm15" & LF
         & "vpsrld $4, %%ymm12, %%ymm12" & LF
         & "vcvtdq2ps %%ymm12, %%ymm12" & LF
         & "vmulps %%ymm20, %%ymm12, %%ymm12" & LF
         & "vsubps %%ymm28, %%ymm12, %%ymm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm12, %%xmm12" & LF
         & "vcvtps2pd %%xmm12, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vpsrld $4, %%ymm13, %%ymm13" & LF
         & "vcvtdq2ps %%ymm13, %%ymm13" & LF
         & "vmulps %%ymm21, %%ymm13, %%ymm13" & LF
         & "vsubps %%ymm29, %%ymm13, %%ymm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm13, %%xmm13" & LF
         & "vcvtps2pd %%xmm13, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm22, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm30, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vcvtdq2ps %%ymm15, %%ymm15" & LF
         & "vmulps %%ymm23, %%ymm15, %%ymm15" & LF
         & "vsubps %%ymm31, %%ymm15, %%ymm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm15, %%xmm15" & LF
         & "vcvtps2pd %%xmm15, %%ymm10" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "addq $32, %%r8" & LF
         & "addq $32, %%r12" & LF
         & "addq $32, %%r13" & LF
         & "addq $32, %%r14" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "vmovupd %%ymm0, 0(%4)" & LF
         & "vmovupd %%ymm1, 32(%4)" & LF
         & "vmovupd %%ymm2, 64(%4)" & LF
         & "vmovupd %%ymm3, 96(%4)" & LF
         & "vmovupd %%ymm4, 128(%4)" & LF
         & "vmovupd %%ymm5, 160(%4)" & LF
         & "vmovupd %%ymm6, 192(%4)" & LF
         & "vmovupd %%ymm7, 224(%4)" & LF
         & "vzeroupper",
         Inputs =>
           [System.Address'Asm_Input ("r", Weight), System.Address'Asm_Input ("r", Vector),
            B.Byte_Count'Asm_Input ("r", Row_Stride),
            System.Address'Asm_Input ("r", Parameters (Parameters'First)'Address),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, ymm8, ymm9, ymm10, "
           & "ymm12, ymm13, ymm14, ymm15, ymm16, ymm17, ymm18, ymm19, ymm20, ymm21, ymm22, ymm23, "
           & "ymm24, ymm25, ymm26, ymm27, ymm28, ymm29, ymm30, ymm31, "
           & "r8, r9, r10, r11, r12, r13, r14, r15, cc, memory",
         Volatile => True);
   end Rows;

   --  Two independent rows per ZMM register, four binary64 lanes each.
   --  Each row retains its original lane and block accumulation order.
   procedure Panels
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        (
           "vmovupd 0(%4), %%zmm0" & LF
         & "vmovupd 64(%4), %%zmm1" & LF
         & "vmovupd 128(%4), %%zmm2" & LF
         & "vmovupd 192(%4), %%zmm3" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r11" & LF
         & "movl $4, %%r15d" & LF
         & "1:" & LF
         & "vbroadcastss 0(%%r11), %%xmm16" & LF
         & "vbroadcastss 8(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm16, %%ymm16" & LF
         & "vbroadcastss 4(%%r11), %%xmm17" & LF
         & "vbroadcastss 12(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm17, %%ymm17" & LF
         & "vbroadcastss 16(%%r11), %%xmm18" & LF
         & "vbroadcastss 24(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm18, %%ymm18" & LF
         & "vbroadcastss 20(%%r11), %%xmm19" & LF
         & "vbroadcastss 28(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm19, %%ymm19" & LF
         & "vbroadcastss 32(%%r11), %%xmm20" & LF
         & "vbroadcastss 40(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm20, %%ymm20" & LF
         & "vbroadcastss 36(%%r11), %%xmm21" & LF
         & "vbroadcastss 44(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm21, %%ymm21" & LF
         & "vbroadcastss 48(%%r11), %%xmm22" & LF
         & "vbroadcastss 56(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm22, %%ymm22" & LF
         & "vbroadcastss 52(%%r11), %%xmm23" & LF
         & "vbroadcastss 60(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm23, %%ymm23" & LF
         & "vbroadcastf32x4 0(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 0(%%r8), %%ymm8" & LF
         & "vpmovzxbd 8(%%r8), %%ymm9" & LF
         & "vpmovzxbd 16(%%r8), %%ymm10" & LF
         & "vpmovzxbd 24(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 16(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 32(%%r8), %%ymm8" & LF
         & "vpmovzxbd 40(%%r8), %%ymm9" & LF
         & "vpmovzxbd 48(%%r8), %%ymm10" & LF
         & "vpmovzxbd 56(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 32(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 64(%%r8), %%ymm8" & LF
         & "vpmovzxbd 72(%%r8), %%ymm9" & LF
         & "vpmovzxbd 80(%%r8), %%ymm10" & LF
         & "vpmovzxbd 88(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 48(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 96(%%r8), %%ymm8" & LF
         & "vpmovzxbd 104(%%r8), %%ymm9" & LF
         & "vpmovzxbd 112(%%r8), %%ymm10" & LF
         & "vpmovzxbd 120(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 64(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 128(%%r8), %%ymm8" & LF
         & "vpmovzxbd 136(%%r8), %%ymm9" & LF
         & "vpmovzxbd 144(%%r8), %%ymm10" & LF
         & "vpmovzxbd 152(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 80(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 160(%%r8), %%ymm8" & LF
         & "vpmovzxbd 168(%%r8), %%ymm9" & LF
         & "vpmovzxbd 176(%%r8), %%ymm10" & LF
         & "vpmovzxbd 184(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 96(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 192(%%r8), %%ymm8" & LF
         & "vpmovzxbd 200(%%r8), %%ymm9" & LF
         & "vpmovzxbd 208(%%r8), %%ymm10" & LF
         & "vpmovzxbd 216(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 112(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 224(%%r8), %%ymm8" & LF
         & "vpmovzxbd 232(%%r8), %%ymm9" & LF
         & "vpmovzxbd 240(%%r8), %%ymm10" & LF
         & "vpmovzxbd 248(%%r8), %%ymm11" & LF
         & "vpslld $28, %%ymm8, %%ymm8" & LF
         & "vpsrld $28, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpslld $28, %%ymm9, %%ymm9" & LF
         & "vpsrld $28, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpslld $28, %%ymm10, %%ymm10" & LF
         & "vpsrld $28, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpslld $28, %%ymm11, %%ymm11" & LF
         & "vpsrld $28, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "vbroadcastss 0(%%r11), %%xmm16" & LF
         & "vbroadcastss 8(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm16, %%ymm16" & LF
         & "vbroadcastss 4(%%r11), %%xmm17" & LF
         & "vbroadcastss 12(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm17, %%ymm17" & LF
         & "vbroadcastss 16(%%r11), %%xmm18" & LF
         & "vbroadcastss 24(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm18, %%ymm18" & LF
         & "vbroadcastss 20(%%r11), %%xmm19" & LF
         & "vbroadcastss 28(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm19, %%ymm19" & LF
         & "vbroadcastss 32(%%r11), %%xmm20" & LF
         & "vbroadcastss 40(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm20, %%ymm20" & LF
         & "vbroadcastss 36(%%r11), %%xmm21" & LF
         & "vbroadcastss 44(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm21, %%ymm21" & LF
         & "vbroadcastss 48(%%r11), %%xmm22" & LF
         & "vbroadcastss 56(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm22, %%ymm22" & LF
         & "vbroadcastss 52(%%r11), %%xmm23" & LF
         & "vbroadcastss 60(%%r11), %%xmm24" & LF
         & "vinsertf32x4 $1, %%xmm24, %%ymm23, %%ymm23" & LF
         & "vbroadcastf32x4 0(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 0(%%r8), %%ymm8" & LF
         & "vpmovzxbd 8(%%r8), %%ymm9" & LF
         & "vpmovzxbd 16(%%r8), %%ymm10" & LF
         & "vpmovzxbd 24(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 16(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 32(%%r8), %%ymm8" & LF
         & "vpmovzxbd 40(%%r8), %%ymm9" & LF
         & "vpmovzxbd 48(%%r8), %%ymm10" & LF
         & "vpmovzxbd 56(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 32(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 64(%%r8), %%ymm8" & LF
         & "vpmovzxbd 72(%%r8), %%ymm9" & LF
         & "vpmovzxbd 80(%%r8), %%ymm10" & LF
         & "vpmovzxbd 88(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 48(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 96(%%r8), %%ymm8" & LF
         & "vpmovzxbd 104(%%r8), %%ymm9" & LF
         & "vpmovzxbd 112(%%r8), %%ymm10" & LF
         & "vpmovzxbd 120(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 64(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 128(%%r8), %%ymm8" & LF
         & "vpmovzxbd 136(%%r8), %%ymm9" & LF
         & "vpmovzxbd 144(%%r8), %%ymm10" & LF
         & "vpmovzxbd 152(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 80(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 160(%%r8), %%ymm8" & LF
         & "vpmovzxbd 168(%%r8), %%ymm9" & LF
         & "vpmovzxbd 176(%%r8), %%ymm10" & LF
         & "vpmovzxbd 184(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 96(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 192(%%r8), %%ymm8" & LF
         & "vpmovzxbd 200(%%r8), %%ymm9" & LF
         & "vpmovzxbd 208(%%r8), %%ymm10" & LF
         & "vpmovzxbd 216(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "vbroadcastf32x4 112(%%r9), %%ymm4" & LF
         & "vcvtps2pd %%ymm4, %%zmm4" & LF
         & "vpmovzxbd 224(%%r8), %%ymm8" & LF
         & "vpmovzxbd 232(%%r8), %%ymm9" & LF
         & "vpmovzxbd 240(%%r8), %%ymm10" & LF
         & "vpmovzxbd 248(%%r8), %%ymm11" & LF
         & "vpsrld $4, %%ymm8, %%ymm8" & LF
         & "vcvtdq2ps %%ymm8, %%ymm8" & LF
         & "vmulps %%ymm16, %%ymm8, %%ymm8" & LF
         & "vsubps %%ymm17, %%ymm8, %%ymm8" & LF
         & "vcvtps2pd %%ymm8, %%zmm8" & LF
         & "vfmadd231pd %%zmm4, %%zmm8, %%zmm0" & LF
         & "vpsrld $4, %%ymm9, %%ymm9" & LF
         & "vcvtdq2ps %%ymm9, %%ymm9" & LF
         & "vmulps %%ymm18, %%ymm9, %%ymm9" & LF
         & "vsubps %%ymm19, %%ymm9, %%ymm9" & LF
         & "vcvtps2pd %%ymm9, %%zmm9" & LF
         & "vfmadd231pd %%zmm4, %%zmm9, %%zmm1" & LF
         & "vpsrld $4, %%ymm10, %%ymm10" & LF
         & "vcvtdq2ps %%ymm10, %%ymm10" & LF
         & "vmulps %%ymm20, %%ymm10, %%ymm10" & LF
         & "vsubps %%ymm21, %%ymm10, %%ymm10" & LF
         & "vcvtps2pd %%ymm10, %%zmm10" & LF
         & "vfmadd231pd %%zmm4, %%zmm10, %%zmm2" & LF
         & "vpsrld $4, %%ymm11, %%ymm11" & LF
         & "vcvtdq2ps %%ymm11, %%ymm11" & LF
         & "vmulps %%ymm22, %%ymm11, %%ymm11" & LF
         & "vsubps %%ymm23, %%ymm11, %%ymm11" & LF
         & "vcvtps2pd %%ymm11, %%zmm11" & LF
         & "vfmadd231pd %%zmm4, %%zmm11, %%zmm3" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "addq $256, %%r8" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "vmovupd %%zmm0, 0(%4)" & LF
         & "vmovupd %%zmm1, 64(%4)" & LF
         & "vmovupd %%zmm2, 128(%4)" & LF
         & "vmovupd %%zmm3, 192(%4)" & LF
         & "vzeroupper",
         Inputs =>
           [System.Address'Asm_Input ("r", Weight), System.Address'Asm_Input ("r", Vector),
            B.Byte_Count'Asm_Input ("r", Row_Stride),
            System.Address'Asm_Input ("r", Parameters (Parameters'First)'Address),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "zmm0, zmm1, zmm2, zmm3, zmm4, zmm8, zmm9, zmm10, zmm11, zmm12, "
           & "zmm16, zmm17, zmm18, zmm19, zmm20, zmm21, zmm22, zmm23, zmm24, "
           & "r8, r9, r10, r11, r12, r13, r14, r15, cc, memory",
         Volatile => True);
   end Panels;

end Model_Runner.Tensors.Wide_Products;
