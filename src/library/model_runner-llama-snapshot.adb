separate (Model_Runner.Llama)
procedure Snapshot
  (Item   : in out Session;
   Source : Model'Class;
   Into   : out B.Byte_Array_Access;
   Status : out E.Error_Info)
is
   Settings : constant Configuration := Source.Settings;

   Held     : constant B.Byte_Count := B.Byte_Count (Item.Committed);
   KV_Width : constant B.Byte_Count :=
     B.Byte_Count (Settings.KV_Heads * Settings.Head_Size);
   V_Width  : constant B.Byte_Count :=
     B.Byte_Count (Settings.KV_Heads * Settings.Value_Size);
   Layers   : constant B.Byte_Count := B.Byte_Count (Settings.Layers);

   --  Where each layer's run begins, and how long it is. A layer that
   --  holds everything begins at zero and runs to what was committed,
   --  which is what every layer did before one of them slid.
   function Origin_Of (Layer : B.Byte_Count) return B.Byte_Count
   is (if Item.Origin = null then 0
       else B.Byte_Count (Item.Origin.all (Natural (Layer))));

   --  A linear layer holds no keys and values: nothing of it is a run.
   function Run_Of (Layer : B.Byte_Count) return B.Byte_Count
   is (if Linear (Settings, Natural (Layer)) or else Origin_Of (Layer) >= Held
       then 0 else Held - Origin_Of (Layer));

   --  And what it holds instead, written after every layer's values:
   --  every linear layer's convolution memory and state, as they are.
   States : constant B.Byte_Count :=
     (if Hybrid (Settings.Kind)
      then B.Byte_Count (Conv_Room (Settings))
           + B.Byte_Count (State_Room (Settings))
      else 0);

   function Runs return B.Byte_Count;

   function Runs return B.Byte_Count is
      Total : B.Byte_Count := 0;
   begin
      for Layer in 0 .. Layers - 1 loop
         Total := Total + Run_Of (Layer);
      end loop;
      return Total;
   end Runs;

   Spans : constant B.Byte_Count := Runs;

   --  And after everything, for a model whose positions have three
   --  parts, what each committed position turns by: four numbers of
   --  eight bytes a position. A reader that finds them missing --
   --  a snapshot from before they were written -- turns every
   --  position by its index, which is what a snapshot from then held.
   Marks : constant B.Byte_Count :=
     (if Item.Marks = null then 0 else Held * 4 * 8);

   --  Ten numbers of eight bytes, then a token each, then two numbers a
   --  layer saying where its run begins and how many positions the layer
   --  holds room for, then the two caches at four bytes an element
   --  whichever precision they are held in.
   Length : constant B.Byte_Count :=
     10 * 8 + Held * 8 + 2 * Layers * 8
     + Spans * KV_Width * 4
     + Spans * V_Width * 4
     + States * 4
     + Marks;

   At_Byte : B.Byte_Count := 0;

   procedure Put (Value : Interfaces.Unsigned_64) is
   begin
      Into.all (Into.all'First + At_Byte .. Into.all'First + At_Byte + 7) :=
        B.Put_U64 (Value);
      At_Byte := At_Byte + 8;
   end Put;

   procedure Put_Count (Value : Natural) is
   begin
      Put (Interfaces.Unsigned_64 (Value));
   end Put_Count;

   procedure Put_Bits (Bits : Interfaces.Unsigned_32) is
   begin
      Into.all (Into.all'First + At_Byte .. Into.all'First + At_Byte + 3) :=
        B.Put_U32 (Bits);
      At_Byte := At_Byte + 4;
   end Put_Bits;
begin
   --  What the device wrote and the host was owed, which this
   --  reads: the copy is brought up to date where it is used
   --  rather than at the end of every call.
   declare
      Settled : Boolean;
   begin
      Settle_Cache (Item, Settled);
   end;

   Into := null;
   Status := E.Success;

   if Item.Current not in Ready | Evaluating_Prompt | Generating
     or else Item.Owner = null
   then
      Status := E.Make (E.Lifecycle_Invalid_State);
      return;
   end if;

   B.Allocate (Length, Into);
   if Into = null then
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;

   Put (Interfaces.Unsigned_64'(Session_Magic));
   Put_Count (Natural'(Session_Version));
   Put (Fingerprint (Source));
   Put_Count (Settings.Layers);
   Put_Count (Settings.KV_Heads);
   Put_Count (Settings.Head_Size);
   Put_Count (Settings.Value_Size);
   Put_Count (Item.Context);
   Put_Count (Item.Committed);
   --  The keys' storage, and the values' where it differs, in the
   --  word's eighths: a snapshot of a session storing both alike says
   --  what it always said.
   Put_Count (Cache_Precision'Pos (Item.Held)
              + (if Item.Held_Values /= Item.Held
                 then 8 * Cache_Precision'Pos (Item.Held_Values) else 0));

   for Index in 0 .. Item.Committed - 1 loop
      Put_Count (Natural (Item.History.all (Index)));
   end loop;

   --  Where each layer's run begins, and the room it has. The second is
   --  what a reader compares against its own geometry: a session opened
   --  the same way cuts the cache the same way, and one that did not
   --  cannot be told where these positions belong.
   for Layer_Index in 0 .. Layers - 1 loop
      Put (Interfaces.Unsigned_64 (Origin_Of (Layer_Index)));
      Put (Interfaces.Unsigned_64
             (if Item.Cells = null then Element_Count (Item.Context)
              else Item.Cells.all (Natural (Layer_Index))));
   end loop;

   --  One layer's run of positions at a time, from where that layer
   --  begins, and the layers are not adjacent.
   for Layer_Index in 0 .. Layers - 1 loop
      declare
         First : constant Element_Count :=
           Keys_At (Item, Natural (Layer_Index));
      begin
         for Index in 0 .. Element_Count (Run_Of (Layer_Index) * KV_Width)
                            - 1
         loop
            if Item.Held in Eighth | Fourth then
               --  Written as the numbers it stands for rather than as
               --  its bytes and scales: a saved context is read back by
               --  a session that may hold a different precision, and
               --  four bytes an element is what the format says.
               Put_Bits
                 (N.Bits
                    (Unpack
                       (Item.Byte_Keys.all, First + Index,
                        Element_Count (KV_Width), Item.Key_Scales.all,
                        Item.Held)));
            elsif Item.Held = Exact then
               Put_Bits (N.Bits (Item.Keys.all (First + Index)));
            else
               Put_Bits
                 (Interfaces.Unsigned_32
                    (Item.Half_Keys.all (First + Index)));
            end if;
         end loop;
      end;
   end loop;

   for Layer_Index in 0 .. Layers - 1 loop
      declare
         First : constant Element_Count :=
           Values_At (Item, Natural (Layer_Index));
      begin
         for Index in 0 .. Element_Count (Run_Of (Layer_Index) * V_Width)
                            - 1
         loop
            --  The values as the keys above, and the packed caches
            --  unpacked as the keys were: the byte cache's values
            --  went through the halved arm here, which holds nothing
            --  for it, and a byte session could not snapshot at all.
            if Item.Held in Eighth | Fourth then
               Put_Bits
                 (N.Bits
                    (Unpack
                       (Item.Byte_Values.all, First + Index,
                        Element_Count (V_Width), Item.Value_Scales.all,
                        Item.Held_Values)));
            elsif Item.Held = Exact then
               Put_Bits (N.Bits (Item.Values.all (First + Index)));
            else
               Put_Bits
                 (Interfaces.Unsigned_32
                    (Item.Half_Values.all (First + Index)));
            end if;
         end loop;
      end;
   end loop;

   --  The linear layers' memories and states as they are now: the
   --  slot the committed count reads, whole.
   if Item.Conv_State /= null then
      declare
         Slot : constant Element_Count := State_Slot (Item, Item.Committed);
         Every : constant Element_Count := Conv_Room (Source.Settings);
      begin
         for Value of Item.Conv_State.all
           (Slot * Every .. (Slot + 1) * Every - 1)
         loop
            Put_Bits (N.Bits (Value));
         end loop;
      end;
   end if;

   if Item.Delta_State /= null then
      declare
         Slot : constant Element_Count := State_Slot (Item, Item.Committed);
         Every : constant Element_Count := State_Room (Source.Settings);
      begin
         for Value of Item.Delta_State.all
           (Slot * Every .. (Slot + 1) * Every - 1)
         loop
            Put_Bits (N.Bits (Value));
         end loop;
      end;
   end if;

   if Item.Marks /= null then
      for Index in 0 .. Item.Committed - 1 loop
         declare
            Mark : constant Rope_Mark := Item.Marks.all (Index);
         begin
            Put_Count (Mark.Place.T);
            Put_Count (Mark.Place.H);
            Put_Count (Mark.Place.W);
            Put_Count (Mark.Next);
         end;
      end loop;
   end if;
end Snapshot;
