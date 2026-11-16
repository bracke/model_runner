private with System;

--  Cancellation for a synchronous host I/O call made by a known task.
--  This is needed only on hosts whose anonymous pipes cannot be made
--  non-blocking.  A token belongs to one task and one call at a time.
package Model_Runner.Platform.IO_Cancellation is

   type Token is limited private;

   --  Whether this host can cancel a synchronous I/O call in another task.
   function Supported return Boolean;

   --  Register the calling task.  Registered is False when the host could
   --  not acquire the handle needed to cancel that task's next I/O call.
   procedure Register_Current_Task
     (Item       : in out Token;
      Registered : out Boolean);

   --  Ask the host to end the registered task's pending synchronous I/O.
   function Cancel (Item : Token) return Boolean;

   --  Release the registration after the I/O call has returned.
   procedure Release (Item : in out Token);

private
   type Token is limited record
      Handle : System.Address := System.Null_Address with Atomic;
   end record;

end Model_Runner.Platform.IO_Cancellation;
