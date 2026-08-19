--  What each of the suite's cases costs.
--
--  The suite takes twenty-eight minutes and nothing said where they went.
--  AUnit measures every routine and would have answered this, but the build
--  selects its no-calendar variant, so every elapsed time it reports is zero
--  -- which is why a reporter that ranks them prints a list of noughts.
--
--  So the clock goes around the cases instead. Each of the nine is run as a
--  suite of its own and timed with Ada.Calendar, which is the same clock the
--  gate uses for its stages and for the same reason: the load average is not
--  a clock, and one of these was once measured with it.
--
--  This runs the whole suite, case by case, so it costs what the suite costs.
--  It is a tool for asking where the time is, not something the gate runs.
--
--  Task safety: one run at a time; it writes to standard output.
package Case_Timing is

   --  Run every case on its own and say what each took, longest first.
   procedure Report;

   --  The same for the routines of one case, named by a prefix that AUnit's
   --  own filter understands: the case's name, or the case's name and a
   --  routine's. Ninety-nine per cent of the suite is one case, so naming the
   --  case is only half an answer.
   --
   --  @param Named The case whose routines are to be timed.
   procedure Report_Routines (Named : String);

end Case_Timing;
