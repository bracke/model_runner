private with Ada.Finalization;
private with Interfaces;

--  A table from text to a value, flat: the keys in one pool of text and
--  the slots in one array, probed in order from the key's hash.
--
--  A vocabulary's pieces and merges, a hundred and fifty thousand of each,
--  were hashed maps of indefinite keys -- an allocation for every key and
--  every node -- and building them was a quarter of a second of every load
--  and giving them back most of a second of every exit. Here a table is
--  two allocations, grown by doubling, and given back as two.
generic
   type Element_Type is private;
package Model_Runner.String_Tables is

   type Table is tagged limited private;

   --  Make room for Count keys of Text_Bytes bytes in all, so that a table
   --  filled to that does not grow while it is filled.
   --
   --  @param Item The table.
   --  @param Count Keys to hold.
   --  @param Text_Bytes Bytes the keys take together.
   procedure Reserve (Item : in out Table; Count, Text_Bytes : Natural);

   --  Add Key with Value where the table does not hold Key; where it does,
   --  leave it as it is.
   --
   --  @param Item The table.
   --  @param Key The key.
   --  @param Value Its value.
   --  @param Inserted False where Key was already there.
   procedure Insert
     (Item     : in out Table;
      Key      : String;
      Value    : Element_Type;
      Inserted : out Boolean);

   --  Add Key with Value, or where the table holds Key, give it Value.
   --
   --  @param Item The table.
   --  @param Key The key.
   --  @param Value Its value.
   procedure Include
     (Item  : in out Table;
      Key   : String;
      Value : Element_Type);

   --  The value Key has.
   --
   --  @param Item The table.
   --  @param Key The key.
   --  @param Found False where the table does not hold Key.
   --  @param Value Its value, where Found.
   procedure Find
     (Item  : Table;
      Key   : String;
      Found : out Boolean;
      Value : out Element_Type);

   --  How many keys the table holds.
   --
   --  @param Item The table.
   --  @return The count.
   function Length (Item : Table) return Natural;

   --  Give back everything the table holds.
   --
   --  @param Item The table, empty after.
   procedure Clear (Item : in out Table);

private

   type Slot is record
      Hash  : Interfaces.Unsigned_32 := 0;
      First : Positive := 1;
      Last  : Natural := 0;
      Value : Element_Type;
      Used  : Boolean := False;
   end record;

   type Slot_Array is array (Natural range <>) of Slot;
   type Slot_Access is access Slot_Array;
   type Text_Access is access String;

   type Table is new Ada.Finalization.Limited_Controlled with record
      Slots     : Slot_Access := null;
      Text      : Text_Access := null;
      Text_Used : Natural := 0;
      Count     : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Table);

end Model_Runner.String_Tables;
