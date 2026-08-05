with Ada.Real_Time;

package body Model_Runner.Clocks is

   use type Interfaces.Unsigned_64;

   --  Elaboration-time origin, so that readings start near zero and cannot
   --  overflow the 64-bit nanosecond range within any plausible run.
   Origin : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

   ----------
   -- Read --
   ----------

   function Read (Item : Clock_Reference) return Nanoseconds
   is (if Item = null then 0 else Item.all.Now);

   -------------
   -- Elapsed --
   -------------

   function Elapsed (From, To : Nanoseconds) return Nanoseconds
   is (if To >= From then To - From else 0);

   ----------------------
   -- Rate_Per_Second --
   ----------------------

   function Rate_Per_Second
     (Units       : Interfaces.Unsigned_64;
      Duration_Ns : Nanoseconds) return Long_Float is
   begin
      if Duration_Ns = 0 then
         return 0.0;
      else
         return Long_Float (Units) * Long_Float (Nanoseconds_Per_Second)
           / Long_Float (Duration_Ns);
      end if;
   end Rate_Per_Second;

   ---------
   -- Now --
   ---------

   overriding function Now (Self : System_Clock) return Nanoseconds is
      pragma Unreferenced (Self);
      use type Ada.Real_Time.Time;
      Span    : constant Ada.Real_Time.Time_Span :=
        Ada.Real_Time.Clock - Origin;
      Elapsed_Time : constant Duration := Ada.Real_Time.To_Duration (Span);
   begin
      if Elapsed_Time <= 0.0 then
         return 0;
      else
         return Nanoseconds
           (Long_Float (Elapsed_Time) * Long_Float (Nanoseconds_Per_Second));
      end if;
   exception
      when others =>
         return 0;
   end Now;

end Model_Runner.Clocks;
