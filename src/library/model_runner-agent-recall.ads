with Ada.Strings.Unbounded;
with Interfaces;
with Model_Runner.Tools.Runner;

--  What the agent loop remembers of the calls a model has made, so that a
--  call made again is answered from the first rather than run twice -- and
--  so that it is not, once the state the first one read has changed.
--
--  A call is known by a key the loop makes of its name and arguments. A
--  call that reads is remembered with its answer and how it ended, and the
--  same call again gets that answer. A call that changes state forgets
--  every call before it: what they answered was read from state it may
--  have changed, so the next of them runs again -- a file read after it
--  was written is read, not answered with what it held before. The call
--  that changed is kept, so the same change made twice with nothing
--  between is still not made twice.
--
--  Bounded: past Most calls a call is no longer remembered, and runs.
--
--  Task safety: one task, the loop's.
package Model_Runner.Agent.Recall is

   type Memory is tagged limited private;

   --  The calls remembered at most.
   Most : constant := 256;

   --  Whether a call is remembered.
   --
   --  @param Self The memory.
   --  @param Key The call's key.
   --  @return True when it was made and nothing since has forgotten it.
   function Holds (Self : Memory; Key : Interfaces.Unsigned_64) return Boolean;

   --  Whether a remembered call has its answer yet: a call made earlier in
   --  the same turn has none until that turn's calls have run.
   --
   --  @param Self The memory.
   --  @param Key The call's key.
   --  @return True when it is held and answered.
   function Answered (Self : Memory; Key : Interfaces.Unsigned_64) return Boolean;

   --  A remembered call's answer, or "".
   --
   --  @param Self The memory.
   --  @param Key The call's key.
   --  @return The text it answered.
   function Answer (Self : Memory; Key : Interfaces.Unsigned_64) return String;

   --  How a remembered call ended; Done for one not held.
   --
   --  @param Self The memory.
   --  @param Key The call's key.
   --  @return Its outcome.
   function Ended (Self : Memory; Key : Interfaces.Unsigned_64)
     return Model_Runner.Tools.Runner.Call_Outcome;

   --  Remember a call made, not yet answered. A call already held is left.
   --
   --  @param Self The memory.
   --  @param Key The call's key.
   procedure Remember (Self : in out Memory; Key : Interfaces.Unsigned_64);

   --  Keep a held call's answer, the first one given. A call not held, or
   --  answered already, is left.
   --
   --  @param Self The memory.
   --  @param Key The call's key.
   --  @param Text What it answered.
   --  @param Ended How it ended.
   procedure Keep
     (Self  : in out Memory;
      Key   : Interfaces.Unsigned_64;
      Text  : String;
      Ended : Model_Runner.Tools.Runner.Call_Outcome);

   --  A call that changes state is to run: every other call is forgotten,
   --  and this one remembered.
   --
   --  @param Self The memory.
   --  @param Key The changing call's key.
   procedure Changed (Self : in out Memory; Key : Interfaces.Unsigned_64);

   --  The work as the loop saw it happen, call by call: what each call
   --  was about -- a path, where it named one -- what it does to state,
   --  and how it last ended. The loop writes a compacted conversation's
   --  record of the work from this rather than asking the model to
   --  summarize itself.
   type Work_Log is tagged limited private;

   --  A call that ran, and how it ended. The same call about the same
   --  thing is one entry, its ending the latest: a failure a later call
   --  answered is no longer a failure.
   --
   --  @param Self The log.
   --  @param Named The function called.
   --  @param Subject What it was about: its path, or "".
   --  @param Kind What it does to state.
   --  @param Ended How it ended.
   procedure Note
     (Self    : in out Work_Log;
      Named   : String;
      Subject : String;
      Kind    : Model_Runner.Tools.Runner.Call_Kind;
      Ended   : Model_Runner.Tools.Runner.Call_Outcome);

   --  The record: what was changed, what was read, what still fails and
   --  what was refused, a line each, bounded to Record_Most characters.
   --  "" before any call.
   --
   --  @param Self The log.
   --  @return The record.
   function Record_Text (Self : Work_Log) return String;

   --  The longest record written.
   Record_Most : constant := 1_536;

   --  Pairs of fingerprints seen -- a call and what it answered, a path and
   --  what was written to it -- kept across every change, so that an answer
   --  the same as one before a change, or a file put back as an earlier
   --  write left it, is noticed.
   type Sightings is tagged limited private;

   --  Whether a pair was seen before; it is seen from now on either way.
   --
   --  @param Self The sightings.
   --  @param Of_What The call, or the path.
   --  @param Was What it answered, or what was written.
   --  @return True when the pair was seen before this.
   function Seen_Again
     (Self    : in out Sightings;
      Of_What : Interfaces.Unsigned_64;
      Was     : Interfaces.Unsigned_64) return Boolean;

private

   type Entry_Row is record
      Named   : Ada.Strings.Unbounded.Unbounded_String;
      Subject : Ada.Strings.Unbounded.Unbounded_String;
      Kind    : Model_Runner.Tools.Runner.Call_Kind;
      Ended   : Model_Runner.Tools.Runner.Call_Outcome;
   end record;

   type Entry_Rows is array (1 .. Most) of Entry_Row;

   type Work_Log is tagged limited record
      Rows : Entry_Rows;
      Used : Natural := 0;
   end record;

   type Pair is record
      Of_What, Was : Interfaces.Unsigned_64 := 0;
   end record;
   type Pairs is array (1 .. 4 * Most) of Pair;

   type Sightings is tagged limited record
      Held : Pairs;
      Used : Natural := 0;
   end record;

   type Keys is array (1 .. Most) of Interfaces.Unsigned_64;
   type Texts is array (1 .. Most) of Ada.Strings.Unbounded.Unbounded_String;
   type Endings is array (1 .. Most) of Model_Runner.Tools.Runner.Call_Outcome;
   type Flags is array (1 .. Most) of Boolean;

   type Memory is tagged limited record
      Held       : Keys;
      Used       : Natural := 0;
      Answers    : Texts;
      Ends       : Endings;
      Has_Answer : Flags := [others => False];
   end record;

end Model_Runner.Agent.Recall;
