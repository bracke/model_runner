package body Model_Runner.Durable_Syncs is

   --  For each kind, how many syncs are still done before one fails;
   --  Natural'Last, none is to.
   Ahead : array (Kind) of Natural := [others => Natural'Last];

   procedure Fail_Next (Which : Kind; Passing : Natural := 0) is
   begin
      Ahead (Which) := Passing;
   end Fail_Next;

   --  Whether this sync of WHICH is the one to fail.
   function Fails (Which : Kind) return Boolean is
   begin
      if Ahead (Which) = Natural'Last then
         return False;
      elsif Ahead (Which) = 0 then
         Ahead (Which) := Natural'Last;
         return True;
      else
         Ahead (Which) := Ahead (Which) - 1;
         return False;
      end if;
   end Fails;

   function Sync_File (Path : String) return Hostkit.Durability.Outcome is
     (if Fails (File) then Hostkit.Durability.Failed else Hostkit.Durability.Sync_File (Path));

   function Sync_Directory (Path : String) return Hostkit.Durability.Outcome is
     (if Fails (Folder) then Hostkit.Durability.Failed else Hostkit.Durability.Sync_Directory (Path));

end Model_Runner.Durable_Syncs;
