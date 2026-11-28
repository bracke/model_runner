separate (Model_Runner.Quantization.Integers.Kernels)
procedure Reference_Tile
  (Format : G.Tensor_Type; Data : Model_Runner.Bytes.Byte_Array;
   Offset, Row_Bytes : Model_Runner.Bytes.Byte_Count;
   Rows, Blocks : Element_Count; Values : Signed_Array;
   Scales : N.Real_Array; Totals, Halves : Sum_Array;
   First, Stride, Count : Element_Count;
   Sums : in out N.Wide_Real_Array; Ok : out Boolean;
   Interleaved : Boolean; Metadata : N.Real_Array;
   Target : access N.Real_Array := null; Result_First, Result_Stride : Element_Count := 0;
   Partner : B.Byte_Array := []; Partner_Offset : B.Byte_Count := 0;
   Partner_Metadata : N.Real_Array := []; Partner_Target : access N.Real_Array := null;
   Result_Members : Model_Runner.Shares.Member_Rows := [];
      Input_Members : Model_Runner.Shares.Member_Rows := [])
is
   package B renames Model_Runner.Bytes;
   package IL renames Model_Runner.Quantization.Interleave;
   use type Interfaces.Integer_32;
   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;
   Groups : constant Element_Count := (if Format in G.Type_Q8_0 | G.Type_Q5_0 then 1 else 8);
   Columns : constant Element_Count := Blocks * Groups * 32;
   Fields : constant Element_Count := (if Format = G.Type_Q6_K then 5 else 6);
   Native : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
   Coefficients : B.Byte_Array (0 .. B.Byte_Count (Blocks * 32) - 1);
   D : N.Real_Array (0 .. Blocks * 4 - 1);
   Joint : constant Boolean := Partner_Target /= null;
   Streaming : constant Boolean := not Interleaved;
   --  Reuse the eight-vector kernel for seven native Q5_K inputs. The last
   --  address repeats a live input; only the seven requested results escape.
   Seven : constant Boolean := Format = G.Type_Q5_K and then Count = 7
     and then Streaming and then not Joint;
   --  Streaming reads native bytes and integer sums directly. Keep a single
   --  addressable sentinel for unused argument fields instead of staging.
   Codes : B.Byte_Array (0 .. B.Byte_Count (if Streaming then 1 else Blocks * Groups * 64) - 1);
   Factors : Sum_Array (0 .. (if Streaming then 1 else Blocks * Groups * 16) - 1);
   Correction : Sum_Array (0 .. (if Streaming then 1 else Blocks * 8 * 16) - 1);
   Quad : constant Boolean := not Joint and then Groups = 1 and then not Interleaved
     and then Count = 2 and then Rows <= 4096;
   Cached_Coefficients : constant Boolean := Streaming and then Groups = 8
     and then Metadata'Length = Rows * Blocks * Fields
     and then (not Joint or else Partner_Metadata'Length = Rows * Blocks * Fields);
   Answer : N.Wide_Real_Array (1 .. (if Target = null then Rows * Count else 0));
   Acc : N.Real_Array (0 .. 255);
   type Addresses is array (Element_Count range 0 .. (if Seven then 8 else Count) - 1) of System.Address;
   Inputs, Scaling, Totalling : Addresses;
   type Tile_Arguments is record
      Codes, Factors, Correction, Inputs, Scaling, D, Output : System.Address;
      Blocks, Correction_Stride : Element_Count;
      Delta_Bytes : System.Storage_Elements.Integer_Address;
      Map, Bits, Coefficient_A, Coefficient_B : System.Address;
      Coefficient_Stride : Element_Count;
      Weight_Rows : System.Address;
   end record;
   for Tile_Arguments use record
      Codes at 0 range 0 .. 63;
      Factors at 8 range 0 .. 63;
      Correction at 16 range 0 .. 63;
      Inputs at 24 range 0 .. 63;
      Scaling at 32 range 0 .. 63;
      D at 40 range 0 .. 63;
      Output at 48 range 0 .. 63;
      Blocks at 56 range 0 .. 63;
      Correction_Stride at 64 range 0 .. 63;
      Delta_Bytes at 72 range 0 .. 63;
      Map at 80 range 0 .. 63;
      Bits at 88 range 0 .. 63;
      Coefficient_A at 96 range 0 .. 63;
      Coefficient_B at 104 range 0 .. 63;
      Coefficient_Stride at 112 range 0 .. 63;
      Weight_Rows at 120 range 0 .. 63;
   end record;
   Arguments : aliased Tile_Arguments;
   Argument_Pointer : aliased constant System.Address := Arguments'Address;
   type Four_Addresses is array (Natural range 0 .. 3) of System.Address;
   Weight_Rows : Four_Addresses;
   Step : Element_Count;
   R, V : Element_Count := 0;
   LF : constant Character := ASCII.LF;

   Map : constant B.Byte_Array (0 .. 31) :=
     [0 .. 7 => 0, 8 .. 15 => 1, 16 .. 23 => 2, 24 .. 31 => 3];
   Bits : constant B.Byte_Array (0 .. 31) :=
     [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128,
      1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];

   function Source_Row (Index : Element_Count) return Element_Count is
     (if Input_Members'Length = 0 then Index
      else Element_Count (Input_Members (Input_Members'First + Natural (Index))));

   function Inputs_Fit return Boolean is
      Last : Element_Count := 0;
      Extent : Element_Count;
   begin
      if Input_Members'Length /= 0 and then Input_Members'Length /= Count then return False; end if;
      if Count = 0 then return False; end if;
      if Input_Members'Length = 0 then Last := Count - 1;
      else
         --  A map consumes Stride even when only one vector is requested.
         --  The ordinary one-vector path does not use Stride at all.
         if Count = 1 and then Stride mod (Groups * 32) /= 0 then return False; end if;
         for Member of Input_Members loop Last := Element_Count'Max (Last, Element_Count (Member)); end loop;
      end if;
      if Stride /= 0 and then Last > (Element_Count'Last - First) / Stride then return False; end if;
      Extent := First + Last * Stride;
      if Extent > Element_Count'Last - Columns then return False; end if;
      return Values'Length >= Extent + Columns
        and then Scales'Length >= Extent / 32 + Blocks * Groups
        and then (Groups /= 8 or else Totals'Length >= Extent / 32 + Blocks * 8)
        and then (Format /= G.Type_Q6_K or else Halves'Length >= Extent / 16 + Blocks * 16);
   end Inputs_Fit;

   Safe_Signed : Boolean := True;
   function Negatable (Input : System.Address; Length : Element_Count) return Boolean is
      Bad : Interfaces.Unsigned_32;
   begin
      System.Machine_Code.Asm
        ("movq %1, %%r8" & LF
         & "movq %2, %%r9" & LF
         & "movl $0x80808080, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm0" & LF
         & "xorl %%ecx, %%ecx" & LF
         & "1:" & LF
         & "vpcmpeqb (%%r8), %%ymm0, %%ymm1" & LF
         & "vpmovmskb %%ymm1, %%eax" & LF
         & "orl %%eax, %%ecx" & LF
         & "addq $32, %%r8" & LF
         & "subq $32, %%r9" & LF
         & "jnz 1b" & LF
         & "movl %%ecx, %0" & LF
         & "vzeroupper",
         Outputs => Interfaces.Unsigned_32'Asm_Output ("=r", Bad),
         Inputs => [System.Address'Asm_Input ("r", Input), Element_Count'Asm_Input ("r", Length)],
         Clobber => "rax,rcx,r8,r9,ymm0,ymm1,cc,memory", Volatile => True);
      return Bad = 0;
   end Negatable;

   procedure Decode_Codes (Source, Target : System.Address) is
   begin
   if Format = G.Type_Q8_0 then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "vmovdqu 2(%%r8), %%ymm0" & LF
         & "vmovdqu %%ymm0, (%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Map (0)'Address),
                    System.Address'Asm_Input ("r", Bits (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm4,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory",
         Volatile => True);
   elsif Format = G.Type_Q5_0 then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "vmovdqu (%2), %%ymm12" & LF
         & "vmovdqu (%3), %%ymm13" & LF
         & "vpbroadcastd 2(%%r8), %%ymm4" & LF
         & "vpshufb %%ymm12, %%ymm4, %%ymm4" & LF
         & "vpand %%ymm13, %%ymm4, %%ymm4" & LF
         & "vpxor %%ymm14, %%ymm14, %%ymm14" & LF
         & "vpcmpeqb %%ymm14, %%ymm4, %%ymm4" & LF
         & "movl $0x10101010, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm15" & LF
         & "vpand %%ymm15, %%ymm4, %%ymm4" & LF
         & "vmovdqu 6(%%r8), %%xmm0" & LF
         & "vpand %%xmm9, %%xmm0, %%xmm1" & LF
         & "vpsrlw $4, %%xmm0, %%xmm2" & LF
         & "vpand %%xmm9, %%xmm2, %%xmm2" & LF
         & "vinserti128 $1, %%xmm2, %%ymm1, %%ymm1" & LF
         & "vpsubb %%ymm4, %%ymm1, %%ymm1" & LF
         & "vmovdqu %%ymm1, (%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Map (0)'Address),
                    System.Address'Asm_Input ("r", Bits (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm4,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory",
         Volatile => True);
   elsif Format = G.Type_Q6_K then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "movl $0x03030303, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm10" & LF
         & "vmovdqu 0(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 128(%%r8), %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 0(%%r9)" & LF
         & "vmovdqu 32(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 128(%%r8), %%ymm1" & LF
         & "vpsrlw $2, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 64(%%r9)" & LF
         & "vmovdqu 0(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 128(%%r8), %%ymm1" & LF
         & "vpsrlw $4, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 128(%%r9)" & LF
         & "vmovdqu 32(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 128(%%r8), %%ymm1" & LF
         & "vpsrlw $6, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 192(%%r9)" & LF
         & "vmovdqu 64(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 160(%%r8), %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 256(%%r9)" & LF
         & "vmovdqu 96(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 160(%%r8), %%ymm1" & LF
         & "vpsrlw $2, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 320(%%r9)" & LF
         & "vmovdqu 64(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 160(%%r8), %%ymm1" & LF
         & "vpsrlw $4, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 384(%%r9)" & LF
         & "vmovdqu 96(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu 160(%%r8), %%ymm1" & LF
         & "vpsrlw $6, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 448(%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Map (0)'Address),
                    System.Address'Asm_Input ("r", Bits (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm4,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory",
         Volatile => True);
   else
      if Format = G.Type_Q4_K then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "vmovdqu 16(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 0(%%r9)" & LF
         & "vmovdqu 16(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 64(%%r9)" & LF
         & "vmovdqu 48(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 128(%%r9)" & LF
         & "vmovdqu 48(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 192(%%r9)" & LF
         & "vmovdqu 80(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 256(%%r9)" & LF
         & "vmovdqu 80(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 320(%%r9)" & LF
         & "vmovdqu 112(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 384(%%r9)" & LF
         & "vmovdqu 112(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 448(%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Map (0)'Address),
                    System.Address'Asm_Input ("r", Bits (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm4,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory",
         Volatile => True);
      end if;
      if Format = G.Type_Q5_K then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "movl $0x01010101, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm10" & LF
         & "vmovdqu 16(%%r8), %%ymm12" & LF
         & "vmovdqu 48(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $0, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 0(%%r9)" & LF
         & "vmovdqu 48(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $1, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 64(%%r9)" & LF
         & "vmovdqu 80(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $2, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 128(%%r9)" & LF
         & "vmovdqu 80(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $3, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 192(%%r9)" & LF
         & "vmovdqu 112(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $4, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 256(%%r9)" & LF
         & "vmovdqu 112(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $5, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 320(%%r9)" & LF
         & "vmovdqu 144(%%r8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $6, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 384(%%r9)" & LF
         & "vmovdqu 144(%%r8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $7, %%ymm12, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 448(%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Map (0)'Address),
                    System.Address'Asm_Input ("r", Bits (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm4,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,ymm15,cc,memory",
         Volatile => True);
      end if;
   end if;
   end Decode_Codes;

   function Fold (At_Lane : Element_Count) return N.Real is
      A : constant N.Real := Acc (At_Lane) + Acc (At_Lane + 4);
      B : constant N.Real := Acc (At_Lane + 1) + Acc (At_Lane + 5);
      C : constant N.Real := Acc (At_Lane + 2) + Acc (At_Lane + 6);
      D : constant N.Real := Acc (At_Lane + 3) + Acc (At_Lane + 7);
   begin
      return (A + C) + (B + D);
   end Fold;

   procedure Expand_Factors (Block, Lane : Element_Count) is
      At_Coeff : constant B.Byte_Count := B.Byte_Count ((Block * 2 + Lane) * 16);
   begin
               for Group in 0 .. Groups - 1 loop
                  declare
                     Input : constant System.Address := Coefficients
                       (At_Coeff + B.Byte_Count (if Format = G.Type_Q6_K then Group * 2 else Group))'Address;
                     Target : constant System.Address := Factors ((Block * Groups + Group) * 16 + Lane * 8)'Address;
                  begin
                     if Format = G.Type_Q6_K then
                        System.Machine_Code.Asm
                          ("movsbl (%0), %%eax" & LF
                           & "vmovd %%eax, %%xmm0" & LF
                           & "vpbroadcastd %%xmm0, %%xmm0" & LF
                           & "movsbl 1(%0), %%eax" & LF
                           & "vmovd %%eax, %%xmm1" & LF
                           & "vpbroadcastd %%xmm1, %%xmm1" & LF
                           & "vinserti128 $1, %%xmm1, %%ymm0, %%ymm0" & LF
                           & "vmovdqu %%ymm0, (%1)",
                           Inputs => [System.Address'Asm_Input ("r", Input), System.Address'Asm_Input ("r", Target)],
                           Clobber => "rax,ymm0,xmm1,memory", Volatile => True);
                     else
                        System.Machine_Code.Asm
                          ("movzbl (%0), %%eax" & LF
                           & "vmovd %%eax, %%xmm0" & LF
                           & "vpbroadcastd %%xmm0, %%ymm0" & LF
                           & "vmovdqu %%ymm0, (%1)",
                           Inputs => [System.Address'Asm_Input ("r", Input), System.Address'Asm_Input ("r", Target)],
                           Clobber => "rax,ymm0,memory", Volatile => True);
                     end if;
                  end;
               end loop;
   end Expand_Factors;

   Gather_Offsets : constant Sum_Array (0 .. 7) := [0, 32, 64, 96, 128, 160, 192, 224];
   Fifth_Shifts : constant Sum_Array (0 .. 3) := [0, 2, 4, 6];
   procedure Panel_Codes (Source, Target : System.Address) is
   begin
      if Format = G.Type_Q8_0 then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "vmovdqu (%2), %%ymm8" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 16(%%r8,%%ymm8), %%ymm0" & LF
         & "movl $0x80808080, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm1" & LF
         & "vpxor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, (%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Gather_Offsets (0)'Address),
                    System.Address'Asm_Input ("r", Fifth_Shifts (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,memory,cc",
         Volatile => True);
      elsif Format = G.Type_Q5_0 then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "vmovdqu (%2), %%ymm8" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "vpcmpeqd %%xmm7, %%xmm7, %%xmm7" & LF
         & "vpxor %%xmm0, %%xmm0, %%xmm0" & LF
         & "vpgatherdd %%xmm7, 16(%%r8,%%xmm8), %%xmm0" & LF
         & "vpand %%xmm9, %%xmm0, %%xmm1" & LF
         & "vpsrlw $4, %%xmm0, %%xmm2" & LF
         & "vpand %%xmm9, %%xmm2, %%xmm2" & LF
         & "vinserti128 $1, %%xmm2, %%ymm1, %%ymm1" & LF
         & "vpbroadcastd 144(%%r8), %%xmm2" & LF
         & "vmovdqu (%3), %%xmm3" & LF
         & "vpsrlvd %%xmm3, %%xmm2, %%xmm2" & LF
         & "vpsrlw $1, %%xmm2, %%xmm3" & LF
         & "vinserti128 $1, %%xmm3, %%ymm2, %%ymm2" & LF
         & "movl $0x01010101, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm3" & LF
         & "vpand %%ymm3, %%ymm2, %%ymm2" & LF
         & "vpsllw $4, %%ymm2, %%ymm2" & LF
         & "vpor %%ymm2, %%ymm1, %%ymm1" & LF
         & "movl $0x10101010, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm3" & LF
         & "vpsubb %%ymm3, %%ymm1, %%ymm1" & LF
         & "vmovdqu %%ymm1, (%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Gather_Offsets (0)'Address),
                    System.Address'Asm_Input ("r", Fifth_Shifts (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,memory,cc",
         Volatile => True);
      elsif Format = G.Type_Q4_K then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "vmovdqu (%2), %%ymm8" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "movl $0x03030303, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm10" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 128(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 0(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 128(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 64(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 384(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 128(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 384(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 192(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 640(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 256(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 640(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 320(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 896(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 384(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 896(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 448(%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Gather_Offsets (0)'Address),
                    System.Address'Asm_Input ("r", Fifth_Shifts (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,memory,cc",
         Volatile => True);
      elsif Format = G.Type_Q5_K then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "vmovdqu (%2), %%ymm8" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "movl $0x03030303, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm10" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm4, %%ymm4, %%ymm4" & LF
         & "vpgatherdd %%ymm7, 1152(%%r8,%%ymm8), %%ymm4" & LF
         & "movl $0x01010101, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm10" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 128(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $0, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 0(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 128(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $1, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 64(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 384(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $2, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 128(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 384(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $3, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 192(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 640(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $4, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 256(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 640(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $5, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 320(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 896(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $6, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 384(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 896(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpsrlw $7, %%ymm4, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 448(%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Gather_Offsets (0)'Address),
                    System.Address'Asm_Input ("r", Fifth_Shifts (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,memory,cc",
         Volatile => True);
      elsif Format = G.Type_Q6_K then
      System.Machine_Code.Asm
        ("movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "vmovdqu (%2), %%ymm8" & LF
         & "movl $0x0f0f0f0f, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm9" & LF
         & "movl $0x03030303, %%eax" & LF
         & "vpbroadcastd %%eax, %%ymm10" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 144(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1168(%%r8,%%ymm8), %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 0(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 400(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1424(%%r8,%%ymm8), %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 64(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 656(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1168(%%r8,%%ymm8), %%ymm1" & LF
         & "vpsrlw $2, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 128(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 912(%%r8,%%ymm8), %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1424(%%r8,%%ymm8), %%ymm1" & LF
         & "vpsrlw $2, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 192(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 144(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1168(%%r8,%%ymm8), %%ymm1" & LF
         & "vpsrlw $4, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 256(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 400(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1424(%%r8,%%ymm8), %%ymm1" & LF
         & "vpsrlw $4, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 320(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 656(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1168(%%r8,%%ymm8), %%ymm1" & LF
         & "vpsrlw $6, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 384(%%r9)" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm0, %%ymm0, %%ymm0" & LF
         & "vpgatherdd %%ymm7, 912(%%r8,%%ymm8), %%ymm0" & LF
         & "vpsrlw $4, %%ymm0, %%ymm0" & LF
         & "vpand %%ymm9, %%ymm0, %%ymm0" & LF
         & "vpcmpeqd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vpxor %%ymm1, %%ymm1, %%ymm1" & LF
         & "vpgatherdd %%ymm7, 1424(%%r8,%%ymm8), %%ymm1" & LF
         & "vpsrlw $6, %%ymm1, %%ymm1" & LF
         & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
         & "vpsllw $4, %%ymm1, %%ymm1" & LF
         & "vpor %%ymm1, %%ymm0, %%ymm0" & LF
         & "vmovdqu %%ymm0, 448(%%r9)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("r", Source), System.Address'Asm_Input ("r", Target),
                    System.Address'Asm_Input ("r", Gather_Offsets (0)'Address),
                    System.Address'Asm_Input ("r", Fifth_Shifts (0)'Address)],
         Clobber => "rax,r8,r9,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,memory,cc",
         Volatile => True);
      end if;
   end Panel_Codes;

   procedure Decode_Panel (Lane, Actual : Element_Count) is
      Fields : constant Element_Count := (if Format = G.Type_Q6_K then 5 else 6);
      Which : constant B.Byte_Count := B.Byte_Count (Actual mod 8);
      Readable : Boolean;
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            Base : constant B.Byte_Count := Offset + B.Byte_Count ((Actual / 8) * Blocks + Block) * IL.Block_Bytes
              (Format);
            Meta : constant Element_Count := (Actual * Blocks + Block) * Fields;
            At_Coeff : constant B.Byte_Count := B.Byte_Count ((Block * 2 + Lane) * 16);
            Cached : constant Boolean := Groups = 8 and then Metadata'Length = Rows * Blocks * Fields;
         begin
            D (Block * 4 + Lane) :=
              (if Cached then Metadata (Metadata'First + Meta)
               else N.To_Real (N.Half (B.Get_U16 (Data, Base + Which * 2, Readable))));
            D (Block * 4 + Lane + 2) :=
              (if Format in G.Type_Q4_K | G.Type_Q5_K
               then -(if Cached then Metadata (Metadata'First + Meta + 1)
                      else N.To_Real (N.Half (B.Get_U16 (Data, Base + 16 + Which * 2, Readable))))
               else 0.0);
            if Groups = 8 then
               if Cached then
                  declare
                     Raw : B.Byte_Array (0 .. 15) with Import,
                       Address => Metadata (Metadata'First + Meta + (if Format = G.Type_Q6_K then 1 else 2))'Address;
                  begin Coefficients (At_Coeff .. At_Coeff + 15) := Raw; end;
               elsif Format = G.Type_Q6_K then
                  for Group in B.Byte_Count range 0 .. 15 loop
                     Coefficients (At_Coeff + Group) := Data (Data'First + Base + 16 + Group * 8 + Which);
                  end loop;
               else
                  for Group in B.Byte_Count range 0 .. 7 loop
                     declare
                        Low : constant B.Byte := Data (Data'First + Base + 32 + Group * 8 + Which);
                        Top : constant B.Byte := Interfaces.Shift_Right
                          (Data (Data'First + Base + 96 + (Group / 2) * 8 + Which), Natural ((Group rem 2) * 4));
                     begin
                        Coefficients (At_Coeff + Group) := (Low and 15) or Interfaces.Shift_Left (Top and 3, 4);
                        Coefficients (At_Coeff + Group + 8) := Interfaces.Shift_Right (Low, 4)
                          or Interfaces.Shift_Left (Interfaces.Shift_Right (Top, 2) and 3, 4);
                     end;
                  end loop;
               end if;
               if not Streaming then Expand_Factors (Block, Lane); end if;
            end if;
            Panel_Codes (Data (Data'First + Base + Which * 4)'Address,
                         Codes (B.Byte_Count (Block * Groups * 64 + Lane * 32))'Address);
         end;
      end loop;
   end Decode_Panel;

   procedure Decode (Source : B.Byte_Array; Base : B.Byte_Count; Lane, Actual : Element_Count;
                     Cached_Metadata : N.Real_Array) is
      Readable : Boolean;
      function Half (At_Byte : B.Byte_Count) return N.Real is
        (N.To_Real (N.Half (B.Get_U16 (Source, At_Byte, Readable))));
   begin
      if Streaming and then (Groups = 1 or else Cached_Coefficients) then return; end if;
      for Block in 0 .. Blocks - 1 loop
         declare
            At_Byte : constant B.Byte_Count := Base + B.Byte_Count (Block) * Native;
            H : constant Element_Count := Block * 4 + Lane;
            At_Meta : constant Element_Count := (Actual * Blocks + Block)
              * (if Format = G.Type_Q6_K then 5 else 6);
            At_Coeff : constant B.Byte_Count := B.Byte_Count ((Block * 2 + Lane) * 16);
         begin
            if not Streaming then
            D (H) := (if Cached_Metadata'Length = Rows * Blocks
                        * (if Format = G.Type_Q6_K then 5 else 6)
                      then Cached_Metadata (Cached_Metadata'First + At_Meta)
                      else Half (At_Byte + (if Format = G.Type_Q6_K then 208 else 0)));
            D (H + 2) := (if Format in G.Type_Q4_K | G.Type_Q5_K
                          then -(if Cached_Metadata'Length = Rows * Blocks * 6
                                 then Cached_Metadata (Cached_Metadata'First + At_Meta + 1) else Half (At_Byte + 2))
                          else 0.0);
            end if;
            if not Streaming then
               Decode_Codes
              (Source (Source'First + At_Byte)'Address,
               Codes (B.Byte_Count (Block * Groups * 64 + Lane * 32))'Address);
            end if;
            if Groups = 8 then
               if Cached_Metadata'Length = Rows * Blocks * (if Format = G.Type_Q6_K then 5 else 6) then
                  declare
                     Raw : B.Byte_Array (0 .. 15) with Import,
                       Address => Cached_Metadata (Cached_Metadata'First + At_Meta + (if Format = G.Type_Q6_K then
                     1 else
                     2))'Address;
                  begin Coefficients (At_Coeff .. At_Coeff + 15) := Raw; end;
               else
                  Reference_Coefficients
                    (Format, Source, At_Byte, Coefficients (At_Coeff .. At_Coeff + 15), Readable);
               end if;
               if not Streaming then Expand_Factors (Block, Lane); end if;
            end if;
         end;
      end loop;
   end Decode;
begin
   Ok := False;
   if not Deep or else Rows = 0 or else Blocks = 0 or else Count = 0
     or else Native = 0 or else First mod (Groups * 32) /= 0
     or else (Count > 1 and then Stride mod (Groups * 32) /= 0)
     or else (Target = null and then Sums'Length < Rows * Count)
     or else not Inputs_Fit
     or else not B.Has_Room (Data, Offset,
       (if Interleaved then B.Byte_Count ((Rows + 7) / 8) * B.Byte_Count (Blocks) * IL.Block_Bytes (Format)
        else (B.Byte_Count (Rows) - 1) * Row_Bytes + B.Byte_Count (Blocks) * Native))
   then return; end if;
   if Target /= null and then (Result_Stride < Result_First + Rows
     or else Target.all'Length < (Count - 1) * Result_Stride + Result_First + Rows)
   then return; end if;
   if Result_Members'Length /= 0 then
      if Target = null or else Result_Members'Length /= Count then return; end if;
      for I in Result_Members'Range loop
         if Element_Count (Result_Members (I)) >= Target.all'Length / Result_Stride then return; end if;
         if Joint and then Element_Count (Result_Members (I)) >= Partner_Target.all'Length / Result_Stride
         then return; end if;
         for J in Result_Members'First .. I - 1 loop
            if Result_Members (I) = Result_Members (J) then return; end if;
         end loop;
      end loop;
   end if;
   if Joint and then (Target = null or else Interleaved
     or else System."=" (Target.all'Address, Partner_Target.all'Address)
     or else Partner_Target.all'Length < (Count - 1) * Result_Stride + Result_First + Rows
     or else not B.Has_Room (Partner, Partner_Offset,
          B.Byte_Count (Rows - 1) * Row_Bytes + B.Byte_Count (Blocks) * Native))
   then return; end if;
   for Index in Inputs'Range loop
      declare
         Source : constant Element_Count := Source_Row (Element_Count'Min (Index, Count - 1));
      begin
         Inputs (Index) := Values (Values'First + First + Source * Stride)'Address;
         Scaling (Index) := Scales (Scales'First + (First + Source * Stride) / 32)'Address;
         Totalling (Index) :=
           (if Format = G.Type_Q6_K then Halves (Halves'First + (First + Source * Stride) / 16)'Address
            elsif Groups = 8 then Totals (Totals'First + (First + Source * Stride) / 32)'Address
            else System.Null_Address);
      end;
   end loop;
   if Groups = 1 then
      for Index in Inputs'Range loop
         if not Negatable (Inputs (Index), Columns) then Safe_Signed := False; exit; end if;
      end loop;
   end if;
   while R < Rows loop
      for Lane in Weight_Rows'Range loop
         Weight_Rows (Lane) := Data (Data'First + Offset
           + B.Byte_Count (Element_Count'Min (R + Element_Count (Lane), Rows - 1)) * Row_Bytes)'Address;
      end loop;
      for Lane in Element_Count range 0 .. 1 loop
         declare
            Actual : constant Element_Count := Element_Count'Min (R + Lane, Rows - 1);
         begin
            if Interleaved then
               Decode_Panel (Lane, Actual);
            else
               if Joint and then Lane = 1 then
                  Decode (Partner, Partner_Offset + B.Byte_Count (R) * Row_Bytes, Lane, R, Partner_Metadata);
               else
                  Decode (Data, Offset + B.Byte_Count (if Joint then R else Actual) * Row_Bytes,
                          Lane, (if Joint then R else Actual), Metadata);
               end if;
            end if;
         end;
      end loop;
      V := 0;
      while V < Count loop
         Step := (if Seven then 8
                  elsif Groups = 1 and then not Interleaved and then Safe_Signed and then Count - V >= 16 then 16
                  elsif Count - V >= 8 then 8
                  elsif Count - V >= 4 then 4 elsif Count - V >= 2 then 2 else 1);
         if Groups = 8 and then not Streaming then
            for Block in 0 .. Blocks - 1 loop
               for Vector in 0 .. Step - 1 loop
                  for Lane in Element_Count range 0 .. 1 loop
                     declare
                        Coeff : constant System.Address := Coefficients (B.Byte_Count ((Block * 2 + Lane) *
                     16))'Address;
                        Input : constant System.Address :=
                          Totalling (V + Vector) + System.Storage_Elements.Storage_Offset
                            (Block * (if Format = G.Type_Q6_K then 64 else 32));
                        Output : constant System.Address := Correction ((Block * 8 + Vector) * 16 + Lane *
                     8)'Address;
                     begin
                        if Format = G.Type_Q6_K then
                           System.Machine_Code.Asm
                             ("vpmovsxbw (%0), %%ymm0" & LF
                              & "vmovdqu (%1), %%ymm1" & LF
                              & "vpackssdw 32(%1), %%ymm1, %%ymm1" & LF
                              & "vpermq $0xd8, %%ymm1, %%ymm1" & LF
                              & "vpmaddwd %%ymm1, %%ymm0, %%ymm0" & LF
                              & "vpslld $5, %%ymm0, %%ymm0" & LF
                              & "vmovdqu %%ymm0, (%2)",
                              Inputs => [System.Address'Asm_Input ("r", Coeff), System.Address'Asm_Input ("r",
                     Input), System.Address'Asm_Input ("r", Output)],
                              Clobber => "ymm0,ymm1,memory", Volatile => True);
                        else
                           System.Machine_Code.Asm
                             ("vpmovzxbw 8(%0), %%xmm0" & LF
                              & "vmovdqu (%1), %%xmm1" & LF
                              & "vpackssdw 16(%1), %%xmm1, %%xmm1" & LF
                              & "vpmaddwd %%xmm1, %%xmm0, %%xmm0" & LF
                              & "vpxor %%ymm2, %%ymm2, %%ymm2" & LF
                              & "vmovdqu %%ymm2, (%2)" & LF
                              & "vmovdqu %%xmm0, (%2)",
                              Inputs => [System.Address'Asm_Input ("r", Coeff), System.Address'Asm_Input ("r",
                     Input), System.Address'Asm_Input ("r", Output)],
                              Clobber => "xmm0,xmm1,ymm2,memory", Volatile => True);
                           if Format = G.Type_Q5_K then
                              Correction ((Block * 8 + Vector) * 16 + Lane * 8) :=
                                Correction ((Block * 8 + Vector) * 16 + Lane * 8)
                                + Correction ((Block * 8 + Vector) * 16 + Lane * 8 + 1)
                                + Correction ((Block * 8 + Vector) * 16 + Lane * 8 + 2)
                                + Correction ((Block * 8 + Vector) * 16 + Lane * 8 + 3);
                           end if;
                        end if;
                     end;
                  end loop;
               end loop;
            end loop;
         end if;
         declare
            use System.Storage_Elements;
            A : constant System.Address := Data (Data'First + Offset + B.Byte_Count (R) * Row_Bytes)'Address;
            Other : constant System.Address :=
              (if Joint then Partner (Partner'First + Partner_Offset + B.Byte_Count (R) * Row_Bytes)'Address
               else Data (Data'First + Offset + B.Byte_Count (Element_Count'Min (R + 1, Rows - 1)) *
                 Row_Bytes)'Address);
         begin
            Arguments :=
              (Codes => (if Streaming then A else Codes (0)'Address), Factors => (if Streaming and then Groups = 8
                then Coefficients (0)'Address else Factors (0)'Address),
               Correction => (if Streaming and then Groups = 8 then Totalling (V)'Address else Correction
                 (0)'Address), Inputs => Inputs (V)'Address, Scaling => Scaling (V)'Address,
               D => D (0)'Address, Output => Acc (0)'Address, Blocks => Blocks, Correction_Stride => 8 * 64,
               Delta_Bytes => To_Integer (Other) - To_Integer (A), Map => Map (0)'Address, Bits => Bits (0)'Address,
               Coefficient_A => (if Cached_Coefficients then Metadata (Metadata'First + R * Blocks * Fields
                   + (if Format = G.Type_Q6_K then 1 else 2))'Address else Coefficients (0)'Address),
               Coefficient_B => (if Cached_Coefficients then
                 (if Joint then Partner_Metadata (Partner_Metadata'First + R * Blocks * Fields
                    + (if Format = G.Type_Q6_K then 1 else 2))'Address
                  else Metadata (Metadata'First + Element_Count'Min (R + 1, Rows - 1) * Blocks * Fields
                    + (if Format = G.Type_Q6_K then 1 else 2))'Address)
                 else Coefficients (16)'Address),
               Coefficient_Stride => (if Cached_Coefficients then Fields * 4 else 32), Weight_Rows =>
                 Weight_Rows'Address);
         end;
         if Step = 16 then
            --  Small native blocks finish each integer stream before the next
            --  vector, leaving sixteen ordered FMA accumulators resident.
            if Format = G.Type_Q8_0 then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "movq 80(%%rax), %%r10" & LF
                     & "movq 88(%%rax), %%r12" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "vxorps %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vxorps %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vxorps %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vxorps %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vxorps %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vxorps %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vxorps %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vxorps %%zmm15, %%zmm15, %%zmm15" & LF
                     & "1:" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm7" & LF
                     & "movq 64(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 64(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm8" & LF
                     & "movq 72(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 72(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm9" & LF
                     & "movq 80(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 80(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm10" & LF
                     & "movq 88(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 88(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm11" & LF
                     & "movq 96(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 96(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm12" & LF
                     & "movq 104(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 104(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm13" & LF
                     & "movq 112(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 112(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm14" & LF
                     & "movq 120(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 120(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm15" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vmovups %%zmm8, 512(%%r8)" & LF
                     & "vmovups %%zmm9, 576(%%r8)" & LF
                     & "vmovups %%zmm10, 640(%%r8)" & LF
                     & "vmovups %%zmm11, 704(%%r8)" & LF
                     & "vmovups %%zmm12, 768(%%r8)" & LF
                     & "vmovups %%zmm13, 832(%%r8)" & LF
                     & "vmovups %%zmm14, 896(%%r8)" & LF
                     & "vmovups %%zmm15, 960(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,cc,memory,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,zmm12,zmm13,zmm14,zmm15,"
                       & "zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                       & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31",
                     Volatile => True);
            else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "movq 80(%%rax), %%r10" & LF
                     & "movq 88(%%rax), %%r12" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "vxorps %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vxorps %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vxorps %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vxorps %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vxorps %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vxorps %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vxorps %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vxorps %%zmm15, %%zmm15, %%zmm15" & LF
                     & "1:" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm7" & LF
                     & "movq 64(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 64(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm8" & LF
                     & "movq 72(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 72(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm9" & LF
                     & "movq 80(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 80(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm10" & LF
                     & "movq 88(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 88(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm11" & LF
                     & "movq 96(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 96(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm12" & LF
                     & "movq 104(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 104(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm13" & LF
                     & "movq 112(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 112(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm14" & LF
                     & "movq 120(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm27, %%zmm28" & LF
                     & "movq 120(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm26" & LF
                     & "vfmadd231ps %%zmm26, %%zmm28, %%zmm15" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vmovups %%zmm8, 512(%%r8)" & LF
                     & "vmovups %%zmm9, 576(%%r8)" & LF
                     & "vmovups %%zmm10, 640(%%r8)" & LF
                     & "vmovups %%zmm11, 704(%%r8)" & LF
                     & "vmovups %%zmm12, 768(%%r8)" & LF
                     & "vmovups %%zmm13, 832(%%r8)" & LF
                     & "vmovups %%zmm14, 896(%%r8)" & LF
                     & "vmovups %%zmm15, 960(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,cc,memory,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,zmm12,zmm13,zmm14,zmm15,"
                       & "zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                       & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31",
                     Volatile => True);
            end if;
         elsif Quad then
            if Step = 1 then
               if Format = G.Type_Q8_0 then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vmovdqu64 2(%%rsi), %%ymm16" & LF
                     & "vmovdqu64 2(%%r9), %%ymm17" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm25, %%k3" & LF
                     & "vpabsb %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k3%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm25, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $34, %%rdi" & LF
                     & "addq $34, %%rsi" & LF
                     & "addq $34, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vmovdqu64 2(%%rsi), %%ymm16" & LF
                     & "vmovdqu64 2(%%r9), %%ymm17" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm31, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm17" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm25, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $34, %%rdi" & LF
                     & "addq $34, %%rsi" & LF
                     & "addq $34, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rsi), %%xmm16" & LF
                     & "vpandd %%xmm30, %%xmm16, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm16, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm16" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rsi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm16, %%ymm16%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r9), %%xmm17" & LF
                     & "vpandd %%xmm30, %%xmm17, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm17, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm17" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r9), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm17, %%ymm17%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm25, %%k3" & LF
                     & "vpabsb %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k3%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm25, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $22, %%rdi" & LF
                     & "addq $22, %%rsi" & LF
                     & "addq $22, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rsi), %%xmm16" & LF
                     & "vpandd %%xmm30, %%xmm16, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm16, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm16" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rsi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm16, %%ymm16%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r9), %%xmm17" & LF
                     & "vpandd %%xmm30, %%xmm17, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm17, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm17" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r9), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm17, %%ymm17%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm31, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm17" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm25, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $22, %%rdi" & LF
                     & "addq $22, %%rsi" & LF
                     & "addq $22, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            else
               if Format = G.Type_Q8_0 then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vmovdqu64 2(%%rsi), %%ymm16" & LF
                     & "vmovdqu64 2(%%r9), %%ymm17" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm25, %%k3" & LF
                     & "vpabsb %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k3%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm25, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k3%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm25, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $34, %%rdi" & LF
                     & "addq $34, %%rsi" & LF
                     & "addq $34, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vmovups %%zmm1, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vmovdqu64 2(%%rsi), %%ymm16" & LF
                     & "vmovdqu64 2(%%r9), %%ymm17" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm31, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm17" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm25, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm17" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm25, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $34, %%rdi" & LF
                     & "addq $34, %%rsi" & LF
                     & "addq $34, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vmovups %%zmm1, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rsi), %%xmm16" & LF
                     & "vpandd %%xmm30, %%xmm16, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm16, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm16" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rsi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm16, %%ymm16%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r9), %%xmm17" & LF
                     & "vpandd %%xmm30, %%xmm17, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm17, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm17" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r9), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm17, %%ymm17%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm25, %%k3" & LF
                     & "vpabsb %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k3%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm25, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqa64 %%zmm26, %%zmm27" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm27%{%%k3%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm27, %%zmm25, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $22, %%rdi" & LF
                     & "addq $22, %%rsi" & LF
                     & "addq $22, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vmovups %%zmm1, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 120(%%rax), %%rbx" & LF
                     & "movq 0(%%rbx), %%r8" & LF
                     & "movq 8(%%rbx), %%rdi" & LF
                     & "movq 16(%%rbx), %%rsi" & LF
                     & "movq 24(%%rbx), %%r9" & LF
                     & "movq 24(%%rax), %%r10" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 56(%%rax), %%r15" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%r14, %%r14" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rsi), %%xmm16" & LF
                     & "vpandd %%xmm30, %%xmm16, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm16, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm16" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rsi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm16, %%ymm16%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r9), %%xmm17" & LF
                     & "vpandd %%xmm30, %%xmm17, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm17, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm17" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r9), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm17, %%ymm17%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm17, %%zmm16, %%zmm25" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm31, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm17" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm25, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vbroadcasti64x4 (%%rbx,%%r13), %%zmm26" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm17" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm25, %%zmm16" & LF
                     & "vpsubd %%zmm17, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw (%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw (%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw (%%rsi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw (%%r9), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r14), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $22, %%rdi" & LF
                     & "addq $22, %%rsi" & LF
                     & "addq $22, %%r9" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $4, %%r14" & LF
                     & "decq %%r15" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm2, 64(%%r8)" & LF
                     & "vmovups %%zmm1, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,k3,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,"
                        & "zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            end if;
         elsif Step = 1 then
            if Format = G.Type_Q8_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q5_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q6_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 8(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 9(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 8(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 9(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 10(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 11(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 10(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 11(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 12(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 13(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 12(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 13(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 14(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 15(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 14(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 15(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 208(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 208(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm8, %%zmm8" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $210, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 0(%%r10), %%zmm8, %%zmm8" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q4_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "addq $144, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q5_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "addq $176, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            end if;
         elsif Step = 2 then
            if Format = G.Type_Q8_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q5_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q6_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 8(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 9(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 8(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 9(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 10(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 11(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 10(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 11(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 12(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 13(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 12(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 13(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 14(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 15(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 14(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 15(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 208(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 208(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm8, %%zmm8" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm9, %%zmm9" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $210, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 0(%%r10), %%zmm8, %%zmm8" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 64(%%r10), %%zmm9, %%zmm9" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q4_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "addq $144, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 128(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps 64(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 128(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q5_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "addq $176, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 128(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps 64(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 128(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            end if;
         elsif Step = 4 then
            if Format = G.Type_Q8_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q5_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q6_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 8(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 9(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 8(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 9(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 10(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 11(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 10(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 11(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 12(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 13(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 12(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 13(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 14(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 15(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 14(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 15(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 208(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 208(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm8, %%zmm8" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm9, %%zmm9" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm10, %%zmm10" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm11, %%zmm11" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $210, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 0(%%r10), %%zmm8, %%zmm8" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 64(%%r10), %%zmm9, %%zmm9" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 128(%%r10), %%zmm10, %%zmm10" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 192(%%r10), %%zmm11, %%zmm11" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q4_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 16(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 24(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $144, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps 64(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps 128(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps 192(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q5_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 16(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 24(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $176, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpmulld %%zmm25, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps 64(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps 128(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps 192(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            end if;
         elsif Step = 8 then
            if Format = G.Type_Q8_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "vmovdqu64 2(%%r8), %%ymm24" & LF
                     & "vmovdqu64 2(%%rdi), %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $34, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q5_0 then
               if Streaming then
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%r8), %%xmm24" & LF
                     & "vpandd %%xmm30, %%xmm24, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm24, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm24" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%r8), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm24, %%ymm24%{%%k2%}" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 6(%%rdi), %%xmm25" & LF
                     & "vpandd %%xmm30, %%xmm25, %%xmm26" & LF
                     & "vpsrlw $4, %%xmm25, %%xmm27" & LF
                     & "vpandd %%xmm30, %%xmm27, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm26, %%ymm25" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 80(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm28" & LF
                     & "movq 88(%%rax), %%rbx" & LF
                     & "vmovdqu64 (%%rbx), %%ymm29" & LF
                     & "vpbroadcastd 2(%%rdi), %%ymm27" & LF
                     & "vpshufb %%ymm28, %%ymm27, %%ymm27" & LF
                     & "vptestnmb %%ymm29, %%ymm27, %%k2" & LF
                     & "movl $0x10101010, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpsubb %%ymm30, %%ymm25, %%ymm25%{%%k2%}" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $22, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               else
                  if Safe_Signed then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpcmpb $1, %%zmm30, %%zmm24, %%k1" & LF
                     & "vpabsb %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpsubb %%zmm26, %%zmm30, %%zmm26%{%%k1%}" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vpxord %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vpxord %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vpxord %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vpxord %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vpxord %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vpxord %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vpxord %%zmm15, %%zmm15, %%zmm15" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "movl $0x80808080, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm31" & LF
                     & "vpxord %%zmm31, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm8, %%zmm8" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm9, %%zmm9" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm10, %%zmm10" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm11, %%zmm11" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm12, %%zmm12" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm13, %%zmm13" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm14, %%zmm14" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm16" & LF
                     & "vpxord %%zmm30, %%zmm30, %%zmm30" & LF
                     & "vpdpbusd %%zmm26, %%zmm31, %%zmm30" & LF
                     & "vpsubd %%zmm30, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm16, %%zmm15, %%zmm15" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm8, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm9, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm10, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm11, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm12, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm13, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm14, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm15, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $64, %%r8" & LF
                     & "addq $64, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $4, %%r13" & LF
                     & "addq $32, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
                  end if;
               end if;
            elsif Format = G.Type_Q6_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpxord %%zmm18, %%zmm18, %%zmm18" & LF
                     & "vpxord %%zmm19, %%zmm19, %%zmm19" & LF
                     & "vpxord %%zmm20, %%zmm20, %%zmm20" & LF
                     & "vpxord %%zmm21, %%zmm21, %%zmm21" & LF
                     & "vpxord %%zmm22, %%zmm22, %%zmm22" & LF
                     & "vpxord %%zmm23, %%zmm23, %%zmm23" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 0(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 128(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 32(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 128(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 8(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 9(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 8(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 9(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 10(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 11(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 10(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 11(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 64(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 12(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 13(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 12(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 13(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 160(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 96(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 160(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x03030303, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movsbl 14(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm25" & LF
                     & "movsbl 15(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm25, %%ymm25" & LF
                     & "movsbl 14(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm28" & LF
                     & "movsbl 15(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%xmm27" & LF
                     & "vinserti32x4 $1, %%xmm27, %%ymm28, %%ymm28" & LF
                     & "vinserti64x4 $1, %%ymm28, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "vpbroadcastw 208(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 208(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm16, %%zmm16" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm16, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm17, %%zmm17" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm17, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm18, %%zmm18" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm18, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm19, %%zmm19" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm19, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm20, %%zmm20" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm20, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm21, %%zmm21" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm21, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm22, %%zmm22" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm22, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13,2), %%ymm29" & LF
                     & "vpackssdw 32(%%rbx,%%r13,2), %%ymm29, %%ymm29" & LF
                     & "vpermq $0xd8, %%ymm29, %%ymm29" & LF
                     & "vpmovsxbw (%%r9), %%ymm28" & LF
                     & "vpmaddwd %%ymm29, %%ymm28, %%ymm28" & LF
                     & "vpslld $5, %%ymm28, %%ymm28" & LF
                     & "vpmovsxbw 0(%%r12), %%ymm30" & LF
                     & "vpmaddwd %%ymm29, %%ymm30, %%ymm30" & LF
                     & "vpslld $5, %%ymm30, %%ymm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vpsubd %%zmm28, %%zmm23, %%zmm23" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm23, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $210, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "1:" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpxord %%zmm18, %%zmm18, %%zmm18" & LF
                     & "vpxord %%zmm19, %%zmm19, %%zmm19" & LF
                     & "vpxord %%zmm20, %%zmm20, %%zmm20" & LF
                     & "vpxord %%zmm21, %%zmm21, %%zmm21" & LF
                     & "vpxord %%zmm22, %%zmm22, %%zmm22" & LF
                     & "vpxord %%zmm23, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 0(%%r10), %%zmm16, %%zmm16" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm16, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 64(%%r10), %%zmm17, %%zmm17" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm17, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 128(%%r10), %%zmm18, %%zmm18" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm18, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 192(%%r10), %%zmm19, %%zmm19" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm19, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 256(%%r10), %%zmm20, %%zmm20" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm20, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 320(%%r10), %%zmm21, %%zmm21" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm21, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 384(%%r10), %%zmm22, %%zmm22" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm22, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vpsubd 448(%%r10), %%zmm23, %%zmm23" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm23, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q4_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "vxorps %%zmm15, %%zmm15, %%zmm15" & LF
                     & "1:" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpxord %%zmm18, %%zmm18, %%zmm18" & LF
                     & "vpxord %%zmm19, %%zmm19, %%zmm19" & LF
                     & "vpxord %%zmm20, %%zmm20, %%zmm20" & LF
                     & "vpxord %%zmm21, %%zmm21, %%zmm21" & LF
                     & "vpxord %%zmm22, %%zmm22, %%zmm22" & LF
                     & "vpxord %%zmm23, %%zmm23, %%zmm23" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 16(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm16, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm8" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm17, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm9" & LF
                     & "movq 16(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm18, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm10" & LF
                     & "movq 24(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm19, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm11" & LF
                     & "movq 32(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm20, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm12" & LF
                     & "movq 40(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm21, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm13" & LF
                     & "movq 48(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm22, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm14" & LF
                     & "movq 56(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm23, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm15" & LF
                     & "addq $144, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm8, 512(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm9, 576(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm10, 640(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm11, 704(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm12, 768(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm13, 832(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm14, 896(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vmovups %%zmm15, 960(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "vxorps %%zmm15, %%zmm15, %%zmm15" & LF
                     & "1:" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpxord %%zmm18, %%zmm18, %%zmm18" & LF
                     & "vpxord %%zmm19, %%zmm19, %%zmm19" & LF
                     & "vpxord %%zmm20, %%zmm20, %%zmm20" & LF
                     & "vpxord %%zmm21, %%zmm21, %%zmm21" & LF
                     & "vpxord %%zmm22, %%zmm22, %%zmm22" & LF
                     & "vpxord %%zmm23, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm16, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm8" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm17, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps 64(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm9" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm18, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps 128(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm10" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm19, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps 192(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm11" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm20, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "vcvtdq2ps 256(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm12" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm21, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "vcvtdq2ps 320(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm13" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm22, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "vcvtdq2ps 384(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm14" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm23, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "vcvtdq2ps 448(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm15" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm8, 512(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm9, 576(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm10, 640(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm11, 704(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm12, 768(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm13, 832(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm14, 896(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vmovups %%zmm15, 960(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            elsif Format = G.Type_Q5_K then
               if Streaming then
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 96(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 104(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 112(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "vxorps %%zmm15, %%zmm15, %%zmm15" & LF
                     & "1:" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpxord %%zmm18, %%zmm18, %%zmm18" & LF
                     & "vpxord %%zmm19, %%zmm19, %%zmm19" & LF
                     & "vpxord %%zmm20, %%zmm20, %%zmm20" & LF
                     & "vpxord %%zmm21, %%zmm21, %%zmm21" & LF
                     & "vpxord %%zmm22, %%zmm22, %%zmm22" & LF
                     & "vpxord %%zmm23, %%zmm23, %%zmm23" & LF
                     & "leaq (%%r8,%%rsi), %%rdi" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $0, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 0(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 0(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 48(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $1, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 1(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 1(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $2, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 2(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 2(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 80(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $3, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 3(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 3(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $4, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 4(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 4(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 112(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $5, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 5(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 5(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $6, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 6(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 6(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%r8), %%ymm24" & LF
                     & "vpsrlw $4, %%ymm24, %%ymm24" & LF
                     & "vpandd %%ymm30, %%ymm24, %%ymm24" & LF
                     & "vmovdqu64 16(%%r8), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm24, %%ymm24" & LF
                     & "movl $0x0f0f0f0f, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vmovdqu64 144(%%rdi), %%ymm25" & LF
                     & "vpsrlw $4, %%ymm25, %%ymm25" & LF
                     & "vpandd %%ymm30, %%ymm25, %%ymm25" & LF
                     & "vmovdqu64 16(%%rdi), %%ymm26" & LF
                     & "vpsrlw $7, %%ymm26, %%ymm26" & LF
                     & "movl $0x01010101, %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm30" & LF
                     & "vpandd %%ymm30, %%ymm26, %%ymm26" & LF
                     & "vpsllw $4, %%ymm26, %%ymm26" & LF
                     & "vpord %%ymm26, %%ymm25, %%ymm25" & LF
                     & "vinserti64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "movzbl 7(%%r9), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm25" & LF
                     & "movzbl 7(%%r12), %%eax" & LF
                     & "vpbroadcastd %%eax, %%ymm27" & LF
                     & "vinserti64x4 $1, %%ymm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "vpaddd %%zmm29, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "vpaddd %%zmm29, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "vpaddd %%zmm29, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm28" & LF
                     & "vpxord %%zmm29, %%zmm29, %%zmm29" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpdpbusd %%zmm28, %%zmm24, %%zmm29" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm29, %%zmm29" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "vpaddd %%zmm29, %%zmm23, %%zmm23" & LF
                     & "vpbroadcastw 0(%%r8), %%xmm24" & LF
                     & "vcvtph2ps %%xmm24, %%xmm24" & LF
                     & "vbroadcastss %%xmm24, %%ymm24" & LF
                     & "vpbroadcastw 0(%%rdi), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vpbroadcastw 2(%%r8), %%xmm25" & LF
                     & "vcvtph2ps %%xmm25, %%xmm25" & LF
                     & "vbroadcastss %%xmm25, %%ymm25" & LF
                     & "vpbroadcastw 2(%%rdi), %%xmm26" & LF
                     & "vcvtph2ps %%xmm26, %%xmm26" & LF
                     & "vbroadcastss %%xmm26, %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movl $0x80000000, %%eax" & LF
                     & "vpbroadcastd %%eax, %%zmm27" & LF
                     & "vxorps %%zmm27, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm16, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm8" & LF
                     & "movq 8(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm17, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm9" & LF
                     & "movq 16(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm18, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm10" & LF
                     & "movq 24(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm19, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm11" & LF
                     & "movq 32(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm20, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm12" & LF
                     & "movq 40(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm21, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm13" & LF
                     & "movq 48(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm22, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm14" & LF
                     & "movq 56(%%r10), %%rbx" & LF
                     & "vmovdqu64 (%%rbx,%%r13), %%xmm29" & LF
                     & "vpackssdw 16(%%rbx,%%r13), %%xmm29, %%xmm29" & LF
                     & "vpmovzxbw 8(%%r9), %%xmm28" & LF
                     & "vpmaddwd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpmovzxbw 8(%%r12), %%xmm30" & LF
                     & "vpmaddwd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0x4e, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vpshufd $0xb1, %%xmm28, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm28, %%xmm28" & LF
                     & "vmovd %%xmm28, %%eax" & LF
                     & "vpxord %%ymm28, %%ymm28, %%ymm28" & LF
                     & "vmovd %%eax, %%xmm28" & LF
                     & "vpshufd $0x4e, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vpshufd $0xb1, %%xmm30, %%xmm29" & LF
                     & "vpaddd %%xmm29, %%xmm30, %%xmm30" & LF
                     & "vmovd %%xmm30, %%eax" & LF
                     & "vpxord %%ymm30, %%ymm30, %%ymm30" & LF
                     & "vmovd %%eax, %%xmm30" & LF
                     & "vinserti64x4 $1, %%ymm30, %%zmm28, %%zmm28" & LF
                     & "vmovdqa64 %%zmm28, %%zmm31" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm23, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "vcvtdq2ps %%zmm31, %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm15" & LF
                     & "addq $176, %%r8" & LF
                     & "addq %%r15, %%r9" & LF
                     & "addq %%r15, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm8, 512(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm9, 576(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm10, 640(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm11, 704(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm12, 768(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm13, 832(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm14, 896(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vmovups %%zmm15, 960(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               else
                  System.Machine_Code.Asm
                    ("movq %0, %%rax" & LF
                     & "movq 0(%%rax), %%r8" & LF
                     & "movq 8(%%rax), %%r9" & LF
                     & "movq 16(%%rax), %%r10" & LF
                     & "movq 24(%%rax), %%rcx" & LF
                     & "movq 32(%%rax), %%r11" & LF
                     & "movq 40(%%rax), %%r12" & LF
                     & "movq 56(%%rax), %%r14" & LF
                     & "movq 64(%%rax), %%r15" & LF
                     & "movq 72(%%rax), %%rsi" & LF
                     & "xorq %%r13, %%r13" & LF
                     & "xorq %%rdx, %%rdx" & LF
                     & "vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm8, %%zmm8, %%zmm8" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm9, %%zmm9, %%zmm9" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm10, %%zmm10, %%zmm10" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "vxorps %%zmm11, %%zmm11, %%zmm11" & LF
                     & "vxorps %%zmm4, %%zmm4, %%zmm4" & LF
                     & "vxorps %%zmm12, %%zmm12, %%zmm12" & LF
                     & "vxorps %%zmm5, %%zmm5, %%zmm5" & LF
                     & "vxorps %%zmm13, %%zmm13, %%zmm13" & LF
                     & "vxorps %%zmm6, %%zmm6, %%zmm6" & LF
                     & "vxorps %%zmm14, %%zmm14, %%zmm14" & LF
                     & "vxorps %%zmm7, %%zmm7, %%zmm7" & LF
                     & "vxorps %%zmm15, %%zmm15, %%zmm15" & LF
                     & "1:" & LF
                     & "vpxord %%zmm16, %%zmm16, %%zmm16" & LF
                     & "vpxord %%zmm17, %%zmm17, %%zmm17" & LF
                     & "vpxord %%zmm18, %%zmm18, %%zmm18" & LF
                     & "vpxord %%zmm19, %%zmm19, %%zmm19" & LF
                     & "vpxord %%zmm20, %%zmm20, %%zmm20" & LF
                     & "vpxord %%zmm21, %%zmm21, %%zmm21" & LF
                     & "vpxord %%zmm22, %%zmm22, %%zmm22" & LF
                     & "vpxord %%zmm23, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 0(%%r8), %%zmm24" & LF
                     & "vmovdqu64 0(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 0(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 64(%%r8), %%zmm24" & LF
                     & "vmovdqu64 64(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 32(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 128(%%r8), %%zmm24" & LF
                     & "vmovdqu64 128(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 64(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 192(%%r8), %%zmm24" & LF
                     & "vmovdqu64 192(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 96(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 256(%%r8), %%zmm24" & LF
                     & "vmovdqu64 256(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 128(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 320(%%r8), %%zmm24" & LF
                     & "vmovdqu64 320(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 160(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 384(%%r8), %%zmm24" & LF
                     & "vmovdqu64 384(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 192(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vmovdqu64 448(%%r8), %%zmm24" & LF
                     & "vmovdqu64 448(%%r9), %%zmm25" & LF
                     & "movq 0(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm16, %%zmm16" & LF
                     & "movq 8(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm17, %%zmm17" & LF
                     & "movq 16(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm18, %%zmm18" & LF
                     & "movq 24(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm19, %%zmm19" & LF
                     & "movq 32(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm20, %%zmm20" & LF
                     & "movq 40(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm21, %%zmm21" & LF
                     & "movq 48(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm22, %%zmm22" & LF
                     & "movq 56(%%rcx), %%rbx" & LF
                     & "vbroadcasti64x4 224(%%rbx,%%rdx), %%zmm26" & LF
                     & "vpxord %%zmm27, %%zmm27, %%zmm27" & LF
                     & "vpdpbusd %%zmm26, %%zmm24, %%zmm27" & LF
                     & "vpmulld %%zmm25, %%zmm27, %%zmm27" & LF
                     & "vpaddd %%zmm27, %%zmm23, %%zmm23" & LF
                     & "vbroadcastss 0(%%r12), %%ymm24" & LF
                     & "vbroadcastss 4(%%r12), %%ymm25" & LF
                     & "vinsertf64x4 $1, %%ymm25, %%zmm24, %%zmm24" & LF
                     & "vbroadcastss 8(%%r12), %%ymm25" & LF
                     & "vbroadcastss 12(%%r12), %%ymm26" & LF
                     & "vinsertf64x4 $1, %%ymm26, %%zmm25, %%zmm25" & LF
                     & "movq 0(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm16, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm0" & LF
                     & "vcvtdq2ps 0(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm8" & LF
                     & "movq 8(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm17, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm1" & LF
                     & "vcvtdq2ps 64(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm9" & LF
                     & "movq 16(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm18, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm2" & LF
                     & "vcvtdq2ps 128(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm10" & LF
                     & "movq 24(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm19, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm3" & LF
                     & "vcvtdq2ps 192(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm11" & LF
                     & "movq 32(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm20, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm4" & LF
                     & "vcvtdq2ps 256(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm12" & LF
                     & "movq 40(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm21, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm5" & LF
                     & "vcvtdq2ps 320(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm13" & LF
                     & "movq 48(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm22, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm6" & LF
                     & "vcvtdq2ps 384(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm14" & LF
                     & "movq 56(%%r11), %%rbx" & LF
                     & "vbroadcastss (%%rbx,%%r13), %%zmm26" & LF
                     & "vmulps %%zmm24, %%zmm26, %%zmm27" & LF
                     & "vcvtdq2ps %%zmm23, %%zmm28" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm7" & LF
                     & "vcvtdq2ps 448(%%r10), %%zmm28" & LF
                     & "vmulps %%zmm25, %%zmm26, %%zmm27" & LF
                     & "vfmadd231ps %%zmm27, %%zmm28, %%zmm15" & LF
                     & "addq $512, %%r8" & LF
                     & "addq $512, %%r9" & LF
                     & "addq %%r15, %%r10" & LF
                     & "addq $16, %%r12" & LF
                     & "addq $32, %%r13" & LF
                     & "addq $256, %%rdx" & LF
                     & "decq %%r14" & LF
                     & "jnz 1b" & LF
                     & "movq %0, %%rax" & LF
                     & "movq 48(%%rax), %%r8" & LF
                     & "vmovups %%zmm0, 0(%%r8)" & LF
                     & "vmovups %%zmm8, 512(%%r8)" & LF
                     & "vmovups %%zmm1, 64(%%r8)" & LF
                     & "vmovups %%zmm9, 576(%%r8)" & LF
                     & "vmovups %%zmm2, 128(%%r8)" & LF
                     & "vmovups %%zmm10, 640(%%r8)" & LF
                     & "vmovups %%zmm3, 192(%%r8)" & LF
                     & "vmovups %%zmm11, 704(%%r8)" & LF
                     & "vmovups %%zmm4, 256(%%r8)" & LF
                     & "vmovups %%zmm12, 768(%%r8)" & LF
                     & "vmovups %%zmm5, 320(%%r8)" & LF
                     & "vmovups %%zmm13, 832(%%r8)" & LF
                     & "vmovups %%zmm6, 384(%%r8)" & LF
                     & "vmovups %%zmm14, 896(%%r8)" & LF
                     & "vmovups %%zmm7, 448(%%r8)" & LF
                     & "vmovups %%zmm15, 960(%%r8)" & LF
                     & "vzeroupper",
                     Inputs => System.Address'Asm_Input ("m", Argument_Pointer),
                     Clobber => "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,k1,k2,"
                       & "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,zmm11,"
                       & "zmm12,zmm13,zmm14,zmm15,zmm16,zmm17,zmm18,zmm19,zmm20,zmm21,zmm22,zmm23,"
                        & "zmm24,zmm25,zmm26,zmm27,zmm28,zmm29,zmm30,zmm31,cc,memory",
                     Volatile => True);
               end if;
            end if;
         end if;
         for Vector in 0 .. Element_Count'Min (Step, Count - V) - 1 loop
            for Lane in Element_Count range 0 .. (if Joint then 1 else Element_Count'Min ((if Quad then 3 else 1),
              Rows - R - 1)) loop
               declare
                  At_Main : constant Element_Count := Vector * (if Quad then 32 else 16) + Lane * 8;
                  At_Min : constant Element_Count := (Step + Vector) * 16 + Lane * 8;
                  Result : N.Real := Fold (At_Main);
               begin
                  if Format = G.Type_Q4_K then
                     Result := Result + ((Acc (At_Min) + Acc (At_Min + 2))
                       + (Acc (At_Min + 1) + Acc (At_Min + 3)));
                  elsif Format = G.Type_Q5_K then Result := Result + Acc (At_Min);
                  end if;
                  if Target /= null then
                     if Joint and then Lane = 1 then
                        Partner_Target.all (Partner_Target.all'First + Result_First + R
                          + (if Result_Members'Length = 0 then V + Vector
                           else Element_Count (Result_Members (Result_Members'First + Natural (V + Vector))))
                           * Result_Stride) := Result;
                     else
                        Target.all (Target.all'First + Result_First + R + Lane
                          + (if Result_Members'Length = 0 then V + Vector
                           else Element_Count (Result_Members (Result_Members'First + Natural (V + Vector))))
                           * Result_Stride) := Result;
                     end if;
                  else
                     Answer (1 + (R + Lane) * Count + V + Vector) := N.Wide_Real (Result);
                  end if;
               end;
            end loop;
         end loop;
         V := V + Element_Count'Min (Step, Count - V);
      end loop;
      R := R + (if Joint then 1 elsif Quad then 4 else 2);
   end loop;
   for Index in Answer'Range loop
      Sums (Sums'First + Index - 1) := Sums (Sums'First + Index - 1) + Answer (Index);
   end loop;
   Ok := True;
end Reference_Tile;
