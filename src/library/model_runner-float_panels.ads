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

   --  Lay out in panels a matrix already in binary32: its element at row
   --  R, column K is Source (From + R * Row_Step + K * Column_Step), so a
   --  matrix read across its rows is packed as readily as one read down
   --  its columns -- an attention head's keys, and its values turned. The
   --  set's memory is kept where it is large enough; the panels are laid
   --  out across Team.
   --
   --  @param Team Tasks to share the panels out across, or null.
   --  @param Source The elements.
   --  @param From The first element's index.
   --  @param Rows The matrix's rows: the answers a vector makes.
   --  @param Columns Its columns: the elements a vector holds.
   --  @param Row_Step Elements from one row's element to the next row's.
   --  @param Column_Step Elements from one column's to the next.
   --  @param Into Receives the panels.
   --  @param Status Success, or the allocation failing or a shape of none.
   procedure Pack
     (Team        : Model_Runner.Shares.Team_Access;
      Source      : Model_Runner.Numerics.Real_Array;
      From        : Element_Count;
      Rows        : Element_Count;
      Columns     : Element_Count;
      Row_Step    : Element_Count;
      Column_Step : Element_Count;
      Into        : in out Panel_Set;
      Status      : out Model_Runner.Errors.Error_Info);

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

   --  The same, the vectors and the answers where they lie inside wider
   --  rows: vector i from Vectors (Vectors_From + i * Vector_Step), its
   --  answers into Target (Target_From + i * Target_Step) on.
   --
   --  @param Team Tasks to share the tiles out across, or null.
   --  @param Item A packed set.
   --  @param Vectors The vectors.
   --  @param Vectors_From The first vector's first element.
   --  @param Vector_Step Elements from one vector to the next.
   --  @param Count How many vectors.
   --  @param Target Receives the answers.
   --  @param Target_From Where the first vector's go.
   --  @param Target_Step Elements from one vector's answers to the next's.
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
