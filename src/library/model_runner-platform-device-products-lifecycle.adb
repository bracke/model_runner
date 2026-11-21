package body Model_Runner.Platform.Device.Products.Lifecycle is

   protected State is
      procedure Claim (Granted : out Boolean);
      procedure Release;
      procedure Select_Instance (Item : System.Address);
      function Selected_Instance return System.Address;
   private
      Held             : Boolean := False;
      Current_Instance : System.Address := System.Null_Address;
   end State;

   protected body State is
      procedure Claim (Granted : out Boolean) is
      begin
         Granted := not Held;
         if Granted then
            Held := True;
         end if;
      end Claim;

      procedure Release is
      begin
         Held := False;
      end Release;

      procedure Select_Instance (Item : System.Address) is
      begin
         Current_Instance := Item;
      end Select_Instance;

      function Selected_Instance return System.Address is (Current_Instance);
   end State;

   procedure Claim (Granted : out Boolean) is
   begin
      State.Claim (Granted);
   end Claim;

   procedure Release is
   begin
      State.Release;
   end Release;

   procedure Select_Instance (Item : System.Address) is
   begin
      State.Select_Instance (Item);
   end Select_Instance;

   function Selected_Instance return System.Address is
     (State.Selected_Instance);

end Model_Runner.Platform.Device.Products.Lifecycle;
