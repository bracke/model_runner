with Interfaces;
with System.Machine_Code;

package body Model_Runner.Float_Panels is

   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Tensors;

   subtype Real is Model_Runner.Numerics.Real;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   use type Real;
   use type Element_Count;
   use type T.Real_Array_Access;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Shares.Team_Access;

   LF : constant Character := ASCII.LF;

   Chosen : Kernel_Kind := Plain with Atomic;

   --  Columns of the inner dimension one pass over a tile sums: a panel's
   --  block is then 32 KB, what a core's first-level cache holds, and six
   --  vectors' block 6 KB.
   Block : constant := 256;

   --  Vectors and panels one item of the shared work covers: the vectors'
   --  block about 100 KB and the panels' 128 KB, both in the second-level
   --  cache while the item's tiles walk them. Chunk is a whole number of
   --  every kernel's tile.
   Chunk : constant := 96;
   Group : constant := 4;

   --  Vectors a tile holds, by kernel: twelve registers of answers in the
   --  widest -- six vectors by two registers -- and three by four in the
   --  wide, which has half the lanes and as many registers.
   function Tile_Vectors (Kind : Kernel_Kind) return Element_Count
   is (case Kind is
         when Widest => 6,
         when Wide   => 3,
         when Plain  => 6);

   --  What a kernel is handed, in memory: one register then carries it,
   --  and the kernel has the others. Places are addresses, steps bytes,
   --  Add nought where the answers are written and one where they are
   --  added to what Answers holds.
   type Tile_Call is record
      Vectors : System.Address;
      Panel   : System.Address;
      Answers : System.Address;
      Across  : Interfaces.Unsigned_64;
      Steps   : Interfaces.Unsigned_64;
      Down    : Interfaces.Unsigned_64;
      Add     : Interfaces.Unsigned_64;
   end record
   with Convention => C;

   for Tile_Call use record
      Vectors at 0 range 0 .. 63;
      Panel   at 8 range 0 .. 63;
      Answers at 16 range 0 .. 63;
      Across  at 24 range 0 .. 63;
      Steps   at 32 range 0 .. 63;
      Down    at 40 range 0 .. 63;
      Add     at 48 range 0 .. 63;
   end record;

   --  Six vectors by a panel, in the widest registers: each column's two
   --  registers of weights read once and multiplied into all six.
   procedure Widest_Tile (Call : Tile_Call) is
   begin
      System.Machine_Code.Asm
        ("movq %0, %%r11" & LF &
         "movq 0(%%r11), %%rsi" & LF &
         "movq 24(%%r11), %%rdx" & LF &
         "leaq (%%rsi,%%rdx,2), %%rdi" & LF &
         "addq %%rdx, %%rdi" & LF &
         "movq 8(%%r11), %%rax" & LF &
         "movq 32(%%r11), %%rcx" & LF &
         "vxorps %%zmm0, %%zmm0, %%zmm0" & LF &
         "vxorps %%zmm1, %%zmm1, %%zmm1" & LF &
         "vxorps %%zmm2, %%zmm2, %%zmm2" & LF &
         "vxorps %%zmm3, %%zmm3, %%zmm3" & LF &
         "vxorps %%zmm4, %%zmm4, %%zmm4" & LF &
         "vxorps %%zmm5, %%zmm5, %%zmm5" & LF &
         "vxorps %%zmm6, %%zmm6, %%zmm6" & LF &
         "vxorps %%zmm7, %%zmm7, %%zmm7" & LF &
         "vxorps %%zmm8, %%zmm8, %%zmm8" & LF &
         "vxorps %%zmm9, %%zmm9, %%zmm9" & LF &
         "vxorps %%zmm10, %%zmm10, %%zmm10" & LF &
         "vxorps %%zmm11, %%zmm11, %%zmm11" & LF &
         "1:" & LF &
         "vmovups (%%rax), %%zmm12" & LF &
         "vmovups 64(%%rax), %%zmm13" & LF &
         "vbroadcastss (%%rsi), %%zmm14" & LF &
         "vfmadd231ps %%zmm12, %%zmm14, %%zmm0" & LF &
         "vfmadd231ps %%zmm13, %%zmm14, %%zmm1" & LF &
         "vbroadcastss (%%rsi,%%rdx), %%zmm15" & LF &
         "vfmadd231ps %%zmm12, %%zmm15, %%zmm2" & LF &
         "vfmadd231ps %%zmm13, %%zmm15, %%zmm3" & LF &
         "vbroadcastss (%%rsi,%%rdx,2), %%zmm14" & LF &
         "vfmadd231ps %%zmm12, %%zmm14, %%zmm4" & LF &
         "vfmadd231ps %%zmm13, %%zmm14, %%zmm5" & LF &
         "vbroadcastss (%%rdi), %%zmm15" & LF &
         "vfmadd231ps %%zmm12, %%zmm15, %%zmm6" & LF &
         "vfmadd231ps %%zmm13, %%zmm15, %%zmm7" & LF &
         "vbroadcastss (%%rdi,%%rdx), %%zmm14" & LF &
         "vfmadd231ps %%zmm12, %%zmm14, %%zmm8" & LF &
         "vfmadd231ps %%zmm13, %%zmm14, %%zmm9" & LF &
         "vbroadcastss (%%rdi,%%rdx,2), %%zmm15" & LF &
         "vfmadd231ps %%zmm12, %%zmm15, %%zmm10" & LF &
         "vfmadd231ps %%zmm13, %%zmm15, %%zmm11" & LF &
         "addq $4, %%rsi" & LF &
         "addq $4, %%rdi" & LF &
         "addq $128, %%rax" & LF &
         "decq %%rcx" & LF &
         "jnz 1b" & LF &
         "movq 16(%%r11), %%r8" & LF &
         "movq 40(%%r11), %%r9" & LF &
         "leaq (%%r8,%%r9,2), %%r10" & LF &
         "addq %%r9, %%r10" & LF &
         "cmpq $0, 48(%%r11)" & LF &
         "je 2f" & LF &
         "vaddps (%%r8), %%zmm0, %%zmm0" & LF &
         "vaddps 64(%%r8), %%zmm1, %%zmm1" & LF &
         "vaddps (%%r8,%%r9), %%zmm2, %%zmm2" & LF &
         "vaddps 64(%%r8,%%r9), %%zmm3, %%zmm3" & LF &
         "vaddps (%%r8,%%r9,2), %%zmm4, %%zmm4" & LF &
         "vaddps 64(%%r8,%%r9,2), %%zmm5, %%zmm5" & LF &
         "vaddps (%%r10), %%zmm6, %%zmm6" & LF &
         "vaddps 64(%%r10), %%zmm7, %%zmm7" & LF &
         "vaddps (%%r10,%%r9), %%zmm8, %%zmm8" & LF &
         "vaddps 64(%%r10,%%r9), %%zmm9, %%zmm9" & LF &
         "vaddps (%%r10,%%r9,2), %%zmm10, %%zmm10" & LF &
         "vaddps 64(%%r10,%%r9,2), %%zmm11, %%zmm11" & LF &
         "2:" & LF &
         "vmovups %%zmm0, (%%r8)" & LF &
         "vmovups %%zmm1, 64(%%r8)" & LF &
         "vmovups %%zmm2, (%%r8,%%r9)" & LF &
         "vmovups %%zmm3, 64(%%r8,%%r9)" & LF &
         "vmovups %%zmm4, (%%r8,%%r9,2)" & LF &
         "vmovups %%zmm5, 64(%%r8,%%r9,2)" & LF &
         "vmovups %%zmm6, (%%r10)" & LF &
         "vmovups %%zmm7, 64(%%r10)" & LF &
         "vmovups %%zmm8, (%%r10,%%r9)" & LF &
         "vmovups %%zmm9, 64(%%r10,%%r9)" & LF &
         "vmovups %%zmm10, (%%r10,%%r9,2)" & LF &
         "vmovups %%zmm11, 64(%%r10,%%r9,2)" & LF &
         "vzeroupper",
         Inputs   => System.Address'Asm_Input ("r", Call'Address),
         Clobber  =>
           "rax,rcx,rdx,rsi,rdi,r8,r9,r10,r11,zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,zmm8,zmm9,zmm10,"
           & "zmm11,zmm12,zmm13,zmm14,zmm15,memory,cc",
         Volatile => True);
   end Widest_Tile;

   --  Three vectors by a panel, in the wide registers: four registers of
   --  answers a vector, and the column's weights a register at a time.
   procedure Wide_Tile (Call : Tile_Call) is
   begin
      System.Machine_Code.Asm
        ("movq %0, %%r11" & LF &
         "movq 0(%%r11), %%rsi" & LF &
         "movq 24(%%r11), %%rdx" & LF &
         "movq 8(%%r11), %%rax" & LF &
         "movq 32(%%r11), %%rcx" & LF &
         "vxorps %%ymm0, %%ymm0, %%ymm0" & LF &
         "vxorps %%ymm1, %%ymm1, %%ymm1" & LF &
         "vxorps %%ymm2, %%ymm2, %%ymm2" & LF &
         "vxorps %%ymm3, %%ymm3, %%ymm3" & LF &
         "vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
         "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
         "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
         "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
         "vxorps %%ymm8, %%ymm8, %%ymm8" & LF &
         "vxorps %%ymm9, %%ymm9, %%ymm9" & LF &
         "vxorps %%ymm10, %%ymm10, %%ymm10" & LF &
         "vxorps %%ymm11, %%ymm11, %%ymm11" & LF &
         "1:" & LF &
         "vbroadcastss (%%rsi), %%ymm12" & LF &
         "vbroadcastss (%%rsi,%%rdx), %%ymm13" & LF &
         "vbroadcastss (%%rsi,%%rdx,2), %%ymm14" & LF &
         "vmovups (%%rax), %%ymm15" & LF &
         "vfmadd231ps %%ymm15, %%ymm12, %%ymm0" & LF &
         "vfmadd231ps %%ymm15, %%ymm13, %%ymm4" & LF &
         "vfmadd231ps %%ymm15, %%ymm14, %%ymm8" & LF &
         "vmovups 32(%%rax), %%ymm15" & LF &
         "vfmadd231ps %%ymm15, %%ymm12, %%ymm1" & LF &
         "vfmadd231ps %%ymm15, %%ymm13, %%ymm5" & LF &
         "vfmadd231ps %%ymm15, %%ymm14, %%ymm9" & LF &
         "vmovups 64(%%rax), %%ymm15" & LF &
         "vfmadd231ps %%ymm15, %%ymm12, %%ymm2" & LF &
         "vfmadd231ps %%ymm15, %%ymm13, %%ymm6" & LF &
         "vfmadd231ps %%ymm15, %%ymm14, %%ymm10" & LF &
         "vmovups 96(%%rax), %%ymm15" & LF &
         "vfmadd231ps %%ymm15, %%ymm12, %%ymm3" & LF &
         "vfmadd231ps %%ymm15, %%ymm13, %%ymm7" & LF &
         "vfmadd231ps %%ymm15, %%ymm14, %%ymm11" & LF &
         "addq $4, %%rsi" & LF &
         "addq $128, %%rax" & LF &
         "decq %%rcx" & LF &
         "jnz 1b" & LF &
         "movq 16(%%r11), %%r8" & LF &
         "movq 40(%%r11), %%r9" & LF &
         "cmpq $0, 48(%%r11)" & LF &
         "je 2f" & LF &
         "vaddps (%%r8), %%ymm0, %%ymm0" & LF &
         "vaddps 32(%%r8), %%ymm1, %%ymm1" & LF &
         "vaddps 64(%%r8), %%ymm2, %%ymm2" & LF &
         "vaddps 96(%%r8), %%ymm3, %%ymm3" & LF &
         "vaddps (%%r8,%%r9), %%ymm4, %%ymm4" & LF &
         "vaddps 32(%%r8,%%r9), %%ymm5, %%ymm5" & LF &
         "vaddps 64(%%r8,%%r9), %%ymm6, %%ymm6" & LF &
         "vaddps 96(%%r8,%%r9), %%ymm7, %%ymm7" & LF &
         "vaddps (%%r8,%%r9,2), %%ymm8, %%ymm8" & LF &
         "vaddps 32(%%r8,%%r9,2), %%ymm9, %%ymm9" & LF &
         "vaddps 64(%%r8,%%r9,2), %%ymm10, %%ymm10" & LF &
         "vaddps 96(%%r8,%%r9,2), %%ymm11, %%ymm11" & LF &
         "2:" & LF &
         "vmovups %%ymm0, (%%r8)" & LF &
         "vmovups %%ymm1, 32(%%r8)" & LF &
         "vmovups %%ymm2, 64(%%r8)" & LF &
         "vmovups %%ymm3, 96(%%r8)" & LF &
         "vmovups %%ymm4, (%%r8,%%r9)" & LF &
         "vmovups %%ymm5, 32(%%r8,%%r9)" & LF &
         "vmovups %%ymm6, 64(%%r8,%%r9)" & LF &
         "vmovups %%ymm7, 96(%%r8,%%r9)" & LF &
         "vmovups %%ymm8, (%%r8,%%r9,2)" & LF &
         "vmovups %%ymm9, 32(%%r8,%%r9,2)" & LF &
         "vmovups %%ymm10, 64(%%r8,%%r9,2)" & LF &
         "vmovups %%ymm11, 96(%%r8,%%r9,2)" & LF &
         "vzeroupper",
         Inputs   => System.Address'Asm_Input ("r", Call'Address),
         Clobber  =>
           "rax,rcx,rdx,rsi,r8,r9,r11,ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,"
           & "ymm11,ymm12,ymm13,ymm14,ymm15,memory,cc",
         Volatile => True);
   end Wide_Tile;

   --  Six vectors by a panel, in plain code: the same sums in the same
   --  order, a multiply and an add apiece.
   procedure Plain_Tile (Call : Tile_Call) is
      Rows    : constant Element_Count := 6;
      Across  : constant Element_Count := Element_Count (Call.Across / 4);
      Down    : constant Element_Count := Element_Count (Call.Down / 4);
      Steps   : constant Element_Count := Element_Count (Call.Steps);
      Vectors : constant Real_Array (0 .. (Rows - 1) * Across + Steps - 1)
        with Import, Address => Call.Vectors;
      Panel   : constant Real_Array (0 .. Steps * Width - 1)
        with Import, Address => Call.Panel;
      Answers : Real_Array (0 .. (Rows - 1) * Down + Width - 1)
        with Import, Address => Call.Answers;
      Sums    : Real_Array (0 .. Width - 1);
   begin
      for Row in 0 .. Rows - 1 loop
         Sums := [others => 0.0];
         for Step in 0 .. Steps - 1 loop
            declare
               Value : constant Real := Vectors (Row * Across + Step);
            begin
               for Lane in Element_Count range 0 .. Width - 1 loop
                  Sums (Lane) := Sums (Lane) + Value * Panel (Step * Width + Lane);
               end loop;
            end;
         end loop;
         for Lane in Element_Count range 0 .. Width - 1 loop
            Answers (Row * Down + Lane) :=
              (if Call.Add = 0 then Sums (Lane) else Answers (Row * Down + Lane) + Sums (Lane));
         end loop;
      end loop;
   end Plain_Tile;

   procedure Tile (Kind : Kernel_Kind; Call : Tile_Call) is
   begin
      case Kind is
         when Widest => Widest_Tile (Call);
         when Wide   => Wide_Tile (Call);
         when Plain  => Plain_Tile (Call);
      end case;
   end Tile;

   ----------
   -- Pack --
   ----------

   procedure Pack
     (Weight : Model_Runner.Tensors.View;
      Into   : in out Panel_Set;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Rows    : constant Element_Count := Weight.Rows;
      Columns : constant Element_Count := Weight.Columns;
      Panels  : constant Element_Count := (Rows + Width - 1) / Width;
   begin
      Free (Into);
      Status := E.Success;
      if Rows = 0 or else Columns = 0 then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      T.Allocate (Panels * Columns * Width, Into.Data);
      if Into.Data = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      declare
         Data : Real_Array renames Into.Data.all;
         Row_Values : T.Real_Array_Access;
      begin
         --  The rows past the weight's last are zeros, which the tiles
         --  multiply and nothing reads.
         Data (Data'First + Rows / Width * Columns * Width .. Data'Last) := [others => 0.0];
         T.Allocate (Columns, Row_Values);
         if Row_Values = null then
            Status := E.Make (E.Memory_Allocation_Failed);
         end if;
         for Row in 0 .. Rows - 1 loop
            exit when E.Is_Error (Status);
            T.Dequantize_Row (Weight, Row, Row_Values.all, Status);
            exit when E.Is_Error (Status);
            declare
               Base : constant Element_Count := Data'First + Row / Width * Columns * Width + Row mod Width;
            begin
               for Column in 0 .. Columns - 1 loop
                  Data (Base + Column * Width) := Row_Values (Row_Values'First + Column);
               end loop;
            end;
         end loop;
         T.Free (Row_Values);
      end;
      if E.Is_Error (Status) then
         Free (Into);
         return;
      end if;
      Into.Rows := Rows;
      Into.Columns := Columns;
   end Pack;

   --  A share of the panels of a matrix laid out from binary32 already
   --  in memory: panel P's column K, lane L, is the element at Row_Step *
   --  (P * Width + L) + Column_Step * K from the first.
   type Pack_Work is new Model_Runner.Shares.Work with record
      Source       : System.Address;
      Span         : Element_Count;
      Data         : System.Address;
      Rows         : Element_Count;
      Columns      : Element_Count;
      Row_Step     : Element_Count;
      Column_Step  : Element_Count;
   end record;

   overriding procedure Run (Item : in out Pack_Work; First : Element_Count; Last : Element_Count);

   overriding procedure Run (Item : in out Pack_Work; First : Element_Count; Last : Element_Count) is
      Source : constant Real_Array (0 .. Item.Span - 1) with Import, Address => Item.Source;
      Data   : Real_Array (0 .. (Last + 1) * Item.Columns * Width - 1) with Import, Address => Item.Data;
   begin
      for P in First .. Last loop
         declare
            Lanes : constant Element_Count := Element_Count'Min (Width, Item.Rows - P * Width);
            Base  : constant Element_Count := P * Item.Columns * Width;
         begin
            for K in 0 .. Item.Columns - 1 loop
               for Lane in Element_Count range 0 .. Width - 1 loop
                  Data (Base + K * Width + Lane) :=
                    (if Lane < Lanes
                     then Source ((P * Width + Lane) * Item.Row_Step + K * Item.Column_Step)
                     else 0.0);
               end loop;
            end loop;
         end;
      end loop;
   end Run;

   procedure Pack
     (Team        : Model_Runner.Shares.Team_Access;
      Source      : Model_Runner.Numerics.Real_Array;
      From        : Element_Count;
      Rows        : Element_Count;
      Columns     : Element_Count;
      Row_Step    : Element_Count;
      Column_Step : Element_Count;
      Into        : in out Panel_Set;
      Status      : out Model_Runner.Errors.Error_Info)
   is
      Panels : constant Element_Count := (Rows + Width - 1) / Width;
      Whole  : Boolean := False;
   begin
      Status := E.Success;
      if Rows = 0 or else Columns = 0 then
         Free (Into);
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      --  Kept where it is large enough: a set packed again and again, as
      --  attention packs every head's keys, allocates once.
      if Into.Data = null or else Into.Data'Length < Panels * Columns * Width then
         Free (Into);
         T.Allocate (Panels * Columns * Width, Into.Data);
         if Into.Data = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end if;
      declare
         Work : aliased Pack_Work :=
           (Source      => Source (From)'Address,
            Span        => Source'Last - From + 1,
            Data        => Into.Data.all'Address,
            Rows        => Rows,
            Columns     => Columns,
            Row_Step    => Row_Step,
            Column_Step => Column_Step);
      begin
         if Team /= null then
            Team.Divide (Panels, Work'Unchecked_Access, Whole, Cost => Panels * Columns * Width);
         end if;
         if not Whole then
            Work.Run (0, Panels - 1);
         end if;
      end;
      Into.Rows := Rows;
      Into.Columns := Columns;
   end Pack;

   ----------
   -- Free --
   ----------

   procedure Free (Item : in out Panel_Set) is
   begin
      T.Free (Item.Data);
      Item.Rows := 0;
      Item.Columns := 0;
   end Free;

   function Is_Packed (Item : Panel_Set) return Boolean
   is (Item.Data /= null);

   --------------
   -- Multiply --
   --------------

   --  The product cut into items, each Chunk vectors by Group panels:
   --  item U the vectors' chunk U mod Chunks of the panels' group U /
   --  Chunks, so the items a share runs one after another read the same
   --  panels.
   type Product_Work is new Model_Runner.Shares.Work with record
      Kind    : Kernel_Kind;
      Data    : System.Address;
      Rows    : Element_Count;
      Columns : Element_Count;
      Count   : Element_Count;
      Chunks  : Element_Count;
      --  The first vector's first element and the first answer's, and
      --  how far apart two vectors and two answers lie, in elements.
      Vectors : System.Address;
      Target  : System.Address;
      Across  : Element_Count;
      Down    : Element_Count;
   end record;

   overriding procedure Run (Item : in out Product_Work; First : Element_Count; Last : Element_Count);

   overriding procedure Run (Item : in out Product_Work; First : Element_Count; Last : Element_Count) is
      Columns : constant Element_Count := Item.Columns;
      Rows    : constant Element_Count := Item.Rows;
      Panels  : constant Element_Count := (Rows + Width - 1) / Width;
      Step    : constant Element_Count := Tile_Vectors (Item.Kind);
      Across  : constant Element_Count := Item.Across;
      Down    : constant Element_Count := Item.Down;
      Vectors : constant Real_Array (0 .. (Item.Count - 1) * Across + Columns - 1)
        with Import, Address => Item.Vectors;
      Target  : Real_Array (0 .. (Item.Count - 1) * Down + Rows - 1)
        with Import, Address => Item.Target;
      Data    : constant Real_Array (0 .. Panels * Columns * Width - 1)
        with Import, Address => Item.Data;
   begin
      for U in First .. Last loop
         declare
            From    : constant Element_Count := U mod Item.Chunks * Chunk;
            Here    : constant Element_Count := Element_Count'Min (Chunk, Item.Count - From);
            P_First : constant Element_Count := U / Item.Chunks * Group;
            P_Last  : constant Element_Count := Element_Count'Min (P_First + Group - 1, Panels - 1);
            Start   : Element_Count := 0;
         begin
            while Start < Columns loop
               declare
                  Steps : constant Element_Count := Element_Count'Min (Block, Columns - Start);
               begin
                  for P in P_First .. P_Last loop
                     declare
                        Lanes  : constant Element_Count := Element_Count'Min (Width, Rows - P * Width);
                        Panel  : constant System.Address := Data ((P * Columns + Start) * Width)'Address;
                        Vector : Element_Count := From;
                     begin
                        while Vector < From + Here loop
                           declare
                              Take : constant Element_Count := Element_Count'Min (Step, From + Here - Vector);
                           begin
                              if Take = Step and then Lanes = Width then
                                 Tile (Item.Kind,
                                       (Vectors => Vectors (Vector * Across + Start)'Address,
                                        Panel   => Panel,
                                        Answers => Target (Vector * Down + P * Width)'Address,
                                        Across  => Interfaces.Unsigned_64 (Across * 4),
                                        Steps   => Interfaces.Unsigned_64 (Steps),
                                        Down    => Interfaces.Unsigned_64 (Down * 4),
                                        Add     => (if Start = 0 then 0 else 1)));
                              else
                                 --  A tile the vectors or the weight's rows
                                 --  run out in: through spare room, the rows
                                 --  that are there copied in and the answers
                                 --  that are there taken out.
                                 declare
                                    Spare_In  : Real_Array (0 .. Step * Steps - 1) := [others => 0.0];
                                    Spare_Out : Real_Array (0 .. Step * Width - 1);
                                 begin
                                    for R in 0 .. Take - 1 loop
                                       Spare_In (R * Steps .. R * Steps + Steps - 1) :=
                                         Vectors ((Vector + R) * Across + Start
                                                  .. (Vector + R) * Across + Start + Steps - 1);
                                    end loop;
                                    Tile (Item.Kind,
                                          (Vectors => Spare_In'Address,
                                           Panel   => Panel,
                                           Answers => Spare_Out'Address,
                                           Across  => Interfaces.Unsigned_64 (Steps * 4),
                                           Steps   => Interfaces.Unsigned_64 (Steps),
                                           Down    => Interfaces.Unsigned_64 (Width * 4),
                                           Add     => 0));
                                    for R in 0 .. Take - 1 loop
                                       for Lane in 0 .. Lanes - 1 loop
                                          declare
                                             At_Target : constant Element_Count :=
                                               (Vector + R) * Down + P * Width + Lane;
                                          begin
                                             Target (At_Target) :=
                                               (if Start = 0 then Spare_Out (R * Width + Lane)
                                                else Target (At_Target) + Spare_Out (R * Width + Lane));
                                          end;
                                       end loop;
                                    end loop;
                                 end;
                              end if;
                              Vector := Vector + Take;
                           end;
                        end loop;
                     end;
                  end loop;
                  Start := Start + Steps;
               end;
            end loop;
         end;
      end loop;
   end Run;

   procedure Multiply
     (Team    : Model_Runner.Shares.Team_Access;
      Item    : Panel_Set;
      Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Element_Count;
      Target  : in out Model_Runner.Numerics.Real_Array) is
   begin
      Multiply
        (Team, Item, Vectors, Vectors'First, Item.Columns, Count, Target, Target'First, Item.Rows);
   end Multiply;

   procedure Multiply
     (Team         : Model_Runner.Shares.Team_Access;
      Item         : Panel_Set;
      Vectors      : Model_Runner.Numerics.Real_Array;
      Vectors_From : Element_Count;
      Vector_Step  : Element_Count;
      Count        : Element_Count;
      Target       : in out Model_Runner.Numerics.Real_Array;
      Target_From  : Element_Count;
      Target_Step  : Element_Count)
   is
      Panels : constant Element_Count := (Item.Rows + Width - 1) / Width;
      Chunks : constant Element_Count := (Count + Chunk - 1) / Chunk;
      Items  : constant Element_Count := Chunks * ((Panels + Group - 1) / Group);
      Whole  : Boolean := False;
   begin
      if Count = 0 then
         return;
      end if;
      declare
         Work : aliased Product_Work :=
           (Kind    => Chosen,
            Data    => Item.Data.all'Address,
            Rows    => Item.Rows,
            Columns => Item.Columns,
            Count   => Count,
            Chunks  => Chunks,
            Vectors => Vectors (Vectors_From)'Address,
            Target  => Target (Target_From)'Address,
            Across  => Vector_Step,
            Down    => Target_Step);
      begin
         if Team /= null then
            Team.Divide (Items, Work'Unchecked_Access, Whole, Cost => Count * Item.Rows * Item.Columns);
         end if;
         if not Whole then
            Work.Run (0, Items - 1);
         end if;
      end;
   end Multiply;

   ----------------
   -- Use_Kernel --
   ----------------

   procedure Use_Kernel (Kind : Kernel_Kind) is
   begin
      Chosen := Kind;
   end Use_Kernel;

   function Kernel return Kernel_Kind
   is (Chosen);

end Model_Runner.Float_Panels;
