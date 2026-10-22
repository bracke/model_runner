with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Shares;
with Model_Runner.Tensors;

--  A weight laid out for multiplying many vectors at once, in binary32, on
--  the processor.
--
--  The engine's float products walk a row of weights against four vectors
--  at a time, which is right where a token reads a matrix once and the
--  reading is the cost. A picture's decoder is the other case: thousands of
--  pixels against each matrix, and the arithmetic is the cost. Those
--  products ran at 114 GF/s on the eight cores the processor has, where the
--  multiply-add units can do some 850. What they lacked was the shape the
--  arithmetic wants: answers held in registers across a run of the inner
--  dimension, and weights read in the order the registers take them.
--
--  So the weight is laid out again, once: its rows cut into panels of
--  Width, and each panel stored column by column, the Width weights of one
--  column side by side -- what one pair of the widest registers holds. A
--  tile of answers, six vectors by one panel, sums in twelve registers
--  while the column walks, and is written once a block of the inner
--  dimension is done. The vectors are read in place, a block of the inner
--  dimension at a time, so the six a tile reads stay in the first-level
--  cache while the panel's block sits in the second.
--
--  Three kernels compute the tile: the widest registers where the
--  processor has them, the wide ones where it has only those, and plain
--  code otherwise. Each sums every answer over the inner dimension in its
--  order, one multiply-add at a time, so they differ from each other only
--  in whether a multiply and an add are fused.
--
--  Task safety: Pack writes the set it is given; Multiply reads the set and
--  the vectors and writes each answer from one task only.
package Model_Runner.Float_Panels is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   --  Rows of the weight a panel holds.
   Width : constant := 32;

   --  A weight laid out in panels, or nothing.
   type Panel_Set is private;

   --  The kernels a tile can be computed with, narrowest first.
   type Kernel_Kind is (Plain, Wide, Widest);

   --  Lay Weight out in panels into Into, which is freed first.
   --
   --  @param Weight The matrix, any format a row of can be decoded from.
   --  @param Into Receives the panels.
   --  @param Status Success, or the allocation or a row's decoding failing.
   procedure Pack
     (Weight : Model_Runner.Tensors.View;
      Into   : in out Panel_Set;
      Status : out Model_Runner.Errors.Error_Info);

   --  Give back what Pack took. Nothing to give back is not an error.
   --
   --  @param Item The set.
   procedure Free (Item : in out Panel_Set);

   --  Report whether a set holds a weight.
   --
   --  @param Item The set.
   --  @return True after a successful Pack and before Free.
   function Is_Packed (Item : Panel_Set) return Boolean;

   --  Target := the weight times each of Count vectors: Target's vector i
   --  is Rows answers from Target (i * Rows), where Rows are the weight's
   --  own; the vectors are Columns each from Vectors (0). Across Team's
   --  tasks, or on this one where Team is null or declines.
   --
   --  @param Team Tasks to share the tiles out across, or null.
   --  @param Item A packed set.
   --  @param Vectors Count vectors of the weight's columns, from index 0.
   --  @param Count How many vectors.
   --  @param Target Receives Count vectors of the weight's rows, from
   --    index 0.
   procedure Multiply
     (Team    : Model_Runner.Shares.Team_Access;
      Item    : Panel_Set;
      Vectors : Model_Runner.Numerics.Real_Array;
      Count   : Element_Count;
      Target  : in out Model_Runner.Numerics.Real_Array)
   with Pre => Is_Packed (Item);

   --  Choose the kernel. The processor's backend asks the host once and
   --  sets the widest it has; a test sets each in turn, so every kernel is
   --  checked on a host that has the widest.
   --
   --  @param Kind The kernel; one the host lacks would fault.
   procedure Use_Kernel (Kind : Kernel_Kind);

   --  The kernel in use.
   --
   --  @return What Use_Kernel last set; Plain before.
   function Kernel return Kernel_Kind;

private

   type Panel_Set is record
      Data    : Model_Runner.Tensors.Real_Array_Access;
      Rows    : Element_Count := 0;
      Columns : Element_Count := 0;
   end record;

end Model_Runner.Float_Panels;
