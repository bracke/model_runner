with Interfaces.C;

package body Model_Runner.Platform.IO_Cancellation is

   use type Interfaces.C.int;
   use type System.Address;

   subtype DWord is Interfaces.C.unsigned_long;
   Thread_Terminate : constant DWord := 16#0001#;

   function Get_Current_Thread_Id return DWord
     with Import, Convention => Stdcall, External_Name => "GetCurrentThreadId";

   function Open_Thread
     (Access_Rights : DWord;
      Inherit       : Interfaces.C.int;
      Thread_Id     : DWord) return System.Address
     with Import, Convention => Stdcall, External_Name => "OpenThread";

   function Cancel_Synchronous_IO
     (Thread : System.Address) return Interfaces.C.int
     with Import, Convention => Stdcall, External_Name => "CancelSynchronousIo";

   function Close_Handle (Handle : System.Address) return Interfaces.C.int
     with Import, Convention => Stdcall, External_Name => "CloseHandle";

   function Supported return Boolean is (True);

   procedure Register_Current_Task
     (Item       : in out Token;
      Registered : out Boolean)
   is
   begin
      Item.Handle := Open_Thread
        (Thread_Terminate, 0, Get_Current_Thread_Id);
      Registered := Item.Handle /= System.Null_Address;
   end Register_Current_Task;

   function Cancel (Item : Token) return Boolean is
     (Item.Handle /= System.Null_Address
      and then Cancel_Synchronous_IO (Item.Handle) /= 0);

   procedure Release (Item : in out Token) is
      Ignored : Interfaces.C.int;
   begin
      if Item.Handle /= System.Null_Address then
         Ignored := Close_Handle (Item.Handle);
         Item.Handle := System.Null_Address;
      end if;
   end Release;

end Model_Runner.Platform.IO_Cancellation;
