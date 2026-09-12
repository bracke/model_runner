--  The rule's kernel, compiled more than once.
--
--  The body here is the whole of what a chunk of the gated delta rule
--  costs a head, and it is a generic for one reason: so that the same
--  source can be built twice, once for the instruction set every x86-64
--  has and once for a wider one, and the host asked at run time which of
--  them it may enter. Wider is not read by the body -- the compiler's
--  target does the work, a row of the state being eight lanes rather than
--  four -- and is here so that the two instantiations are two units.
--
--  Task safety: pure procedure on caller-supplied buffers, no state.
private generic
   Wider : Boolean := False;
package Model_Runner.Delta_Rule.Kernel is

   --  Model_Runner.Delta_Rule.Chunk and nothing else; what each parameter
   --  means is written out there once.
   --
   --  @param State Every state of the session.
   --  @param From Origin of this head's state the chunk begins with.
   --  @param Written Origin of this head's state each position leaves.
   --  @param Head State size.
   --  @param Count Positions in the chunk.
   --  @param Mixed The projected rows.
   --  @param Stride Distance between positions' rows in Mixed.
   --  @param Key_At Origin of the key within the first position's row.
   --  @param Query_At Origin of the query within it.
   --  @param Value_At Origin of the value within it.
   --  @param Decay The decay a position.
   --  @param Rate The rate a position.
   --  @param Z_Gate The gate rows.
   --  @param Z_At Origin of the head's gate in the first position's row.
   --  @param Z_Stride Distance between positions' rows in Z_Gate.
   --  @param Blend Where the answers go.
   --  @param Blend_At Origin of the head's answer in the first row.
   --  @param Blend_Stride Distance between positions' rows in Blend.
   --  @param State_Norm The gain a dimension of the answer.
   --  @param Epsilon The normalization's stabilizer.
   --  @param Scale What the answer is scaled by.
   procedure Chunk
     (State        : in out Real_Array;
      From         : Element_Count;
      Written      : Slot_Origins;
      Head         : Element_Count;
      Count        : Element_Count;
      Mixed        : Real_Array;
      Stride       : Element_Count;
      Key_At       : Element_Count;
      Query_At     : Element_Count;
      Value_At     : Element_Count;
      Decay        : Real_Array;
      Rate         : Real_Array;
      Z_Gate       : Real_Array;
      Z_At         : Element_Count;
      Z_Stride     : Element_Count;
      Blend        : in out Real_Array;
      Blend_At     : Element_Count;
      Blend_Stride : Element_Count;
      State_Norm   : Real_Array;
      Epsilon      : Real;
      Scale        : Real);

end Model_Runner.Delta_Rule.Kernel;
