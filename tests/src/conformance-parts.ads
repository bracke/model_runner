--  The sweep split across processes, side by side, and its parts' reports
--  added up.
--
--  The sweep is one procedure whose state -- the fixture it built, the
--  reference's answers for it, the counts -- belongs to the architecture it
--  is crossing, and the architectures do not share it. So the parts are
--  processes rather than tasks: each is this program run as `tests
--  conformance --part K/N`, crossing every N-th architecture from the K-th,
--  and printing its report as one line; this runs them at once and adds the
--  lines up. Counts are summed and the worst differences are the worst of
--  any part's, so the sum is the whole sweep's report, held to the same
--  accounting -- and a part that died, or printed no report, is a sweep that
--  did not run, not one that passed.
package Conformance.Parts is

   --  How many parts a sweep is split into on this machine: one a processor
   --  but one, at most eight, at least one. A part is one process, mostly
   --  on one processor, and about a gigabyte and a half.
   --
   --  @return The count.
   function Count return Positive;

   --  A report as the one line a part prints.
   --
   --  @param Item The report.
   --  @return The line, starting "conformance-part:".
   function Line_Of (Item : Report) return String;

   --  A part's report, read back from its line.
   --
   --  @param Line The line.
   --  @param Item The report.
   --  @param Read Whether the line was one.
   procedure Read_Line (Line : String; Item : out Report; Read : out Boolean);

   --  Add a part's report into the whole's.
   --
   --  @param Into The whole.
   --  @param Part The part.
   procedure Add (Into : in out Report; Part : Report);

   --  Run the sweep in parts, each this program as a process of its own,
   --  and add their reports up. A part that printed no report leaves the
   --  whole unaccounted, so the sweep reads as not run; its standard error
   --  -- the first disagreement, among the rest -- is passed on.
   --
   --  @param Result The whole sweep's report.
   --  @param Short_Sweep Whether the parts sweep short.
   --  @param Program This program, as it was started.
   --  @param Integers Whether the parts run in the quantized arithmetic.
   procedure Run
     (Result      : out Report;
      Short_Sweep : Boolean;
      Program     : String;
      Integers    : Boolean);

end Conformance.Parts;
