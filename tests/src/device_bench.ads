--  What a device attention costs, taken apart.
--
--  The first two shapes of that kernel were each measured against the
--  processor and each lost -- one by twelve times, the next by four -- and
--  both were written before anything measured where their time went. This
--  asks that question instead: one call is timed at two cache sizes and at
--  two head counts, so what is per-call and what is per-position can be told
--  apart, and the arithmetic done can be put beside the seconds taken.
--
--  A device that reaches a fiftieth of what it should is not a kernel that
--  wants rewriting in the same shape again; it is a kernel reading its cache
--  from the wrong place, or one invocation deep, and those look different in
--  these numbers.
--
--  Task safety: one run at a time; it writes to standard output.
package Device_Bench is

   --  Time attention at several shapes and say what each cost, and every
   --  format's product at one, four and eight vectors.
   --
   --  @param Formats_Only Only the formats' products, which is what a
   --    kernel change for a format is judged on.
   --  @param Format_Rounds Rounds over every format and width, each cell
   --    said as the median of its rounds.
   procedure Report
     (Formats_Only  : Boolean := False;
      Format_Rounds : Positive := 5);

end Device_Bench;
