with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Model_Runner.Tools.Runner;

--  What the agent loop remembers of the calls a model has made, so that a
--  call made again is answered from the first rather than run twice -- and
--  so that it is not, once the state the first one read has changed.
--
--  A call is known by its identity: its name and its arguments in a
--  canonical form, so the same object written with its members in another
--  order or other spacing is the same call, and two calls are the same
--  only where their identities are equal -- never because two digests
--  happened to agree. A
--  call that reads is remembered with its answer and how it ended, and the
--  same call again gets that answer. A call that changes state forgets
--  every call before it that read what it changes: what they answered was
--  read from state it may have changed, so the next of them runs again -- a
--  file read after it was written is read, not answered with what it held
--  before. The call that changed is kept, so the same change made twice
--  with nothing between is still not made twice. And an answer read from
--  the tree is kept with a stamp of what it read, and stands only while
--  the stamp does: the tree is not the harness's alone.
--
--  Unbounded: what a run has made is remembered however many calls that
--  is, so the protection does not lapse in a long one.
--
--  Task safety: one task, the loop's.
package Model_Runner.Agent.Recall is

   type Memory is tagged limited private;

   --  A call's identity: its name, and its arguments with an object's
   --  members in the order of their names and no space between tokens.
   --  Arguments that are not JSON are taken with the space outside their
   --  strings dropped.
   --
   --  @param Named The function called.
   --  @param Arguments Its arguments.
   --  @return The identity.
   function Identity (Named : String; Arguments : String) return String;

   --  Arguments in that canonical form.
   --
   --  @param Arguments The arguments.
   --  @return Them, canonical.
   function Canonical (Arguments : String) return String;

   --  Whether a call is remembered.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @return True when it was made and nothing since has forgotten it.
   function Holds (Self : Memory; Key : String) return Boolean;

   --  Whether a remembered call has its answer yet: a call made earlier in
   --  the same turn has none until that turn's calls have run.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @return True when it is held and answered.
   function Answered (Self : Memory; Key : String) return Boolean;

   --  A remembered call's answer, or "".
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @return The text it answered.
   function Answer (Self : Memory; Key : String) return String;

   --  How a remembered call ended; Done for one not held.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @return Its outcome.
   function Ended (Self : Memory; Key : String)
     return Model_Runner.Tools.Runner.Call_Outcome;

   --  Remember a call made, not yet answered. A call already held is left.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @param Touches What it reads or changes.
   procedure Remember
     (Self    : in out Memory;
      Key     : String;
      Touches : Model_Runner.Tools.Runner.Resource := Model_Runner.Tools.Runner.Anything);

   --  The stamp a remembered call's answer was kept with; "" for none.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @return The stamp.
   function Stamp_Of (Self : Memory; Key : String) return String;

   --  Forget one call: what it read has changed under it, though no call
   --  here changed it.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   procedure Forget (Self : in out Memory; Key : String);

   --  Keep a held call's answer, the first one given. A call not held, or
   --  answered already, is left.
   --
   --  @param Self The memory.
   --  @param Key The call's identity.
   --  @param Text What it answered.
   --  @param Ended How it ended.
   --  @param Stamp What it read, as it was when it answered (see
   --    Runner.Stamp): the answer stands only while that stamp does.
   procedure Keep
     (Self  : in out Memory;
      Key   : String;
      Text  : String;
      Ended : Model_Runner.Tools.Runner.Call_Outcome;
      Stamp : String := "");

   --  A call that changes state is to run: every call that read what it
   --  changes is forgotten -- all of them, where it may change anything --
   --  and this one remembered. A call that read nothing outside itself is
   --  kept, and so is one that read what this does not change: a note put
   --  in the scratchpad leaves a file read standing.
   --
   --  @param Self The memory.
   --  @param Key The changing call's identity.
   --  @param Touches What it changes.
   procedure Changed
     (Self    : in out Memory;
      Key     : String;
      Touches : Model_Runner.Tools.Runner.Resource := Model_Runner.Tools.Runner.Anything);

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

   --  Pairs seen -- a call and what it answered, a path and
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
      Of_What : String;
      Was     : String) return Boolean;

private

   type Entry_Row is record
      Named   : Ada.Strings.Unbounded.Unbounded_String;
      Subject : Ada.Strings.Unbounded.Unbounded_String;
      Kind    : Model_Runner.Tools.Runner.Call_Kind;
      Ended   : Model_Runner.Tools.Runner.Call_Outcome;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Entry_Row);

   type Work_Log is tagged limited record
      Rows : Entry_Vectors.Vector;
   end record;

   --  A pair is held whole -- what it is of, a separator, what it was --
   --  so two pairs are the same only where they are.
   package Pair_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (String, Ada.Strings.Hash, Equivalent_Elements => "=");

   type Sightings is tagged limited record
      Held : Pair_Sets.Set;
   end record;

   type Remembered is record
      Answer     : Ada.Strings.Unbounded.Unbounded_String;
      Ends       : Model_Runner.Tools.Runner.Call_Outcome;
      Has_Answer : Boolean := False;
      Touches    : Model_Runner.Tools.Runner.Resource := Model_Runner.Tools.Runner.Anything;
      Stamp      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Call_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Remembered, Ada.Strings.Hash, "=");

   type Memory is tagged limited record
      Held : Call_Maps.Map;
   end record;

end Model_Runner.Agent.Recall;
