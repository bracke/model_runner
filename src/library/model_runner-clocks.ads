with Interfaces;

--  Monotonic timing.
--
--  Statistics are measured against a monotonic clock so that a wall-clock
--  adjustment cannot produce a negative duration or an implausible token rate.
--  The interface exists so that tests can supply a clock they control and
--  assert on exact durations.
--
--  Task safety: implementations must be callable from any task.
package Model_Runner.Clocks is

   subtype Nanoseconds is Interfaces.Unsigned_64;

   Nanoseconds_Per_Second : constant := 1_000_000_000;

   --  A source of monotonic timestamps.
   type Clock is limited interface;

   --  Current reading of a monotonic clock.
   --
   --  The epoch is unspecified; only differences are meaningful. Readings
   --  never decrease.
   --
   --  @param Self Clock instance.
   --  @return Nanoseconds since an unspecified epoch.
   function Now (Self : Clock) return Nanoseconds is abstract;

   type Clock_Reference is access all Clock'Class;

   --  Read a possibly absent clock.
   --
   --  @param Item Clock reference, possibly null.
   --  @return Current reading, or 0 when no clock was supplied.
   function Read (Item : Clock_Reference) return Nanoseconds;

   --  Difference between two readings, clamped at zero.
   --
   --  @param From Earlier reading.
   --  @param To Later reading.
   --  @return Elapsed nanoseconds; 0 when To precedes From.
   function Elapsed (From, To : Nanoseconds) return Nanoseconds;

   --  Rate in units per second.
   --
   --  @param Units Number of units processed.
   --  @param Duration_Ns Elapsed nanoseconds.
   --  @return Units per second, or 0.0 when the duration is zero.
   function Rate_Per_Second
     (Units       : Interfaces.Unsigned_64;
      Duration_Ns : Nanoseconds) return Long_Float;

   --  A clock backed by the host's monotonic timer.
   type System_Clock is limited new Clock with null record;

   --  Current reading of the host monotonic timer.
   --
   --  @param Self Clock instance.
   --  @return Nanoseconds since program elaboration.
   overriding function Now (Self : System_Clock) return Nanoseconds;

end Model_Runner.Clocks;
