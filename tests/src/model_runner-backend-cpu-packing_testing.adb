package body Model_Runner.Backend.CPU.Packing_Testing is
   function Storage (Item : Packed_Rows) return System.Address is
     (if Item.Values = null then System.Null_Address else Item.Values (Item.Values'First)'Address);
end Model_Runner.Backend.CPU.Packing_Testing;
