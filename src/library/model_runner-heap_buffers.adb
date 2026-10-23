with Ada.Unchecked_Deallocation;

package body Model_Runner.Heap_Buffers is

   procedure Free is new Ada.Unchecked_Deallocation (Ada.Streams.Stream_Element_Array, Byte_Access);
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   ----------------
   -- Initialize --
   ----------------

   overriding procedure Initialize (Item : in out Bytes) is
   begin
      Item.Data := new Ada.Streams.Stream_Element_Array (1 .. Item.Length);
   end Initialize;

   overriding procedure Initialize (Item : in out Text) is
   begin
      Item.Data := new String (1 .. Item.Length);
   end Initialize;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Bytes) is
   begin
      Free (Item.Data);
   end Finalize;

   overriding procedure Finalize (Item : in out Text) is
   begin
      Free (Item.Data);
   end Finalize;

   package body Holders is
      procedure Free is new Ada.Unchecked_Deallocation (Element, Element_Access);

      overriding procedure Initialize (Item : in out Holder) is
      begin
         Item.Data := new Element;
      end Initialize;

      overriding procedure Finalize (Item : in out Holder) is
      begin
         Free (Item.Data);
      end Finalize;
   end Holders;

end Model_Runner.Heap_Buffers;
