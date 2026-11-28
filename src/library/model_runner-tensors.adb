with Model_Runner.Tensors.Wide_Products;
with Ada.Containers.Generic_Array_Sort;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;

with Interfaces;
with System.Machine_Code;
with System.Atomic_Operations.Modular_Arithmetic;

with Model_Runner.Arithmetic;
with Model_Runner.Quantization;
with Model_Runner.Quantization.Interleave;

package body Model_Runner.Tensors is

   package N renames Model_Runner.Numerics;
   use type N.Wide_Real;
   use type Interfaces.Unsigned_64;

   --  The rows the fallback read out of their panels, every task's.
   type Row_Count is mod 2 ** 64
     with Atomic;
   Fallback_Count : aliased Row_Count := 0;
   package Counting is new System.Atomic_Operations.Modular_Arithmetic (Row_Count);

   -------------------
   -- Fallback_Rows --
   -------------------

   function Fallback_Rows return Natural
   is (Natural (Row_Count'Min (Fallback_Count, Row_Count (Natural'Last))));

   use type System.Address;

   --  Weights come from a model file and may be infinities or not-a-numbers,
   --  so the kernels here can produce one. That is data, not a fault: callers
   --  test with Kernels.All_Finite and report it. Validity checking raises on
   --  the value before any of them can look, so it is suppressed for the same
   --  reason it is in Numerics and the sampler. Bounds and range checking are
   --  untouched.
   pragma Suppress (Validity_Check);

   use type Element_Count;

   --  How many elements a row kernel decodes before consuming them. Large
   --  enough that the per-span cost is negligible, small enough that the
   --  decoded values stay in the nearest cache and the stack cost is fixed
   --  whatever the row width.
   Max_Chunk : constant Element_Count := 1024;

   --  The chunk rounded down to a whole number of blocks, so a span never
   --  splits one. A block wider than the chunk decodes one block at a time.
   function Chunk_Elements (Per_Block : Element_Count) return Element_Count
   is (if Per_Block = 0 then Max_Chunk
       elsif Per_Block >= Max_Chunk then Per_Block
       else Max_Chunk / Per_Block * Per_Block);

   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Arithmetic.Checked;

   package A renames Model_Runner.Arithmetic;
   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package Q renames Model_Runner.Quantization;

   procedure Deallocate is
     new Ada.Unchecked_Deallocation (Real_Array, Real_Array_Access);

   procedure Deallocate_Halves is
     new Ada.Unchecked_Deallocation (Half_Array, Half_Array_Access);

   --------------
   -- Allocate --
   --------------

   procedure Allocate (Length : Element_Count; Result : out Real_Array_Access) is
   begin
      --  Zero already: the pool is calloc's, and a large block is pages
      --  nothing has touched yet, which writing zeros into would touch.
      Result := new Real_Array (0 .. Length - 1);
   exception
      when Storage_Error =>
         Result := null;
   end Allocate;

   ----------
   -- Free --
   ----------

   procedure Free (Item : in out Real_Array_Access) is
   begin
      if Item /= null then
         Deallocate (Item);
      end if;
      Item := null;
   end Free;

   procedure Allocate (Length : Element_Count; Result : out Half_Array_Access)
   is
   begin
      Result := new Half_Array (0 .. Length - 1);
   exception
      when Storage_Error =>
         Result := null;
   end Allocate;

   procedure Free (Item : in out Half_Array_Access) is
   begin
      if Item /= null then
         Deallocate_Halves (Item);
      end if;
      Item := null;
   end Free;

   procedure Free (Item : in out Group_Room_Access) is
      procedure Release is
        new Ada.Unchecked_Deallocation (Group_Room, Group_Room_Access);
   begin
      if Item = null then
         return;
      end if;

      for Index in Item.all'Range loop
         Free (Item.all (Index));
      end loop;

      Release (Item);
   end Free;

   ----------------
   -- Is_Present --
   ----------------

   function Is_Present (Item : View) return Boolean
   is (Item.Base /= System.Null_Address
       and then Item.Rows > 0 and then Item.Columns > 0);

   ----------------------
   -- First_Of_Storage --
   ----------------------

   function First_Of_Storage (Places : Storage_Places) return Storage_Firsts
   is
      type Order is array (Positive range <>) of Positive;
      type Order_Access is access Order;

      procedure Free is new Ada.Unchecked_Deallocation (Order, Order_Access);

      function Before (Left, Right : Positive) return Boolean
      is (if Places (Left).Base /= Places (Right).Base
          then Places (Left).Base < Places (Right).Base
          elsif Places (Left).Offset /= Places (Right).Offset
          then Places (Left).Offset < Places (Right).Offset
          else Left < Right);

      procedure Sort is new Ada.Containers.Generic_Array_Sort
        (Positive, Positive, Order, Before);

      Result : Storage_Firsts (Places'Range) := [others => False];
      Sorted : Order_Access := new Order (Places'Range);
      Last   : Natural := 0;
   begin
      for Index in Places'Range loop
         Sorted (Index) := Index;
      end loop;
      Sort (Sorted.all);
      for Index of Sorted.all loop
         if Last = 0 or else Places (Last) /= Places (Index) then
            Result (Index) := True;
         end if;
         Last := Index;
      end loop;
      Free (Sorted);
      return Result;
   end First_Of_Storage;

   ----------------
   -- Row_Bytes --
   ----------------

   function Row_Bytes (Item : View) return B.Byte_Count is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
   begin
      if Per_Block = 0 then
         return 0;
      else
         return B.Byte_Count (Item.Columns / Per_Block)
           * B.Byte_Count (G.Block_Bytes (Item.Format));
      end if;
   end Row_Bytes;

   ---------------
   -- Elements --
   ---------------

   function Elements (Item : View) return Element_Count
   is (Item.Rows * Item.Columns);

   ----------
   -- Make --
   ----------

   --  The owned form, said in terms of the borrowed one: a buffer this
   --  program allocated is a buffer at an address with a length, and nothing
   --  below this line needs to know which it was handed.
   procedure Make
     (Format  : G.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Data    : B.Byte_Array_Access;
      Offset  : B.Byte_Count;
      Result  : out View;
      Status  : out E.Error_Info) is
   begin
      if Data = null then
         Result := Empty_View;
         Status := E.Make (E.Tensor_Out_Of_Bounds);
         return;
      end if;

      Make (Format, Rows, Columns, Data.all'Address,
            B.Byte_Count (Data.all'Length), Offset, Result, Status);
   end Make;

   procedure Make
     (Format  : G.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Base    : System.Address;
      Span    : B.Byte_Count;
      Offset  : B.Byte_Count;
      Result  : out View;
      Status  : out E.Error_Info)
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      Result := Empty_View;

      if not Q.Is_Decodable (Format) then
         Status := E.Make (E.Tensor_Format_Unsupported);
         E.Add_Text (Status, "format", G.Type_Name (Format), E.Param_Identifier);
         return;
      end if;

      if Rows = 0 or else Columns = 0 or else Base = System.Null_Address then
         Status := E.Make (E.Tensor_Invalid_Shape);
         E.Add_Integer (Status, "rows", Long_Long_Integer (Rows));
         E.Add_Integer (Status, "columns", Long_Long_Integer (Columns));
         return;
      end if;

      if Per_Block = 0 or else Columns mod Per_Block /= 0 then
         Status := E.Make (E.Tensor_Block_Misaligned);
         E.Add_Text (Status, "format", G.Type_Name (Format), E.Param_Identifier);
         E.Add_Integer (Status, "columns", Long_Long_Integer (Columns));
         return;
      end if;

      declare
         Per_Row : constant A.Checked :=
           A.To_Checked (Interfaces.Unsigned_64 (Columns / Per_Block))
           * A.To_Checked (G.Block_Bytes (Format));
         Total   : constant A.Checked :=
           Per_Row * A.To_Checked (Interfaces.Unsigned_64 (Rows));
         Finish  : constant A.Checked :=
           Total + A.To_Checked (Interfaces.Unsigned_64 (Offset));
      begin
         if not A.Is_Valid (Finish) then
            Status := E.Make (E.Tensor_Invalid_Shape);
            return;
         end if;

         if B.Byte_Count (A.Value (Finish)) > Span then
            Status := E.Make (E.Tensor_Out_Of_Bounds);
            E.Add_Integer
              (Status, "offset", Long_Long_Integer (Offset), E.Param_Offset);
            E.Add_Integer
              (Status, "size", Long_Long_Integer (A.Value (Total)),
               E.Param_Bytes);
            E.Add_Integer
              (Status, "available", Long_Long_Integer (Span),
               E.Param_Bytes);
            return;
         end if;

         Result :=
           (Format  => Format,
            Rows    => Rows,
            Columns => Columns,
            Role    => Role_Other,
            Base    => Base,
            Span    => Span,
            Offset  => Offset,
            Length  => B.Byte_Count (A.Value (Total)),
            Interleaved => False,
            Reference_Activations => False, Scales => null);
         Status := E.Success;
      end;
   end Make;

   --------------------
   -- Make_Panels --
   --------------------

   procedure Make_Panels
     (Format  : G.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Data    : B.Byte_Array_Access;
      Offset  : B.Byte_Count;
      Result  : out View;
      Status  : out E.Error_Info) is
   begin
      if Data = null then
         Result := Empty_View;
         Status := E.Make (E.Tensor_Out_Of_Bounds);
         return;
      end if;

      Make_Panels_At
        (Format, Rows, Columns, Data.all'Address,
         B.Byte_Count (Data.all'Length), Offset, Result, Status);
   end Make_Panels;

   --------------------
   -- Make_Panels_At --
   --------------------

   procedure Make_Panels_At
     (Format  : G.Tensor_Type;
      Rows    : Element_Count;
      Columns : Element_Count;
      Base    : System.Address;
      Span    : B.Byte_Count;
      Offset  : B.Byte_Count;
      Result  : out View;
      Status  : out E.Error_Info)
   is
      package IL renames Model_Runner.Quantization.Interleave;

      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      Result := Empty_View;

      if Base = System.Null_Address then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
         return;
      end if;

      if not IL.Interleaves (Format, Rows, Columns) then
         Status := E.Make (E.Tensor_Format_Unsupported);
         E.Add_Text (Status, "format", G.Type_Name (Format),
                     E.Param_Identifier);
         return;
      end if;

      declare
         Total : constant B.Byte_Count :=
           IL.Panel_Bytes (Format, Rows, Columns / Per_Block);
      begin
         if Offset + Total > Span then
            Status := E.Make (E.Tensor_Out_Of_Bounds);
            E.Add_Integer
              (Status, "offset", Long_Long_Integer (Offset), E.Param_Offset);
            E.Add_Integer
              (Status, "size", Long_Long_Integer (Total), E.Param_Bytes);
            E.Add_Integer
              (Status, "available", Long_Long_Integer (Span), E.Param_Bytes);
            return;
         end if;

         Result :=
           (Format      => Format,
            Rows        => Rows,
            Columns     => Columns,
            Role        => Role_Other,
            Base        => Base,
            Span        => Span,
            Offset      => Offset,
            Length      => Total,
            Interleaved => True,
            Reference_Activations => False, Scales => null);
         Status := E.Success;
      end;
   end Make_Panels_At;

   --------------
   -- Row_Dot --
   --------------

   function Row_Dot
     (Item   : View;
      Row    : Element_Count;
      Vector : Real_Array) return Real
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Sums : Model_Runner.Numerics.Wide_Real_Array (0 .. 0) := [others => 0.0];
      Ok   : Boolean;
   begin
      if not Is_Present (Item)
        or else Row >= Item.Rows
        or else Per_Block = 0
        or else Vector'Length /= Item.Columns
      then
         return 0.0;
      end if;

      --  A row of a panel is a gather, and this is the reader that pays for
      --  it: the row is put back the way the file had it and then computed
      --  the ordinary way. Nothing on the product's path comes through here
      --  -- the kernel reads the panels where they are -- so the copy is a
      --  test's cost or a refusal's, not a token's.
      if Item.Interleaved then
         declare
            Held : B.Byte_Array (1 .. Item.Span)
              with Import, Address => Item.Base;

            Row_Span : constant B.Byte_Count := Row_Bytes (Item);
            Alone    : B.Byte_Array (0 .. Row_Span - 1);
            Taken    : Boolean;
         begin
            Counting.Atomic_Add (Fallback_Count, 1);
            Model_Runner.Quantization.Interleave.Extract_Row
              (Format => Item.Format,
               Source => Held,
               From   => Item.Offset,
               Row    => Row,
               Blocks => Item.Columns / Per_Block,
               Target => Alone,
               Ok     => Taken);

            if not Taken then
               return 0.0;
            end if;

            Q.Accumulate_Dot
              (Format  => Item.Format,
               Data    => Alone,
               Offset  => 0,
               Blocks  => Item.Columns / Per_Block,
               Vectors => Vector,
               First   => Vector'First,
               Stride  => Item.Columns,
               Count   => 1,
               Sums    => Sums,
               Ok      => Ok);
         end;

         return (if Ok then Real (Sums (0)) else 0.0);
      end if;

      --  The same kernel the matrix product uses, with one input vector, so
      --  a row computed alone and the same row computed inside a batch give
      --  the same bits.
      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;
      begin
         Q.Accumulate_Dot
           (Format  => Item.Format,
            Data    => Held,
            Offset  => Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item),
            Blocks  => Item.Columns / Per_Block,
            Vectors => Vector,
            First   => Vector'First,
            Stride  => Item.Columns,
            Count   => 1,
            Sums    => Sums,
            Ok      => Ok);
      end;

      return (if Ok then Real (Sums (0)) else 0.0);
   end Row_Dot;

   ---------------------
   -- Dequantize_Row --
   ---------------------

   procedure Dequantize_Row
     (Item   : View;
      Row    : Element_Count;
      Target : out Real_Array;
      Status : out E.Error_Info)
   is
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Block_Size : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (Item.Format));
      Base   : B.Byte_Count;
      Ok     : Boolean;
      Column : Element_Count := 0;
   begin
      Target := [others => 0.0];

      if not Is_Present (Item)
        or else Row >= Item.Rows
        or else Target'Length /= Item.Columns
      then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
         E.Add_Integer (Status, "row", Long_Long_Integer (Row));
         E.Add_Integer (Status, "rows", Long_Long_Integer (Item.Rows));
         return;
      end if;

      --  As in Row_Dot: a panel's row is assembled first and decoded from
      --  the assembled copy, so every reader below this line sees the layout
      --  the file had.
      if Item.Interleaved then
         declare
            Held : B.Byte_Array (1 .. Item.Span)
              with Import, Address => Item.Base;

            Row_Span : constant B.Byte_Count := Row_Bytes (Item);
            Alone    : B.Byte_Array (0 .. Row_Span - 1);
            Taken    : Boolean;
         begin
            Counting.Atomic_Add (Fallback_Count, 1);
            Model_Runner.Quantization.Interleave.Extract_Row
              (Format => Item.Format,
               Source => Held,
               From   => Item.Offset,
               Row    => Row,
               Blocks => Item.Columns / Per_Block,
               Target => Alone,
               Ok     => Taken);

            if Taken then
               Q.Decode_Blocks
                 (Item.Format, Alone, 0, Item.Columns / Per_Block,
                  Target, Ok);
            else
               Ok := False;
            end if;
         end;

         if not Ok then
            Status := E.Make (E.Tensor_Out_Of_Bounds);
            return;
         end if;

         Status := E.Success;
         return;
      end if;

      Base := Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item);

      while Column < Item.Columns loop
         declare
            Remaining : constant Element_Count := Item.Columns - Column;
            Span      : constant Element_Count :=
              Element_Count'Min (Chunk_Elements (Per_Block), Remaining);
            Blocks    : constant Element_Count := Span / Per_Block;
         begin
            declare
               Held : B.Byte_Array (1 .. Item.Span)
                 with Import, Address => Item.Base;
            begin
               Q.Decode_Blocks
                 (Item.Format, Held, Base, Blocks,
                  Target (Target'First + Column
                          .. Target'First + Column + Span - 1), Ok);
            end;
            if not Ok then
               Status := E.Make (E.Tensor_Out_Of_Bounds);
               return;
            end if;

            Column := Column + Span;
            Base := Base + Block_Size * B.Byte_Count (Blocks);
         end;
      end loop;

      Status := E.Success;
   end Dequantize_Row;

   --------------------
   -- Mat_Vec_Range --
   --------------------

   procedure Mat_Vec_Range
     (Item   : View;
      Vector : Real_Array;
      Target : in out Real_Array;
      First  : Element_Count;
      Last   : Element_Count) is
   begin
      if not Is_Present (Item) or else First > Last or else Last >= Item.Rows
      then
         return;
      end if;

      --  One input vector is the same work arranged the same way, so a token
      --  evaluated alone and the same token evaluated inside a batch produce
      --  identical bits rather than merely close ones.
      Mat_Mul_Range (Item, Vector, 1, Target, First, Last);
   end Mat_Vec_Range;

   --------------
   -- Mat_Vec --
   --------------

   procedure Mat_Vec
     (Item   : View;
      Vector : Real_Array;
      Target : in out Real_Array;
      Status : out E.Error_Info) is
   begin
      if not Is_Present (Item)
        or else Vector'Length /= Item.Columns
        or else Target'Length /= Item.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer (Status, "rows", Long_Long_Integer (Item.Rows));
         E.Add_Integer (Status, "columns", Long_Long_Integer (Item.Columns));
         E.Add_Integer (Status, "input", Long_Long_Integer (Vector'Length));
         E.Add_Integer (Status, "output", Long_Long_Integer (Target'Length));
         return;
      end if;

      Mat_Vec_Range (Item, Vector, Target, 0, Item.Rows - 1);
      Status := E.Success;
   end Mat_Vec;

   --------------------
   -- Mat_Mul_Range --
   --------------------

   Wide_Halves : Boolean := False with Atomic;
   Deep_Products : Boolean := False with Atomic;
   Brain_Products : Boolean := False with Atomic;

   procedure Use_Deep_Products (Allowed : Boolean) is
   begin
      Deep_Products := Allowed;
   end Use_Deep_Products;

   procedure Use_Deep_Products (Allowed : Boolean; Brain : Boolean) is
   begin
      Deep_Products := Allowed;
      Brain_Products := Brain;
   end Use_Deep_Products;

   procedure Use_Wide_Halves (Allowed : Boolean) is
   begin
      Wide_Halves := Allowed;
   end Use_Wide_Halves;

   procedure Mat_Mul_Range_Float
     (Item    : View;
      Vectors : Real_Array;
      Count   : Element_Count;
      Target  : in out Real_Array;
      First   : Element_Count;
      Last    : Element_Count;
      Handled : out Boolean)
   is
      use type Model_Runner.GGUF.Tensor_Type;
      use type Interfaces.Unsigned_32;
      use type Real;
      LF : constant Character := ASCII.LF;
      Columns : constant Element_Count := Item.Columns;
      Eights  : constant Element_Count := Columns / 8;
      Stride  : constant Element_Count := Columns * 4;
      type Lane_Sums is array (0 .. 63) of Real with Alignment => 32;
      Sums : aliased Lane_Sums;
      Row  : Element_Count;

      type Float_Kind is (Halves, Brains, Singles);
      Kind : constant Float_Kind :=
        (case Item.Format is
           when Model_Runner.GGUF.Type_F16  => Halves,
           when Model_Runner.GGUF.Type_BF16 => Brains,
           when others                      => Singles);
      Width_Bytes : constant B.Byte_Count := (if Kind = Singles then 4 else 2);
   begin
      Handled := False;
      if not Wide_Halves
        or else Item.Format not in Model_Runner.GGUF.Type_F16
                                 | Model_Runner.GGUF.Type_BF16
                                 | Model_Runner.GGUF.Type_F32
        or else Item.Interleaved
        or else not Is_Present (Item)
        or else First > Last
        or else Last >= Item.Rows
        or else Count = 0
        or else Vectors'Length < Count * Columns
        or else Target'Length < Count * Item.Rows
      then
         return;
      end if;

      if Item.Reference_Activations and then Kind = Brains and then Deep_Products and then Brain_Products
        and then Columns > 0 and then Columns mod 64 = 0
      then
         --  BF16 checkpoints round the input as well as the stored weights.
         --  Two independent pairwise-dot streams reproduce the native CPU
         --  contract without expanding either matrix to binary32 storage.
         declare
            Data : B.Byte_Array (1 .. Item.Span) with Import, Address => Item.Base;
            Value : Real;
         begin
            for Row in First .. Last loop
               for Vector in Element_Count range 0 .. Count - 1 loop
                  System.Machine_Code.Asm
                    ("vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "movq %1, %%r8" & LF
                     & "movq %2, %%r9" & LF
                     & "movq %3, %%r10" & LF
                     & "1:" & LF
                     & "vmovups 0(%%r9), %%zmm4" & LF
                     & "vmovups 64(%%r9), %%zmm5" & LF
                     & "vcvtne2ps2bf16 %%zmm4, %%zmm5, %%zmm6" & LF
                     & "vmovdqu64 0(%%r8), %%zmm7" & LF
                     & "vdpbf16ps %%zmm6, %%zmm7, %%zmm0" & LF
                     & "vmovups 128(%%r9), %%zmm4" & LF
                     & "vmovups 192(%%r9), %%zmm5" & LF
                     & "vcvtne2ps2bf16 %%zmm4, %%zmm5, %%zmm6" & LF
                     & "vmovdqu64 64(%%r8), %%zmm7" & LF
                     & "vdpbf16ps %%zmm6, %%zmm7, %%zmm1" & LF
                     & "addq $128, %%r8" & LF
                     & "addq $256, %%r9" & LF
                     & "decq %%r10" & LF
                     & "jnz 1b" & LF
                     & "vextractf64x4 $1, %%zmm0, %%ymm2" & LF
                     & "vaddps %%ymm0, %%ymm2, %%ymm2" & LF
                     & "vextractf128 $1, %%ymm2, %%xmm3" & LF
                     & "vaddps %%xmm2, %%xmm3, %%xmm3" & LF
                     & "vpermilps $0x4e, %%xmm3, %%xmm2" & LF
                     & "vaddps %%xmm3, %%xmm2, %%xmm2" & LF
                     & "vmovaps %%xmm2, %%xmm3" & LF
                     & "vshufps $0x55, %%xmm2, %%xmm2, %%xmm2" & LF
                     & "vaddss %%xmm2, %%xmm3, %%xmm3" & LF
                     & "vextractf64x4 $1, %%zmm1, %%ymm2" & LF
                     & "vaddps %%ymm1, %%ymm2, %%ymm2" & LF
                     & "vextractf128 $1, %%ymm2, %%xmm4" & LF
                     & "vaddps %%xmm2, %%xmm4, %%xmm4" & LF
                     & "vpermilps $0x4e, %%xmm4, %%xmm2" & LF
                     & "vaddps %%xmm4, %%xmm2, %%xmm2" & LF
                     & "vmovaps %%xmm2, %%xmm4" & LF
                     & "vshufps $0x55, %%xmm2, %%xmm2, %%xmm2" & LF
                     & "vaddss %%xmm2, %%xmm4, %%xmm4" & LF
                     & "vaddss %%xmm3, %%xmm4, %%xmm4" & LF
                     & "vmovss %%xmm4, %0" & LF
                     & "vzeroupper",
                     Outputs => [Real'Asm_Output ("=m", Value)],
                     Inputs => [System.Address'Asm_Input
                                  ("r", Data (Data'First + Item.Offset
                                              + B.Byte_Count (Row) * Row_Bytes (Item))'Address),
                                System.Address'Asm_Input ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                Element_Count'Asm_Input ("r", Columns / 64)],
                     Clobber => "r8,r9,r10,zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm7,cc,memory",
                     Volatile => True);
                  Target (Target'First + Vector * Item.Rows + Row) := Value;
               end loop;
            end loop;
         end;
         Handled := True;
         return;
      end if;

      if Item.Reference_Activations and then Kind = Singles and then Deep_Products
        and then Columns > 0 and then Columns mod 64 = 0
      then
         --  The reference CPU profile uses four sixteen-coordinate FMA
         --  streams, then a fixed binary32 fold. Other roles never call
         --  this arithmetic-specific entry point.
         declare
            Data : B.Byte_Array (1 .. Item.Span) with Import, Address => Item.Base;
            Value : Real;
         begin
            for Row in First .. Last loop
               for Vector in Element_Count range 0 .. Count - 1 loop
                  System.Machine_Code.Asm
                    ("vxorps %%zmm0, %%zmm0, %%zmm0" & LF
                     & "vxorps %%zmm1, %%zmm1, %%zmm1" & LF
                     & "vxorps %%zmm2, %%zmm2, %%zmm2" & LF
                     & "vxorps %%zmm3, %%zmm3, %%zmm3" & LF
                     & "movq %1, %%r8" & LF
                     & "movq %2, %%r9" & LF
                     & "movq %3, %%r10" & LF
                     & "1:" & LF
                     & "vmovups 0(%%r8), %%zmm4" & LF
                     & "vfmadd231ps 0(%%r9), %%zmm4, %%zmm0" & LF
                     & "vmovups 64(%%r8), %%zmm4" & LF
                     & "vfmadd231ps 64(%%r9), %%zmm4, %%zmm1" & LF
                     & "vmovups 128(%%r8), %%zmm4" & LF
                     & "vfmadd231ps 128(%%r9), %%zmm4, %%zmm2" & LF
                     & "vmovups 192(%%r8), %%zmm4" & LF
                     & "vfmadd231ps 192(%%r9), %%zmm4, %%zmm3" & LF
                     & "addq $256, %%r8" & LF
                     & "addq $256, %%r9" & LF
                     & "decq %%r10" & LF
                     & "jnz 1b" & LF
                     & "vaddps %%zmm2, %%zmm0, %%zmm0" & LF
                     & "vaddps %%zmm3, %%zmm1, %%zmm1" & LF
                     & "vaddps %%zmm1, %%zmm0, %%zmm0" & LF
                     & "vextractf64x4 $1, %%zmm0, %%ymm1" & LF
                     & "vaddps %%ymm0, %%ymm1, %%ymm0" & LF
                     & "vextractf128 $1, %%ymm0, %%xmm1" & LF
                     & "vaddps %%xmm0, %%xmm1, %%xmm1" & LF
                     & "vpermilps $0x4e, %%xmm1, %%xmm0" & LF
                     & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
                     & "vmovaps %%xmm0, %%xmm2" & LF
                     & "vshufps $0x55, %%xmm0, %%xmm0, %%xmm0" & LF
                     & "vaddss %%xmm0, %%xmm2, %%xmm2" & LF
                     & "vmovss %%xmm2, %0" & LF
                     & "vzeroupper",
                     Outputs => [Real'Asm_Output ("=m", Value)],
                     Inputs => [System.Address'Asm_Input
                                  ("r", Data (Data'First + Item.Offset
                                              + B.Byte_Count (Row) * Row_Bytes (Item))'Address),
                                System.Address'Asm_Input ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                Element_Count'Asm_Input ("r", Columns / 64)],
                     Clobber => "r8,r9,r10,zmm0,zmm1,zmm2,zmm3,zmm4,cc,memory", Volatile => True);
                  Target (Target'First + Vector * Item.Rows + Row) := Value;
               end loop;
            end loop;
         end;
         Handled := True;
         return;
      end if;

      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;
         Row_Span : constant B.Byte_Count := Row_Bytes (Item);

         --  The elements past the last whole eight, one at a time.
         function Tail
           (At_Row : B.Byte_Count; Vector : Element_Count) return Real
         is
            Total : Real := 0.0;
         begin
            for Column in Eights * 8 .. Columns - 1 loop
               declare
                  At_Byte : constant B.Byte_Count :=
                    Held'First + At_Row + B.Byte_Count (Column) * Width_Bytes;
                  function Word (From : B.Byte_Count) return Interfaces.Unsigned_32
                  is (Interfaces.Unsigned_32 (Held (From))
                      or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Held (From + 1)), 8));
                  function As_Real is new Ada.Unchecked_Conversion
                    (Interfaces.Unsigned_32, Real);
                  Value : constant Real :=
                    (case Kind is
                       when Halves =>
                         Model_Runner.Numerics.To_Real
                           (Model_Runner.Numerics.Half (Interfaces.Unsigned_16 (Word (At_Byte)))),
                       when Brains =>
                         As_Real (Interfaces.Shift_Left (Word (At_Byte), 16)),
                       when Singles =>
                         As_Real (Word (At_Byte)
                                  or Interfaces.Shift_Left (Word (At_Byte + 2), 16)));
               begin
                  Total := Total
                    + Value * Vectors (Vectors'First + Vector * Columns + Column);
               end;
            end loop;
            return Total;
         end Tail;
      begin
         Row := First;
         while Row <= Last loop
            declare
               At_Row : constant B.Byte_Count :=
                 Item.Offset + B.Byte_Count (Row) * Row_Span;
               Vector : Element_Count := 0;
            begin
               --  Two rows at a time against four vectors where both are
               --  there: every activation read is multiplied twice.
               if Row < Last and then Count >= 4 and then Eights > 0 then
                  while Count - Vector >= 4 loop
                     case Kind is
                        when Halves =>
                           System.Machine_Code.Asm
                             ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                              "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
                              "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
                              "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
                              "vxorps %%ymm8, %%ymm8, %%ymm8" & LF &
                              "vxorps %%ymm9, %%ymm9, %%ymm9" & LF &
                              "vxorps %%ymm10, %%ymm10, %%ymm10" & LF &
                              "vxorps %%ymm11, %%ymm11, %%ymm11" & LF &
                              "movq %0, %%rsi" & LF &
                              "movq %1, %%rdi" & LF &
                              "movq %2, %%rdx" & LF &
                              "movq %3, %%rcx" & LF &
                              "movq %5, %%r8" & LF &
                              "1:" & LF &
                              "vcvtph2ps (%%rsi), %%ymm0" & LF &
                              "vcvtph2ps (%%rsi,%%r8), %%ymm1" & LF &
                              "vmovups (%%rdi), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm4" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm8" & LF &
                              "vmovups (%%rdi,%%rdx), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm5" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm9" & LF &
                              "leaq (%%rdi,%%rdx,2), %%rax" & LF &
                              "vmovups (%%rax), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm6" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm10" & LF &
                              "vmovups (%%rax,%%rdx), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm7" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm11" & LF &
                              "addq $16, %%rsi" & LF &
                              "addq $32, %%rdi" & LF &
                              "decq %%rcx" & LF &
                              "jnz 1b" & LF &
                              "movq %4, %%rax" & LF &
                              "vmovups %%ymm4, (%%rax)" & LF &
                              "vmovups %%ymm5, 32(%%rax)" & LF &
                              "vmovups %%ymm6, 64(%%rax)" & LF &
                              "vmovups %%ymm7, 96(%%rax)" & LF &
                              "vmovups %%ymm8, 128(%%rax)" & LF &
                              "vmovups %%ymm9, 160(%%rax)" & LF &
                              "vmovups %%ymm10, 192(%%rax)" & LF &
                              "vmovups %%ymm11, 224(%%rax)" & LF &
                              "vzeroupper",
                              Inputs =>
                                [System.Address'Asm_Input
                                   ("r", Held (Held'First + At_Row)'Address),
                                 System.Address'Asm_Input
                                   ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                 Element_Count'Asm_Input ("r", Stride),
                                 Element_Count'Asm_Input ("r", Eights),
                                 System.Address'Asm_Input ("r", Sums'Address),
                                 B.Byte_Count'Asm_Input ("r", Row_Span)],
                              Clobber =>
                                "rax,rcx,rdx,rsi,rdi,r8,ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,"
                                & "ymm7,ymm8,ymm9,ymm10,ymm11,memory",
                              Volatile => True);
                        when Brains =>
                           System.Machine_Code.Asm
                             ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                              "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
                              "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
                              "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
                              "vxorps %%ymm8, %%ymm8, %%ymm8" & LF &
                              "vxorps %%ymm9, %%ymm9, %%ymm9" & LF &
                              "vxorps %%ymm10, %%ymm10, %%ymm10" & LF &
                              "vxorps %%ymm11, %%ymm11, %%ymm11" & LF &
                              "movq %0, %%rsi" & LF &
                              "movq %1, %%rdi" & LF &
                              "movq %2, %%rdx" & LF &
                              "movq %3, %%rcx" & LF &
                              "movq %5, %%r8" & LF &
                              "1:" & LF &
                              "vpmovzxwd (%%rsi), %%ymm0" & LF &
                                                   "vpslld $16, %%ymm0, %%ymm0" & LF &
                              "vpmovzxwd (%%rsi,%%r8), %%ymm1" & LF &
                                                   "vpslld $16, %%ymm1, %%ymm1" & LF &
                              "vmovups (%%rdi), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm4" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm8" & LF &
                              "vmovups (%%rdi,%%rdx), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm5" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm9" & LF &
                              "leaq (%%rdi,%%rdx,2), %%rax" & LF &
                              "vmovups (%%rax), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm6" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm10" & LF &
                              "vmovups (%%rax,%%rdx), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm7" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm11" & LF &
                              "addq $16, %%rsi" & LF &
                              "addq $32, %%rdi" & LF &
                              "decq %%rcx" & LF &
                              "jnz 1b" & LF &
                              "movq %4, %%rax" & LF &
                              "vmovups %%ymm4, (%%rax)" & LF &
                              "vmovups %%ymm5, 32(%%rax)" & LF &
                              "vmovups %%ymm6, 64(%%rax)" & LF &
                              "vmovups %%ymm7, 96(%%rax)" & LF &
                              "vmovups %%ymm8, 128(%%rax)" & LF &
                              "vmovups %%ymm9, 160(%%rax)" & LF &
                              "vmovups %%ymm10, 192(%%rax)" & LF &
                              "vmovups %%ymm11, 224(%%rax)" & LF &
                              "vzeroupper",
                              Inputs =>
                                [System.Address'Asm_Input
                                   ("r", Held (Held'First + At_Row)'Address),
                                 System.Address'Asm_Input
                                   ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                 Element_Count'Asm_Input ("r", Stride),
                                 Element_Count'Asm_Input ("r", Eights),
                                 System.Address'Asm_Input ("r", Sums'Address),
                                 B.Byte_Count'Asm_Input ("r", Row_Span)],
                              Clobber =>
                                "rax,rcx,rdx,rsi,rdi,r8,ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,"
                                & "ymm7,ymm8,ymm9,ymm10,ymm11,memory",
                              Volatile => True);
                        when Singles =>
                           System.Machine_Code.Asm
                             ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                              "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
                              "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
                              "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
                              "vxorps %%ymm8, %%ymm8, %%ymm8" & LF &
                              "vxorps %%ymm9, %%ymm9, %%ymm9" & LF &
                              "vxorps %%ymm10, %%ymm10, %%ymm10" & LF &
                              "vxorps %%ymm11, %%ymm11, %%ymm11" & LF &
                              "movq %0, %%rsi" & LF &
                              "movq %1, %%rdi" & LF &
                              "movq %2, %%rdx" & LF &
                              "movq %3, %%rcx" & LF &
                              "movq %5, %%r8" & LF &
                              "1:" & LF &
                              "vmovups (%%rsi), %%ymm0" & LF &
                              "vmovups (%%rsi,%%r8), %%ymm1" & LF &
                              "vmovups (%%rdi), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm4" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm8" & LF &
                              "vmovups (%%rdi,%%rdx), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm5" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm9" & LF &
                              "leaq (%%rdi,%%rdx,2), %%rax" & LF &
                              "vmovups (%%rax), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm6" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm10" & LF &
                              "vmovups (%%rax,%%rdx), %%ymm2" & LF &
                              "vfmadd231ps %%ymm2, %%ymm0, %%ymm7" & LF &
                              "vfmadd231ps %%ymm2, %%ymm1, %%ymm11" & LF &
                              "addq $32, %%rsi" & LF &
                              "addq $32, %%rdi" & LF &
                              "decq %%rcx" & LF &
                              "jnz 1b" & LF &
                              "movq %4, %%rax" & LF &
                              "vmovups %%ymm4, (%%rax)" & LF &
                              "vmovups %%ymm5, 32(%%rax)" & LF &
                              "vmovups %%ymm6, 64(%%rax)" & LF &
                              "vmovups %%ymm7, 96(%%rax)" & LF &
                              "vmovups %%ymm8, 128(%%rax)" & LF &
                              "vmovups %%ymm9, 160(%%rax)" & LF &
                              "vmovups %%ymm10, 192(%%rax)" & LF &
                              "vmovups %%ymm11, 224(%%rax)" & LF &
                              "vzeroupper",
                              Inputs =>
                                [System.Address'Asm_Input
                                   ("r", Held (Held'First + At_Row)'Address),
                                 System.Address'Asm_Input
                                   ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                 Element_Count'Asm_Input ("r", Stride),
                                 Element_Count'Asm_Input ("r", Eights),
                                 System.Address'Asm_Input ("r", Sums'Address),
                                 B.Byte_Count'Asm_Input ("r", Row_Span)],
                              Clobber =>
                                "rax,rcx,rdx,rsi,rdi,r8,ymm0,ymm1,ymm2,ymm4,ymm5,ymm6,"
                                & "ymm7,ymm8,ymm9,ymm10,ymm11,memory",
                              Volatile => True);
                     end case;

                     for Pair in Element_Count range 0 .. 1 loop
                        for K in 0 .. 3 loop
                           declare
                              Total : Real := 0.0;
                           begin
                              for Lane in 0 .. 7 loop
                                 Total := Total
                                   + Sums (Natural (Pair) * 32 + K * 8 + Lane);
                              end loop;
                              Target (Target'First + (Vector + Element_Count (K)) * Item.Rows
                                      + Row + Pair) :=
                                Total + Tail (At_Row + B.Byte_Count (Pair) * Row_Span,
                                              Vector + Element_Count (K));
                           end;
                        end loop;
                     end loop;
                     Vector := Vector + 4;
                  end loop;

                  --  The vectors left over, a row at a time.
                  for Pair in Element_Count range 0 .. 1 loop
                     for Left in Vector .. Count - 1 loop
                        declare
                           Total : Real := 0.0;
                           Base  : constant B.Byte_Count :=
                             At_Row + B.Byte_Count (Pair) * Row_Span;
                        begin
                           case Kind is
                              when Halves =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rcx" & LF &
                                    "1:" & LF &
                                    "vcvtph2ps (%%rsi), %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "addq $16, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %3, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + Base)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Left * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber => "rax,rcx,rsi,rdi,ymm0,ymm4,memory",
                                    Volatile => True);
                              when Brains =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rcx" & LF &
                                    "1:" & LF &
                                    "vpmovzxwd (%%rsi), %%ymm0" & LF &
                                                         "vpslld $16, %%ymm0, %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "addq $16, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %3, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + Base)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Left * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber => "rax,rcx,rsi,rdi,ymm0,ymm4,memory",
                                    Volatile => True);
                              when Singles =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rcx" & LF &
                                    "1:" & LF &
                                    "vmovups (%%rsi), %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "addq $32, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %3, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + Base)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Left * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber => "rax,rcx,rsi,rdi,ymm0,ymm4,memory",
                                    Volatile => True);
                           end case;
                           for Lane in 0 .. 7 loop
                              Total := Total + Sums (Lane);
                           end loop;
                           Target (Target'First + Left * Item.Rows + Row + Pair) :=
                             Total + Tail (Base, Left);
                        end;
                     end loop;
                  end loop;
                  Vector := Count;
                  Row := Row + 1;
               end if;

               while Vector < Count loop
                  declare
                     Group : constant Element_Count :=
                       (if Count - Vector >= 4 then 4 else 1);
                  begin
                     if Eights > 0 then
                        if Group = 4 then
                           case Kind is
                              when Halves =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
                                    "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
                                    "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rdx" & LF &
                                    "movq %3, %%rcx" & LF &
                                    "1:" & LF &
                                    "vcvtph2ps (%%rsi), %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "vfmadd231ps (%%rdi,%%rdx), %%ymm0, %%ymm5" & LF &
                                    "leaq (%%rdi,%%rdx,2), %%rax" & LF &
                                    "vfmadd231ps (%%rax), %%ymm0, %%ymm6" & LF &
                                    "vfmadd231ps (%%rax,%%rdx), %%ymm0, %%ymm7" & LF &
                                    "addq $16, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %4, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vmovups %%ymm5, 32(%%rax)" & LF &
                                    "vmovups %%ymm6, 64(%%rax)" & LF &
                                    "vmovups %%ymm7, 96(%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + At_Row)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Stride),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber =>
                                      "rax,rcx,rdx,rsi,rdi,ymm0,ymm4,ymm5,ymm6,ymm7,memory",
                                    Volatile => True);
                              when Brains =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
                                    "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
                                    "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rdx" & LF &
                                    "movq %3, %%rcx" & LF &
                                    "1:" & LF &
                                    "vpmovzxwd (%%rsi), %%ymm0" & LF &
                                                         "vpslld $16, %%ymm0, %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "vfmadd231ps (%%rdi,%%rdx), %%ymm0, %%ymm5" & LF &
                                    "leaq (%%rdi,%%rdx,2), %%rax" & LF &
                                    "vfmadd231ps (%%rax), %%ymm0, %%ymm6" & LF &
                                    "vfmadd231ps (%%rax,%%rdx), %%ymm0, %%ymm7" & LF &
                                    "addq $16, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %4, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vmovups %%ymm5, 32(%%rax)" & LF &
                                    "vmovups %%ymm6, 64(%%rax)" & LF &
                                    "vmovups %%ymm7, 96(%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + At_Row)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Stride),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber =>
                                      "rax,rcx,rdx,rsi,rdi,ymm0,ymm4,ymm5,ymm6,ymm7,memory",
                                    Volatile => True);
                              when Singles =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "vxorps %%ymm5, %%ymm5, %%ymm5" & LF &
                                    "vxorps %%ymm6, %%ymm6, %%ymm6" & LF &
                                    "vxorps %%ymm7, %%ymm7, %%ymm7" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rdx" & LF &
                                    "movq %3, %%rcx" & LF &
                                    "1:" & LF &
                                    "vmovups (%%rsi), %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "vfmadd231ps (%%rdi,%%rdx), %%ymm0, %%ymm5" & LF &
                                    "leaq (%%rdi,%%rdx,2), %%rax" & LF &
                                    "vfmadd231ps (%%rax), %%ymm0, %%ymm6" & LF &
                                    "vfmadd231ps (%%rax,%%rdx), %%ymm0, %%ymm7" & LF &
                                    "addq $32, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %4, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vmovups %%ymm5, 32(%%rax)" & LF &
                                    "vmovups %%ymm6, 64(%%rax)" & LF &
                                    "vmovups %%ymm7, 96(%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + At_Row)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Stride),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber =>
                                      "rax,rcx,rdx,rsi,rdi,ymm0,ymm4,ymm5,ymm6,ymm7,memory",
                                    Volatile => True);
                           end case;
                        else
                           case Kind is
                              when Halves =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rcx" & LF &
                                    "1:" & LF &
                                    "vcvtph2ps (%%rsi), %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "addq $16, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %3, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + At_Row)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber => "rax,rcx,rsi,rdi,ymm0,ymm4,memory",
                                    Volatile => True);
                              when Brains =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rcx" & LF &
                                    "1:" & LF &
                                    "vpmovzxwd (%%rsi), %%ymm0" & LF &
                                                         "vpslld $16, %%ymm0, %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "addq $16, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %3, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + At_Row)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber => "rax,rcx,rsi,rdi,ymm0,ymm4,memory",
                                    Volatile => True);
                              when Singles =>
                                 System.Machine_Code.Asm
                                   ("vxorps %%ymm4, %%ymm4, %%ymm4" & LF &
                                    "movq %0, %%rsi" & LF &
                                    "movq %1, %%rdi" & LF &
                                    "movq %2, %%rcx" & LF &
                                    "1:" & LF &
                                    "vmovups (%%rsi), %%ymm0" & LF &
                                    "vfmadd231ps (%%rdi), %%ymm0, %%ymm4" & LF &
                                    "addq $32, %%rsi" & LF &
                                    "addq $32, %%rdi" & LF &
                                    "decq %%rcx" & LF &
                                    "jnz 1b" & LF &
                                    "movq %3, %%rax" & LF &
                                    "vmovups %%ymm4, (%%rax)" & LF &
                                    "vzeroupper",
                                    Inputs =>
                                      [System.Address'Asm_Input
                                         ("r", Held (Held'First + At_Row)'Address),
                                       System.Address'Asm_Input
                                         ("r", Vectors (Vectors'First + Vector * Columns)'Address),
                                       Element_Count'Asm_Input ("r", Eights),
                                       System.Address'Asm_Input ("r", Sums'Address)],
                                    Clobber => "rax,rcx,rsi,rdi,ymm0,ymm4,memory",
                                    Volatile => True);
                           end case;
                        end if;
                     else
                        Sums := [others => 0.0];
                     end if;

                     for K in 0 .. Group - 1 loop
                        declare
                           Total : Real := 0.0;
                        begin
                           for Lane in 0 .. 7 loop
                              Total := Total + Sums (Natural (K) * 8 + Lane);
                           end loop;
                           Target (Target'First + (Vector + K) * Item.Rows + Row) :=
                             Total + Tail (At_Row, Vector + K);
                        end;
                     end loop;
                     Vector := Vector + Group;
                  end;
               end loop;
            end;
            Row := Row + 1;
         end loop;
      end;

      Handled := True;
   end Mat_Mul_Range_Float;

   --  Both multiplicands are widened binary32 values. Every nonzero finite
   --  product needs at most 48 significant bits and has magnitude between
   --  2**(-298) and 2**256, so binary64 represents every finite product exactly. Fusing
   --  that exact product with the existing binary64 addition rounds only
   --  the addition, exactly as before. Lane and span folds stay separate.
   --  The existing Wide_Halves guard requires x86-64-v3, including FMA.
   --  Two decoded rows share each activation conversion across four vectors.
   --  Each output retains the ordinary four binary64 lane reductions.
   procedure Row_Pair_Dot
     (Left, Right, Vector : System.Address; Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   with Inline_Always;

   procedure Row_Pair_Dot
     (Left, Right, Vector : System.Address; Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        ("vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r12" & LF
         & "movq %4, %%r11" & LF
         & "leaq (%%r10, %%r12, 2), %%r13" & LF
         & "addq %%r12, %%r13" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r8), %%ymm8" & LF
         & "vcvtps2pd (%%r9), %%ymm9" & LF
         & "vcvtps2pd (%%r10), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vcvtps2pd (%%r10, %%r12), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vcvtps2pd (%%r10, %%r12, 2), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vcvtps2pd (%%r13), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r10" & LF
         & "addq $16, %%r13" & LF
         & "decq %%r11" & LF
         & "jnz 1b" & LF
         & "vmovupd %%ymm0, (%5)" & LF
         & "vmovupd %%ymm1, 32(%5)" & LF
         & "vmovupd %%ymm2, 64(%5)" & LF
         & "vmovupd %%ymm3, 96(%5)" & LF
         & "vmovupd %%ymm4, 128(%5)" & LF
         & "vmovupd %%ymm5, 160(%5)" & LF
         & "vmovupd %%ymm6, 192(%5)" & LF
         & "vmovupd %%ymm7, 224(%5)" & LF
         & "vzeroupper",
         Inputs =>
           [System.Address'Asm_Input ("r", Left),
            System.Address'Asm_Input ("r", Right),
            System.Address'Asm_Input ("r", Vector),
            Interfaces.Unsigned_64'Asm_Input
              ("r", Interfaces.Unsigned_64 (Stride) * 4),
            Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Fours)),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, r8, r9, r10, r11, r12, r13, cc, memory",
         Volatile => True);
   end Row_Pair_Dot;

   --  Six vectors share each decoded weight conversion, with unchanged
   --  per-output four-lane reductions. All twelve accumulators stay in registers.
   procedure Row_Pair_Six_Dot
     (Left, Right, Vector : System.Address; Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   with Inline_Always;

   procedure Row_Pair_Six_Dot
     (Left, Right, Vector : System.Address; Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        ("vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vxorpd %%ymm8, %%ymm8, %%ymm8" & LF
         & "vxorpd %%ymm9, %%ymm9, %%ymm9" & LF
         & "vxorpd %%ymm10, %%ymm10, %%ymm10" & LF
         & "vxorpd %%ymm11, %%ymm11, %%ymm11" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r12" & LF
         & "movq %4, %%r11" & LF
         & "leaq (%%r10, %%r12, 2), %%r13" & LF
         & "addq %%r12, %%r13" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r8), %%ymm12" & LF
         & "vcvtps2pd (%%r9), %%ymm13" & LF
         & "vcvtps2pd (%%r10), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm0" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm6" & LF
         & "vcvtps2pd (%%r10, %%r12), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm1" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm7" & LF
         & "vcvtps2pd (%%r10, %%r12, 2), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm2" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm8" & LF
         & "vcvtps2pd (%%r13), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm3" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm9" & LF
         & "vcvtps2pd (%%r10, %%r12, 4), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm4" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm10" & LF
         & "vcvtps2pd (%%r13, %%r12, 2), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm5" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm11" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r10" & LF
         & "addq $16, %%r13" & LF
         & "decq %%r11" & LF
         & "jnz 1b" & LF
         & "vmovupd %%ymm0, 0(%5)" & LF
         & "vmovupd %%ymm1, 32(%5)" & LF
         & "vmovupd %%ymm2, 64(%5)" & LF
         & "vmovupd %%ymm3, 96(%5)" & LF
         & "vmovupd %%ymm4, 128(%5)" & LF
         & "vmovupd %%ymm5, 160(%5)" & LF
         & "vmovupd %%ymm6, 192(%5)" & LF
         & "vmovupd %%ymm7, 224(%5)" & LF
         & "vmovupd %%ymm8, 256(%5)" & LF
         & "vmovupd %%ymm9, 288(%5)" & LF
         & "vmovupd %%ymm10, 320(%5)" & LF
         & "vmovupd %%ymm11, 352(%5)" & LF
         & "vzeroupper",
         Inputs =>
           [System.Address'Asm_Input ("r", Left),
            System.Address'Asm_Input ("r", Right),
            System.Address'Asm_Input ("r", Vector),
            Interfaces.Unsigned_64'Asm_Input
              ("r", Interfaces.Unsigned_64 (Stride) * 4),
            Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Fours)),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, r8, r9, r10, r11, r12, r13, cc, memory",
         Volatile => True);
   end Row_Pair_Six_Dot;

   --  Three rows share each activation conversion across four vectors.
   --  Twelve output accumulators, three weights and one activation use the
   --  sixteen vector registers; finite widened products remain exact.
   procedure Row_Triple_Dot
     (Weight, Vector : System.Address;
      Row_Stride, Vector_Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   with Inline_Always;

   procedure Row_Triple_Dot
     (Weight, Vector : System.Address;
      Row_Stride, Vector_Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        ("vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vxorpd %%ymm8, %%ymm8, %%ymm8" & LF
         & "vxorpd %%ymm9, %%ymm9, %%ymm9" & LF
         & "vxorpd %%ymm10, %%ymm10, %%ymm10" & LF
         & "vxorpd %%ymm11, %%ymm11, %%ymm11" & LF
         & "movq %0, %%r8" & LF
         & "movq %%r8, %%r9" & LF
         & "addq %2, %%r9" & LF
         & "movq %%r9, %%r14" & LF
         & "addq %2, %%r14" & LF
         & "movq %1, %%r10" & LF
         & "movq %3, %%r12" & LF
         & "movq %4, %%r11" & LF
         & "leaq (%%r10, %%r12, 2), %%r13" & LF
         & "addq %%r12, %%r13" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r8), %%ymm12" & LF
         & "vcvtps2pd (%%r9), %%ymm13" & LF
         & "vcvtps2pd (%%r14), %%ymm14" & LF
         & "vcvtps2pd (%%r10), %%ymm15" & LF
         & "vfmadd231pd %%ymm12, %%ymm15, %%ymm0" & LF
         & "vfmadd231pd %%ymm13, %%ymm15, %%ymm4" & LF
         & "vfmadd231pd %%ymm14, %%ymm15, %%ymm8" & LF
         & "vcvtps2pd (%%r10, %%r12), %%ymm15" & LF
         & "vfmadd231pd %%ymm12, %%ymm15, %%ymm1" & LF
         & "vfmadd231pd %%ymm13, %%ymm15, %%ymm5" & LF
         & "vfmadd231pd %%ymm14, %%ymm15, %%ymm9" & LF
         & "vcvtps2pd (%%r10, %%r12, 2), %%ymm15" & LF
         & "vfmadd231pd %%ymm12, %%ymm15, %%ymm2" & LF
         & "vfmadd231pd %%ymm13, %%ymm15, %%ymm6" & LF
         & "vfmadd231pd %%ymm14, %%ymm15, %%ymm10" & LF
         & "vcvtps2pd (%%r13), %%ymm15" & LF
         & "vfmadd231pd %%ymm12, %%ymm15, %%ymm3" & LF
         & "vfmadd231pd %%ymm13, %%ymm15, %%ymm7" & LF
         & "vfmadd231pd %%ymm14, %%ymm15, %%ymm11" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r14" & LF
         & "addq $16, %%r10" & LF
         & "addq $16, %%r13" & LF
         & "decq %%r11" & LF
         & "jnz 1b" & LF
         & "vmovupd %%ymm0, 0(%5)" & LF
         & "vmovupd %%ymm1, 32(%5)" & LF
         & "vmovupd %%ymm2, 64(%5)" & LF
         & "vmovupd %%ymm3, 96(%5)" & LF
         & "vmovupd %%ymm4, 128(%5)" & LF
         & "vmovupd %%ymm5, 160(%5)" & LF
         & "vmovupd %%ymm6, 192(%5)" & LF
         & "vmovupd %%ymm7, 224(%5)" & LF
         & "vmovupd %%ymm8, 256(%5)" & LF
         & "vmovupd %%ymm9, 288(%5)" & LF
         & "vmovupd %%ymm10, 320(%5)" & LF
         & "vmovupd %%ymm11, 352(%5)" & LF
         & "vzeroupper",
         Inputs =>
           [System.Address'Asm_Input ("r", Weight),
            System.Address'Asm_Input ("r", Vector),
            Interfaces.Unsigned_64'Asm_Input
              ("r", Interfaces.Unsigned_64 (Row_Stride) * 4),
            Interfaces.Unsigned_64'Asm_Input
              ("r", Interfaces.Unsigned_64 (Vector_Stride) * 4),
            Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Fours)),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
           & "r8, r9, r10, r11, r12, r13, r14, cc, memory",
         Volatile => True);
   end Row_Triple_Dot;

   --  One activation vector feeds eight independent output rows. The
   --  original four lane sums advance in order for each row; exact widened
   --  binary32 FMA lets independent accumulators hide instruction latency.
   procedure Eight_Output_Dot
     (Weight, Vector : System.Address; Row_Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   with Inline_Always;

   procedure Eight_Output_Dot
     (Weight, Vector : System.Address; Row_Stride, Fours : Element_Count;
      Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        ("vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r11" & LF
         & "movq %3, %%r10" & LF
         & "leaq (%%r8, %%r11, 2), %%r12" & LF
         & "addq %%r11, %%r12" & LF
         & "leaq (%%r8, %%r11, 4), %%r13" & LF
         & "leaq (%%r13, %%r11, 2), %%r14" & LF
         & "addq %%r11, %%r14" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r9), %%ymm8" & LF
         & "vcvtps2pd (%%r8), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm0" & LF
         & "vcvtps2pd (%%r8, %%r11), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm1" & LF
         & "vcvtps2pd (%%r8, %%r11, 2), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm2" & LF
         & "vcvtps2pd (%%r12), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm3" & LF
         & "vcvtps2pd (%%r13), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm4" & LF
         & "vcvtps2pd (%%r13, %%r11), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm5" & LF
         & "vcvtps2pd (%%r13, %%r11, 2), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm6" & LF
         & "vcvtps2pd (%%r14), %%ymm9" & LF
         & "vfmadd231pd %%ymm9, %%ymm8, %%ymm7" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r12" & LF
         & "addq $16, %%r13" & LF
         & "addq $16, %%r14" & LF
         & "decq %%r10" & LF
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
           [System.Address'Asm_Input ("r", Weight),
            System.Address'Asm_Input ("r", Vector),
            Interfaces.Unsigned_64'Asm_Input
              ("r", Interfaces.Unsigned_64 (Row_Stride) * 4),
            Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Fours)),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
           & "r8, r9, r10, r11, r12, r13, r14, cc, memory",
         Volatile => True);
   end Eight_Output_Dot;

   --  Only compact scale/minimum parameters are staged, never decoded
   --  Q4_K rows. Preserve the four binary64 lanes across every block.
   procedure Q4_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   with Inline_Always;

   procedure Q4_Output_Product
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
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vcvtps2pd 96(%%r9), %%ymm10" & LF
         & "vcvtps2pd 112(%%r9), %%ymm11" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vpmovzxbd 0(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vcvtps2pd 96(%%r9), %%ymm10" & LF
         & "vcvtps2pd 112(%%r9), %%ymm11" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vpmovzxbd 16(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
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
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
           & "r8, r9, r10, r11, r12, r13, r14, r15, cc, memory",
         Volatile => True);
   end Q4_Output_Product;

   procedure Small_Batch_Output_Product
     (Left, Right, First, Second, Third : System.Address;
      Fours : Element_Count; Lanes : out N.Wide_Real_Array)
   with Inline_Always;

   procedure Small_Batch_Output_Product
     (Left, Right, First, Second, Third : System.Address;
      Fours : Element_Count; Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r11" & LF
         & "movq %4, %%r12" & LF
         & "movq %5, %%r13" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r10), %%ymm8" & LF
         & "vcvtps2pd (%%r11), %%ymm9" & LF
         & "vcvtps2pd (%%r12), %%ymm10" & LF
         & "vcvtps2pd (%%r8), %%ymm6" & LF
         & "vcvtps2pd (%%r9), %%ymm7" & LF
         & "vfmadd231pd %%ymm8, %%ymm6, %%ymm0" & LF
         & "vfmadd231pd %%ymm8, %%ymm7, %%ymm3" & LF
         & "vfmadd231pd %%ymm9, %%ymm6, %%ymm1" & LF
         & "vfmadd231pd %%ymm9, %%ymm7, %%ymm4" & LF
         & "vfmadd231pd %%ymm10, %%ymm6, %%ymm2" & LF
         & "vfmadd231pd %%ymm10, %%ymm7, %%ymm5" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r10" & LF
         & "addq $16, %%r11" & LF
         & "addq $16, %%r12" & LF
         & "decq %%r13" & LF
         & "jnz 1b" & LF
         & "movq %6, %%r14" & LF
         & "vmovupd %%ymm0, 0(%%r14)" & LF
         & "vmovupd %%ymm1, 32(%%r14)" & LF
         & "vmovupd %%ymm2, 64(%%r14)" & LF
         & "vmovupd %%ymm3, 96(%%r14)" & LF
         & "vmovupd %%ymm4, 128(%%r14)" & LF
         & "vmovupd %%ymm5, 160(%%r14)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Left), System.Address'Asm_Input ("m", Right),
                    System.Address'Asm_Input ("m", First), System.Address'Asm_Input ("m", Second),
                    System.Address'Asm_Input ("m", Third), Element_Count'Asm_Input ("m", Fours),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, ymm8, ymm9, ymm10, "
           & "r8, r9, r10, r11, r12, r13, r14, cc, memory", Volatile => True);
   end Small_Batch_Output_Product;

   procedure Q5_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   with Inline_Always;

   procedure Q5_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Params : constant System.Address := Parameters (Parameters'First)'Address;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "movq %4, %%rdx" & LF
         & "vmovupd 0(%%rdx), %%ymm0" & LF
         & "vmovupd 32(%%rdx), %%ymm1" & LF
         & "vmovupd 64(%%rdx), %%ymm2" & LF
         & "vmovupd 96(%%rdx), %%ymm3" & LF
         & "vmovupd 128(%%rdx), %%ymm4" & LF
         & "vmovupd 160(%%rdx), %%ymm5" & LF
         & "vmovupd 192(%%rdx), %%ymm6" & LF
         & "vmovupd 224(%%rdx), %%ymm7" & LF
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
         & "movl $32, %%edx" & LF
         & "xorl %%ecx, %%ecx" & LF
         & "1:" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vcvtps2pd 96(%%r9), %%ymm10" & LF
         & "vcvtps2pd 112(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "incl %%ecx" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vcvtps2pd 96(%%r9), %%ymm10" & LF
         & "vcvtps2pd 112(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vbroadcastss 20(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vbroadcastss 28(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 32(%%r11), %%ymm12" & LF
         & "vbroadcastss 36(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 40(%%r11), %%ymm12" & LF
         & "vbroadcastss 44(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 48(%%r11), %%ymm12" & LF
         & "vbroadcastss 52(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 56(%%r11), %%ymm12" & LF
         & "vbroadcastss 60(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $128, %%r9" & LF
         & "addq $64, %%r11" & LF
         & "incl %%ecx" & LF
         & "addq $32, %%r8" & LF
         & "addq $32, %%r12" & LF
         & "addq $32, %%r13" & LF
         & "addq $32, %%r14" & LF
         & "addq $32, %%rdx" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "movq %4, %%rdx" & LF
         & "vmovupd %%ymm0, 0(%%rdx)" & LF
         & "vmovupd %%ymm1, 32(%%rdx)" & LF
         & "vmovupd %%ymm2, 64(%%rdx)" & LF
         & "vmovupd %%ymm3, 96(%%rdx)" & LF
         & "vmovupd %%ymm4, 128(%%rdx)" & LF
         & "vmovupd %%ymm5, 160(%%rdx)" & LF
         & "vmovupd %%ymm6, 192(%%rdx)" & LF
         & "vmovupd %%ymm7, 224(%%rdx)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Weight), System.Address'Asm_Input ("m", Vector),
                    B.Byte_Count'Asm_Input ("m", Row_Stride), System.Address'Asm_Input ("m", Params),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
           & "rax, rcx, rdx, r8, r9, r10, r11, r12, r13, r14, r15, cc, memory",
         Volatile => True);
   end Q5_Output_Product;

   procedure Q6_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   with Inline_Always;

   procedure Q6_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Params : constant System.Address := Parameters (Parameters'First)'Address;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "movq %4, %%rdx" & LF
         & "vmovupd 0(%%rdx), %%ymm0" & LF
         & "vmovupd 32(%%rdx), %%ymm1" & LF
         & "vmovupd 64(%%rdx), %%ymm2" & LF
         & "vmovupd 96(%%rdx), %%ymm3" & LF
         & "vmovupd 128(%%rdx), %%ymm4" & LF
         & "vmovupd 160(%%rdx), %%ymm5" & LF
         & "vmovupd 192(%%rdx), %%ymm6" & LF
         & "vmovupd 224(%%rdx), %%ymm7" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r11" & LF
         & "leaq (%%r8, %%r10, 2), %%r12" & LF
         & "addq %%r10, %%r12" & LF
         & "leaq (%%r8, %%r10, 4), %%r13" & LF
         & "leaq (%%r13, %%r10, 2), %%r14" & LF
         & "addq %%r10, %%r14" & LF
         & "movl $32, %%eax" & LF
         & "vmovd %%eax, %%xmm13" & LF
         & "vpbroadcastd %%xmm13, %%ymm13" & LF
         & "movl $128, %%edx" & LF
         & "movl $2, %%r15d" & LF
         & "1:" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r12), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r13), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r13, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r14), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm0" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm0" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm1" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm1" & LF
         & "leaq (%%r8, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm2" & LF
         & "leaq (%%r12), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 12(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm3" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r12), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm3" & LF
         & "leaq (%%r13), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 16(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm4" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r13), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm4" & LF
         & "leaq (%%r13, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 20(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r13, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm5" & LF
         & "leaq (%%r13, %%r10, 2), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 24(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm6" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r13, %%r10, 2), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm6" & LF
         & "leaq (%%r14), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 28(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm9, %%ymm15, %%ymm7" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r14), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm10, %%ymm15, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm11, %%ymm15, %%ymm7" & LF
         & "addq $64, %%r9" & LF
         & "addq $32, %%r11" & LF
         & "addq $64, %%r8" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $64, %%r14" & LF
         & "subq $32, %%rdx" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "movq %4, %%rdx" & LF
         & "vmovupd %%ymm0, 0(%%rdx)" & LF
         & "vmovupd %%ymm1, 32(%%rdx)" & LF
         & "vmovupd %%ymm2, 64(%%rdx)" & LF
         & "vmovupd %%ymm3, 96(%%rdx)" & LF
         & "vmovupd %%ymm4, 128(%%rdx)" & LF
         & "vmovupd %%ymm5, 160(%%rdx)" & LF
         & "vmovupd %%ymm6, 192(%%rdx)" & LF
         & "vmovupd %%ymm7, 224(%%rdx)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Weight), System.Address'Asm_Input ("m", Vector),
                    B.Byte_Count'Asm_Input ("m", Row_Stride), System.Address'Asm_Input ("m", Params),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
           & "rax, rcx, rdx, r8, r9, r10, r11, r12, r13, r14, r15, cc, memory",
         Volatile => True);
   end Q6_Output_Product;

   --  Packed Q8 rows retain binary32 dequantization before widening and
   --  their original four binary64 lane sums. No decoded row is stored.
   procedure Q8_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Blocks : Element_Count; Lanes : out N.Wide_Real_Array)
   with Inline_Always;

   procedure Q8_Output_Product
     (Weight, Vector : System.Address; Row_Stride : B.Byte_Count;
      Blocks : Element_Count; Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        ("vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r11" & LF
         & "movq %3, %%r10" & LF
         & "leaq (%%r8, %%r11, 2), %%r12" & LF
         & "addq %%r11, %%r12" & LF
         & "leaq (%%r8, %%r11, 4), %%r13" & LF
         & "leaq (%%r13, %%r11, 2), %%r14" & LF
         & "addq %%r11, %%r14" & LF
         & "1:" & LF
         & "vpxor %%xmm12, %%xmm12, %%xmm12" & LF
         & "vpinsrw $0, (%%r8), %%xmm12, %%xmm12" & LF
         & "vpinsrw $1, (%%r8, %%r11), %%xmm12, %%xmm12" & LF
         & "vpinsrw $2, (%%r8, %%r11, 2), %%xmm12, %%xmm12" & LF
         & "vpinsrw $3, (%%r12), %%xmm12, %%xmm12" & LF
         & "vpinsrw $4, (%%r13), %%xmm12, %%xmm12" & LF
         & "vpinsrw $5, (%%r13, %%r11), %%xmm12, %%xmm12" & LF
         & "vpinsrw $6, (%%r13, %%r11, 2), %%xmm12, %%xmm12" & LF
         & "vpinsrw $7, (%%r14), %%xmm12, %%xmm12" & LF
         & "vcvtph2ps %%xmm12, %%ymm12" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vcvtps2pd 16(%%r9), %%ymm9" & LF
         & "vcvtps2pd 32(%%r9), %%ymm10" & LF
         & "vcvtps2pd 48(%%r9), %%ymm11" & LF
         & "vpermilps $0, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r8), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm0" & LF
         & "vpmovsxbd 10(%%r8), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm0" & LF
         & "vpermilps $85, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r8, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm1" & LF
         & "vpmovsxbd 10(%%r8, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm1" & LF
         & "vpermilps $170, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r8, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm2" & LF
         & "vpmovsxbd 10(%%r8, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm2" & LF
         & "vpermilps $255, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r12), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm3" & LF
         & "vpmovsxbd 10(%%r12), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm3" & LF
         & "vpermilps $0, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r13), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm4" & LF
         & "vpmovsxbd 10(%%r13), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm4" & LF
         & "vpermilps $85, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r13, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm5" & LF
         & "vpmovsxbd 10(%%r13, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm5" & LF
         & "vpermilps $170, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r13, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm6" & LF
         & "vpmovsxbd 10(%%r13, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm6" & LF
         & "vpermilps $255, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 2(%%r14), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm7" & LF
         & "vpmovsxbd 10(%%r14), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm7" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vcvtps2pd 80(%%r9), %%ymm9" & LF
         & "vcvtps2pd 96(%%r9), %%ymm10" & LF
         & "vcvtps2pd 112(%%r9), %%ymm11" & LF
         & "vpermilps $0, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r8), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm0" & LF
         & "vpmovsxbd 26(%%r8), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm0" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm0" & LF
         & "vpermilps $85, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r8, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm1" & LF
         & "vpmovsxbd 26(%%r8, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm1" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm1" & LF
         & "vpermilps $170, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r8, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm2" & LF
         & "vpmovsxbd 26(%%r8, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm2" & LF
         & "vpermilps $255, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $0, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r12), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm3" & LF
         & "vpmovsxbd 26(%%r12), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm3" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm3" & LF
         & "vpermilps $0, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r13), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm4" & LF
         & "vpmovsxbd 26(%%r13), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm4" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm4" & LF
         & "vpermilps $85, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r13, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm5" & LF
         & "vpmovsxbd 26(%%r13, %%r11), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm5" & LF
         & "vpermilps $170, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r13, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm6" & LF
         & "vpmovsxbd 26(%%r13, %%r11, 2), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm6" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm6" & LF
         & "vpermilps $255, %%ymm12, %%ymm13" & LF
         & "vperm2f128 $17, %%ymm13, %%ymm13, %%ymm13" & LF
         & "vpmovsxbd 18(%%r14), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm8, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm9, %%ymm7" & LF
         & "vpmovsxbd 26(%%r14), %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm10, %%ymm7" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vfmadd231pd %%ymm15, %%ymm11, %%ymm7" & LF
         & "addq $34, %%r8" & LF
         & "addq $128, %%r9" & LF
         & "addq $34, %%r12" & LF
         & "addq $34, %%r13" & LF
         & "addq $34, %%r14" & LF
         & "decq %%r10" & LF
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
           [System.Address'Asm_Input ("r", Weight),
            System.Address'Asm_Input ("r", Vector),
            Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Row_Stride)),
            Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Blocks)),
            System.Address'Asm_Input ("r", Lanes (Lanes'First)'Address)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
           & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, "
           & "r8, r9, r10, r11, r12, r13, r14, cc, memory",
         Volatile => True);
   end Q8_Output_Product;

   --  Two packed physical rows across three token vectors. No F32 weight rows.
   procedure Q4_Token_Product
     (Weight, First, Second, Third : System.Address; Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   with Inline_Always;
   procedure Q4_Token_Product
     (Weight, First, Second, Third : System.Address; Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Params : constant System.Address := Parameters (Parameters'First)'Address;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "movq %6, %%rax" & LF
         & "vmovupd 0(%%rax), %%ymm0" & LF
         & "vmovupd 32(%%rax), %%ymm1" & LF
         & "vmovupd 64(%%rax), %%ymm2" & LF
         & "vmovupd 96(%%rax), %%ymm3" & LF
         & "vmovupd 128(%%rax), %%ymm4" & LF
         & "vmovupd 160(%%rax), %%ymm5" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r12" & LF
         & "movq %3, %%r13" & LF
         & "movq %4, %%r10" & LF
         & "movq %5, %%r11" & LF
         & "movl $4, %%r15d" & LF
         & "movl $32, %%edx" & LF
         & "xorl %%ecx, %%ecx" & LF
         & "1:" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $128, %%r9" & LF
         & "addq $128, %%r12" & LF
         & "addq $128, %%r13" & LF
         & "addq $16, %%r11" & LF
         & "incl %%ecx" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $128, %%r9" & LF
         & "addq $128, %%r12" & LF
         & "addq $128, %%r13" & LF
         & "addq $16, %%r11" & LF
         & "incl %%ecx" & LF
         & "addq $32, %%r8" & LF
         & "addq $32, %%rdx" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "movq %6, %%rax" & LF
         & "vmovupd %%ymm0, 0(%%rax)" & LF
         & "vmovupd %%ymm1, 32(%%rax)" & LF
         & "vmovupd %%ymm2, 64(%%rax)" & LF
         & "vmovupd %%ymm3, 96(%%rax)" & LF
         & "vmovupd %%ymm4, 128(%%rax)" & LF
         & "vmovupd %%ymm5, 160(%%rax)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Weight), System.Address'Asm_Input ("m", First),
                    System.Address'Asm_Input ("m", Second), System.Address'Asm_Input ("m", Third),
                    B.Byte_Count'Asm_Input ("m", Stride), System.Address'Asm_Input ("m", Params),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm8, ymm12, ymm13, ymm14, ymm15, "
           & "rax, rcx, rdx, r8, r9, r10, r11, r12, r13, r15, cc, memory", Volatile => True);
   end Q4_Token_Product;

   --  Two packed physical rows across three token vectors. No F32 weight rows.
   procedure Q5_Token_Product
     (Weight, First, Second, Third : System.Address; Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   with Inline_Always;
   procedure Q5_Token_Product
     (Weight, First, Second, Third : System.Address; Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Params : constant System.Address := Parameters (Parameters'First)'Address;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "movq %6, %%rax" & LF
         & "vmovupd 0(%%rax), %%ymm0" & LF
         & "vmovupd 32(%%rax), %%ymm1" & LF
         & "vmovupd 64(%%rax), %%ymm2" & LF
         & "vmovupd 96(%%rax), %%ymm3" & LF
         & "vmovupd 128(%%rax), %%ymm4" & LF
         & "vmovupd 160(%%rax), %%ymm5" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r12" & LF
         & "movq %3, %%r13" & LF
         & "movq %4, %%r10" & LF
         & "movq %5, %%r11" & LF
         & "movl $4, %%r15d" & LF
         & "movl $32, %%edx" & LF
         & "xorl %%ecx, %%ecx" & LF
         & "1:" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $128, %%r9" & LF
         & "addq $128, %%r12" & LF
         & "addq $128, %%r13" & LF
         & "addq $16, %%r11" & LF
         & "incl %%ecx" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "leaq (%%r8), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vbroadcastss 4(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "subq %%rdx, %%rax" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 64(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 64(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 64(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 80(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 80(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 80(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vmovd %%ecx, %%xmm12" & LF
         & "vpsrld %%xmm12, %%ymm15, %%ymm15" & LF
         & "vpslld $31, %%ymm15, %%ymm15" & LF
         & "vpsrld $27, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vbroadcastss 8(%%r11), %%ymm12" & LF
         & "vbroadcastss 12(%%r11), %%ymm13" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vsubps %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 96(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 96(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 96(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 112(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 112(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 112(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $128, %%r9" & LF
         & "addq $128, %%r12" & LF
         & "addq $128, %%r13" & LF
         & "addq $16, %%r11" & LF
         & "incl %%ecx" & LF
         & "addq $32, %%r8" & LF
         & "addq $32, %%rdx" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "movq %6, %%rax" & LF
         & "vmovupd %%ymm0, 0(%%rax)" & LF
         & "vmovupd %%ymm1, 32(%%rax)" & LF
         & "vmovupd %%ymm2, 64(%%rax)" & LF
         & "vmovupd %%ymm3, 96(%%rax)" & LF
         & "vmovupd %%ymm4, 128(%%rax)" & LF
         & "vmovupd %%ymm5, 160(%%rax)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Weight), System.Address'Asm_Input ("m", First),
                    System.Address'Asm_Input ("m", Second), System.Address'Asm_Input ("m", Third),
                    B.Byte_Count'Asm_Input ("m", Stride), System.Address'Asm_Input ("m", Params),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm8, ymm12, ymm13, ymm14, ymm15, "
           & "rax, rcx, rdx, r8, r9, r10, r11, r12, r13, r15, cc, memory", Volatile => True);
   end Q5_Token_Product;

   --  Two packed physical rows across three token vectors. No F32 weight rows.
   procedure Q6_Token_Product
     (Weight, First, Second, Third : System.Address; Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   with Inline_Always;
   procedure Q6_Token_Product
     (Weight, First, Second, Third : System.Address; Stride : B.Byte_Count;
      Parameters : Real_Array; Lanes : in out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Params : constant System.Address := Parameters (Parameters'First)'Address;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "movq %6, %%rax" & LF
         & "vmovupd 0(%%rax), %%ymm0" & LF
         & "vmovupd 32(%%rax), %%ymm1" & LF
         & "vmovupd 64(%%rax), %%ymm2" & LF
         & "vmovupd 96(%%rax), %%ymm3" & LF
         & "vmovupd 128(%%rax), %%ymm4" & LF
         & "vmovupd 160(%%rax), %%ymm5" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r12" & LF
         & "movq %3, %%r13" & LF
         & "movq %4, %%r10" & LF
         & "movq %5, %%r11" & LF
         & "movl $32, %%eax" & LF
         & "vmovd %%eax, %%xmm13" & LF
         & "vpbroadcastd %%xmm13, %%ymm13" & LF
         & "movl $128, %%edx" & LF
         & "movl $2, %%r15d" & LF
         & "1:" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $2, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8, %%r10), %%ymm14" & LF
         & "vpslld $28, %%ymm14, %%ymm14" & LF
         & "vpsrld $28, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 0(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 8(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 16(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $4, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 24(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 0(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 32(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 8(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 40(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "leaq (%%r8), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 0(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm0" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm1" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm2" & LF
         & "leaq (%%r8, %%r10), %%rax" & LF
         & "addq %%rdx, %%rax" & LF
         & "vbroadcastss 4(%%r11), %%ymm12" & LF
         & "vpmovzxbd 16(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 48(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 0(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 0(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 0(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 16(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 16(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 16(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vpmovzxbd 24(%%rax), %%ymm15" & LF
         & "vpsrld $6, %%ymm15, %%ymm15" & LF
         & "vpslld $30, %%ymm15, %%ymm15" & LF
         & "vpsrld $26, %%ymm15, %%ymm15" & LF
         & "vpmovzxbd 56(%%r8, %%r10), %%ymm14" & LF
         & "vpsrld $4, %%ymm14, %%ymm14" & LF
         & "vpor %%ymm15, %%ymm14, %%ymm14" & LF
         & "vpsubd %%ymm13, %%ymm14, %%ymm14" & LF
         & "vcvtdq2ps %%ymm14, %%ymm14" & LF
         & "vmulps %%ymm12, %%ymm14, %%ymm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 32(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 32(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 32(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "vextractf128 $1, %%ymm14, %%xmm14" & LF
         & "vcvtps2pd %%xmm14, %%ymm15" & LF
         & "vcvtps2pd 48(%%r9), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm3" & LF
         & "vcvtps2pd 48(%%r12), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm4" & LF
         & "vcvtps2pd 48(%%r13), %%ymm8" & LF
         & "vfmadd231pd %%ymm8, %%ymm15, %%ymm5" & LF
         & "addq $64, %%r9" & LF
         & "addq $64, %%r12" & LF
         & "addq $64, %%r13" & LF
         & "addq $8, %%r11" & LF
         & "addq $64, %%r8" & LF
         & "subq $32, %%rdx" & LF
         & "decl %%r15d" & LF
         & "jnz 1b" & LF
         & "movq %6, %%rax" & LF
         & "vmovupd %%ymm0, 0(%%rax)" & LF
         & "vmovupd %%ymm1, 32(%%rax)" & LF
         & "vmovupd %%ymm2, 64(%%rax)" & LF
         & "vmovupd %%ymm3, 96(%%rax)" & LF
         & "vmovupd %%ymm4, 128(%%rax)" & LF
         & "vmovupd %%ymm5, 160(%%rax)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Weight), System.Address'Asm_Input ("m", First),
                    System.Address'Asm_Input ("m", Second), System.Address'Asm_Input ("m", Third),
                    B.Byte_Count'Asm_Input ("m", Stride), System.Address'Asm_Input ("m", Params),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm8, ymm12, ymm13, ymm14, ymm15, "
           & "rax, rcx, rdx, r8, r9, r10, r11, r12, r13, r15, cc, memory", Volatile => True);
   end Q6_Token_Product;

   function Scale_Count (Item : View) return Element_Count is
      use type G.Tensor_Type;
   begin
      if not Is_Present (Item) or else Item.Interleaved
        or else Item.Format not in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K
        or else Item.Columns mod 256 /= 0
      then return 0; end if;
      return Item.Rows * (Item.Columns / 256) * 16;
   end Scale_Count;

   function Reference_Scale_Count (Item : View) return Element_Count is
      use type G.Tensor_Type;
   begin
      if not Is_Present (Item) or else Item.Columns mod 256 /= 0
        or else Item.Format not in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K
      then return 0; end if;
      return Item.Rows * (Item.Columns / 256) * (if Item.Format = G.Type_Q6_K then 5 else 6);
   end Reference_Scale_Count;

   procedure Decode_Reference_Scales (Item : View; Into : out Real_Array; Status : out E.Error_Info) is
      use type G.Tensor_Type;
      Blocks : constant Element_Count := Item.Columns / 256;
      Fields : constant Element_Count := (if Item.Format = G.Type_Q6_K then 5 else 6);
      Headers : constant Element_Count := (if Item.Format = G.Type_Q6_K then 1 else 2);
      Native : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Item.Format));
      Data : B.Byte_Array (1 .. Item.Span) with Import, Address => Item.Base;
      Row : B.Byte_Array (0 .. B.Byte_Count (Blocks) * Native - 1);
      Good : Boolean;
   begin
      Status := E.Make (E.Tensor_Shape_Mismatch);
      if Reference_Scale_Count (Item) = 0 or else Into'Length /= Reference_Scale_Count (Item) then return; end if;
      for Which in 0 .. Item.Rows - 1 loop
         if Item.Interleaved then
            Model_Runner.Quantization.Interleave.Extract_Row
              (Item.Format, Data, Item.Offset, Which, Blocks, Row, Good);
            if not Good then return; end if;
         end if;
         for Block in 0 .. Blocks - 1 loop
            for Field in 0 .. Headers - 1 loop
               declare
                  At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * Native
                    + (if Item.Format = G.Type_Q6_K then 208 else B.Byte_Count (Field * 2));
                  Value : constant Interfaces.Unsigned_16 :=
                    (if Item.Interleaved then B.Get_U16 (Row, At_Byte, Good)
                     else B.Get_U16 (Data, Item.Offset + B.Byte_Count (Which) * Row_Bytes (Item) + At_Byte, Good));
               begin
                  if not Good then return; end if;
                  Into (Into'First + (Which * Blocks + Block) * Fields + Field) := N.To_Real (N.Half (Value));
               end;
            end loop;
            declare
               Coeff : B.Byte_Array (0 .. 15) with Import,
                 Address => Into (Into'First + (Which * Blocks + Block) * Fields + Headers)'Address;
            begin
               Model_Runner.Quantization.Integers.Reference_Coefficients
                 (Item.Format, (if Item.Interleaved then Row else Data),
                  (if Item.Interleaved then B.Byte_Count (Block) * Native
                   else Item.Offset + B.Byte_Count (Which) * Row_Bytes (Item) + B.Byte_Count (Block) * Native),
                  Coeff, Good);
               if not Good then return; end if;
            end;
         end loop;
      end loop;
      Status := E.Success;
   end Decode_Reference_Scales;

   procedure Decode_Scales (Item : View; Into : out Real_Array; Status : out E.Error_Info) is
      use type G.Tensor_Type;
      use type N.Real;
      use type Interfaces.Unsigned_16;
      Count : constant Element_Count := Scale_Count (Item);
      Blocks : constant Element_Count := Item.Columns / 256;
      Data : B.Byte_Array (1 .. Item.Span) with Import, Address => Item.Base;
      function Half (At_Pos : B.Byte_Count) return Real is
        (N.To_Real (N.Half (Interfaces.Unsigned_16 (Data (Data'First + At_Pos)) or
           Interfaces.Shift_Left (Interfaces.Unsigned_16 (Data (Data'First + At_Pos + 1)), 8))));
   begin
      Into := [others => 0.0];
      Status := E.Make (E.Tensor_Shape_Mismatch);
      if Count = 0 or else Into'Length /= Count then return; end if;
      if not B.Has_Room (Data, Item.Offset, B.Byte_Count (Item.Rows) * Row_Bytes (Item)) then return; end if;
      for Row in 0 .. Item.Rows - 1 loop
         for Block in 0 .. Blocks - 1 loop
            declare
               Base : constant B.Byte_Count := Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item)
                 + B.Byte_Count (Block) * B.Byte_Count (G.Block_Bytes (Item.Format));
               At_Scale : constant Element_Count := Into'First + (Row * Blocks + Block) * 16;
               D : constant Real := Half (Base + (if Item.Format = G.Type_Q6_K then 208 else 0));
            begin
               if Item.Format = G.Type_Q6_K then
                  for Sub in Element_Count range 0 .. 15 loop
                     declare
                        Raw : constant Integer := Integer (Data (Data'First + Base + 192 + B.Byte_Count (Sub)));
                     begin
                        Into (At_Scale + Sub) := D * Real (if Raw < 128 then Raw else Raw - 256);
                     end;
                  end loop;
               else
                  for Sub in Element_Count range 0 .. 7 loop
                     declare
                        function Byte_At (X : Element_Count) return Natural is
                          (Natural (Data (Data'First + Base + 4 + B.Byte_Count (X))));
                        Factor : constant Natural := (if Sub < 4 then Byte_At (Sub) mod 64
                          else Byte_At (Sub + 4) mod 16 + (Byte_At (Sub - 4) / 64) * 16);
                        Lowest : constant Natural := (if Sub < 4 then Byte_At (Sub + 4) mod 64
                          else Byte_At (Sub + 4) / 16 + (Byte_At (Sub) / 64) * 16);
                     begin
                        Into (At_Scale + Sub * 2) := D * Real (Factor);
                        Into (At_Scale + Sub * 2 + 1) := Half (Base + 2) * Real (Lowest);
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end loop;
      Status := E.Success;
   end Decode_Scales;

   --  Indexed counterpart of the existing paired-row 4-vector kernel.
   procedure Selected_4_Product
     (Left, Right, Vectors : System.Address; Fours : Element_Count; Lanes : out N.Wide_Real_Array)
   with Inline_Always;
   procedure Selected_4_Product
     (Left, Right, Vectors : System.Address; Fours : Element_Count; Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%rax" & LF
         & "movq 0(%%rax), %%r10" & LF
         & "movq 8(%%rax), %%r11" & LF
         & "movq 16(%%rax), %%r12" & LF
         & "movq 24(%%rax), %%r13" & LF
         & "movq %3, %%rcx" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r8), %%ymm8" & LF
         & "vcvtps2pd (%%r9), %%ymm9" & LF
         & "vcvtps2pd (%%r10), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm0" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm4" & LF
         & "vcvtps2pd (%%r11), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm1" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm5" & LF
         & "vcvtps2pd (%%r12), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm2" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm6" & LF
         & "vcvtps2pd (%%r13), %%ymm10" & LF
         & "vfmadd231pd %%ymm8, %%ymm10, %%ymm3" & LF
         & "vfmadd231pd %%ymm9, %%ymm10, %%ymm7" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r10" & LF
         & "addq $16, %%r11" & LF
         & "addq $16, %%r12" & LF
         & "addq $16, %%r13" & LF
         & "decq %%rcx" & LF
         & "jnz 1b" & LF
         & "movq %4, %%rdx" & LF
         & "vmovupd %%ymm0, 0(%%rdx)" & LF
         & "vmovupd %%ymm1, 32(%%rdx)" & LF
         & "vmovupd %%ymm2, 64(%%rdx)" & LF
         & "vmovupd %%ymm3, 96(%%rdx)" & LF
         & "vmovupd %%ymm4, 128(%%rdx)" & LF
         & "vmovupd %%ymm5, 160(%%rdx)" & LF
         & "vmovupd %%ymm6, 192(%%rdx)" & LF
         & "vmovupd %%ymm7, 224(%%rdx)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Left), System.Address'Asm_Input ("m", Right),
                    System.Address'Asm_Input ("m", Vectors), Element_Count'Asm_Input ("m", Fours),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, ymm8, ymm9, ymm10, r8, r9, r10, "
           & "r11, r12, r13, rax, rcx, rdx, cc, memory", Volatile => True);
   end Selected_4_Product;

   --  Indexed counterpart of the existing paired-row 6-vector kernel.
   procedure Selected_6_Product
     (Left, Right, Vectors : System.Address; Fours : Element_Count; Lanes : out N.Wide_Real_Array)
   with Inline_Always;
   procedure Selected_6_Product
     (Left, Right, Vectors : System.Address; Fours : Element_Count; Lanes : out N.Wide_Real_Array)
   is
      LF : constant Character := ASCII.LF;
      Output : constant System.Address := Lanes (Lanes'First)'Address;
   begin
      System.Machine_Code.Asm
        (
           "vxorpd %%ymm0, %%ymm0, %%ymm0" & LF
         & "vxorpd %%ymm1, %%ymm1, %%ymm1" & LF
         & "vxorpd %%ymm2, %%ymm2, %%ymm2" & LF
         & "vxorpd %%ymm3, %%ymm3, %%ymm3" & LF
         & "vxorpd %%ymm4, %%ymm4, %%ymm4" & LF
         & "vxorpd %%ymm5, %%ymm5, %%ymm5" & LF
         & "vxorpd %%ymm6, %%ymm6, %%ymm6" & LF
         & "vxorpd %%ymm7, %%ymm7, %%ymm7" & LF
         & "vxorpd %%ymm8, %%ymm8, %%ymm8" & LF
         & "vxorpd %%ymm9, %%ymm9, %%ymm9" & LF
         & "vxorpd %%ymm10, %%ymm10, %%ymm10" & LF
         & "vxorpd %%ymm11, %%ymm11, %%ymm11" & LF
         & "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%rax" & LF
         & "movq 0(%%rax), %%r10" & LF
         & "movq 8(%%rax), %%r11" & LF
         & "movq 16(%%rax), %%r12" & LF
         & "movq 24(%%rax), %%r13" & LF
         & "movq 32(%%rax), %%r14" & LF
         & "movq 40(%%rax), %%r15" & LF
         & "movq %3, %%rcx" & LF
         & "1:" & LF
         & "vcvtps2pd (%%r8), %%ymm12" & LF
         & "vcvtps2pd (%%r9), %%ymm13" & LF
         & "vcvtps2pd (%%r10), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm0" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm6" & LF
         & "vcvtps2pd (%%r11), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm1" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm7" & LF
         & "vcvtps2pd (%%r12), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm2" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm8" & LF
         & "vcvtps2pd (%%r13), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm3" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm9" & LF
         & "vcvtps2pd (%%r14), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm4" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm10" & LF
         & "vcvtps2pd (%%r15), %%ymm14" & LF
         & "vfmadd231pd %%ymm12, %%ymm14, %%ymm5" & LF
         & "vfmadd231pd %%ymm13, %%ymm14, %%ymm11" & LF
         & "addq $16, %%r8" & LF
         & "addq $16, %%r9" & LF
         & "addq $16, %%r10" & LF
         & "addq $16, %%r11" & LF
         & "addq $16, %%r12" & LF
         & "addq $16, %%r13" & LF
         & "addq $16, %%r14" & LF
         & "addq $16, %%r15" & LF
         & "decq %%rcx" & LF
         & "jnz 1b" & LF
         & "movq %4, %%rdx" & LF
         & "vmovupd %%ymm0, 0(%%rdx)" & LF
         & "vmovupd %%ymm1, 32(%%rdx)" & LF
         & "vmovupd %%ymm2, 64(%%rdx)" & LF
         & "vmovupd %%ymm3, 96(%%rdx)" & LF
         & "vmovupd %%ymm4, 128(%%rdx)" & LF
         & "vmovupd %%ymm5, 160(%%rdx)" & LF
         & "vmovupd %%ymm6, 192(%%rdx)" & LF
         & "vmovupd %%ymm7, 224(%%rdx)" & LF
         & "vmovupd %%ymm8, 256(%%rdx)" & LF
         & "vmovupd %%ymm9, 288(%%rdx)" & LF
         & "vmovupd %%ymm10, 320(%%rdx)" & LF
         & "vmovupd %%ymm11, 352(%%rdx)" & LF
         & "vzeroupper",
         Inputs => [System.Address'Asm_Input ("m", Left), System.Address'Asm_Input ("m", Right),
                    System.Address'Asm_Input ("m", Vectors), Element_Count'Asm_Input ("m", Fours),
                    System.Address'Asm_Input ("m", Output)],
         Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, ymm8, ymm9, ymm10, ymm11, ymm12, "
           & "ymm13, ymm14, r8, r9, r10, r11, r12, r13, r14, r15, rax, rcx, rdx, cc, memory", Volatile => True);
   end Selected_6_Product;

   procedure Mat_Mul_Range
     (Item    : View;
      Vectors : Real_Array;
      Count   : Element_Count;
      Target  : in out Real_Array;
      First   : Element_Count;
      Last    : Element_Count;
      Members : Model_Runner.Shares.Member_Rows := [])
   is
      use type G.Tensor_Type;
      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Blocks : Element_Count;
      Sums   : Model_Runner.Numerics.Wide_Real_Array (0 .. Count - 1);
      Ok     : Boolean;
      Next_Row : Element_Count := First;

      function Input_Row (Index : Element_Count) return Element_Count is
        (if Members'Length = 0 then Index
         else Element_Count (Members (Members'First + Natural (Index))));

      procedure Fused_Tokens (Data : B.Byte_Array; Row : Element_Count; Applied : out Boolean) is
         use type N.Real;
         use type Interfaces.Unsigned_16;
         use type System.Bit_Order;
         Row_Span : constant B.Byte_Count := Row_Bytes (Item);
         Block_Bytes : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Item.Format));
         Groups : constant Element_Count := (Count + 2) / 3;
         Lanes : N.Wide_Real_Array (0 .. Groups * 24 - 1);
         Totals : N.Wide_Real_Array (0 .. 2 * Count - 1) := [others => 0.0];
         Parameters : Real_Array (0 .. 31);
         Done : Element_Count := 0;
         function Half (At_Pos : B.Byte_Count) return Real is
           (N.To_Real (N.Half (Interfaces.Unsigned_16 (Data (Data'First + At_Pos)) or
            Interfaces.Shift_Left (Interfaces.Unsigned_16 (Data (Data'First + At_Pos + 1)), 8))));
      begin
         Applied := False;
         if Count not in 2 .. 16 or else (Count > 3 and then Item.Columns > 256)
           or else Item.Format not in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K
           or else System.Default_Bit_Order /= System.Low_Order_First
           or else not B.Has_Room (Data, Item.Offset + B.Byte_Count (Row) * Row_Span,
                                   Row_Span + B.Byte_Count (Blocks) * Block_Bytes)
         then return; end if;
         while Done < Blocks loop
            declare
               Take : constant Element_Count := Element_Count'Min (8, Blocks - Done);
            begin
               Lanes := [others => 0.0];
               for Block in 0 .. Take - 1 loop
                  for Part in Element_Count range 0 .. 1 loop
                     if Item.Scales /= null and then Item.Scales.all'Length = Scale_Count (Item) then
                        for Sub in Element_Count range 0 .. 15 loop
                           declare
                              At_Scale : constant Element_Count := Item.Scales.all'First
                                + ((Row + Part) * Blocks + Done + Block) * 16 + Sub;
                              At_Parameter : constant Element_Count :=
                                (if Item.Format = G.Type_Q6_K then Sub * 2 + Part
                                 else (Sub / 2) * 4 + Part * 2 + Sub mod 2);
                           begin
                              Parameters (At_Parameter) := Item.Scales (At_Scale);
                           end;
                        end loop;
                     else
                     declare
                        Base : constant B.Byte_Count := Item.Offset + B.Byte_Count (Row + Part) * Row_Span
                          + B.Byte_Count (Done + Block) * Block_Bytes;
                        D : constant Real :=
                          Half (Base + (if Item.Format = G.Type_Q6_K then 208 else 0));
                     begin
                        if Item.Format = G.Type_Q6_K then
                           for Sub in Element_Count range 0 .. 15 loop
                              declare
                                 Raw : constant Integer :=
                                   Integer (Data (Data'First + Base + 192 + B.Byte_Count (Sub)));
                              begin
                                 Parameters (Sub * 2 + Part) := D * Real (if Raw < 128 then Raw else Raw - 256);
                              end;
                           end loop;
                        else
                           for Sub in Element_Count range 0 .. 7 loop
                              declare
                                 function Byte_At (X : Element_Count) return Natural is
                                   (Natural (Data (Data'First + Base + 4 + B.Byte_Count (X))));
                                 Factor : constant Natural := (if Sub < 4 then Byte_At (Sub) mod 64
                                   else Byte_At (Sub + 4) mod 16 + (Byte_At (Sub - 4) / 64) * 16);
                                 Lowest : constant Natural := (if Sub < 4 then Byte_At (Sub + 4) mod 64
                                   else Byte_At (Sub + 4) / 16 + (Byte_At (Sub) / 64) * 16);
                              begin
                                 Parameters (Sub * 4 + Part * 2) := D * Real (Factor);
                                 Parameters (Sub * 4 + Part * 2 + 1) := Half (Base + 2) * Real (Lowest);
                              end;
                           end loop;
                        end if;
                     end;
                     end if;
                  end loop;
                  for Group in 0 .. Groups - 1 loop
                     declare
                        First : constant Element_Count := Group * 3;
                        Second : constant Element_Count := Element_Count'Min (First + 1, Count - 1);
                        Third : constant Element_Count := Element_Count'Min (First + 2, Count - 1);
                        Column : constant Element_Count := (Done + Block) * 256;
                        At_Weight : constant B.Byte_Count := Item.Offset + B.Byte_Count (Row) * Row_Span
                          + B.Byte_Count (Done + Block) * Block_Bytes
                          + (if Item.Format = G.Type_Q4_K then 16 elsif Item.Format = G.Type_Q5_K then 48 else 0);
                     begin
                        if Item.Format = G.Type_Q4_K then
                           Q4_Token_Product
                             (Data (Data'First + At_Weight)'Address,
                              Vectors (Vectors'First + Input_Row (First) * Item.Columns + Column)'Address,
                              Vectors (Vectors'First + Input_Row (Second) * Item.Columns + Column)'Address,
                              Vectors (Vectors'First + Input_Row (Third) * Item.Columns + Column)'Address,
                              Row_Span, Parameters, Lanes (Group * 24 .. Group * 24 + 23));
                        elsif Item.Format = G.Type_Q5_K then
                           Q5_Token_Product
                             (Data (Data'First + At_Weight)'Address,
                              Vectors (Vectors'First + Input_Row (First) * Item.Columns + Column)'Address,
                              Vectors (Vectors'First + Input_Row (Second) * Item.Columns + Column)'Address,
                              Vectors (Vectors'First + Input_Row (Third) * Item.Columns + Column)'Address,
                              Row_Span, Parameters, Lanes (Group * 24 .. Group * 24 + 23));
                        elsif Item.Format = G.Type_Q6_K then
                           Q6_Token_Product
                             (Data (Data'First + At_Weight)'Address,
                              Vectors (Vectors'First + Input_Row (First) * Item.Columns + Column)'Address,
                              Vectors (Vectors'First + Input_Row (Second) * Item.Columns + Column)'Address,
                              Vectors (Vectors'First + Input_Row (Third) * Item.Columns + Column)'Address,
                              Row_Span, Parameters, Lanes (Group * 24 .. Group * 24 + 23));
                        end if;
                     end;
                  end loop;
               end loop;
               for Part in Element_Count range 0 .. 1 loop
                  for Vector in 0 .. Count - 1 loop
                     declare
                        At_Lane : constant Element_Count := (Vector / 3) * 24 + Part * 12 + (Vector mod 3) * 4;
                     begin
                        Totals (Part * Count + Vector) := Totals (Part * Count + Vector)
                          + (Lanes (At_Lane) + Lanes (At_Lane + 1) + Lanes (At_Lane + 2) + Lanes (At_Lane + 3));
                     end;
                  end loop;
               end loop;
               Done := Done + Take;
            end;
         end loop;
         for Part in Element_Count range 0 .. 1 loop
            for Vector in 0 .. Count - 1 loop
               Target (Target'First + Vector * Item.Rows + Row + Part) := Real (Totals (Part * Count + Vector));
            end loop;
         end loop;
         Applied := True;
      end Fused_Tokens;

      procedure Pair (Data : B.Byte_Array; Row : Element_Count) is
         --  Match Accumulate_Dot's 2048-element span boundaries exactly.
         Span_Elements : constant Element_Count := 2048;
         Left, Right : Real_Array (0 .. Span_Elements - 1);
         Lanes : N.Wide_Real_Array (0 .. 47);
         Totals : N.Wide_Real_Array (0 .. 2 * Count - 1) := [others => 0.0];
         Column : Element_Count := 0;
         Done : Element_Count := 0;
         Row_Span : constant B.Byte_Count := Row_Bytes (Item);
         Good_Left, Good_Right : Boolean;
         Block_Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Item.Format));
      begin
         declare
            Applied : Boolean;
         begin
            Fused_Tokens (Data, Row, Applied);
            if Applied then return; end if;
         end;
         while Done < Blocks loop
            declare
               Take : constant Element_Count := Element_Count'Min (Span_Elements / Per_Block, Blocks - Done);
               Span : constant Element_Count := Take * Per_Block;
               Which : Element_Count := 0;
            begin
               Q.Decode_Blocks
                 (Item.Format, Data, Item.Offset + B.Byte_Count (Row) * Row_Span
                  + B.Byte_Count (Done) * Block_Width, Take, Left (0 .. Span - 1), Good_Left);
               Q.Decode_Blocks
                 (Item.Format, Data, Item.Offset + B.Byte_Count (Row + 1) * Row_Span
                  + B.Byte_Count (Done) * Block_Width, Take, Right (0 .. Span - 1), Good_Right);
               if not Good_Left or else not Good_Right then
                  if Members'Length > 0 then
                     for Part in Element_Count range 0 .. 1 loop
                        for Index in 0 .. Count - 1 loop
                           declare
                              From : constant Element_Count := Vectors'First + Input_Row (Index) * Item.Columns;
                              Into : constant Element_Count := Target'First + Index * Item.Rows;
                           begin
                              Mat_Mul_Range
                                (Item, Vectors (From .. From + Item.Columns - 1), 1,
                                 Target (Into .. Into + Item.Rows - 1), Row + Part, Row + Part);
                           end;
                        end loop;
                     end loop;
                     return;
                  end if;
                  --  Preserve each row's independent refusal behavior.
                  for Part in Element_Count range 0 .. 1 loop
                     Sums := [others => 0.0];
                     Q.Accumulate_Dot
                       (Item.Format, Data, Item.Offset + B.Byte_Count (Row + Part) * Row_Span,
                        Blocks, Vectors, Vectors'First, Item.Columns, Count, Sums, Ok);
                     for Vector in 0 .. Count - 1 loop
                        Target (Target'First + Vector * Item.Rows + Row + Part) :=
                          (if Ok then Real (Sums (Vector)) else 0.0);
                     end loop;
                  end loop;
                  return;
               end if;
               if Members'Length > 0 then
                  while Which < Count loop
                     declare
                        Left_Count : constant Element_Count := Count - Which;
                        Width : constant Element_Count :=
                          (if Left_Count in 6 | 12 or else (Left_Count >= 6 and then Left_Count mod 4 = 2)
                             or else (Left_Count >= 9 and then Left_Count mod 4 = 1) then 6
                           elsif Left_Count >= 4 and then Left_Count /= 5 then 4 else 3);
                        Active : constant Element_Count := Element_Count'Min (Width, Left_Count);
                        type Addresses is array (Element_Count range 0 .. 5) of System.Address;
                        Inputs : Addresses;
                     begin
                        for Member in Inputs'Range loop
                           Inputs (Member) := Vectors (Vectors'First
                             + Input_Row (Element_Count'Min (Which + Member, Count - 1)) * Item.Columns
                             + Column)'Address;
                        end loop;
                        if Width = 6 then
                           Selected_6_Product (Left (0)'Address, Right (0)'Address, Inputs'Address, Span / 4, Lanes);
                        elsif Width = 4 then
                           Selected_4_Product (Left (0)'Address, Right (0)'Address, Inputs'Address, Span / 4, Lanes);
                        else
                           Small_Batch_Output_Product
                             (Left (0)'Address, Right (0)'Address, Inputs (0), Inputs (1), Inputs (2), Span / 4, Lanes);
                        end if;
                        for Part in Element_Count range 0 .. 1 loop
                           for Member in 0 .. Active - 1 loop
                              declare
                                 Base : constant Element_Count := Part * Width * 4 + Member * 4;
                                 Into : constant Element_Count := Part * Count + Which + Member;
                              begin
                                 Totals (Into) := Totals (Into)
                                   + (Lanes (Base) + Lanes (Base + 1) + Lanes (Base + 2) + Lanes (Base + 3));
                              end;
                           end loop;
                        end loop;
                        Which := Which + Active;
                     end;
                  end loop;
               elsif Count in 2 .. 3 then
                  Small_Batch_Output_Product
                    (Left (0)'Address, Right (0)'Address,
                     Vectors (Vectors'First + Column)'Address,
                     Vectors (Vectors'First + Item.Columns + Column)'Address,
                     Vectors (Vectors'First + (if Count = 3 then 2 * Item.Columns else 0) + Column)'Address,
                     Span / 4, Lanes);
                  for Part in Element_Count range 0 .. 1 loop
                     for Member in 0 .. Count - 1 loop
                        declare
                           Base : constant Element_Count := Part * 12 + Member * 4;
                        begin
                           Totals (Part * Count + Member) := Totals (Part * Count + Member)
                             + (Lanes (Base) + Lanes (Base + 1) + Lanes (Base + 2) + Lanes (Base + 3));
                        end;
                     end loop;
                  end loop;
                  Which := Count;
               end if;
               while Count - Which >= 6 loop
                  Row_Pair_Six_Dot
                    (Left (0)'Address, Right (0)'Address,
                     Vectors (Vectors'First + Which * Item.Columns + Column)'Address,
                     Item.Columns, Span / 4, Lanes);
                  for Part in Element_Count range 0 .. 1 loop
                     for Member in Element_Count range 0 .. 5 loop
                        declare
                           Base : constant Element_Count := Part * 24 + Member * 4;
                           Into : constant Element_Count := Part * Count + Which + Member;
                        begin
                           Totals (Into) := Totals (Into)
                             + (Lanes (Base) + Lanes (Base + 1) + Lanes (Base + 2) + Lanes (Base + 3));
                        end;
                     end loop;
                  end loop;
                  Which := Which + 6;
               end loop;
               while Count - Which >= 4 loop
                  Row_Pair_Dot
                    (Left (0)'Address, Right (0)'Address,
                     Vectors (Vectors'First + Which * Item.Columns + Column)'Address,
                     Item.Columns, Span / 4, Lanes);
                  for Part in Element_Count range 0 .. 1 loop
                     for Member in Element_Count range 0 .. 3 loop
                        declare
                           Base : constant Element_Count := Part * 16 + Member * 4;
                           Into : constant Element_Count := Part * Count + Which + Member;
                        begin
                           Totals (Into) := Totals (Into)
                             + (Lanes (Base) + Lanes (Base + 1) + Lanes (Base + 2) + Lanes (Base + 3));
                        end;
                     end loop;
                  end loop;
                  Which := Which + 4;
               end loop;
               if Which < Count then
                  declare
                     Left_Bytes : B.Byte_Array (1 .. B.Byte_Count (Span) * 4)
                       with Import, Address => Left (0)'Address;
                     Right_Bytes : B.Byte_Array (1 .. B.Byte_Count (Span) * 4)
                       with Import, Address => Right (0)'Address;
                  begin
                     Q.Accumulate_Dot
                       (G.Type_F32, Left_Bytes, 0, Span, Vectors,
                        Vectors'First + Which * Item.Columns + Column, Item.Columns, Count - Which,
                        Totals (Which .. Count - 1), Ok);
                     Q.Accumulate_Dot
                       (G.Type_F32, Right_Bytes, 0, Span, Vectors,
                        Vectors'First + Which * Item.Columns + Column, Item.Columns, Count - Which,
                        Totals (Count + Which .. 2 * Count - 1), Ok);
                  end;
               end if;
               Done := Done + Take;
               Column := Column + Span;
            end;
         end loop;
         for Vector in 0 .. Count - 1 loop
            Target (Target'First + Vector * Item.Rows + Row) := Real (Totals (Vector));
            Target (Target'First + Vector * Item.Rows + Row + 1) := Real (Totals (Count + Vector));
         end loop;
      end Pair;

      procedure Triple (Data : B.Byte_Array; Row : Element_Count) is
         Span_Elements : constant Element_Count := 2048;
         Weights : Real_Array (0 .. 3 * Span_Elements - 1);
         Lanes : N.Wide_Real_Array (0 .. 47);
         Totals : N.Wide_Real_Array (0 .. 3 * Count - 1) := [others => 0.0];
         Column : Element_Count := 0;
         Done : Element_Count := 0;
         Row_Span : constant B.Byte_Count := Row_Bytes (Item);
         Block_Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Item.Format));
         Decoded : Boolean;
      begin
         while Done < Blocks loop
            declare
               Take : constant Element_Count := Element_Count'Min (Span_Elements / Per_Block, Blocks - Done);
               Span : constant Element_Count := Take * Per_Block;
               Which : Element_Count := 0;
            begin
               for Part in Element_Count range 0 .. 2 loop
                  Q.Decode_Blocks
                    (Item.Format, Data, Item.Offset + B.Byte_Count (Row + Part) * Row_Span
                     + B.Byte_Count (Done) * Block_Width, Take,
                     Weights (Part * Span_Elements .. Part * Span_Elements + Span - 1), Decoded);
                  if not Decoded then
                     --  A refused row must not determine another row's result.
                     for Refused in Element_Count range 0 .. 2 loop
                        Sums := [others => 0.0];
                        Q.Accumulate_Dot
                          (Item.Format, Data, Item.Offset + B.Byte_Count (Row + Refused) * Row_Span,
                           Blocks, Vectors, Vectors'First, Item.Columns, Count, Sums, Ok);
                        for Vector in 0 .. Count - 1 loop
                           Target (Target'First + Vector * Item.Rows + Row + Refused) :=
                             (if Ok then Real (Sums (Vector)) else 0.0);
                        end loop;
                     end loop;
                     return;
                  end if;
               end loop;
               while Count - Which >= 4 loop
                  Row_Triple_Dot
                    (Weights (0)'Address,
                     Vectors (Vectors'First + Which * Item.Columns + Column)'Address,
                     Span_Elements, Item.Columns, Span / 4, Lanes);
                  for Part in Element_Count range 0 .. 2 loop
                     for Member in Element_Count range 0 .. 3 loop
                        declare
                           Base : constant Element_Count := Part * 16 + Member * 4;
                           Into : constant Element_Count := Part * Count + Which + Member;
                        begin
                           Totals (Into) := Totals (Into)
                             + (Lanes (Base) + Lanes (Base + 1) + Lanes (Base + 2) + Lanes (Base + 3));
                        end;
                     end loop;
                  end loop;
                  Which := Which + 4;
               end loop;
               if Which < Count then
                  for Part in Element_Count range 0 .. 2 loop
                     declare
                        Bytes : B.Byte_Array (1 .. B.Byte_Count (Span) * 4)
                          with Import, Address => Weights (Part * Span_Elements)'Address;
                     begin
                        Q.Accumulate_Dot
                          (G.Type_F32, Bytes, 0, Span, Vectors,
                           Vectors'First + Which * Item.Columns + Column, Item.Columns, Count - Which,
                           Totals (Part * Count + Which .. Part * Count + Count - 1), Ok);
                     end;
                  end loop;
               end if;
               Done := Done + Take;
               Column := Column + Span;
            end;
         end loop;
         for Part in Element_Count range 0 .. 2 loop
            for Vector in 0 .. Count - 1 loop
               Target (Target'First + Vector * Item.Rows + Row + Part) := Real (Totals (Part * Count + Vector));
            end loop;
         end loop;
      end Triple;

      procedure Q4_Panels (Data : B.Byte_Array) is
         use type Interfaces.Unsigned_16;
         use type N.Real;
         Parameters : Real_Array (0 .. 127);
         All_Lanes : N.Wide_Real_Array (0 .. Count * 32 - 1);
         Totals : N.Wide_Real_Array (0 .. Count * 8 - 1);
         function Half (At_Pos : B.Byte_Count) return Real is
           (N.To_Real (N.Half (Interfaces.Unsigned_16 (Data (Data'First + At_Pos))
              or Interfaces.Shift_Left (Interfaces.Unsigned_16 (Data (Data'First + At_Pos + 1)), 8))));
      begin
         for Panel in First / 8 .. Last / 8 loop
            Totals := [others => 0.0];
            for Span in 0 .. (Blocks - 1) / 8 loop
               All_Lanes := [others => 0.0];
               for Block in Span * 8 .. Element_Count'Min (Span * 8 + 7, Blocks - 1) loop
                  declare
                     Base : constant B.Byte_Count := Item.Offset
                       + B.Byte_Count (Panel * Blocks + Block) * 1152;
                  begin
                     for Row in Element_Count range 0 .. 7 loop
                        declare
                           D : constant Real := Half (Base + B.Byte_Count (Row) * 2);
                           M : constant Real := Half (Base + 16 + B.Byte_Count (Row) * 2);
                        begin
                           for Sub in Element_Count range 0 .. 7 loop
                              declare
                                 Low : constant Natural := Natural
                                   (Data (Data'First + Base + 32 + B.Byte_Count (Sub * 8 + Row)));
                                 Top : constant Natural := Natural
                                   (Data (Data'First + Base + 96 + B.Byte_Count ((Sub / 2) * 8 + Row)))
                                     / 2 ** (4 * Natural (Sub mod 2));
                              begin
                                 Parameters (Sub * 16 + Row * 2) := D * Real (Low mod 16 + (Top mod 4) * 16);
                                 Parameters (Sub * 16 + Row * 2 + 1) := M * Real (Low / 16 + ((Top / 4) mod 4) * 16);
                              end;
                           end loop;
                        end;
                     end loop;
                     for Which in 0 .. Count - 1 loop
                        Wide_Products.Panels
                          (Data (Data'First + Base + 128)'Address,
                           Vectors (Vectors'First + Input_Row (Which) * Item.Columns + Block * 256)'Address,
                           0, Parameters, All_Lanes (Which * 32 .. Which * 32 + 31));
                     end loop;
                  end;
               end loop;
               for Which in 0 .. Count - 1 loop
                  for Row in Element_Count range 0 .. 7 loop
                     declare
                        At_Lane : constant Element_Count := Which * 32 + Row * 4;
                     begin
                        Totals (Which * 8 + Row) := Totals (Which * 8 + Row)
                          + (All_Lanes (At_Lane) + All_Lanes (At_Lane + 1)
                             + All_Lanes (At_Lane + 2) + All_Lanes (At_Lane + 3));
                     end;
                  end loop;
               end loop;
            end loop;
            for Which in 0 .. Count - 1 loop
               for Row in Element_Count range 0 .. 7 loop
                  Target (Target'First + Which * Item.Rows + Panel * 8 + Row) := Real (Totals (Which * 8 + Row));
               end loop;
            end loop;
         end loop;
      end Q4_Panels;

      procedure Q4_Eight_Rows
        (Data : B.Byte_Array; At_Byte : B.Byte_Count; Row_Span : B.Byte_Count;
         Take, Column : Element_Count; Lanes : out N.Wide_Real_Array)
      is
         use type Interfaces.Unsigned_16;
         use type N.Real;
         Parameters : Real_Array (0 .. 127);
         function Half (At_Pos : B.Byte_Count) return Real is
           (N.To_Real (N.Half (Interfaces.Unsigned_16 (Data (Data'First + At_Pos))
               or Interfaces.Shift_Left (Interfaces.Unsigned_16 (Data (Data'First + At_Pos + 1)), 8))));
      begin
         Lanes := [others => 0.0];
         for Block in 0 .. Take - 1 loop
            --  Load the next selected block into cache while this block's
            --  scale preparation and arithmetic run. Never cross the row
            --  span or fetch an expert the router did not select.
            if Block + 1 < Take then
               for Part in Element_Count range 0 .. 7 loop
                  declare
                     Next : constant System.Address := Data
                       (Data'First + At_Byte + B.Byte_Count (Block + 1) * 144
                        + B.Byte_Count (Part) * Row_Span)'Address;
                  begin
                     System.Machine_Code.Asm
                       ("prefetcht0 0(%0)" & ASCII.LF & "prefetcht0 64(%0)" & ASCII.LF & "prefetcht0 128(%0)",
                        Inputs => System.Address'Asm_Input ("r", Next), Volatile => True);
                  end;
               end loop;
            end if;
            for Part in Element_Count range 0 .. 7 loop
               if Item.Scales /= null and then Item.Scales.all'Length = Scale_Count (Item) then
                  for Sub in Element_Count range 0 .. 15 loop
                     declare
                        Physical : constant Element_Count := Element_Count ((At_Byte - Item.Offset) / Row_Span) + Part;
                        At_Scale : constant Element_Count := Item.Scales.all'First
                          + (Physical * Blocks + Column / 256 + Block) * 16 + Sub;
                        At_Parameter : constant Element_Count :=
                          (Sub / 2) * 16 + Part * 2 + Sub mod 2;
                     begin
                        Parameters (At_Parameter) := Item.Scales (At_Scale);
                     end;
                  end loop;
               else
               declare
                  Base : constant B.Byte_Count := At_Byte + B.Byte_Count (Block) * 144 + B.Byte_Count (Part) * Row_Span;
                  D : constant Real := Half (Base);
                  Minimum : constant Real := Half (Base + 2);
                  function Byte_At (Index : Element_Count) return Natural is
                    (Natural (Data (Data'First + Base + 4 + B.Byte_Count (Index))));
               begin
                  for Sub in Element_Count range 0 .. 7 loop
                     declare
                        Factor : constant Natural :=
                          (if Sub < 4 then Byte_At (Sub) mod 64
                           else Byte_At (Sub + 4) mod 16 + (Byte_At (Sub - 4) / 64) * 16);
                        Lowest : constant Natural :=
                          (if Sub < 4 then Byte_At (Sub + 4) mod 64
                           else Byte_At (Sub + 4) / 16 + (Byte_At (Sub) / 64) * 16);
                     begin
                        Parameters (Sub * 16 + Part * 2) := D * Real (Factor);
                        Parameters (Sub * 16 + Part * 2 + 1) := Minimum * Real (Lowest);
                     end;
                  end loop;
               end;
               end if;
            end loop;
            if Deep_Products then
               Wide_Products.Rows
                 (Data (Data'First + At_Byte + B.Byte_Count (Block) * 144 + 16)'Address,
                  Vectors (Vectors'First + Column + Block * 256)'Address, Row_Span, Parameters, Lanes);
            else
            Q4_Output_Product
              (Data (Data'First + At_Byte + B.Byte_Count (Block) * 144 + 16)'Address,
               Vectors (Vectors'First + Column + Block * 256)'Address, Row_Span, Parameters, Lanes);
            end if;
         end loop;
      end Q4_Eight_Rows;

      procedure Q5_Eight_Rows
        (Data : B.Byte_Array; At_Byte : B.Byte_Count; Row_Span : B.Byte_Count;
         Take, Column : Element_Count; Lanes : out N.Wide_Real_Array)
      is
         use type Interfaces.Unsigned_16;
         use type N.Real;
         Parameters : Real_Array (0 .. 127);
         function Half (At_Pos : B.Byte_Count) return Real is
           (N.To_Real (N.Half (Interfaces.Unsigned_16 (Data (Data'First + At_Pos))
               or Interfaces.Shift_Left (Interfaces.Unsigned_16 (Data (Data'First + At_Pos + 1)), 8))));
      begin
         Lanes := [others => 0.0];
         for Block in 0 .. Take - 1 loop
            for Part in Element_Count range 0 .. 7 loop
               if Item.Scales /= null and then Item.Scales.all'Length = Scale_Count (Item) then
                  for Sub in Element_Count range 0 .. 15 loop
                     declare
                        Physical : constant Element_Count := Element_Count ((At_Byte - Item.Offset) / Row_Span) + Part;
                        At_Scale : constant Element_Count := Item.Scales.all'First
                          + (Physical * Blocks + Column / 256 + Block) * 16 + Sub;
                        At_Parameter : constant Element_Count :=
                          (Sub / 2) * 16 + Part * 2 + Sub mod 2;
                     begin
                        Parameters (At_Parameter) := Item.Scales (At_Scale);
                     end;
                  end loop;
               else
               declare
                  Base : constant B.Byte_Count := At_Byte + B.Byte_Count (Block) * 176 + B.Byte_Count (Part) * Row_Span;
                  D : constant Real := Half (Base);
                  Minimum : constant Real := Half (Base + 2);
                  function Byte_At (Index : Element_Count) return Natural is
                    (Natural (Data (Data'First + Base + 4 + B.Byte_Count (Index))));
               begin
                  for Sub in Element_Count range 0 .. 7 loop
                     declare
                        Factor : constant Natural :=
                          (if Sub < 4 then Byte_At (Sub) mod 64
                           else Byte_At (Sub + 4) mod 16 + (Byte_At (Sub - 4) / 64) * 16);
                        Lowest : constant Natural :=
                          (if Sub < 4 then Byte_At (Sub + 4) mod 64
                           else Byte_At (Sub + 4) / 16 + (Byte_At (Sub) / 64) * 16);
                     begin
                        Parameters (Sub * 16 + Part * 2) := D * Real (Factor);
                        Parameters (Sub * 16 + Part * 2 + 1) := Minimum * Real (Lowest);
                     end;
                  end loop;
               end;
               end if;
            end loop;
            Q5_Output_Product
              (Data (Data'First + At_Byte + B.Byte_Count (Block) * 176 + 48)'Address,
               Vectors (Vectors'First + Column + Block * 256)'Address, Row_Span, Parameters, Lanes);
         end loop;
      end Q5_Eight_Rows;

      procedure Q6_Eight_Rows
        (Data : B.Byte_Array; At_Byte : B.Byte_Count; Row_Span : B.Byte_Count;
         Take, Column : Element_Count; Lanes : out N.Wide_Real_Array)
      is
         use type Interfaces.Unsigned_16;
         use type N.Real;
         Parameters : Real_Array (0 .. 127);
      begin
         Lanes := [others => 0.0];
         for Block in 0 .. Take - 1 loop
            for Part in Element_Count range 0 .. 7 loop
               if Item.Scales /= null and then Item.Scales.all'Length = Scale_Count (Item) then
                  for Sub in Element_Count range 0 .. 15 loop
                     declare
                        Physical : constant Element_Count := Element_Count ((At_Byte - Item.Offset) / Row_Span) + Part;
                        At_Scale : constant Element_Count := Item.Scales.all'First
                          + (Physical * Blocks + Column / 256 + Block) * 16 + Sub;
                        At_Parameter : constant Element_Count :=
                          Sub * 8 + Part;
                     begin
                        Parameters (At_Parameter) := Item.Scales (At_Scale);
                     end;
                  end loop;
               else
               declare
                  Base : constant B.Byte_Count := At_Byte + B.Byte_Count (Block) * 210 + B.Byte_Count (Part) * Row_Span;
                  D : constant Real := N.To_Real (N.Half
                    (Interfaces.Unsigned_16 (Data (Data'First + Base + 208)) or Interfaces.Shift_Left
                      (Interfaces.Unsigned_16 (Data (Data'First + Base + 209)), 8)));
               begin
                  for Sub in Element_Count range 0 .. 15 loop
                     declare
                        Bits : constant Integer := Integer (Data (Data'First + Base + 192 + B.Byte_Count (Sub)));
                        Signed : constant Integer := (if Bits < 128 then Bits else Bits - 256);
                     begin
                        Parameters (Sub * 8 + Part) := D * Real (Signed);
                     end;
                  end loop;
               end;
               end if;
            end loop;
            Q6_Output_Product
              (Data (Data'First + At_Byte + B.Byte_Count (Block) * 210)'Address,
               Vectors (Vectors'First + Column + Block * 256)'Address, Row_Span, Parameters, Lanes);
         end loop;
      end Q6_Eight_Rows;


      procedure Eight_Rows (Data : B.Byte_Array; Row : Element_Count) is
         use type System.Bit_Order;
         Span_Elements : constant Element_Count := 2048;
         Weights : Real_Array (0 .. 8 * Span_Elements - 1);
         Lanes : N.Wide_Real_Array (0 .. 31);
         Totals : N.Wide_Real_Array (0 .. 7) := [others => 0.0];
         Column : Element_Count := 0;
         Done : Element_Count := 0;
         Row_Span : constant B.Byte_Count := Row_Bytes (Item);
         Block_Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Item.Format));
         Decoded : Boolean;
      begin
         while Done < Blocks loop
            declare
               Take : constant Element_Count := Element_Count'Min (Span_Elements / Per_Block, Blocks - Done);
               Span : constant Element_Count := Take * Per_Block;
               At_Byte : constant B.Byte_Count := Item.Offset
                 + B.Byte_Count (Row) * Row_Span + B.Byte_Count (Done) * Block_Width;
               Weight_At : System.Address;
               Weight_Stride : Element_Count;
            begin
               if Item.Format = G.Type_Q4_K
                 and then B.Has_Room (Data, At_Byte, 7 * Row_Span + B.Byte_Count (Take) * 144)
               then
                  Q4_Eight_Rows (Data, At_Byte, Row_Span, Take, Column, Lanes);
               elsif Item.Format = G.Type_Q5_K
                 and then B.Has_Room (Data, At_Byte, 7 * Row_Span + B.Byte_Count (Take) * 176)
               then
                  Q5_Eight_Rows (Data, At_Byte, Row_Span, Take, Column, Lanes);
               elsif Item.Format = G.Type_Q6_K
                 and then B.Has_Room (Data, At_Byte, 7 * Row_Span + B.Byte_Count (Take) * 210)
               then
                  Q6_Eight_Rows (Data, At_Byte, Row_Span, Take, Column, Lanes);
               elsif Item.Format = G.Type_Q8_0
                 and then B.Has_Room (Data, At_Byte, 7 * Row_Span + B.Byte_Count (Take) * 34)
               then
                  Q8_Output_Product
                    (Data (Data'First + At_Byte)'Address, Vectors (Vectors'First + Column)'Address,
                     Row_Span, Take, Lanes);
               else
                  if Item.Format = G.Type_F32
                    and then System.Default_Bit_Order = System.Low_Order_First
                    and then B.Has_Room (Data, At_Byte, 7 * Row_Span + B.Byte_Count (Span) * 4)
                  then
                     --  The guarded x86 path accepts unaligned F32 rows. Keep
                     --  their original stride and read without a workspace copy.
                     Weight_At := Data (Data'First + At_Byte)'Address;
                     Weight_Stride := Item.Columns;
                  else
                     for Part in Element_Count range 0 .. 7 loop
                        Q.Decode_Blocks
                          (Item.Format, Data, Item.Offset + B.Byte_Count (Row + Part) * Row_Span
                           + B.Byte_Count (Done) * Block_Width, Take,
                           Weights (Part * Span_Elements .. Part * Span_Elements + Span - 1), Decoded);
                        if not Decoded then
                           --  Preserve each original row's independent refusal.
                           for Refused in Element_Count range 0 .. 7 loop
                              Sums := [others => 0.0];
                              Q.Accumulate_Dot
                                (Item.Format, Data, Item.Offset + B.Byte_Count (Row + Refused) * Row_Span,
                                 Blocks, Vectors, Vectors'First, Item.Columns, 1, Sums, Ok);
                              Target (Target'First + Row + Refused) :=
                                (if Ok then Real (Sums (0)) else 0.0);
                           end loop;
                           return;
                        end if;
                     end loop;
                     Weight_At := Weights (0)'Address;
                     Weight_Stride := Span_Elements;
                  end if;
                  Eight_Output_Dot
                    (Weight_At, Vectors (Vectors'First + Column)'Address,
                     Weight_Stride, Span / 4, Lanes);
               end if;
               for Part in Element_Count range 0 .. 7 loop
                  declare
                     Base : constant Element_Count := Part * 4;
                  begin
                     Totals (Part) := Totals (Part)
                       + (Lanes (Base) + Lanes (Base + 1) + Lanes (Base + 2) + Lanes (Base + 3));
                  end;
               end loop;
               Done := Done + Take;
               Column := Column + Span;
            end;
         end loop;
         for Part in Element_Count range 0 .. 7 loop
            Target (Target'First + Row + Part) := Real (Totals (Part));
         end loop;
      end Eight_Rows;
   begin
      if not Is_Present (Item)
        or else First > Last
        or else Last >= Item.Rows
        or else Count = 0
        or else Per_Block = 0
        or else (Members'Length = 0 and then Vectors'Length < Count * Item.Columns)
        or else Target'Length < Count * Item.Rows
      then
         return;
      end if;

      Blocks := Item.Columns / Per_Block;
      if Members'Length > 0 then
         if Members'Length /= Count
           or else (for some Member of Members =>
                     Element_Count (Member) >= Vectors'Length / Item.Columns)
         then return; end if;
         declare
            Held : B.Byte_Array (1 .. Item.Span) with Import, Address => Item.Base;
         begin
            if Wide_Halves and then not Item.Interleaved and then Count in 2 .. 16
              and then Item.Columns mod Per_Block = 0
              and then Item.Columns mod 4 = 0
            then
               while Next_Row < Last loop
                  Pair (Held, Next_Row);
                  Next_Row := Next_Row + 2;
               end loop;
            end if;
            if Next_Row <= Last then
               for Index in 0 .. Count - 1 loop
                  declare
                     From : constant Element_Count := Vectors'First + Input_Row (Index) * Item.Columns;
                     Into : constant Element_Count := Target'First + Index * Item.Rows;
                  begin
                     Mat_Mul_Range
                       (Item, Vectors (From .. From + Item.Columns - 1), 1,
                        Target (Into .. Into + Item.Rows - 1), Next_Row, Last);
                  end;
               end loop;
            end if;
         end;
         return;
      end if;


      --  A panel's row is put back where it was before it is read, for the
      --  same reason Row_Dot does it and at the same cost. This is the path
      --  a kernel refusal falls to, so it has to be able to read a matrix
      --  the kernel could not -- and a matrix in panels read as though it
      --  were in rows is not a refusal but wrong answers, which is what it
      --  gave before this was here.
      if Item.Interleaved then
         declare
            Whole : B.Byte_Array (1 .. Item.Span)
              with Import, Address => Item.Base;

            Row_Span : constant B.Byte_Count := Row_Bytes (Item);
            Alone    : B.Byte_Array (0 .. Row_Span - 1);
            Taken    : Boolean;
         begin
            if Deep_Products and then Wide_Halves
              and then Item.Format = G.Type_Q4_K
              and then First mod 8 = 0 and then (Last + 1) mod 8 = 0
            then
               Q4_Panels (Whole);
               return;
            end if;
            Counting.Atomic_Add (Fallback_Count, Row_Count (Last - First + 1));
            for Row in First .. Last loop
               Sums := [others => 0.0];

               Model_Runner.Quantization.Interleave.Extract_Row
                 (Format => Item.Format,
                  Source => Whole,
                  From   => Item.Offset,
                  Row    => Row,
                  Blocks => Blocks,
                  Target => Alone,
                  Ok     => Taken);

               if Taken then
                  Q.Accumulate_Dot
                    (Format  => Item.Format,
                     Data    => Alone,
                     Offset  => 0,
                     Blocks  => Blocks,
                     Vectors => Vectors,
                     First   => Vectors'First,
                     Stride  => Item.Columns,
                     Count   => Count,
                     Sums    => Sums,
                     Ok      => Ok);
               else
                  Ok := False;
               end if;

               for Which in 0 .. Count - 1 loop
                  Target (Target'First + Which * Item.Rows + Row) :=
                    (if Ok then Real (Sums (Which)) else 0.0);
               end loop;
            end loop;
         end;

         return;
      end if;

      --  Declared once around the row loop rather than once a row: an
      --  overlay costs nothing to enter, and nothing to leave, but saying so
      --  once reads better than saying it for every row.
      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;
      begin
         if Wide_Halves
           and then (Item.Format in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K | G.Type_Q5_0 | G.Type_Q8_0
                     or else (Count in 1 .. 3 and then Item.Format in G.Type_F32 | G.Type_F16 | G.Type_BF16
                              and then Item.Columns mod 4 = 0))
           and then Blocks > 0 and then Item.Columns mod Per_Block = 0
         then
            if Count = 1 then
               while Next_Row <= Last and then Last - Next_Row >= 7 loop
                  Eight_Rows (Held, Next_Row);
                  Next_Row := Next_Row + 8;
               end loop;
            elsif Count >= 2 then
               --  Use triples where four-vector groups leave at most one
               --  remainder; bound their workspace to ordinary batch sizes.
               if Count <= 128 and then Count mod 4 <= 1
                 and then not (Count <= 16 and then Item.Columns <= 256
                               and then Item.Format in G.Type_Q4_K | G.Type_Q5_K | G.Type_Q6_K)
               then
                  while Next_Row <= Last and then Last - Next_Row >= 2 loop
                     Triple (Held, Next_Row);
                     Next_Row := Next_Row + 3;
                  end loop;
               end if;
               while Next_Row < Last loop
                  Pair (Held, Next_Row);
                  Next_Row := Next_Row + 2;
               end loop;
            end if;
         end if;
         for Row in Next_Row .. Last loop
            Sums := [others => 0.0];

            --  One call for the whole row. The multiply is folded into the
            --  decode, so the weights are never written out in any form:
            --  there is no span buffer to size, to fill or to read back.
            Q.Accumulate_Dot
              (Format  => Item.Format,
               Data    => Held,
               Offset  => Item.Offset + B.Byte_Count (Row) * Row_Bytes (Item),
               Blocks  => Blocks,
               Vectors => Vectors,
               First   => Vectors'First,
               Stride  => Item.Columns,
               Count   => Count,
               Sums    => Sums,
               Ok      => Ok);

            for Which in 0 .. Count - 1 loop
               Target (Target'First + Which * Item.Rows + Row) :=
                 (if Ok then Real (Sums (Which)) else 0.0);
            end loop;
         end loop;
      end;
   end Mat_Mul_Range;

   ---------------------------
   -- Mat_Mul_Range_Packed --
   ---------------------------

   --  The most vectors, and the largest share of a matrix in bytes, that
   --  Mat_Mul_Range_Packed takes a vector at a time.
   Singly_Most  : constant := 4;
   Singly_Bytes : constant := 1_048_576;

   procedure Mat_Mul_Packed_Pair
     (Left, Right : View; Values : Model_Runner.Quantization.Integers.Signed_Array;
      Scales : Real_Array; Totals, Halves : Model_Runner.Quantization.Integers.Sum_Array;
      Count : Element_Count; A, B : Real_Array_Access; Handled : out Boolean;
      Input_Members : Model_Runner.Shares.Member_Rows := [])
   is
      package QI renames Model_Runner.Quantization.Integers;
      package Bytes renames Model_Runner.Bytes;
      use type G.Tensor_Type;
      Per : constant Element_Count := Element_Count (G.Block_Elements (Left.Format));
   begin
      Handled := False;
      if not Is_Present (Left) or else not Is_Present (Right)
        or else not Left.Reference_Activations or else not Right.Reference_Activations
        or else Left.Interleaved or else Right.Interleaved
        or else Left.Format /= Right.Format or else Left.Rows /= Right.Rows
        or else Left.Columns /= Right.Columns or else Per = 0
        or else Left.Columns mod Per /= 0 or else A = null or else B = null
      then return; end if;
      declare
         Held : Bytes.Byte_Array (1 .. Left.Span) with Import, Address => Left.Base;
         Other : Bytes.Byte_Array (1 .. Right.Span) with Import, Address => Right.Base;
      begin
         QI.Reference_Products
           (Left.Format, Held, Left.Offset, Row_Bytes (Left), Left.Rows, Left.Columns / Per,
            Values, Scales, Totals, Halves, 0, Left.Columns, Count, A, 0, Left.Rows, Handled,
            Metadata => (if Left.Scales /= null then Left.Scales.all else []),
            Partner => Other, Partner_Offset => Right.Offset,
            Partner_Metadata => (if Right.Scales /= null then Right.Scales.all else []),
            Partner_Target => B, Input_Members => Input_Members);
      end;
   end Mat_Mul_Packed_Pair;

   procedure Mat_Mul_Range_Packed
     (Item    : View;
      Values  : Model_Runner.Quantization.Integers.Signed_Array;
      Scales  : Real_Array;
      Totals  : Model_Runner.Quantization.Integers.Sum_Array;
      Halves  : Model_Runner.Quantization.Integers.Sum_Array;
      Count   : Element_Count;
      Target  : in out Real_Array;
      First   : Element_Count;
      Last    : Element_Count;
      Handled : out Boolean;
      Result_Members : Model_Runner.Shares.Member_Rows := [])
   is
      package QI renames Model_Runner.Quantization.Integers;
      use type G.Tensor_Type;

      Per_Block : constant Element_Count :=
        Element_Count (G.Block_Elements (Item.Format));
      Blocks : Element_Count;
      Ok     : Boolean;
   begin
      Handled := False;

      if not Is_Present (Item)
        or else First > Last
        or else Last >= Item.Rows
        or else Count = 0
        or else (Result_Members'Length /= 0 and then
          (not Item.Reference_Activations or else Result_Members'Length /= Count))
        or else Per_Block = 0
        or else not QI.Has_Integer_Kernel
                      (Item.Format, Item.Interleaved, Item.Reference_Activations)
        or else not QI.Is_Packable (Item.Columns)
        or else Values'Length < Count * Item.Columns
        or else Target'Length < Count * Item.Rows
        --  A panel's rows are found by the panel they open: a range that
        --  starts inside one would be read from the panel before it.
        or else (Item.Interleaved
                 and then First mod Model_Runner.Quantization.Interleave.Panel_Rows /= 0)
      then
         return;
      end if;

      Blocks := Item.Columns / Per_Block;

      if Item.Reference_Activations then
         declare
            Held : B.Byte_Array (1 .. Item.Span) with Import, Address => Item.Base;
         begin
            QI.Reference_Products
              (Item.Format, Held,
               (if Item.Interleaved then Item.Offset + B.Byte_Count (First / 8) * B.Byte_Count (Blocks)
                    * Model_Runner.Quantization.Interleave.Block_Bytes (Item.Format)
                else Item.Offset + B.Byte_Count (First) * Row_Bytes (Item)),
               Row_Bytes (Item), Last - First + 1, Blocks, Values, Scales, Totals, Halves,
               0, Item.Columns, Count, Target'Unrestricted_Access, First, Item.Rows, Ok, Item.Interleaved,
               (if Item.Scales /= null and then Reference_Scale_Count (Item) > 0
                  and then Item.Scales.all'Length = Reference_Scale_Count (Item)
                then Item.Scales.all (Item.Scales.all'First + First * Blocks
                       * (if Item.Format = G.Type_Q6_K then 5 else 6)
                     .. Item.Scales.all'First + (Last + 1) * Blocks
                       * (if Item.Format = G.Type_Q6_K then 5 else 6) - 1)
                else []), Result_Members => Result_Members);
            if Ok then Handled := True; return; end if;
         end;
      end if;

      if Result_Members'Length /= 0 then return; end if;

      --  A few vectors against a matrix the nearest caches hold, a vector
      --  at a time through the kernel a single vector takes: the tile of
      --  strips works out a whole tile's scales for every call, which a
      --  batch of a hundred amortizes and a batch of two does not -- a
      --  mixture's expert over two vectors took three and a half times
      --  what it took over one, 0.92 ms against 0.26, where the second
      --  pass over a matrix still in the cache costs a third of the first.
      --  A matrix past the cache is read again from memory each time, and
      --  keeps the strips.
      if Count in 2 .. Singly_Most
        and then not Item.Reference_Activations
        and then not Item.Interleaved
        and then not QI.Takes_Few_Together (Item.Format)
        and then Long_Long_Integer (Last - First + 1)
                 * Long_Long_Integer (Row_Bytes (Item)) <= Singly_Bytes
      then
         declare
            Per_Row  : constant Element_Count :=
              Item.Columns / QI.Activation_Block;
            Per_Half : constant := QI.Activation_Block / QI.Activation_Half;
         begin
            for Which in 0 .. Count - 1 loop
               declare
                  One_Value : constant QI.Signed_Array
                    (0 .. Item.Columns - 1) :=
                    Values (Values'First + Which * Item.Columns
                            .. Values'First + Which * Item.Columns
                               + Item.Columns - 1);
                  One_Scale : constant Real_Array (0 .. Per_Row - 1) :=
                    Scales (Scales'First + Which * Per_Row
                            .. Scales'First + Which * Per_Row + Per_Row - 1);
                  One_Total : constant QI.Sum_Array (0 .. Per_Row - 1) :=
                    Totals (Totals'First + Which * Per_Row
                            .. Totals'First + Which * Per_Row + Per_Row - 1);
                  One_Half  : constant QI.Sum_Array
                    (0 .. Per_Row * Per_Half - 1) :=
                    Halves (Halves'First + Which * Per_Row * Per_Half
                            .. Halves'First + Which * Per_Row * Per_Half
                               + Per_Row * Per_Half - 1);
                  Done : Boolean;
               begin
                  Mat_Mul_Range_Packed
                    (Item, One_Value, One_Scale, One_Total, One_Half, 1,
                     Target (Target'First + Which * Item.Rows
                             .. Target'First + Which * Item.Rows
                                + Item.Rows - 1),
                     First, Last, Done);
                  if not Done then
                     return;
                  end if;
               end;
            end loop;
         end;

         Handled := True;
         return;
      end if;

      declare
         Held : B.Byte_Array (1 .. Item.Span)
           with Import, Address => Item.Base;

         --  A tile's worth of accumulators, row major. Declared once around
         --  the loop rather than once a tile: it is a fixed number of wide
         --  reals and saying so once reads better.
         Tiled : Model_Runner.Numerics.Wide_Real_Array
           (0 .. QI.Row_Tile * Count - 1);

         --  How many rows to take at once, which depends on how many
         --  vectors there are: see Wanted_Tile.
         --
         --  Except where the weights are in panels, which fixes it at four
         --  of them. A panel's rows are summed the same way whatever tile
         --  they arrive in, so unlike the row-major tile this one changes no
         --  answer -- and one panel for a token, which is what Wanted_Tile's
         --  reading would suggest, measured level with four.
         Wanted : constant Element_Count :=
           (if Item.Interleaved then QI.Panel_Tile
            else QI.Wanted_Tile (Count));

         At_Row : Element_Count := First;
      begin
         while At_Row <= Last loop
            declare
               Here : constant Element_Count :=
                 Element_Count'Min (Wanted, Last - At_Row + 1);
            begin
               Tiled := [others => 0.0];

               --  Four rows against one reading of the activation. The row
               --  loop that was here read it once per row, which is the
               --  same bytes out of the same cache line four times.
               QI.Accumulate_Rows
                 (Format    => Item.Format,
                  Data      => Held,

                  --  Where the tile begins, which the layout decides. A
                  --  panel is eight rows and a tile is a whole number of
                  --  them, so a tile's first byte is its first panel's --
                  --  and a panel block is not a row block, so the step is
                  --  not the row's either.
                  Offset    =>
                    (if Item.Interleaved
                     then Item.Offset
                          + B.Byte_Count
                              (At_Row
                               / Model_Runner.Quantization.Interleave
                                   .Panel_Rows)
                            * B.Byte_Count (Blocks)
                            * Model_Runner.Quantization.Interleave
                                .Block_Bytes (Item.Format)
                     else Item.Offset
                          + B.Byte_Count (At_Row) * Row_Bytes (Item)),
                  Row_Bytes => Row_Bytes (Item),
                  Rows      => Here,
                  Blocks    => Blocks,
                  Values    => Values,
                  Scales    => Scales,
                  Totals    => Totals,
                  Halves    => Halves,
                  First     => 0,
                  Stride    => Item.Columns,
                  Count     => Count,
                  Sums      => Tiled,
                  Ok        => Ok,
                  Interleaved => Item.Interleaved,
                  Reference_Arithmetic => Item.Reference_Activations,
                  Metadata =>
                    (if Item.Scales /= null and then Reference_Scale_Count (Item) > 0
                       and then Item.Scales.all'Length = Reference_Scale_Count (Item)
                     then Item.Scales.all
                       (Item.Scales.all'First + At_Row * Blocks
                          * (if Item.Format = G.Type_Q6_K then 5 else 6)
                        .. Item.Scales.all'First + (At_Row + Here) * Blocks
                          * (if Item.Format = G.Type_Q6_K then 5 else 6) - 1)
                     else []));

               --  A tile the integer path refuses is a tile nobody has
               --  computed, and the range is all or nothing: reporting it
               --  here sends the whole share back to the floating-point path
               --  rather than leaving some rows right and some zero.
               if not Ok then
                  return;
               end if;

               --  The vector outside and the row inside, which is the
               --  order the target is laid out in and not the order the
               --  tile is.
               --
               --  A target keeps a whole vector's answers together, so
               --  consecutive rows of one vector are consecutive words;
               --  written the other way round, every step of the inner
               --  loop moved Item.Rows words along -- eight kilobytes for
               --  a two-thousand-row tensor, a cache line touched and
               --  abandoned for each of eight hundred and eighty writes a
               --  tile. Turned about, the writes are contiguous and it is
               --  the reads that stride, inside a seven-kilobyte tile that
               --  is in the nearest cache whichever way it is walked.
               --
               --  The same values reach the same places; a profile put
               --  this procedure at five per cent of a prompt and this
               --  loop at most of it.
               --  The checks are suppressed and the vector's base is
               --  worked out once: a profile found the index compares
               --  costing more than the narrowing convert they guard,
               --  around a loop whose bounds this procedure has already
               --  proved.
               declare
                  pragma Suppress (Index_Check);
                  pragma Suppress (Range_Check);
                  pragma Suppress (Overflow_Check);
               begin
                  for Which in 0 .. Count - 1 loop
                     declare
                        Out_At : constant Element_Count :=
                          Target'First + Which * Item.Rows + At_Row;
                        In_At  : constant Element_Count := Which;
                     begin
                        for Row in 0 .. Here - 1 loop
                           Target (Out_At + Row) :=
                             Real (Tiled (In_At + Row * Count));
                        end loop;
                     end;
                  end loop;
               end;

               At_Row := At_Row + Here;
            end;
         end loop;
      end;

      Handled := True;
   end Mat_Mul_Range_Packed;

end Model_Runner.Tensors;
