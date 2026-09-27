with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Who is working on what, for how long.
--
--  A lease says that one owner -- a session, an agent -- holds a resource
--  until a moment, and it is kept in the runtime state like any other
--  record. It runs out by itself: an owner that crashes stops renewing it,
--  and once the moment passes the resource is free again and the lease is
--  reported as stale, rather than held for ever by an owner that is gone.
package Model_Runner.Framework.Leases is

   --  Take a resource, or renew a lease the owner already holds.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Resource The resource: letters, digits and _ . -.
   --  @param Owner Who takes it.
   --  @param Seconds How long the lease runs before it must be renewed.
   --  @param Status Framework_Lease_Held when another owner holds a lease
   --    that has not run out, Framework_Name_Invalid when the resource is
   --    not a name.
   procedure Acquire
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Resource : String;
      Owner    : String;
      Seconds  : Positive;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Let a resource go. Harmless when there is no lease on it.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Resource The resource.
   --  @param Owner Who lets it go.
   --  @param Status Framework_Lease_Held when another owner holds a lease
   --    that has not run out.
   procedure Release
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Resource : String;
      Owner    : String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Who holds a resource now.
   --
   --  @param Item The store.
   --  @param Resource The resource.
   --  @return The owner, or the empty string when nobody holds a lease on
   --    it that has not run out.
   function Holder (Item : Stores.Store; Resource : String) return String;

   --  The resources whose leases have run out and are still recorded.
   --
   --  @param Item The store.
   --  @return Their names, sorted.
   function Stale (Item : Stores.Store) return Name_Lists.Vector;

end Model_Runner.Framework.Leases;
