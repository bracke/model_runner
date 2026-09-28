with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Transitions;

--  What the project is meant to be: specifications, requirements and
--  decisions, kept apart from any conversation.
--
--  The three share a shape. Each is proposed as a candidate with a stable
--  identifier -- SPEC-, REQ- or DEC-, a key and a number -- moves through a
--  lifecycle of its own, and is changed by a new revision that keeps the
--  one before it: a revision's text is never rewritten, and a copy of each
--  earlier revision stays where it was. What a revision means normatively
--  -- its text and its criteria -- is fingerprinted, so a change of wording
--  can be told from a change of meaning.
--
--  Requirements move from candidate through accepted and implemented to
--  verified. A revision that changes a requirement's meaning undoes what
--  no longer applies: new criteria make a verified requirement implemented
--  again, since the evidence was for the old ones; a new statement sends
--  an implemented or verified one back to accepted, since the
--  implementation was for the old one. Neither is a rewrite of what
--  happened: the earlier revision and its events stay as they were.
--
--  A decision that replaces another says so, and the one replaced is
--  superseded rather than deleted. The accepted decisions that apply to a
--  component are what a task working on it is told.
package Model_Runner.Framework.Intent is

   --  Which register an entity is in.
   type Intent_Kind is (Specification, Requirement, Decision);

   --  What an entity is linked to.
   type Link_Kind is
     (Dependency,
      Component,
      Implementation,
      Task_Link,
      Test,
      Verification);

   --  One entity, as read.
   type Entity is record
      Kind        : Intent_Kind := Requirement;
      Id          : Ada.Strings.Unbounded.Unbounded_String;
      Revision    : Natural := 0;
      State       : Ada.Strings.Unbounded.Unbounded_String;
      Title       : Ada.Strings.Unbounded.Unbounded_String;

      --  What it says: a specification's text, a requirement's statement,
      --  a decision's ruling.
      Text        : Ada.Strings.Unbounded.Unbounded_String;

      --  What it is judged by: a requirement's acceptance criteria, a
      --  decision's rationale, a specification's nothing.
      Criteria    : Ada.Strings.Unbounded.Unbounded_String;

      --  Where it came from, and the key that says it is the same thing
      --  when it comes again.
      Source      : Ada.Strings.Unbounded.Unbounded_String;
      Provenance  : Ada.Strings.Unbounded.Unbounded_String;

      --  What it applies to: "project", or a component's name.
      Scope       : Ada.Strings.Unbounded.Unbounded_String;

      --  The fingerprint of Text and Criteria.
      Meaning     : Ada.Strings.Unbounded.Unbounded_String;

      --  The entity this one replaces, and the one that replaced it.
      Supersedes    : Ada.Strings.Unbounded.Unbounded_String;
      Superseded_By : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  What a revision did beyond itself.
   type Impact is record
      --  Whether the meaning changed, and not only the wording around it.
      Normative     : Boolean := False;

      --  The state before and after.
      Before        : Ada.Strings.Unbounded.Unbounded_String;
      After         : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether verification that applied no longer does.
      Invalidated   : Boolean := False;
   end record;

   --  The word a kind is written as, and the namespace of its identifiers.
   --
   --  @param Kind The kind.
   --  @return SPEC, REQ or DEC.
   function Namespace (Kind : Intent_Kind) return String;

   --  The lifecycle of a kind.
   --
   --  @param Kind The kind.
   --  @return Its machine.
   function Machine_Of (Kind : Intent_Kind) return Transitions.Machine;

   --  The state a kind starts in.
   --
   --  @param Kind The kind.
   --  @return candidate, or proposed for a decision.
   function First_State (Kind : Intent_Kind) return String;

   --  Propose an entity.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind Which register.
   --  @param Key What it belongs to, as PARSER; empty for none.
   --  @param Title A line to show it by.
   --  @param Text What it says.
   --  @param Criteria What it is judged by; may be empty.
   --  @param Source Where it came from, as a file or "user".
   --  @param Provenance What makes it the same thing when it comes again;
   --    may be empty.
   --  @param Scope "project" or a component's name.
   --  @param Id Its identifier.
   --  @param Status Framework_Identifier_Invalid when the key makes none.
   procedure Propose
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Kind       : Intent_Kind;
      Key        : String;
      Title      : String;
      Text       : String;
      Criteria   : String;
      Source     : String;
      Provenance : String;
      Scope      : String;
      Id         : out Ada.Strings.Unbounded.Unbounded_String;
      Status     : out Model_Runner.Errors.Error_Info);

   --  Read an entity's current revision.
   --
   --  @param Item The store.
   --  @param Kind Which register.
   --  @param Id Its identifier.
   --  @param Value The entity.
   --  @param Status Framework_Not_Found when there is none.
   procedure Read
     (Item   : Stores.Store;
      Kind   : Intent_Kind;
      Id     : String;
      Value  : out Entity;
      Status : out Model_Runner.Errors.Error_Info);

   --  Move an entity through its lifecycle, with the event that says so.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind Which register.
   --  @param Id Its identifier.
   --  @param Next The state to move to.
   --  @param Granted The policies the move may use.
   --  @param Status Framework_Transition_Invalid when the move is not one.
   --  @param Actor Who moved it, as Transitions.Apply keeps it.
   procedure Move
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Kind    : Intent_Kind;
      Id      : String;
      Next    : String;
      Granted : Transitions.Permissions;
      Status  : out Model_Runner.Errors.Error_Info;
      Actor   : String := "");

   --  Change what an entity says, as its next revision, keeping a copy of
   --  the revision it replaces and undoing what the change leaves no
   --  longer true.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind Which register.
   --  @param Id Its identifier.
   --  @param Title The new title.
   --  @param Text The new text.
   --  @param Criteria The new criteria.
   --  @param Result What else changed.
   --  @param Status Framework_Transition_Invalid when an obsolete or
   --    superseded entity is revised.
   procedure Revise
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Kind     : Intent_Kind;
      Id       : String;
      Title    : String;
      Text     : String;
      Criteria : String;
      Result   : out Impact;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Link an entity to something, as its next revision.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind Which register.
   --  @param Id Its identifier.
   --  @param Relation What kind of link.
   --  @param Target What it links to.
   --  @param Status Framework_Not_Found when there is no such entity.
   procedure Link
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Kind     : Intent_Kind;
      Id       : String;
      Relation : Link_Kind;
      Target   : String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  What an entity is linked to.
   --
   --  @param Item The store.
   --  @param Kind Which register.
   --  @param Id Its identifier.
   --  @param Relation What kind of link.
   --  @return The targets, in the order they were linked.
   function Links
     (Item     : Stores.Store;
      Kind     : Intent_Kind;
      Id       : String;
      Relation : Link_Kind) return Name_Lists.Vector;

   --  Say what an entity rules on a subject, as its next revision: the
   --  statement authority resolution sets against the others about it.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind Which register.
   --  @param Id Its identifier.
   --  @param Subject What it governs, as scalar.build.command.
   --  @param Ruling What it says about it.
   --  @param Overrides The source whose statement it knowingly overrides;
   --    empty for none.
   --  @param Status Framework_Not_Found when there is no such entity.
   procedure Govern
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Kind      : Intent_Kind;
      Id        : String;
      Subject   : String;
      Ruling    : String;
      Overrides : String;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Replace an accepted entity with another, which is accepted in its
   --  place; the one replaced is superseded and says by what.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Kind Specification or Decision.
   --  @param Old_Id What is replaced.
   --  @param New_Id What replaces it.
   --  @param Status Framework_Transition_Invalid when either cannot move.
   procedure Supersede
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Kind   : Intent_Kind;
      Old_Id : String;
      New_Id : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  The entities of a register, current revisions only.
   --
   --  @param Item The store.
   --  @param Kind Which register.
   --  @param State Only those in this state; empty for all.
   --  @return Their identifiers, sorted.
   function List
     (Item  : Stores.Store;
      Kind  : Intent_Kind;
      State : String := "") return Name_Lists.Vector;

   --  The entity that came from a provenance key, if one did.
   --
   --  @param Item The store.
   --  @param Kind Which register.
   --  @param Provenance The key.
   --  @return Its identifier, or the empty string.
   function Find_By_Provenance
     (Item       : Stores.Store;
      Kind       : Intent_Kind;
      Provenance : String) return String;

   --  The accepted decisions that apply to a component: its own and the
   --  project's.
   --
   --  @param Item The store.
   --  @param Component The component; empty for the project's alone.
   --  @return Their identifiers, sorted.
   function Applicable_Decisions
     (Item      : Stores.Store;
      Component : String) return Name_Lists.Vector;

end Model_Runner.Framework.Intent;
