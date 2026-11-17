private with System;

--  Cancellation for a synchronous host I/O call made by a known task.
--  This is needed only on hosts whose anonymous pipes cannot be made
--  non-blocking.  A token belongs to one task and one call at a time.
package Model_Runner.Platform.IO_Cancellation is

   type Token is limited private;

   --  Whether this host can cancel a synchronous I/O call in another task.
   --
   --  @return True when cancellation is supported.
   function Supported return Boolean;

   --  Register the calling task.  Registered is False when the host could
   --  not acquire the handle needed to cancel that task's next I/O call.
   --
   --  @param Item Registration token to fill.
   --  @param Registered True when the task was registered.
   procedure Register_Current_Task
     (Item       : in out Token;
      Registered : out Boolean);

   --  Ask the host to end the registered task's pending synchronous I/O.
   --
   --  @param Item Registration token for the task.
   --  @return True when cancellation was requested successfully.
   function Cancel (Item : Token) return Boolean;

   --  Release the registration after the I/O call has returned.
   --
   --  @param Item Registration token to release.
   procedure Release (Item : in out Token);

private
   type Token is limited record
      Handle : System.Address := System.Null_Address with Atomic;
   end record;

end Model_Runner.Platform.IO_Cancellation;
