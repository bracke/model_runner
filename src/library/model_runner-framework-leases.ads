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

   --  Say that this process's own work is running under a lease: while it
   --  is, the lease holds though its time has run out -- the time is a
   --  bound on a holder nobody can see, not on one that is plainly working,
   --  and a run that went past its estimate lost its own hold. A lease
   --  this process took for work that is no longer running here -- a
   --  session that ended -- runs out as any other.
   --
   --  @param Resource The resource.
   --  @param Owner Who holds it.
   procedure Working (Resource : String; Owner : String);

   --  Say that work under a lease is no longer running in this process.
   --
   --  @param Resource The resource.
   --  @param Owner Who held it.
   procedure Done_Working (Resource : String; Owner : String);

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

   --  Let go of every lease that has run out: what it held is no one's
   --  now, and a record of it only says so over and over.
   --
   --  @param Item The store.
   --  @param Change The transaction the removals are staged in.
   --  @param Cleared The resources let go of.
   procedure Clear_Stale
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Cleared : out Name_Lists.Vector);

end Model_Runner.Framework.Leases;
