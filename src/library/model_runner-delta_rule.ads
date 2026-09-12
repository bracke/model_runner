with Model_Runner.Numerics;

--  The gated delta rule over a chunk of positions, for the linear layers
--  of a hybrid architecture.
--
--  A position's state is the one before decayed and corrected: S_t =
--  a_t S_(t-1) + k_t u_t', with u_t = b_t (v_t - a_t S_(t-1)' k_t), and
--  its answer is S_t' q_t. Unrolled over a chunk from the state S_0 it
--  began with, with g_t the product of the decays up to t and g_(s..t) the
--  product from s + 1 to t:
--
--    S_t = g_t S_0 + sum over s <= t of g_(s..t) k_s u_s'
--    u_s = b_s (v_s - g_s S_0' k_s - sum over r < s of g_(r..s) (k_r . k_s) u_r)
--    o_t = g_t S_0' q_t + sum over s <= t of g_(s..t) (k_s . q_t) u_s
--
--  So S_0 is read once for every key and query of the chunk, the
--  corrections come out of a triangle of the keys against each other, the
--  answers out of a triangle of the keys against the queries, and S_0 is
--  read once more and written once for the state the chunk leaves -- or
--  for every position's, where a rewind may ask for them, from one pass
--  over each row.
--
--  One source, two compilations, as the integer product has: the kernel
--  is a generic instantiated once for the instruction set every x86-64 has
--  and once for x86-64-v3, where a row of the state is eight lanes rather
--  than four, and the host is asked once which it may enter. Both are
--  compiled with floating-point contraction off, so the two answer bit for
--  bit. The rule is a few thousand rows scaled into running rows a head,
--  which is exactly what wider lanes are for: at the baseline it read 5.8
--  microseconds a head a position on Qwen3.5-0.8B, at the lane rate of
--  the loads and stores.
--
--  Task safety: pure procedures on caller-supplied buffers; the one flag
--  is set at elaboration, before any session.
package Model_Runner.Delta_Rule is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real is Model_Runner.Numerics.Real;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   use type Element_Count;

   --  How many positions a chunk takes at once. A chunk's work past the
   --  state is a few squares of this a head, on the stack of whichever
   --  task takes the head.
   Chunk_Most : constant := 32;

   --  Where each position of a chunk writes its state: the origin of the
   --  head's state in the slot, or Nowhere for a position whose state
   --  nobody will ask for again.
   Nowhere : constant Element_Count := Element_Count'Last;
   type Slot_Origins is
     array (Element_Count range 0 .. Chunk_Most - 1) of Element_Count;

   --  Allow the compilation built for the wider instruction set. Told
   --  once, by whoever has asked the host, before any rule is run.
   --
   --  @param Allowed True where the host has the x86-64-v3 instructions.
   procedure Use_Wide (Allowed : Boolean);

   --  The rule for one head over one chunk.
   --
   --  The state is Head by Head, key-major: row i holds S (i, j) for
   --  every j. The keys, queries and values of the chunk lie in Mixed,
   --  a position's row Stride apart, the key at Key_At and the query at
   --  Query_At and the value at Value_At within it; the gate likewise
   --  in Z_Gate, and the answers go to Blend, both Blend_Stride apart.
   --
   --  @param State Every state of the session; read at From and written
   --    at each of Written.
   --  @param From Origin of this head's state the chunk begins with.
   --  @param Written Origin of this head's state each position leaves,
   --    or Nowhere; the row read is read before any is written, so a
   --    slot written may be the slot read.
   --  @param Head State size, the width of a row.
   --  @param Count Positions in the chunk, at most Chunk_Most.
   --  @param Mixed The projected rows.
   --  @param Stride Distance between positions' rows in Mixed.
   --  @param Key_At Origin of the key within the first position's row.
   --  @param Query_At Origin of the query within it.
   --  @param Value_At Origin of the value within it.
   --  @param Decay The decay a position, Count of them.
   --  @param Rate The rate a position, Count of them.
   --  @param Z_Gate The gate rows.
   --  @param Z_At Origin of the head's gate in the first position's row.
   --  @param Z_Stride Distance between positions' rows in Z_Gate.
   --  @param Blend Where the answers go.
   --  @param Blend_At Origin of the head's answer in the first row.
   --  @param Blend_Stride Distance between positions' rows in Blend.
   --  @param State_Norm The gain a dimension of the answer, Head of them.
   --  @param Epsilon The normalization's stabilizer.
   --  @param Scale What the answer is scaled by before the normalization.
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

end Model_Runner.Delta_Rule;
