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
