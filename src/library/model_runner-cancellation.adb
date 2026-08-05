package body Model_Runner.Cancellation is

   -----------
   -- Token --
   -----------

   protected body Token is

      procedure Request is
      begin
         Requested := True;
         if Requests < Natural'Last then
            Requests := Requests + 1;
         end if;
      end Request;

      procedure Reset is
      begin
         Requested := False;
         Requests := 0;
      end Reset;

      function Is_Requested return Boolean is (Requested);

      function Request_Count return Natural is (Requests);

   end Token;

   ------------------
   -- Is_Cancelled --
   ------------------

   function Is_Cancelled (Item : Token_Reference) return Boolean
   is (Item /= null and then Item.all.Is_Requested);

end Model_Runner.Cancellation;
