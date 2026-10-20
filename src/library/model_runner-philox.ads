with Interfaces;

with Model_Runner.Numerics;

--  Gaussian noise as the picture's reference draws it: Philox 4x32 with ten
--  rounds and one Box-Muller value a counter -- torch's randn on CUDA, as
--  stable-diffusion.cpp imitates it on the processor (`--rng cuda`, its
--  default). The same seed gives the same latent on both, to the bit: the
--  logarithm, the root and the sine are taken in binary64 as the C++
--  overloads take them, and the root rounded to binary32 before the
--  product, where binary32 throughout is up to three units in the last
--  place off.
--
--  Task safety: a Generator is a plain value; one task at a time draws
--  from it.
package Model_Runner.Philox is

   type Generator is private;

   --  @param Seed the picture's seed, as the reference's request has it
   --  @return a generator at its first draw
   function Seeded (Seed : Interfaces.Unsigned_64) return Generator;

   --  One draw: every value of Values, in order, as the reference's randn
   --  of that many fills a tensor; the next draw continues after it.
   --
   --  @param Self the generator, moved on by one draw
   --  @param Values filled with standard normal values
   procedure Draw (Self : in out Generator; Values : out Model_Runner.Numerics.Real_Array);

private

   type Generator is record
      Seed   : Interfaces.Unsigned_64 := 0;
      Offset : Interfaces.Unsigned_32 := 0;
   end record;

end Model_Runner.Philox;
