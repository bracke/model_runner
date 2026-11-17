--  This fallback is compiled on POSIX hosts for which the platform project
--  does not provide a cancellable synchronous-I/O implementation. It has
--  been checked on Linux: the caller observes Supported = False and uses
--  its bounded polling road. It has not been checked on macOS; the only
--  claim made there is the same conservative refusal, with no host ABI or
--  numeric constant involved.
package body Model_Runner.Platform.IO_Cancellation is

   function Supported return Boolean is (False);

   procedure Register_Current_Task
     (Item       : in out Token;
      Registered : out Boolean)
   is
   begin
      Item.Handle := System.Null_Address;
      Registered := False;
   end Register_Current_Task;

   function Cancel (Item : Token) return Boolean is (False);

   procedure Release (Item : in out Token) is
   begin
      Item.Handle := System.Null_Address;
   end Release;

end Model_Runner.Platform.IO_Cancellation;
