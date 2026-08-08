
--  Mapping on a host neither the POSIX nor the Windows body covers.
--
--  This reports that mapping is unavailable and nothing else. It is not a
--  degraded mapping: Is_Supported answers False, Open never succeeds, and the
--  byte sources fall back to reading the file, which every host can do. The
--  memory policy already distinguishes the three cases a caller cares about --
--  map if you can, map or fail, do not map -- so an absent mapping is a
--  configuration this engine already knows how to describe rather than an
--  error it has to invent.
--
--  Model_Runner.Platform.Host_Name, which hostkit answers, names the host a
--  diagnostic should mention rather than leaving the reader to guess.
package body Model_Runner.Platform.Mapping is

   package B renames Model_Runner.Bytes;

   -------------------
   -- Is_Supported --
   -------------------

   function Is_Supported return Boolean is (False);

   ----------
   -- Open --
   ----------

   procedure Open
     (Item      : in out Region;
      Path      : String;
      Available : out Boolean)
   is
      pragma Unreferenced (Path);
   begin
      Close (Item);
      Available := False;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Region) is
   begin
      Item.Address := System.Null_Address;
      Item.Size := 0;
      Item.Handle := -1;
      Item.Mapping := -1;
   end Close;

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Item : Region) return Boolean is (False);

   ----------
   -- Base --
   ----------

   function Base (Item : Region) return System.Address
   is (System.Null_Address);

   ------------
   -- Length --
   ------------

   function Length (Item : Region) return B.Byte_Count is (0);

   ----------
   -- Copy --
   ----------

   procedure Copy
     (Item   : Region;
      Offset : B.Byte_Count;
      Target : out B.Byte_Array;
      Ok     : out Boolean)
   is
      pragma Unreferenced (Item, Offset);
   begin
      Target := [others => 0];
      Ok := False;
   end Copy;

end Model_Runner.Platform.Mapping;
