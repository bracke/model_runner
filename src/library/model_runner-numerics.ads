with Interfaces;

--  Project numeric types and IEEE half-precision conversion.
--
--  The predefined Float is never used for model data. Real is the storage and
--  compute element format and is required to be IEEE binary32; Wide_Real is
--  the accumulation format for reductions that need more headroom than
--  binary32 provides, and is required to be IEEE binary64. Both requirements
--  are checked at compile time below, so a host whose representation differs
--  fails to build rather than producing silently different numbers.
--
--  Accumulation policy. Element-wise operations accumulate in Real. Sums whose
--  length grows with a model dimension -- RMS normalization, softmax
--  normalization, dot products used by attention -- accumulate in Wide_Real
--  and are rounded to Real once, at the end. This is documented per kernel in
--  Model_Runner.Kernels.
--
--  Task safety: all operations are pure functions on scalars.
package Model_Runner.Numerics is
   pragma Pure;

   --  Derived rather than subtypes so that arithmetic operators are directly
   --  visible to every client without a use clause, and so that a conversion
   --  between the compute and accumulation formats has to be written out.
   type Real is new Interfaces.IEEE_Float_32;
   type Wide_Real is new Interfaces.IEEE_Float_64;

   pragma Compile_Time_Error
     (Real'Size /= 32, "Real must be IEEE binary32");
   pragma Compile_Time_Error
     (Wide_Real'Size /= 64, "Wide_Real must be IEEE binary64");

   --  Raw IEEE binary16 bit pattern. Half is a storage encoding, not an
   --  arithmetic type: values are converted to Real before any computation.
   type Half is new Interfaces.Unsigned_16;

   --  Number of elements in a tensor or buffer. Wide enough that a tensor
   --  element count derived from a 64-bit GGUF dimension cannot silently wrap.
   type Element_Count is range 0 .. 2 ** 44;
   subtype Element_Index is Element_Count;

   type Real_Array is array (Element_Index range <>) of Real;
   type Wide_Real_Array is array (Element_Index range <>) of Wide_Real;

   --  Decode an IEEE binary16 value exactly.
   --
   --  Zeros keep their sign, subnormals are normalized without loss,
   --  infinities and NaNs are preserved including the NaN payload's leading
   --  bits. Every binary16 value is representable in binary32, so the
   --  conversion is exact and never rounds.
   --
   --  Inlined because it is called once per element of every half-precision
   --  tensor, and a call there costs several times the conversion itself:
   --  the compiler emitted one call per element and the format decoded at a
   --  fifth of the speed of the others until this aspect was added.
   --
   --  @param Item Half-precision bit pattern.
   --  @return Exactly equal single-precision value.
   function To_Real (Item : Half) return Real
     with Inline;

   --  Encode a value as IEEE binary16 with round-to-nearest-even.
   --
   --  Values above the binary16 range become infinity with the sign of Item,
   --  values below the subnormal range become a signed zero, and NaN stays
   --  NaN. Used by tests and by any future half-precision cache format; the
   --  V1 KV cache stores Real.
   --
   --  @param Item Single-precision value.
   --  @return Nearest half-precision bit pattern.
   function To_Half (Item : Real) return Half;

   --  Reinterpret a value as its IEEE bit pattern.
   --
   --  @param Item Value to inspect.
   --  @return Raw 32-bit encoding.
   function Bits (Item : Real) return Interfaces.Unsigned_32;

   --  Reinterpret an IEEE bit pattern as a value.
   --
   --  @param Item Raw 32-bit encoding.
   --  @return Encoded value.
   function From_Bits (Item : Interfaces.Unsigned_32) return Real;

   --  Reinterpret a wide value as its IEEE bit pattern.
   --
   --  @param Item Value to inspect.
   --  @return Raw 64-bit encoding.
   function Wide_Bits (Item : Wide_Real) return Interfaces.Unsigned_64;

   --  Reinterpret an IEEE bit pattern as a wide value.
   --
   --  @param Item Raw 64-bit encoding.
   --  @return Encoded value.
   function Wide_From_Bits (Item : Interfaces.Unsigned_64) return Wide_Real;

   --  Report whether a value is neither infinite nor NaN.
   --
   --  Implemented on the bit pattern so that it never raises and never
   --  depends on the host's floating-point exception configuration.
   --
   --  @param Item Value to test.
   --  @return True when Item is finite.
   function Is_Finite (Item : Real) return Boolean;

   --  Report whether a value is NaN.
   --
   --  @param Item Value to test.
   --  @return True when Item is a quiet or signalling NaN.
   function Is_NaN (Item : Real) return Boolean;

   --  Report whether a wide value is neither infinite nor NaN.
   --
   --  @param Item Value to test.
   --  @return True when Item is finite.
   function Is_Finite (Item : Wide_Real) return Boolean;

   --  Exponential function used by softmax, evaluated in the wide format.
   --
   --  @param Item Exponent.
   --  @return e raised to Item, or 0.0 when Item underflows the format.
   function Exp (Item : Wide_Real) return Wide_Real;

   --  Square root used by RMS normalization, evaluated in the wide format.
   --
   --  @param Item Non-negative value.
   --  @return Square root of Item; 0.0 when Item is negative or not finite.
   function Sqrt (Item : Wide_Real) return Wide_Real;

   --  Cosine used by rotary positional encoding.
   --
   --  @param Item Angle in radians.
   --  @return Cosine of Item.
   function Cos (Item : Wide_Real) return Wide_Real;

   --  Sine used by rotary positional encoding.
   --
   --  @param Item Angle in radians.
   --  @return Sine of Item.
   function Sin (Item : Wide_Real) return Wide_Real;

   --  Power function used to derive rotary frequencies.
   --
   --  @param Base Positive base.
   --  @param Exponent Exponent.
   --  @return Base raised to Exponent; 0.0 when Base is not positive.
   function Power (Base, Exponent : Wide_Real) return Wide_Real;

   --  Natural logarithm used by rotary scaling configurations.
   --
   --  @param Item Positive value.
   --  @return Natural logarithm of Item; 0.0 when Item is not positive.
   function Log (Item : Wide_Real) return Wide_Real;

end Model_Runner.Numerics;
