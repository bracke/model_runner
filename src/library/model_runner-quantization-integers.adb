with Model_Runner.Quantization.Integers.Deep;
with Model_Runner.Quantization.Integers.Plain;
with Model_Runner.Quantization.Integers.Wide;

package body Model_Runner.Quantization.Integers is

   --  Whether the wider compilation may be entered. Written by one task
   --  before the workers exist and read by all of them after, which is the
   --  protocol Model_Runner.Quantization states for its own such flag.
   Wider : Boolean := False;

   --  And whether the deepest one may be, which is a narrower promise: it
   --  needs the byte dot product and the whole of the instruction set that
   --  carries it.
   Deeper : Boolean := False;

   ---------------------
   -- Use_Wide_Rows --
   ---------------------

   procedure Use_Wide_Rows (Allowed : Boolean) is
   begin
      Wider := Allowed;
   end Use_Wide_Rows;

   --------------------
   -- Use_Deep_Rows --
   --------------------

   procedure Use_Deep_Rows (Allowed : Boolean) is
   begin
      Deeper := Allowed;
   end Use_Deep_Rows;

   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   use type Interfaces.Integer_32;
   use type G.Tensor_Type;
   use type N.Real;

   ------------------------
   -- Has_Integer_Kernel --
   ------------------------

   function Has_Integer_Kernel
     (Format : Model_Runner.GGUF.Tensor_Type) return Boolean
   is (Format = G.Type_Q8_0 or else Format = G.Type_Q4_K);

   --------------------
   -- Packs_Vectors --
   --------------------

   function Packs_Vectors
     (Format : Model_Runner.GGUF.Tensor_Type;
      Count  : Element_Count) return Boolean
   is (Has_Integer_Kernel (Format)
       and then (Format /= G.Type_Q4_K
                 or else Count = 1
                 or else Count >= 4));

   ----------------------
   -- Quantize_Vectors --
   ----------------------

   procedure Quantize_Vectors
     (Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Element_Count;
      Columns : Element_Count;
      Values  : out Signed_Array;
      Scales  : out Model_Runner.Numerics.Real_Array;
      Totals  : out Sum_Array;
      Ok      : out Boolean)
   is
      Elements : constant Element_Count :=
        (if Count > 0 and then Columns > 0 then Count * Columns else 0);
      Blocks   : constant Element_Count := Elements / Activation_Block;
   begin
      Ok := False;

      if Count = 0
        or else not Is_Packable (Columns)
        or else Vectors'Length < Elements
        or else Values'Length < Elements
        or else Scales'Length < Blocks
        or else Totals'Length < Blocks
      then
         return;
      end if;

      --  Two passes over a block: the largest magnitude, then the rounding.
      --  Every index below is inside the lengths proved above, which is what
      --  lets the rounding loop run without a check per element.
      for Block in 0 .. Blocks - 1 loop
         declare
            pragma Suppress (Index_Check);
            pragma Suppress (Range_Check);
            pragma Suppress (Overflow_Check);

            At_Element : constant Element_Count :=
              Block * Activation_Block;
            Largest    : N.Real := 0.0;
            Scale      : N.Real;
            Inverse    : N.Real;
            Total      : Interfaces.Integer_32 := 0;
         begin
            for Index in 0 .. Element_Count (Activation_Block) - 1 loop
               declare
                  Value : constant N.Real :=
                    Vectors (Vectors'First + At_Element + Index);
               begin
                  --  A block holding anything that is not finite has no
                  --  nearest byte. Refusing here rather than clamping is
                  --  what keeps the caller's own finiteness checks the
                  --  place such a value is reported.
                  if not N.Is_Finite (Value) then
                     return;
                  end if;
                  if abs Value > Largest then
                     Largest := abs Value;
                  end if;
               end;
            end loop;

            Scale := Largest / 127.0;
            Inverse := (if Scale > 0.0 then 1.0 / Scale else 0.0);
            Scales (Scales'First + Block) := Scale;

            for Index in 0 .. Element_Count (Activation_Block) - 1 loop
               declare
                  Scaled : constant N.Real :=
                    Vectors (Vectors'First + At_Element + Index) * Inverse;

                  --  Rounded to nearest with ties away from zero, which is
                  --  what Ada's rounding attribute does, and clamped: the
                  --  scale is the largest magnitude over 127, so nothing
                  --  should reach 128, and the clamp is what makes that a
                  --  fact about the code rather than about the arithmetic.
                  Whole  : constant Integer :=
                    Integer'Max (-128,
                                 Integer'Min (127, Integer (N.Real'Rounding
                                                              (Scaled))));
               begin
                  Values (Values'First + At_Element + Index) :=
                    Byte_Signed (Whole);
                  Total := Total + Interfaces.Integer_32 (Whole);
               end;
            end loop;

            Totals (Totals'First + Block) := Total;
         end;
      end loop;

      Ok := True;
   end Quantize_Vectors;

   ----------------------
   -- Accumulate_Rows --
   ----------------------

   procedure Accumulate_Rows
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
      Ok        : out Boolean) is
   begin
      --  One source, three compilations, and the host decides which. Each
      --  is entered only where the host says it has the instructions, which
      --  it is asked once and told here rather than reading a machine
      --  itself: this package interprets what a model file holds and may not
      --  reach a host.
      --
      --  Deepest first, because the deeper promise implies the wider one.
      if Deeper then
         Deep.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, First, Stride, Count, Sums, Ok);
      elsif Wider then
         Wide.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, First, Stride, Count, Sums, Ok);
      else
         Plain.Rows
           (Format, Data, Offset, Row_Bytes, Rows, Blocks, Values, Scales,
            Totals, First, Stride, Count, Sums, Ok);
      end if;
   end Accumulate_Rows;

end Model_Runner.Quantization.Integers;
