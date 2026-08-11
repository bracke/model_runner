--  Public operations no test names.
--
--  Three registries now say what is deliberately not exercised, and this is
--  the third. Reserved_Codes names the diagnostics nothing raises;
--  Unreached_Codes names the ones raised on a path no test walks; this names
--  the operations no test writes down.
--
--  Sixty-two of three hundred and eighty-two were in that position and
--  nothing recorded it, so an operation that is exercised through a caller,
--  one that cannot be reached without a second machine, and one that is
--  simply untested were indistinguishable. Two of the sharpest -- the typed
--  byte readers, which decode metadata out of an untrusted file -- were on
--  it until a test was written for them, which is what the list is for:
--  making the next reader ask why each is still here.
--
--  What the check measures is naming, not exercising, and it errs towards
--  saying an operation is tested: a name written anywhere in the tests
--  counts, it need not be a call, and names are not qualified -- Mat_Mul
--  came off this list because a test names Mat_Mul_Range, which contains it. That is the same proxy the code registry
--  uses and the same caveat applies -- this list going empty would not mean
--  every operation has been exercised.
--
--  Task safety: pure.
package Untested_Surface is

   --  Report whether an operation is one no test names.
   --
   --  @param Name Operation name, as the spec spells it.
   --  @return True when it is on the list.
   function Is_Untested (Name : String) return Boolean;

   --  How many names the list holds.
   --
   --  @return Count.
   function Count return Natural;

end Untested_Surface;
