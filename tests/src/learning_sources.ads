with Ada.Finalization;
with Model_Runner.Byte_Sources.Files;
--  Scope ownership for every file borrowed by the offline learning tools.
package Learning_Sources is
   type Guard is new Ada.Finalization.Limited_Controlled with record
      Bytes : Model_Runner.Byte_Sources.Files.File_Source;
   end record;
   --  @param Item Owned source, closed on every exit path.
   overriding procedure Finalize (Item : in out Guard);
end Learning_Sources;
