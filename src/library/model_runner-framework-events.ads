private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What happened to the project state, written down as it happened.
--
--  An event is staged in the transaction whose change it describes, so it
--  is committed exactly when the change is and never without it: a change
--  that fails leaves no event, and an event is only there to be read once
--  its change has happened. Each carries a number in one sequence, the
--  entity it is about and the transaction it came from. Events describe
--  the state; they are not the state, and nothing is rebuilt from them.
--
--  Whatever acts on events says so in the same transaction as what it
--  did, through Consume. An event delivered twice -- after a crash, or by
--  a replay -- is then recognised the second time and its consequences
--  are not made twice.
package Model_Runner.Framework.Events is

   --  The kinds of event the harness writes.
   type Event_Kind is
     (Project_Initialized,
      Configuration_Changed,
      Specification_Accepted,
      Requirement_Accepted,
      Requirement_Revised,
      Requirement_Obsoleted,
      Decision_Accepted,
      Task_Candidate_Created,
      Task_Accepted,
      Task_Rejected,
      Task_Became_Ready,
      Task_Started,
      Task_Blocked,
      Task_Verification_Started,
      Task_Completed,
      Task_Failed,
      Task_Cancelled,
      Task_Revised,
      Source_Changed,
      Build_Completed,
      Test_Completed,
      Test_Failed,
      Agent_Spawned,
      Agent_Completed,
      Agent_Failed,
      Agent_Cancelled,
      Workspace_Created,
      Workspace_Integrated,
      Requirement_Verified,
      Requirement_Verification_Invalidated,

      --  Beyond the core set: every move of the intent registers is
      --  recorded, so that what happened to one can be read back whole.
      Specification_Proposed,
      Specification_Revised,
      Specification_Rejected,
      Specification_Superseded,
      Specification_Reconsidered,
      Requirement_Proposed,
      Requirement_Implemented,
      Requirement_Blocked,
      Requirement_Rejected,
      Requirement_Reconsidered,
      Decision_Proposed,
      Decision_Revised,
      Decision_Rejected,
      Decision_Superseded,
      Decision_Reconsidered,

      --  A move into or out of a state a project defined, whose meaning its
      --  configuration says: the detail says from where to where.
      Task_Moved,
      Requirement_Moved,

      --  A model's run for a task, begun and ended: the detail names the
      --  task and agent, and how it ended -- so the log holds a /work run
      --  whole, where the invocation records hold its calls.
      Invocation_Started,
      Invocation_Ended);

   --  One event, as read back.
   type Event is record
      Id          : Ada.Strings.Unbounded.Unbounded_String;
      Sequence    : Natural := 0;

      --  The kind as it was written, which a later build may have written
      --  as a word this one does not know; Known says whether Kind is it.
      Kind_Word   : Ada.Strings.Unbounded.Unbounded_String;
      Kind        : Event_Kind := Project_Initialized;
      Known       : Boolean := False;

      Subject     : Ada.Strings.Unbounded.Unbounded_String;
      Transaction : Ada.Strings.Unbounded.Unbounded_String;
      Occurred_At : Ada.Strings.Unbounded.Unbounded_String;
      Detail      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Events in sequence.
   type Event_List is private;

   --  The word an event kind is written as.
   --
   --  @param Kind The kind.
   --  @return Its name, as Task_Accepted.
   function Kind_Name (Kind : Event_Kind) return String;

   --  Stage an event in the transaction whose change it describes.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind What happened.
   --  @param Subject The entity it happened to.
   --  @param Detail Anything more to say; may be empty.
   --  @param Id The event's identifier, EVT- and nine digits.
   --  @param Status Framework_Identifier_Invalid when the subject is not an
   --    identifier.
   procedure Emit
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Kind    : Event_Kind;
      Subject : String;
      Detail  : String;
      Id      : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  The project's revision: the number of the last event, which every
   --  change of the project's state writes one of. Two readings that agree
   --  saw the same state; a later one that is higher saw it move.
   --
   --  @param Item The store.
   --  @return The revision; nought before any event.
   function Revision (Item : Stores.Store) return Natural;

   --  The workspace's revision: how many times the harness has recorded the
   --  project's source changing -- every Source_Changed -- apart from the
   --  project's state. What an invocation started from and ended at, and
   --  what derived knowledge of the source was made at. A change made
   --  outside the harness is not counted here; the repository graph's
   --  fingerprint, read from the files, is what notices that.
   --
   --  @param Item The store.
   --  @return The revision; nought before any change was recorded.
   function Workspace_Revision (Item : Stores.Store) return Natural;

   --  The committed events numbered after a point, in order.
   --
   --  @param Item The store.
   --  @param After The last sequence number already seen; zero for all.
   --  @return The events.
   function Since (Item : Stores.Store; After : Natural) return Event_List;

   --  The latest events, oldest first: those before them are not read.
   --
   --  @param Item The store.
   --  @param Count How many at most.
   --  @return The events.
   function Latest (Item : Stores.Store; Count : Positive) return Event_List;

   --  How many events the log holds, none of them read.
   --
   --  @param Item The store.
   --  @return The number.
   function Count (Item : Stores.Store) return Natural;

   --  How many events a list holds.
   --
   --  @param From The list.
   --  @return The count.
   function Length (From : Event_List) return Natural;

   --  One event of a list.
   --
   --  @param From The list.
   --  @param Index 1 .. Length.
   --  @return The event.
   function Element (From : Event_List; Index : Positive) return Event;

   --  Record that a consumer acts on an event, in the transaction that
   --  holds what it does about it.
   --
   --  @param Item The store.
   --  @param Change The transaction holding the consequences.
   --  @param Consumer Who is acting: a name of letters, digits and _ . -.
   --  @param Event_Id The event.
   --  @param Fresh False when the consumer has acted on the event already,
   --    in which case nothing is staged and it should do nothing now.
   --  @param Status Framework_Name_Invalid when the consumer's name is not
   --    one, and a read failure of its record.
   procedure Consume
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Consumer : String;
      Event_Id : String;
      Fresh    : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info);

   --  The sequence through which a consumer has settled every event: what
   --  it reads next starts after it. Kept as done.through in its record,
   --  a field the record has always allowed; the marks of the events it
   --  covers are dropped as it moves.
   --
   --  @param Item The store.
   --  @param Consumer Who is acting.
   --  @return The sequence; 0 where nothing is settled yet.
   function Settled (Item : Stores.Store; Consumer : String) return Natural;

   --  Stage how far a consumer has settled every event, in the transaction
   --  that consumes them.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Consumer Who is acting.
   --  @param Through The sequence: every event at or below it consumed, or
   --    of no concern to the consumer. Never moved back.
   --  @param Status Framework_Name_Invalid, or a read failure of its record.
   procedure Settle
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Consumer : String;
      Through  : Natural;
      Status   : out Model_Runner.Errors.Error_Info);

private

   package Event_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Event);

   type Event_List is record
      Events : Event_Vectors.Vector;
   end record;

end Model_Runner.Framework.Events;
