with Model_Runner.Numerics;

--  The discrete Fourier transform, of any length, in binary64.
--
--  Speech is read as a spectrogram: a window of samples at a time turned
--  into how much of each frequency it holds. Whisper's window is four
--  hundred samples -- twenty-five milliseconds at sixteen kilohertz -- which
--  is no power of two, so the radix-two transform every textbook starts
--  with does not take it. What is here is the mixed-radix one: the length
--  cut into its factors, fours first, then twos, threes, fives and on, each
--  stage a butterfly of its own radix over the sub-transforms the stage
--  below it made. Four hundred is 4 x 4 x 5 x 5, and a transform of it is
--  some seven thousand complex products where the definition is eighty
--  thousand. A length with a large prime factor still transforms, the
--  butterfly of that radix being the definition over that factor.
--
--  Sign and scale: the forward transform is X(k) = sum x(n) e^(-2 pi i k n
--  / N), unnormalized, as numpy's and torch's are. Only the forward
--  transform of a real input is offered, since that is all a spectrogram
--  asks: its N / 2 + 1 lowest bins, the rest being their conjugates.
--
--  Everything is binary64. The reference computes its spectrogram in
--  binary32; a power spectrum the binary64 one rounds to binary32 is
--  within an ulp or two of it, which the logarithm after it does not see.
--
--  Bounded work: a plan holds its twiddle factors, its factors and a
--  workspace, all sized when it is prepared; a transform allocates
--  nothing.
--
--  Task safety: a Plan is one task's -- the transform writes its
--  workspace. Plans of the same length on different tasks are independent.
package Model_Runner.Fourier is

   subtype Wide_Real is Model_Runner.Numerics.Wide_Real;
   subtype Wide_Real_Array is Model_Runner.Numerics.Wide_Real_Array;

   --  The longest transform a plan is prepared for: five times the window
   --  a spectrogram takes, and a plan of it -- seven arrays of its length
   --  -- still a small frame where one is declared.
   Max_Length : constant := 2_048;

   subtype Transform_Length is Positive range 1 .. Max_Length;

   --  A transform of one length, ready to run.
   type Plan (Length : Transform_Length) is limited private;

   --  Prepare a plan: its factors, its twiddle factors and its workspace.
   --
   --  @param Item The plan, of the length it was declared with.
   procedure Prepare (Item : in out Plan);

   --  Whether Prepare has run.
   --
   --  @param Item The plan.
   --  @return True once prepared.
   function Is_Prepared (Item : Plan) return Boolean;

   --  The forward transform of a real input: its bins 0 .. Length / 2.
   --
   --  @param Item A prepared plan.
   --  @param Input Length samples.
   --  @param Real_Part Receives each bin's real part.
   --  @param Imaginary_Part Receives each bin's imaginary part.
   procedure Forward_Real
     (Item           : in out Plan;
      Input          : Wide_Real_Array;
      Real_Part      : out Wide_Real_Array;
      Imaginary_Part : out Wide_Real_Array)
   with Pre => Is_Prepared (Item)
     and then Input'Length = Item.Length
     and then Real_Part'Length = Item.Length / 2 + 1
     and then Imaginary_Part'Length = Item.Length / 2 + 1;

   --  The same transform computed from its definition, a sum over every
   --  sample for every bin: what the plan is tested against.
   --
   --  @param Input The samples.
   --  @param Real_Part Receives bins 0 .. Input'Length / 2, real parts.
   --  @param Imaginary_Part Receives their imaginary parts.
   procedure Forward_Real_Directly
     (Input          : Wide_Real_Array;
      Real_Part      : out Wide_Real_Array;
      Imaginary_Part : out Wide_Real_Array)
   with Pre => Input'Length > 0
     and then Real_Part'Length = Input'Length / 2 + 1
     and then Imaginary_Part'Length = Input'Length / 2 + 1;

private

   --  At most one factor a halving: eleven for 2,048.
   Max_Factors : constant := 12;

   type Factor_List is array (1 .. Max_Factors) of Positive;

   type Values is array (Natural range <>) of Wide_Real;

   type Plan (Length : Transform_Length) is limited record
      Prepared : Boolean := False;
      --  The radices, outermost first, and how many.
      Radix    : Factor_List := [others => 1];
      Factors  : Natural := 0;
      --  e^(-2 pi i j / Length) for j in 0 .. Length - 1, at j + 1, as
      --  every array here holds its element j.
      Cos_Of, Sin_Of : Values (1 .. Length);
      --  The complex input, and the output being built.
      In_Re, In_Im   : Values (1 .. Length);
      Out_Re, Out_Im : Values (1 .. Length);
      --  One butterfly's inputs; a radix is at most the length.
      Scratch_Re, Scratch_Im : Values (1 .. Length);
   end record;

   function Is_Prepared (Item : Plan) return Boolean is (Item.Prepared);

end Model_Runner.Fourier;
