with Ada.Real_Time;

package body Model_Runner.Entropy is

   use type Interfaces.Unsigned_64;

   --  SplitMix64 finalizer. Mixes a weakly varying counter into a value whose
   --  bits are all sensitive to the input, so that two runs started in the
   --  same millisecond still receive clearly different seeds.
   function Mix (Item : Seed_Value) return Seed_Value is
      Value : Seed_Value := Item;
   begin
      Value := (Value xor Interfaces.Shift_Right (Value, 30))
        * 16#BF58_476D_1CE4_E5B9#;
      Value := (Value xor Interfaces.Shift_Right (Value, 27))
        * 16#94D0_49BB_1331_11EB#;
      return Value xor Interfaces.Shift_Right (Value, 31);
   end Mix;

   ----------
   -- Draw --
   ----------

   procedure Draw (Item : Source_Reference; Seed : out Seed_Value) is
   begin
      if Item = null then
         Seed := Fallback_Seed;
      else
         Item.all.Next_Seed (Seed);
      end if;
   end Draw;

   ---------------
   -- Next_Seed --
   ---------------

   overriding procedure Next_Seed
     (Self : in out Host_Source;
      Seed : out Seed_Value)
   is
      use type Ada.Real_Time.Time_Span;

      Whole    : Ada.Real_Time.Seconds_Count;
      Fraction : Ada.Real_Time.Time_Span;
   begin
      Self.Counter := Self.Counter + 1;

      --  Split the clock rather than subtracting the epoch and converting to
      --  Duration: on hosts where the span from the epoch to now exceeds
      --  Duration'Last that conversion raises, and a value computed in a
      --  declarative part raises past this subprogram's own handler.
      Ada.Real_Time.Split (Ada.Real_Time.Clock, Whole, Fraction);

      Seed :=
        Mix (Seed_Value'Mod (Whole) * 1_000_000_000
             + Seed_Value'Mod (Fraction / Ada.Real_Time.Nanoseconds (1))
             + Self.Counter * 16#9E37_79B9_7F4A_7C15#);
   exception
      when others =>
         Self.Counter := Self.Counter + 1;
         Seed := Mix (Fallback_Seed + Self.Counter);
   end Next_Seed;

   -----------
   -- Fixed --
   -----------

   function Fixed (Value : Seed_Value) return Fixed_Source
   is (Source with Value => Value);

   ---------------
   -- Next_Seed --
   ---------------

   overriding procedure Next_Seed
     (Self : in out Fixed_Source;
      Seed : out Seed_Value) is
   begin
      Seed := Self.Value;
   end Next_Seed;

end Model_Runner.Entropy;
