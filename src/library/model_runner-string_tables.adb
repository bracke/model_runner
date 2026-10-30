with Ada.Unchecked_Deallocation;

package body Model_Runner.String_Tables is

   use type Interfaces.Unsigned_32;

   procedure Free is new Ada.Unchecked_Deallocation (Slot_Array, Slot_Access);
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   --  FNV-1a over the key's bytes.
   function Hash_Of (Key : String) return Interfaces.Unsigned_32 is
      Result : Interfaces.Unsigned_32 := 2_166_136_261;
   begin
      for Char of Key loop
         Result := (Result xor Character'Pos (Char)) * 16_777_619;
      end loop;
      return Result;
   end Hash_Of;

   --  The smallest power of two at least twice Count, and sixteen at
   --  least: probing stays short at half full.
   function Slots_For (Count : Natural) return Natural is
      Result : Natural := 16;
   begin
      while Result < 2 * Count loop
         Result := Result * 2;
      end loop;
      return Result;
   end Slots_For;

   --  Where Key is, or the free slot it would take.
   function Place
     (Item : Table;
      Key  : String;
      Hash : Interfaces.Unsigned_32) return Natural
   is
      Mask : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Item.Slots'Length - 1);
      At_Slot : Natural := Natural (Hash and Mask);
   begin
      loop
         declare
            This : Slot renames Item.Slots (At_Slot);
         begin
            if not This.Used
              or else (This.Hash = Hash
                       and then This.Last - This.First + 1 = Key'Length
                       and then Item.Text (This.First .. This.Last) = Key)
            then
               return At_Slot;
            end if;
         end;
         At_Slot := (At_Slot + 1) mod Item.Slots'Length;
      end loop;
   end Place;

   --  The first free slot from Hash's, for a key moved into new slots,
   --  which no slot there holds yet.
   function Free_Place
     (Item : Table;
      Hash : Interfaces.Unsigned_32) return Natural
   is
      Mask : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Item.Slots'Length - 1);
      At_Slot : Natural := Natural (Hash and Mask);
   begin
      while Item.Slots (At_Slot).Used loop
         At_Slot := (At_Slot + 1) mod Item.Slots'Length;
      end loop;
      return At_Slot;
   end Free_Place;

   --  Room for one more key of Bytes bytes: the slots doubled past half
   --  full, the text doubled past its end.
   procedure Make_Room (Item : in out Table; Bytes : Natural) is
   begin
      if Item.Slots = null or else 2 * (Item.Count + 1) > Item.Slots'Length
      then
         declare
            Old : Slot_Access := Item.Slots;
         begin
            Item.Slots := new Slot_Array
              (0 .. Slots_For (Item.Count + 1) - 1);
            if Old /= null then
               for Moving of Old.all loop
                  if Moving.Used then
                     Item.Slots (Free_Place (Item, Moving.Hash)) := Moving;
                  end if;
               end loop;
               Free (Old);
            end if;
         end;
      end if;

      if Item.Text = null or else Item.Text_Used + Bytes > Item.Text'Length
      then
         declare
            Old  : Text_Access := Item.Text;
            Size : Natural := (if Old = null then 4_096 else Old'Length);
         begin
            while Size < Item.Text_Used + Bytes loop
               Size := Size * 2;
            end loop;
            Item.Text := new String (1 .. Size);
            if Old /= null then
               Item.Text (1 .. Item.Text_Used) := Old (1 .. Item.Text_Used);
               Free (Old);
            end if;
         end;
      end if;
   end Make_Room;

   procedure Reserve (Item : in out Table; Count, Text_Bytes : Natural) is
   begin
      if Item.Slots = null or else Item.Slots'Length < Slots_For (Count) then
         declare
            Old : Slot_Access := Item.Slots;
         begin
            Item.Slots := new Slot_Array (0 .. Slots_For (Count) - 1);
            if Old /= null then
               for Moving of Old.all loop
                  if Moving.Used then
                     Item.Slots (Free_Place (Item, Moving.Hash)) := Moving;
                  end if;
               end loop;
               Free (Old);
            end if;
         end;
      end if;
      if Text_Bytes > 0
        and then (Item.Text = null or else Item.Text'Length < Text_Bytes)
      then
         declare
            Old : Text_Access := Item.Text;
         begin
            Item.Text := new String (1 .. Text_Bytes);
            if Old /= null then
               Item.Text (1 .. Item.Text_Used) := Old (1 .. Item.Text_Used);
               Free (Old);
            end if;
         end;
      end if;
   end Reserve;

   --  Key's slot, made where it is not there; Fresh says which.
   procedure Take
     (Item  : in out Table;
      Key   : String;
      Where : out Natural;
      Fresh : out Boolean)
   is
      Hash : constant Interfaces.Unsigned_32 := Hash_Of (Key);
   begin
      Make_Room (Item, Key'Length);
      Where := Place (Item, Key, Hash);
      Fresh := not Item.Slots (Where).Used;
      if Fresh then
         Item.Text (Item.Text_Used + 1 .. Item.Text_Used + Key'Length) := Key;
         Item.Slots (Where).Hash := Hash;
         Item.Slots (Where).First := Item.Text_Used + 1;
         Item.Slots (Where).Last := Item.Text_Used + Key'Length;
         Item.Slots (Where).Used := True;
         Item.Text_Used := Item.Text_Used + Key'Length;
         Item.Count := Item.Count + 1;
      end if;
   end Take;

   procedure Insert
     (Item     : in out Table;
      Key      : String;
      Value    : Element_Type;
      Inserted : out Boolean)
   is
      Where : Natural;
   begin
      Take (Item, Key, Where, Inserted);
      if Inserted then
         Item.Slots (Where).Value := Value;
      end if;
   end Insert;

   procedure Include
     (Item  : in out Table;
      Key   : String;
      Value : Element_Type)
   is
      Where : Natural;
      Fresh : Boolean;
   begin
      Take (Item, Key, Where, Fresh);
      Item.Slots (Where).Value := Value;
   end Include;

   procedure Find
     (Item  : Table;
      Key   : String;
      Found : out Boolean;
      Value : out Element_Type)
   is
   begin
      Found := False;
      if Item.Slots = null then
         return;
      end if;
      declare
         Where : constant Natural := Place (Item, Key, Hash_Of (Key));
      begin
         if Item.Slots (Where).Used then
            Found := True;
            Value := Item.Slots (Where).Value;
         end if;
      end;
   end Find;

   function Length (Item : Table) return Natural is (Item.Count);

   procedure Clear (Item : in out Table) is
   begin
      if Item.Slots /= null then
         Free (Item.Slots);
      end if;
      if Item.Text /= null then
         Free (Item.Text);
      end if;
      Item.Text_Used := 0;
      Item.Count := 0;
   end Clear;

   overriding procedure Finalize (Item : in out Table) is
   begin
      Clear (Item);
   end Finalize;

end Model_Runner.String_Tables;
