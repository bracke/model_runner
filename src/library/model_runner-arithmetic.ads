with Interfaces;

--  Checked unsigned arithmetic for values derived from untrusted model files.
--
--  Every offset addition, alignment rounding, element-count multiplication and
--  byte-size derivation performed while parsing a GGUF container flows through
--  this package. Overflow is never a run-time exception and never wraps: it is
--  carried in the result as Valid => False and propagates through further
--  operations, so a caller can perform a chain of computations and inspect
--  validity once at the end.
--
--  Task safety: all operations are pure functions on scalars.
package Model_Runner.Arithmetic is
   pragma Pure;

   subtype U64 is Interfaces.Unsigned_64;

   use type Interfaces.Unsigned_64;

   --  A 64-bit unsigned value together with the validity of the computation
   --  that produced it. Once Valid is False it stays False through every
   --  further operation, and Value is meaningless.
   type Checked is record
      Value : U64     := 0;
      Valid : Boolean := True;
   end record;

   --  The absorbing invalid value. Any operation involving it yields it.
   Invalid : constant Checked := (Value => 0, Valid => False);

   --  Wrap a known-good value.
   --
   --  @param Value Value to wrap.
   --  @return Checked value with Valid set.
   function To_Checked (Value : U64) return Checked
   is (Value => Value, Valid => True);

   --  Wrap a non-negative Ada integer.
   --
   --  @param Value Value to wrap.
   --  @return Checked value with Valid set.
   function To_Checked (Value : Natural) return Checked
   is (Value => U64 (Value), Valid => True);

   --  Report whether a checked computation succeeded.
   --
   --  @param Item Checked value to inspect.
   --  @return True when every operation in the chain stayed in range.
   function Is_Valid (Item : Checked) return Boolean
   is (Item.Valid);

   --  Return the value of a valid computation.
   --
   --  @param Item Checked value to read.
   --  @return Computed value; 0 when the computation overflowed.
   function Value (Item : Checked) return U64
   is (if Item.Valid then Item.Value else 0);

   --  Add two checked values, reporting unsigned overflow.
   --
   --  @param Left Left operand.
   --  @param Right Right operand.
   --  @return Sum, or Invalid on overflow or invalid input.
   function "+" (Left, Right : Checked) return Checked;

   --  Add a literal to a checked value.
   --
   --  @param Left Left operand.
   --  @param Right Right operand.
   --  @return Sum, or Invalid on overflow or invalid input.
   function "+" (Left : Checked; Right : U64) return Checked
   is (Left + To_Checked (Right));

   --  Subtract, reporting unsigned underflow.
   --
   --  @param Left Minuend.
   --  @param Right Subtrahend.
   --  @return Difference, or Invalid when Right exceeds Left.
   function "-" (Left, Right : Checked) return Checked;

   --  Subtract a literal, reporting unsigned underflow.
   --
   --  @param Left Minuend.
   --  @param Right Subtrahend.
   --  @return Difference, or Invalid when Right exceeds Left.
   function "-" (Left : Checked; Right : U64) return Checked
   is (Left - To_Checked (Right));

   --  Multiply two checked values, reporting unsigned overflow.
   --
   --  @param Left Left operand.
   --  @param Right Right operand.
   --  @return Product, or Invalid on overflow or invalid input.
   function "*" (Left, Right : Checked) return Checked;

   --  Multiply a checked value by a literal.
   --
   --  @param Left Left operand.
   --  @param Right Right operand.
   --  @return Product, or Invalid on overflow or invalid input.
   function "*" (Left : Checked; Right : U64) return Checked
   is (Left * To_Checked (Right));

   --  Divide, reporting division by zero.
   --
   --  @param Left Dividend.
   --  @param Right Divisor.
   --  @return Quotient, or Invalid when Right is zero.
   function "/" (Left, Right : Checked) return Checked;

   --  Round a value up to a multiple of Alignment.
   --
   --  Alignment must be a non-zero power of two; any other value yields
   --  Invalid, as does an aligned result that would exceed the 64-bit range.
   --
   --  @param Item Value to round.
   --  @param Alignment Power-of-two alignment in bytes.
   --  @return Rounded value, or Invalid.
   function Align_Up (Item : Checked; Alignment : U64) return Checked;

   --  Report whether a value is a non-zero power of two.
   --
   --  @param Value Value to test.
   --  @return True when exactly one bit is set.
   function Is_Power_Of_Two (Value : U64) return Boolean
   is (Value /= 0 and then (Value and (Value - 1)) = 0);

   --  Convert to a non-negative Ada integer, reporting range loss.
   --
   --  @param Item Checked value to convert.
   --  @param Result Converted value; 0 when the conversion fails.
   --  @return True when Item is valid and fits in Natural.
   function To_Natural (Item : Checked; Result : out Natural) return Boolean;

   --  Report whether a checked value is at most a bound.
   --
   --  @param Item Checked value to test.
   --  @param Bound Inclusive upper bound.
   --  @return True when Item is valid and does not exceed Bound.
   function In_Range (Item : Checked; Bound : U64) return Boolean
   is (Item.Valid and then Item.Value <= Bound);

end Model_Runner.Arithmetic;
