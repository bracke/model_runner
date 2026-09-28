private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Stores;

--  Which changes of state an entity may make, and making them.
--
--  A state machine here is data: its states and the moves between them,
--  each move ordinary or one that only an explicit policy -- a reopen, a
--  reconsideration -- permits. A project may take the default machine as
--  it is, forbid moves in it or allow more. A move the machine does not
--  allow is refused before anything is written, so an illegal transition
--  leaves the state as it was.
package Model_Runner.Framework.Transitions is

   --  What a move needs beyond being asked for. Invalidation is what a
   --  revision's new meaning undoes, which nobody asks for directly.
   type Permission is (Ordinary, Reopen, Reconsideration, Invalidation);

   --  The permissions a caller has been given.
   type Permissions is array (Permission) of Boolean;

   --  Only ordinary moves.
   Ordinary_Only : constant Permissions :=
     [Ordinary => True, others => False];

   --  A state machine.
   type Machine is private;

   --  Add a state.
   --
   --  @param Into The machine.
   --  @param State Its name.
   procedure Add_State (Into : in out Machine; State : String);

   --  Allow a move, or change what an allowed one needs.
   --
   --  @param Into The machine; both states are added when they are not in
   --    it.
   --  @param From The state moved from.
   --  @param To The state moved to.
   --  @param Requires What the move needs.
   procedure Allow
     (Into     : in out Machine;
      From     : String;
      To       : String;
      Requires : Permission := Ordinary);

   --  Forbid a move.
   --
   --  @param Into The machine.
   --  @param From The state moved from.
   --  @param To The state moved to.
   procedure Forbid (Into : in out Machine; From : String; To : String);

   --  Whether a machine has a state.
   --
   --  @param From The machine.
   --  @param State The state.
   --  @return True when it has.
   function Is_State (From : Machine; State : String) return Boolean;

   --  Check a move.
   --
   --  @param From The machine.
   --  @param Subject The entity moving, for the diagnostic.
   --  @param Current The state it is in.
   --  @param Next The state it would move to.
   --  @param Granted The permissions given.
   --  @param Status Framework_Transition_Invalid saying why when the move
   --    is not allowed with those permissions.
   procedure Check
     (From    : Machine;
      Subject : String;
      Current : String;
      Next    : String;
      Granted : Permissions;
      Status  : out Model_Runner.Errors.Error_Info);

   --  The default lifecycle of a task.
   --
   --  @return The machine: candidate, accepted, running, blocked,
   --    verification, complete, failed, cancelled and rejected, with the
   --    moves between them, reopening a complete or cancelled task and
   --    reconsidering a rejected one each needing their policy.
   function Task_Machine return Machine;

   --  Move a record's state: check the move, write the record's next
   --  revision with its state field changed, and stage the event that
   --  says so, all in one transaction.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Rules The machine.
   --  @param Where The record's area.
   --  @param Name The record's name.
   --  @param Next The state to move to.
   --  @param Granted The permissions given.
   --  @param Kind The event to stage.
   --  @param Status Framework_Transition_Invalid when the move is not
   --    allowed, and a read failure of the record.
   --  @param Actor Who made the move -- User, a policy's name, an agent --
   --    kept as the record's moved_by, as NEXT_by for an acceptance or a
   --    rejection, and in the event; empty when nobody is to be named.
   procedure Apply
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Rules   : Machine;
      Where   : Area;
      Name    : String;
      Next    : String;
      Granted : Permissions;
      Kind    : Events.Event_Kind;
      Status  : out Model_Runner.Errors.Error_Info;
      Actor   : String := "");

   --  The person at the terminal, as an actor: user and the login name,
   --  or user alone when the host does not say.
   --
   --  @return The actor.
   function User return String;

private

   type Move is record
      From     : Ada.Strings.Unbounded.Unbounded_String;
      To       : Ada.Strings.Unbounded.Unbounded_String;
      Requires : Permission := Ordinary;
   end record;

   package Move_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Move);

   type Machine is record
      States : Name_Lists.Vector;
      Moves  : Move_Vectors.Vector;
   end record;

end Model_Runner.Framework.Transitions;
