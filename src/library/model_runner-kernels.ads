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
   procedure RMS_Norm
     (Source  : Real_Array;
      Weight  : Real_Array;
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
   procedure Apply_Rotary
     (Vector          : in out Real_Array;
      Heads           : Element_Count;
      Head_Size       : Element_Count;
      Rotary          : Element_Count;
      Position        : Natural;
      Base            : Wide_Real;
      Scaling         : Rotary_Scaling := No_Scaling;
      Factors         : Real_Array := No_Factors;
      Pairing         : Rotary_Pairing := Interleaved);

   --  Report whether every element is finite.
   --
   --  @param Item Values to test.
   --  @return True when no element is infinite or NaN.
   function All_Finite (Item : Real_Array) return Boolean;

end Model_Runner.Kernels;
