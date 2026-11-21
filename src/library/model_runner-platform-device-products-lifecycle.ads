with System;

--  Process-wide ownership and dispatch selection for the device-products
--  implementation.  Kept apart from the arithmetic engine so its global
--  lifetime is explicit and independently testable.
private package Model_Runner.Platform.Device.Products.Lifecycle is

   --  Claim the single process-wide device-products engine slot.
   --  @param Granted True when the caller acquired the slot.
   procedure Claim (Granted : out Boolean);

   --  Release the engine slot held by the caller.
   procedure Release;

   --  Select the implementation instance used by dispatched arithmetic calls.
   --  @param Item Address of the active implementation, or Null_Address.
   procedure Select_Instance (Item : System.Address);

   --  Return the implementation selected for dispatched arithmetic calls.
   --  @return Address of the active implementation, or Null_Address.
   function Selected_Instance return System.Address;

end Model_Runner.Platform.Device.Products.Lifecycle;
