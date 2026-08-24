package body Model_Runner.Quantization.Integers.Kernels is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type B.Byte_Count;
   use type N.Real;
   use type N.Wide_Real;

   ----------
   -- Rows --
   ----------

   procedure Rows
     (Format    : Model_Runner.GGUF.Tensor_Type;
      Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Row_Bytes : Model_Runner.Bytes.Byte_Count;
      Rows      : Element_Count;
      Blocks    : Element_Count;
      Values    : Signed_Array;
      Scales    : Model_Runner.Numerics.Real_Array;
      Totals    : Sum_Array;
      First     : Element_Count;
      Stride    : Element_Count;
      Count     : Element_Count;
      Sums      : in out Model_Runner.Numerics.Wide_Real_Array;
      Ok        : out Boolean)
   is
      Width : constant B.Byte_Count :=
        B.Byte_Count (G.Block_Bytes (Format));
      Per   : constant Element_Count :=
        Element_Count (G.Block_Elements (Format));
   begin
      Ok := False;

      if not Has_Integer_Kernel (Format)
        or else Blocks = 0
        or else Count = 0
        or else Rows = 0
        or else Rows > Row_Tile
        or else Per /= Activation_Block
        or else Sums'Length < Rows * Count
        or else not B.Has_Room
                     (Data, Offset,
                      Row_Bytes * B.Byte_Count (Rows - 1)
                      + Width * B.Byte_Count (Blocks))
      then
         return;
      end if;

      --  Every element this call will read, proved once, exactly as the
      --  single-row entry proves its own. The loops below run with the
      --  runtime checks suppressed.
      declare
         Reach : constant Element_Count :=
           First + (Count - 1) * Stride + Blocks * Per;
         Blocks_Reach : constant Element_Count :=
           (First + (Count - 1) * Stride) / Activation_Block + Blocks;
      begin
         if First < Values'First
           or else First mod Activation_Block /= 0
           or else Stride mod Activation_Block /= 0
           or else Reach < First
           or else Reach - 1 > Values'Last
           or else Scales'Length < Blocks_Reach
           or else Totals'Length < Blocks_Reach
         then
            return;
         end if;
      end;

      --  A block of four rows against a block of the activation, which is
      --  loaded once and multiplied four times. A row at a time loaded it
      --  once per row: the bytes are in the nearest cache either way, and
      --  being in the nearest cache is not the same as being in a register.
      --
      --  Four sums are live at once as well, which is what gives the
      --  processor four independent chains to interleave where one row gave
      --  it one and a multiply-add latency to wait out.
      declare
         pragma Suppress (Index_Check);
         pragma Suppress (Range_Check);
         pragma Suppress (Overflow_Check);

         subtype Block_Range is Element_Count range 0 .. Activation_Block - 1;
         type Wide_Block is array (Block_Range) of Interfaces.Integer_16;
         subtype Row_Range is Element_Count range 0 .. Row_Tile - 1;
         type Row_Blocks is array (Row_Range) of Wide_Block;
         type Row_Scales is array (Row_Range) of N.Real;

         Weights : Row_Blocks;
         Scaling : Row_Scales;
         Active  : Wide_Block;
      begin
         for Block in 0 .. Blocks - 1 loop
            for Row in 0 .. Rows - 1 loop
               declare
                  At_Byte : constant B.Byte_Index :=
                    Data'First + Offset
                    + Row_Bytes * B.Byte_Count (Row)
                    + Width * B.Byte_Count (Block);
               begin
                  Scaling (Row) :=
                    N.To_Real
                      (N.Half
                         (Interfaces.Unsigned_16 (Data (At_Byte))
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_16
                                  (Data (At_Byte + 1)), 8)));

                  for Index in Block_Range loop
                     declare
                        U : constant Interfaces.Unsigned_8 :=
                          Data (At_Byte + 2 + B.Byte_Count (Index));
                     begin
                        Weights (Row) (Index) :=
                          Interfaces.Integer_16
                            (if U < 128 then Integer (U)
                             else Integer (U) - 256);
                     end;
                  end loop;
               end;
            end loop;

            for Which in 0 .. Count - 1 loop
               declare
                  At_Value : constant Element_Count :=
                    First + Which * Stride + Block * Activation_Block;
                  At_Scale : constant Element_Count :=
                    At_Value / Activation_Block;
                  Scaled   : constant N.Real :=
                    Scales (Scales'First + At_Scale);
               begin
                  for Index in Block_Range loop
                     Active (Index) :=
                       Interfaces.Integer_16
                         (Values (Values'First + At_Value + Index));
                  end loop;

                  for Row in 0 .. Rows - 1 loop
                     declare
                        Product : Interfaces.Integer_32 := 0;
                     begin
                        for Index in Block_Range loop
                           Product := Product
                             + Interfaces.Integer_32 (Weights (Row) (Index))
                               * Interfaces.Integer_32 (Active (Index));
                        end loop;

                        Sums (Sums'First + Row * Count + Which) :=
                          Sums (Sums'First + Row * Count + Which)
                          + N.Wide_Real
                              (N.Real (Product) * Scaling (Row) * Scaled);
                     end;
                  end loop;
               end;
            end loop;
         end loop;
      end;

      if Totals'Length = 0 then
         return;
      end if;

      Ok := True;
   end Rows;

end Model_Runner.Quantization.Integers.Kernels;
