with Model_Runner.Numerics;

--  Portable scalar reference kernels.
--
--  These are the definition of what this crate computes. Any optimized kernel
--  added later has to agree with them within a documented tolerance, and the
--  differential tests compare against them. They stay available and reachable
--  after such a kernel exists, so a numerical disagreement can always be
--  bisected against a known-good implementation.
--
--  Numerical contract. Element-wise operations accumulate in Real. Reductions
--  whose length grows with a model dimension accumulate in Wide_Real and round
--  to Real once, at the end, so the result does not depend on how the input
--  was partitioned between workers.
--
--  Aliasing. No operation here permits Target to overlap an input other than
--  where the signature says the operation is in place. Residual additions are
--  in place by design and are documented as such.
--
--  Task safety: every operation is a pure function of its arguments plus its
--  output, so disjoint slices may be computed concurrently.
package Model_Runner.Kernels is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Wide_Real is Model_Runner.Numerics.Wide_Real;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   --  Add Addend into Target element-wise.
   --
   --  This is the residual addition. Target is both an input and the output,
   --  which is the intended aliasing.
   --
   --  @param Target Accumulator, updated in place.
   --  @param Addend Values to add; must have Target's length.
   procedure Add (Target : in out Real_Array; Addend : Real_Array);

   --  Multiply Target by Factor element-wise.
   --
   --  @param Target Accumulator, updated in place.
   --  @param Factor Values to multiply by; must have Target's length.
   procedure Multiply (Target : in out Real_Array; Factor : Real_Array);

   --  Multiply Target by a scalar.
   --
   --  @param Target Values to scale, updated in place.
   --  @param Factor Scalar factor.
   procedure Scale (Target : in out Real_Array; Factor : Real);

   --  Dot product of two vectors.
   --
   --  Accumulates in Wide_Real and rounds once.
   --
   --  @param Left Left vector.
   --  @param Right Right vector; must have Left's length.
   --  @return Dot product, or 0.0 when the lengths differ.
   function Dot (Left, Right : Real_Array) return Real;

   --  Dot product of one span out of each of two vectors, for the attention
   --  scores: a query head against a key row.
   --
   --  Accumulates in Real rather than Wide_Real, over eight lanes at a time
   --  where the host has them, which is why it is not Dot above. Dot is the
   --  exact one and rounds once; this one is what the attention scores are
   --  measured against the sweep's bound in, and is what the device has
   --  always computed them in.
   --
   --  Why this is not written as Ada. The shape is a reduction, and a
   --  reduction is the one shape GNAT will not vectorize at -O3 however it
   --  is written: the value blend beside this in the evaluator, which is a
   --  map, comes out as mulpd and addpd, and this came out as mulsd and
   --  addsd. Written as eight independent lanes -- a map by construction --
   --  it still came out as eight scalar chains, and renaming the operands
   --  into slices so the addresses were plainly contiguous did not change
   --  one instruction. This loop is a quarter of a processor prompt.
   --
   --  @param Left Vector the left span is taken from.
   --  @param At_Left First index of the left span.
   --  @param Right Vector the right span is taken from.
   --  @param At_Right First index of the right span.
   --  @param Span Length of both spans.
   --  @return The dot product, or 0.0 when either span leaves its vector.
   function Head_Dot
     (Left     : Real_Array;
      At_Left  : Element_Count;
      Right    : Real_Array;
      At_Right : Element_Count;
      Span     : Element_Count) return Real;

   --  A run of one head's attention scores: a query against many keys.
   --
   --  Scores (At_Score + j) becomes the dot product of the query head with
   --  key row j, times Scale, for j in 0 .. Steps - 1. Key rows are Stride
   --  elements apart, which is the cache's width rather than the head's.
   --
   --  Why this exists when Head_Dot already computes one of these. Head_Dot
   --  ends every dot product with a horizontal fold -- extract the high
   --  half, add, two pairwise adds, move out -- and that fold is a serial
   --  chain of about twenty cycles standing behind eight fused
   --  multiply-adds worth eight. Removing it entirely, which gives wrong
   --  answers, takes four per cent off a 1419-token prompt, so it is worth
   --  about that much to stop paying it once a score.
   --
   --  Eight keys at a time is what stops it. Eight accumulators, one a key,
   --  and the whole query head held in eight more registers across all of
   --  them: a key then costs eight fused multiply-adds reading it where it
   --  lies and nothing else, and the eight folds become one twelve
   --  instruction reduction of all eight accumulators together. The query
   --  is loaded once for the run rather than once a score.
   --
   --  Bit for bit with Head_Dot it is not, and cannot be: a lane's products
   --  are summed in the same order but the eight lanes are folded in a
   --  different one. The conformance sweep is what decides about that, as
   --  it did for Head_Dot itself.
   --
   --  A run shorter than eight keys, or a head that is not sixty-four wide,
   --  goes to Head_Dot a score at a time -- which is what every host
   --  without the wide lanes does with all of them.
   --
   --  @param Query Vector the query head is taken from.
   --  @param At_Query Index of the head's first component.
   --  @param Keys Vector the key rows are taken from.
   --  @param At_Key Index of the first key row's first component.
   --  @param Stride Elements between one key row and the next.
   --  @param Steps How many keys.
   --  @param Span Width of the head.
   --  @param Scale Multiplied into every score.
   --  @param Scores Receives the run.
   --  @param At_Score Index of the first score.
   procedure Head_Scores
     (Query    : Real_Array;
      At_Query : Element_Count;
      Keys     : Real_Array;
      At_Key   : Element_Count;
      Stride   : Element_Count;
      Steps    : Element_Count;
      Span     : Element_Count;
      Scale    : Real;
      Scores   : in out Real_Array;
      At_Score : Element_Count);

   --  One run of an attention head's output: a span of components summed
   --  over a span of positions, each position's values scaled by its score.
   --
   --  Sums is added to rather than set, so a caller that wants only these
   --  positions starts it at zero. Values holds one position's components
   --  contiguously and Stride is how far apart two positions are; Weights
   --  holds one score a position, contiguously.
   --
   --  Why this is not written as Ada either, and it is not the reason
   --  Head_Dot is. This shape is a map and -O3 does vectorize it, eight
   --  lanes of mulps and addps. What it cannot do is keep Sums in
   --  registers across the positions, because Sums is an array the loop
   --  writes: so every position pays a load and a store of the whole run
   --  as well as its arithmetic, five instructions where the arithmetic is
   --  two. A run of sixty-four components is eight registers, and held
   --  there a position costs one broadcast and eight fused multiply-adds
   --  reading the values where they lie -- nine instructions against
   --  forty.
   --
   --  The multiply and the add are fused, so a product is rounded once
   --  where the portable form rounds it twice. That is the more accurate
   --  of the two and it is still a different answer, which the conformance
   --  sweep is what decides about.
   --
   --  @param Sums Run of sums, added to in place.
   --  @param Weights Vector the scores are taken from.
   --  @param At_Weight Index of the first position's score.
   --  @param Values Vector the values are taken from.
   --  @param At_Value Index of the first position's first component.
   --  @param Stride Elements between one position's values and the next's.
   --  @param Steps How many positions.
   procedure Blend_Run
     (Sums      : in out Real_Array;
      Weights   : Real_Array;
      At_Weight : Element_Count;
      Values    : Real_Array;
      At_Value  : Element_Count;
      Stride    : Element_Count;
      Steps     : Element_Count);

   --  Every element of a run replaced by e raised to it, less a constant.
   --
   --  Target (i) becomes exp (Target (i) - Less), which is the shape a
   --  softmax wants: the largest score subtracted so that nothing overflows
   --  and the largest term is one.
   --
   --  Why this is here rather than a call to the library's exponential. A
   --  softmax over an attention row calls that once an element, and a
   --  processor prompt is heads times positions times positions of them: a
   --  profile puts the exponential and the softmax around it at eight and a
   --  half per cent of a 1419-token prompt, nearly all of it inside
   --  __ieee754_exp. One call cannot be vectorized and this shape can --
   --  it is a map, every element independent of every other, which is what
   --  -O3 turns into eight lanes without being asked.
   --
   --  What replaces the call is the standard decomposition: e^x is two
   --  raised to x over the natural logarithm of two, split into a whole
   --  part done by building an exponent and a fraction done by a degree
   --  five polynomial. It is computed in binary32, where the library's is
   --  binary64, and both of those change the answer -- which is what the
   --  conformance sweep is for, as it was for the two insertions above.
   --
   --  The floor at eighty-eight is not a nicety. Below it the true value is
   --  smaller than binary32 holds, and the exponent this builds would wrap
   --  rather than saturate, so a score far behind the leader would come
   --  back as a large number instead of nothing at all.
   --
   --  @param Target Run to replace in place.
   --  @param Less Subtracted from every element before the exponential.
   procedure Exponentiate (Target : in out Real_Array; Less : Real);

   --  Whether Head_Dot and Blend_Run above may use the wide lanes and the
   --  fused multiply-add, which is a fraction of the instructions for the
   --  same arithmetic.
   --
   --  It is told rather than asked, for the reason Quantization's
   --  Use_Wide_Decoders is told: this package interprets what a model file
   --  holds and may not reach a host. The backend that runs it asks and
   --  says so here, once, before any model is read. A caller that never
   --  says leaves both on the loops they had before this existed.
   --
   --  @param Allowed True where the host has the wider instructions.
   procedure Use_Wide_Lanes (Allowed : Boolean);

   --  Root-mean-square normalization with a per-element gain.
   --
   --  Computes Target (i) = Source (i) / sqrt (mean of squares + Epsilon)
   --  multiplied by Weight (i). The mean of squares accumulates in Wide_Real,
   --  which keeps the result stable for the embedding widths this crate
   --  supports.
   --
   --  @param Source Input vector.
   --  @param Weight Per-element gain; must have Source's length.
   --  @param Epsilon Positive stabilizer from the model metadata.
   --  @param Target Output vector; must have Source's length. May alias
   --    Source.
   --  @param Lifted Take the gain as one plus the stored weight rather than
   --    as the weight. Gemma trains its normalization weights around zero
   --    where every other architecture here trains them around one, so a
   --    file read the wrong way is scaled by roughly nothing and answers
   --    nonsense rather than refusing. A parameter rather than a second
   --    kernel, and rather than adding one to the weights at load: the
   --    weights are the file's own bytes, mapped read-only, and this program
   --    does not write to a model.
   procedure RMS_Norm
     (Source  : Real_Array;
      Weight  : Real_Array;
      Epsilon : Real;
      Target  : out Real_Array;
      Lifted  : Boolean := False);

   --  Layer normalization: centre, scale, then gain and bias.
   --
   --  Not the root-mean-square normalization above with extra steps. That
   --  one divides by the root mean square and leaves the mean where it is;
   --  this one subtracts the mean first, divides by the standard deviation,
   --  and adds a bias afterwards. A model trained with one and read with the
   --  other answers, and answers wrongly.
   --
   --  Falcon and the models shaped like it use this. Everything else here
   --  uses the root-mean-square form, which is why that one is the default
   --  and this one is asked for.
   --
   --  @param Source Values to normalize.
   --  @param Weight Gain, one per element.
   --  @param Bias Added after the gain, one per element.
   --  @param Epsilon Added to the variance before the square root.
   --  @param Target Receives the result; zeroed when the lengths disagree.
   procedure Layer_Norm
     (Source  : Real_Array;
      Weight  : Real_Array;
      Bias    : Real_Array;
      Epsilon : Real;
      Target  : out Real_Array);

   --  Softmax over a vector, in place.
   --
   --  The maximum is subtracted before exponentiation. A non-finite input, a
   --  non-finite sum or a zero sum is reported through Ok rather than
   --  producing a silently meaningless distribution.
   --
   --  @param Target Values to normalize, updated in place.
   --  @param Ok True when the result is a usable distribution.
   procedure Softmax (Target : in out Real_Array; Ok : out Boolean);

   --  SiLU activation, in place: x multiplied by the logistic of x.
   --
   --  @param Target Values to activate, updated in place.
   procedure SiLU (Target : in out Real_Array);

   --  Gaussian error unit, in place, in the form the models that want it
   --  were trained with.
   --
   --  The exact function is x times the normal distribution's cumulative
   --  value at x, which needs an error function; what every implementation
   --  of these models uses instead is the hyperbolic-tangent approximation
   --  below, and a model trained against that approximation wants that
   --  approximation rather than the exact function it approximates.
   --
   --  It is close to SiLU and not close enough: the two differ by about a
   --  hundredth of the input at its worst, which is a model that answers
   --  plausibly and not the same way twice.
   --
   --  @param Target Values to transform, updated in place.
   procedure GELU (Target : in out Real_Array);

   --  How a head's elements are paired for the rotation.
   --
   --  Interleaved rotates element 2i against element 2i + 1 within a head,
   --  which is what a Llama file's weights are laid out for. Split rotates
   --  element i against element i + Rotary / 2, which is what a Qwen2
   --  file's are. Both are the same rotation by the same angle over
   --  different elements, and a model rotated the wrong way writes
   --  grammatical sentences that do not mean what it meant -- which is how
   --  this came to be told apart.
   type Rotary_Pairing is (Interleaved, Split);

   --  How a model stretches the rotation to reach past the context it was
   --  trained on.
   --
   --  Unscaled is the rotation as trained. Linear divides every position by
   --  the factor, which reaches further at the cost of resolution between
   --  neighbouring positions everywhere. Yarn divides the low frequencies,
   --  which carry position over long distances, and leaves the high ones --
   --  which tell neighbours apart -- alone, ramping between the two across a
   --  band of dimensions; it also scales the rotated vector, because
   --  interpolating the angles shrinks the attention scores they produce.
   type Rotary_Scaling_Kind is (Unscaled, Linear, Yarn);

   --  Everything the rotation needs about that stretch.
   --
   --  Frequency is the reciprocal of the factor the file states, so 0.25 is
   --  a model stretched fourfold. Original is the context the model was
   --  trained on, which is what the band of ramped dimensions is derived
   --  from. Beta_Fast and Beta_Slow name that band by how many turns a
   --  dimension makes over the original context: dimensions faster than
   --  Beta_Fast are left as trained, dimensions slower than Beta_Slow are
   --  fully interpolated, and the rest are mixed. Attenuation is the file's
   --  own multiplier on the rotated vector.
   --
   --  The defaults are a model that says nothing, which is the rotation as
   --  trained.
   type Rotary_Scaling is record
      Kind        : Rotary_Scaling_Kind := Unscaled;
      Frequency   : Wide_Real := 1.0;
      Original    : Natural := 0;
      Beta_Fast   : Wide_Real := 32.0;
      Beta_Slow   : Wide_Real := 1.0;
      Attenuation : Wide_Real := 1.0;
   end record;

   No_Scaling : constant Rotary_Scaling := (others => <>);

   --  Per-dimension divisors for the rotation's frequencies, when a model
   --  carries them. A model that does not is every element one.
   No_Factors : constant Real_Array (1 .. 0) := [others => 0.0];

   --  Rotary positional encoding, in place.
   --
   --  Elements beyond Rotary are left unchanged.
   --
   --  @param Vector Head-major vector holding Heads heads of Head_Size
   --    elements each, updated in place.
   --  @param Heads Number of heads in Vector.
   --  @param Head_Size Elements per head.
   --  @param Rotary Number of leading elements per head to rotate; must be
   --    even and at most Head_Size.
   --  @param Position Absolute token position.
   --  @param Base RoPE frequency base from the model metadata.
   --  @param Scaling How the model stretches the rotation, if it does.
   --  @param Factors One divisor per rotated pair, indexed from its own
   --    first element, or an empty array when the model carries none. A
   --    wrong length is ignored rather than applied part way.
   --  @param Pairing Which elements of a head are rotated against which.
   --  @param Backwards Rotate the other way, by the same angle.
   --
   --    What it is for is moving a key that was rotated at one position to
   --    another: the angle is linear in the position, so undoing a shift of
   --    N positions is a rotation by the angle N stands for, the other way
   --    round. A context that drops its oldest tokens and slides the rest
   --    down needs exactly that, and without it the keys would describe
   --    positions the text no longer has.
   procedure Apply_Rotary
     (Vector          : in out Real_Array;
      Heads           : Element_Count;
      Head_Size       : Element_Count;
      Rotary          : Element_Count;
      Position        : Natural;
      Base            : Wide_Real;
      Scaling         : Rotary_Scaling := No_Scaling;
      Factors         : Real_Array := No_Factors;
      Pairing         : Rotary_Pairing := Interleaved;
      Backwards       : Boolean := False);

   --  Report whether every element is finite.
   --
   --  @param Item Values to test.
   --  @return True when no element is infinite or NaN.
   function All_Finite (Item : Real_Array) return Boolean;

end Model_Runner.Kernels;
