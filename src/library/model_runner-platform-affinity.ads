with Ada.Finalization;
with Interfaces.C;

--  Optional thread-local placement. An unknown topology or unavailable
--  host service leaves the scheduler's placement unchanged.
package Model_Runner.Platform.Affinity is
   type Core_List is array (Natural range <>) of Integer;

   --  Choose one allowed logical processor per physical core. Return -1
   --  for every participant unless the entire team can be placed.
   --  @param Count Number of participating threads, including the caller.
   --  @return Processors indexed from zero, or -1 when unavailable.
   function Choose (Count : Positive) return Core_List;

   type Binding is new Ada.Finalization.Limited_Controlled with private;

   --  Temporarily bind only the calling thread. Restore its original mask
   --  at scope exit, including exception unwinding. An invalid or no longer
   --  allowed processor has no effect. Workers keep this scope until exit.
   --  @param Item Scope retaining the original mask.
   --  @param Processor Allowed logical processor, or -1 to leave unchanged.
   procedure Pin (Item : in out Binding; Processor : Integer);
private
   type Mask is array (Natural range 0 .. 127) of aliased Interfaces.C.unsigned_char
     with Convention => C;
   type Binding is new Ada.Finalization.Limited_Controlled with record
      Saved : Mask := [others => 0];
      Active : Boolean := False;
   end record;
   overriding procedure Finalize (Item : in out Binding);
end Model_Runner.Platform.Affinity;
