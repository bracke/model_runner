with Ada.Strings.Unbounded;

with Hostkit;
with Hostkit.Process;

--  Running a program for a tool and saying what came of it: one service for
--  every caller that hands a program's output to a model.
--
--  A program runs with its standard output and its standard error each
--  captured, bounded, and kept apart; within a time limit and answering to a
--  cancellation; its whole process group stopped when either comes. What it
--  leaves -- the files its output was captured in -- goes when the call ends,
--  however it ends. The result says whether it started, how it exited,
--  whether it was stopped, and what it said on each stream, so a model that
--  must fix what a program reported is given the report and not a sentence
--  that something failed.
--
--  Task safety: each call is its own; nothing is shared between calls.
package Model_Runner.Processes is

   --  The most of a stream kept: its head and its tail, the middle said to
   --  be left out.
   Stream_Most : constant := 32 * 1024;

   --  A program to run.
   type Request is record
      Program   : Ada.Strings.Unbounded.Unbounded_String;
      Arguments : Hostkit.String_Vectors.Vector;

      --  Where it runs; "" for here.
      Directory : Ada.Strings.Unbounded.Unbounded_String;

      --  How long it may run, or nought for no limit.
      Limit     : Duration := 0.0;

      --  Asked while it runs; True stops it. Null for no cancellation.
      Cancelled : Hostkit.Process.Cancel_Check := null;
   end record;

   --  What came of it.
   type Result is record
      --  Whether it started at all: a program not found, or one that would
      --  not run, did not.
      Started     : Boolean := False;

      --  Whether it was stopped -- at its limit or by its cancellation --
      --  before it ended of itself.
      Stopped     : Boolean := False;

      Exit_Status : Integer := -1;
      Output      : Ada.Strings.Unbounded.Unbounded_String;
      Errors      : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether either stream was longer than Stream_Most and is kept as
      --  its head and its tail.
      Truncated   : Boolean := False;
   end record;

   --  Run a program and wait for it, within its limit and its cancellation.
   --
   --  @param Item What to run.
   --  @return What came of it.
   function Run (Item : Request) return Result;

   --  What a model is told of a run: its output where it succeeded, and
   --  where it did not, its exit status and what it said on its standard
   --  error, then its output.
   --
   --  @param Item The result.
   --  @param Named What it was, as the sentence names it: "the tool
   --    command", "'make'".
   --  @return The text.
   function Told (Item : Result; Named : String) return String;

   --  Whether a run succeeded: started, not stopped, and exited nought.
   --
   --  @param Item The result.
   --  @return Whether it did.
   function Succeeded (Item : Result) return Boolean is
     (Item.Started and then not Item.Stopped and then Item.Exit_Status = 0);

end Model_Runner.Processes;
