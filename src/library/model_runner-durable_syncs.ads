with Hostkit.Durability;

--  The syncs a write is made durable with, through which a test can have
--  one fail: a device that will not take what was written fails only now
--  and then, and what a write does then is held to a test here.
--
--  Task safety: failing is for one test at a time.
package Model_Runner.Durable_Syncs is

   --  What is synced: a file's contents, or a folder's entries.
   type Kind is (File, Folder);

   --  Have a later sync of this kind fail: the one after Passing others of
   --  it, once, and then not again.
   --
   --  @param Which The kind of sync.
   --  @param Passing How many of that kind are done first.
   procedure Fail_Next (Which : Kind; Passing : Natural := 0);

   --  Hostkit.Durability.Sync_File, or Failed where a test said so.
   --
   --  @param Path The file.
   --  @return What syncing came to.
   function Sync_File (Path : String) return Hostkit.Durability.Outcome;

   --  Hostkit.Durability.Sync_Directory, or Failed where a test said so.
   --
   --  @param Path The folder.
   --  @return What syncing came to.
   function Sync_Directory (Path : String) return Hostkit.Durability.Outcome;

end Model_Runner.Durable_Syncs;
