with Ada.Finalization;

with Hostkit.Spawn;

--  Bounded ownership of a child process started by an integration test.
--  A failed assertion must not leave the child running or make the rest of
--  the AUnit process wait forever.
package Child_Guards is

   type Guard is limited new Ada.Finalization.Limited_Controlled with private;

   --  Make Item responsible for Child until Wait succeeds or Item finalizes.
   --  @param Item Guard that takes responsibility for the process.
   --  @param Child Process the integration test started.
   procedure Watch
     (Item  : in out Guard;
      Child : Hostkit.Spawn.Process_Handle);

   --  Wait at most Timeout seconds, collecting and releasing the child on
   --  success.  A timeout leaves it owned by Item so finalization stops it.
   --  @param Item Guard responsible for the process.
   --  @param Timeout Maximum number of seconds to wait.
   --  @param Result Process status when it ended.
   --  @return True when the child ended within the bound.
   function Wait
     (Item    : in out Guard;
      Timeout : Duration;
      Result  : out Hostkit.Spawn.Status) return Boolean;

private

   type Guard is limited new Ada.Finalization.Limited_Controlled with record
      Child : Hostkit.Spawn.Process_Handle := Hostkit.Spawn.Invalid_Process;
   end record;

   overriding procedure Finalize (Item : in out Guard);

end Child_Guards;
