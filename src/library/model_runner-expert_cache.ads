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
   procedure Configure
     (Item     : in out Policy;
      Layers   : Natural;
      Experts  : Natural;
      Capacity : Natural);

   --  Forget all storage and counters.  Idempotent.
   procedure Clear (Item : in out Policy);

   --  Record one router choice and update the resident set.  A cold entry is
   --  promoted only when there is room or its decayed frequency is greater
   --  than the least useful resident entry in the same layer.
   procedure Observe
     (Item    : in out Policy;
      Layer   : Natural;
      Expert  : Natural;
      Outcome : out Observation_Outcome);

   function Is_Resident
     (Item : Policy; Layer : Natural; Expert : Natural) return Boolean;

   --  Current fixed-point recency/frequency score.  It is intended for
   --  telemetry and deterministic tests, not as a stable serialized value.
   function Score
     (Item : Policy; Layer : Natural; Expert : Natural)
      return Interfaces.Unsigned_64;

   function Current_Statistics (Item : Policy) return Statistics;
   function Layer_Count (Item : Policy) return Natural;
   function Expert_Count (Item : Policy) return Natural;
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
