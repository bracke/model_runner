private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Framework.Stores;

--  What in the project state does not hold together.
--
--  The check reads the whole state and reports each thing it finds wrong,
--  without changing anything and without asking a model. What it finds is
--  said by kind and subject, so a caller can list it, count it or refuse
--  to go on. Each phase of the framework adds the checks its own state
--  needs; these are the ones every state has.
package Model_Runner.Framework.Consistency is

   --  What is wrong.
   type Finding_Kind is
     (Schema_Mismatch,
      Duplicate_Identifier,
      Incomplete_Transaction,
      Index_Mismatch,
      Stale_Lease,
      Undefined_Requirement,
      Conflicting_Authority,
      Unknown_Task_Reference,
      Cyclic_Dependency,
      Invalid_Task_Kind,
      Invalid_Task_Field,
      Missing_Symbol,
      Stale_Verification,
      Completed_Without_Gate,
      Workspace_Assignment,
      Permission_Widening,
      Missing_Component,
      Ready_With_Open_Dependency,
      Unserved_Requirement);

   --  One thing found wrong.
   type Finding is record
      Kind    : Finding_Kind := Schema_Mismatch;

      --  What it is about: a record's place, an entity, a resource.
      Subject : Ada.Strings.Unbounded.Unbounded_String;

      --  What exactly.
      Detail  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  What a check found.
   type Finding_List is private;

   --  The word a kind of finding is written as.
   --
   --  @param Kind The kind.
   --  @return Its word, as duplicate_identifier.
   function Kind_Word (Kind : Finding_Kind) return String;

   --  Check an open store.
   --
   --  @param Item The store.
   --  @return What was found; empty when the state holds together.
   function Check (Item : Stores.Store) return Finding_List;

   --  How many findings a list holds.
   --
   --  @param From The list.
   --  @return The count.
   function Length (From : Finding_List) return Natural;

   --  One finding.
   --
   --  @param From The list.
   --  @param Index 1 .. Length.
   --  @return The finding.
   function Element (From : Finding_List; Index : Positive) return Finding;

private

   package Finding_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Finding);

   type Finding_List is record
      Findings : Finding_Vectors.Vector;
   end record;

end Model_Runner.Framework.Consistency;
