--  Devices, on a host this build has no way to reach one from.
--
--  Reporting none is the honest answer rather than a stub that pretends:
--  every caller of this asks whether there is a device and is expected to go
--  on without one. A body for this host would open its own loader here.
package body Model_Runner.Platform.Device is

   function Is_Supported return Boolean is (False);

   function Entry_Point
     (Instance : System.Address; Name : String) return System.Address
   is
      pragma Unreferenced (Instance, Name);
   begin
      return System.Null_Address;
   end Entry_Point;

   procedure Open (Item : in out Inventory; Found : out Boolean) is
   begin
      Close (Item);
      Found := False;
   end Open;

   procedure Close (Item : in out Inventory) is
   begin
      Item.Used := 0;
      Item.Discrete := [others => False];
      Item.Handle := System.Null_Address;
      Item.Handles := [others => System.Null_Address];

      for Index in Item.Names'Range loop
         Item.Names (Index).Last := 0;
      end loop;
   end Close;

   function Count (Item : Inventory) return Natural is (Item.Used);

   function Name (Item : Inventory; Index : Positive) return String is
   begin
      if Index > Item.Used then
         return "";
      end if;

      return Item.Names (Index).Text (1 .. Item.Names (Index).Last);
   end Name;

   function Is_Discrete (Item : Inventory; Index : Positive) return Boolean is
   begin
      return Index <= Item.Used and then Item.Discrete (Index);
   end Is_Discrete;

   procedure Open
     (Item  : in out Context;
      From  : Inventory;
      Index : Positive;
      Ready : out Boolean)
   is
      pragma Unreferenced (From, Index);
   begin
      Close (Item);
      Ready := False;
   end Open;

   procedure Close (Item : in out Context) is
   begin
      Item.Instance := System.Null_Address;
      Item.Physical := System.Null_Address;
      Item.Logical := System.Null_Address;
      Item.Queue := System.Null_Address;
      Item.Family := 0;
      Item.Upload := 0;
      Item.Fast := 0;
      Item.Shared := False;
      Item.Heap := 0;
   end Close;

   function Is_Open (Item : Context) return Boolean is (False);

   function Queue_Family (Item : Context) return Natural is (Item.Family);

   function Shares_Memory (Item : Context) return Boolean is (Item.Shared);

   ------------------------
   -- Takes_Host_Memory --
   ------------------------

   --  Through the accessor rather than the field, because the accessor is
   --  what answers this question and a package reading its own private part
   --  around it would leave an operation nothing calls.
   function Takes_Host_Memory (Item : Context) return Boolean
   is (Item.Imports and then Shares_Memory (Item));

   ---------------------
   -- Host_Alignment --
   ---------------------

   function Host_Alignment (Item : Context) return Interfaces.Unsigned_64
   is (Item.Import_To);

   --------------------------
   -- Plain_Memory_Kinds --
   --------------------------

   function Plain_Memory_Kinds (Item : Context) return Interfaces.Unsigned_32
   is (Item.Plain_Kinds);

   function Memory_Bytes (Item : Context) return Interfaces.Unsigned_64
   is (Item.Heap);

end Model_Runner.Platform.Device;
