package body Learning_Sources is
   overriding procedure Finalize (Item : in out Guard) is
   begin
      Model_Runner.Byte_Sources.Files.Close (Item.Bytes);
   end Finalize;
end Learning_Sources;
