with Model_Runner.Errors;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Stores;

--  The derived indexes: what the state and the repository hold, laid out
--  to be looked up rather than worked out -- requirements, decisions,
--  tasks, components, symbols, tests, traceability, dependencies and a
--  search index of names. Each is derived and never authoritative: it can
--  be deleted and built again from what it was built from, and says what
--  that was, so that one built from something older is known to be stale.
--  Whether they are committed is the repository-state policy's, as for the
--  rest of the indexes.
package Model_Runner.Framework.Indexes is

   --  The indexes there are.
   type Index_Name is
     (Requirements_Index, Decisions_Index, Tasks_Index, Components_Index, Symbols_Index,
      Tests_Index, Traceability_Index, Dependency_Index, Search_Index);

   --  Build every index from the state and a repository graph.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Found The repository as it is now.
   --  @param Status A failure staging one.
   procedure Build
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Repository.Graph;
      Status : out Model_Runner.Errors.Error_Info);

   --  Whether every index was built from the state and the repository as
   --  they are now.
   --
   --  @param Item The store.
   --  @param Found The repository as it is now.
   --  @return False when one is missing or stale.
   function Current (Item : Stores.Store; Found : Repository.Graph) return Boolean;

   --  What one index says, each entry KEY, a tab, and what it says of it.
   --
   --  @param Item The store.
   --  @param Which The index.
   --  @return Its entries, in order; none when it is not there.
   function Entries (Item : Stores.Store; Which : Index_Name) return Name_Lists.Vector;

end Model_Runner.Framework.Indexes;
