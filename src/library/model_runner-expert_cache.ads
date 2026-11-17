with Ada.Finalization;
with Interfaces;

--  Routing-aware policy for a bounded mixture-of-experts cache.
--
--  This package decides which experts are worth retaining; it does not move
--  weights or execute products.  Keeping that boundary explicit lets the
--  policy be exercised against recorded routes before a backend is allowed
--  to change where a model computes.
package Model_Runner.Expert_Cache is

   type Observation_Outcome is (Cache_Hit, Cache_Miss, Promote);

   type Statistics is record
      Observations : Interfaces.Unsigned_64 := 0;
      Hits         : Interfaces.Unsigned_64 := 0;
      Misses       : Interfaces.Unsigned_64 := 0;
      Promotions   : Interfaces.Unsigned_64 := 0;
      Evictions    : Interfaces.Unsigned_64 := 0;
   end record;

   type Policy is limited new Ada.Finalization.Limited_Controlled with private;

   --  Start a fresh policy.  Capacity is the number of experts retained per
   --  layer; zero records misses without retaining anything.
   --
   --  @param Item Policy to configure.
   --  @param Layers Number of mixture layers.
   --  @param Experts Number of experts in each layer.
   --  @param Capacity Experts retained per layer.
   procedure Configure
     (Item     : in out Policy;
      Layers   : Natural;
      Experts  : Natural;
      Capacity : Natural);

   --  Forget all storage and counters.  Idempotent.
   --
   --  @param Item Policy to clear.
   procedure Clear (Item : in out Policy);

   --  Record one router choice and update the resident set.  A cold entry is
   --  promoted only when there is room or its decayed frequency is greater
   --  than the least useful resident entry in the same layer.
   --
   --  @param Item Policy to update.
   --  @param Layer Layer containing the routed expert.
   --  @param Expert Routed expert.
   --  @param Outcome Whether this was a hit, miss, or promotion.
   procedure Observe
     (Item    : in out Policy;
      Layer   : Natural;
      Expert  : Natural;
      Outcome : out Observation_Outcome);

   --  Whether an expert belongs to the policy's resident set.
   --
   --  @param Item Policy to inspect.
   --  @param Layer Layer containing the expert.
   --  @param Expert Expert to inspect.
   --  @return True when the expert is resident.
   function Is_Resident
     (Item : Policy; Layer : Natural; Expert : Natural) return Boolean;

   --  Current fixed-point recency/frequency score.  It is intended for
   --  telemetry and deterministic tests, not as a stable serialized value.
   --
   --  @param Item Policy to inspect.
   --  @param Layer Layer containing the expert.
   --  @param Expert Expert to inspect.
   --  @return Current score.
   function Score
     (Item : Policy; Layer : Natural; Expert : Natural)
      return Interfaces.Unsigned_64;

   --  Counters accumulated by the policy.
   --
   --  @param Item Policy to inspect.
   --  @return Current counters.
   function Current_Statistics (Item : Policy) return Statistics;

   --  Number of configured layers.
   --
   --  @param Item Policy to inspect.
   --  @return Configured layer count.
   function Layer_Count (Item : Policy) return Natural;

   --  Number of configured experts per layer.
   --
   --  @param Item Policy to inspect.
   --  @return Configured expert count.
   function Expert_Count (Item : Policy) return Natural;

   --  Number of experts the policy may retain per layer.
   --
   --  @param Item Policy to inspect.
   --  @return Configured capacity.
   function Capacity_Per_Layer (Item : Policy) return Natural;

private

   type Cache_Entry is record
      Points    : Interfaces.Unsigned_64 := 0;
      Seen_At   : Interfaces.Unsigned_64 := 0;
      Resident  : Boolean := False;
   end record;

   type Entry_Array is array (Natural range <>) of Cache_Entry;
   type Entry_Array_Access is access Entry_Array;

   type Policy is limited new Ada.Finalization.Limited_Controlled with record
      Entries   : Entry_Array_Access := null;
      Layers    : Natural := 0;
      Experts   : Natural := 0;
      Capacity  : Natural := 0;
      Clock     : Interfaces.Unsigned_64 := 0;
      Counts    : Statistics;
   end record;

   overriding procedure Finalize (Item : in out Policy);

end Model_Runner.Expert_Cache;
