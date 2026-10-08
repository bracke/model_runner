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

   --  Whether the caches go as halves: a session holding halves, or an
   --  exact one whose every key and value is a half already -- which is
   --  what a device keeping its cache in halves gives back.
   function Halves_Already return Boolean;

   function Halves_Already return Boolean is
      use type Interfaces.Unsigned_32;

      --  A binary32 a half holds exactly: zero, or within the half's
      --  normal range with nothing in the thirteen mantissa bits a half
      --  has not got; anything else -- a subnormal half, say -- asked of
      --  the conversion itself.
      function Is_Half (Value : Real) return Boolean is
         Bits     : constant Interfaces.Unsigned_32 := N.Bits (Value);
         Exponent : constant Interfaces.Unsigned_32 :=
           Interfaces.Shift_Right (Bits, 23) and 16#FF#;
      begin
         if (Bits and 16#7FFF_FFFF#) = 0 then
            return True;
         elsif Exponent in 113 .. 142 then
            return (Bits and 16#1FFF#) = 0;
         else
            return N.To_Real (N.To_Half (Value)) = Value;
         end if;
      end Is_Half;
   begin
      if Item.Held = Halved then
         return True;
      elsif Item.Held /= Exact then
         return False;
      end if;

      for Layer in 0 .. Layers - 1 loop
         declare
            Keys_First : constant Element_Count :=
              Keys_At (Item, Natural (Layer));
            Values_First : constant Element_Count :=
              Values_At (Item, Natural (Layer));
         begin
            for Index in 0 .. Element_Count (Run_Of (Layer) * KV_Width) - 1
            loop
               declare
                  Value : constant Real := Item.Keys.all (Keys_First + Index);
               begin
                  if not Is_Half (Value) then
                     return False;
                  end if;
               end;
            end loop;
            for Index in 0 .. Element_Count (Run_Of (Layer) * V_Width) - 1
            loop
               declare
                  Value : constant Real :=
                    Item.Values.all (Values_First + Index);
               begin
                  if not Is_Half (Value) then
                     return False;
                  end if;
               end;
            end loop;
         end;
      end loop;
      return True;
   end Halves_Already;

   Narrow : Boolean := False;
   Width  : B.Byte_Count := 4;

   --  Ten numbers of eight bytes, then a token each, then two numbers a
   --  layer saying where its run begins and how many positions the layer
   --  holds room for, then the two caches at four bytes an element
   --  whichever precision they are held in.
   function Length return B.Byte_Count
   is (10 * 8 + Held * 8 + 2 * Layers * 8
       + Spans * KV_Width * Width
       + Spans * V_Width * Width
       + States * 4
       + Marks);

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

   --  A byte at a time in place: B.Put_U32 returns its four on the
   --  secondary stack, and at every element of a cache that was most of
   --  the time Qwen3 8B's prompt of 5,000 took to save.
   --  One element of a cache: its four bytes, or a narrow file's two --
   --  the half it is, which Halves_Already found it to be.
   procedure Put_Element (Bits : Interfaces.Unsigned_32);

   procedure Put_Bits (Bits : Interfaces.Unsigned_32) is
      use type Interfaces.Unsigned_32;
      At_First : constant B.Byte_Count := Into.all'First + At_Byte;
   begin
      Into.all (At_First) := B.Byte (Bits and 16#FF#);
      Into.all (At_First + 1) :=
        B.Byte (Interfaces.Shift_Right (Bits, 8) and 16#FF#);
      Into.all (At_First + 2) :=
        B.Byte (Interfaces.Shift_Right (Bits, 16) and 16#FF#);
      Into.all (At_First + 3) := B.Byte (Interfaces.Shift_Right (Bits, 24));
      At_Byte := At_Byte + 4;
   end Put_Bits;

   --  A run of an exact session's keys or values written narrow at once,
   --  into the halves the file holds where they lie: an element at a time
   --  through Put_Element was most of the save.
   procedure Put_Run
     (From : N.Real_Array; First : Element_Count; Count : Element_Count);

   procedure Put_Element (Bits : Interfaces.Unsigned_32) is
      use type Interfaces.Unsigned_32;
      At_First : constant B.Byte_Count := Into.all'First + At_Byte;
      Exponent : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Right (Bits, 23) and 16#FF#;

      --  The half a binary32 that is one already stands for, by its bits:
      --  the sign, the exponent rebased, the mantissa's top ten. Zero and
      --  the rest -- a subnormal half -- through the conversion, which a
      --  call an element made the slower half of the save.
      Half     : constant Interfaces.Unsigned_32 :=
        (if Item.Held = Halved then Bits
         elsif (Bits and 16#7FFF_FFFF#) = 0
         then Interfaces.Shift_Right (Bits, 16)
         elsif Exponent in 113 .. 142
         then (Interfaces.Shift_Right (Bits, 16) and 16#8000#)
              or Interfaces.Shift_Left (Exponent - 112, 10)
              or (Interfaces.Shift_Right (Bits, 13) and 16#3FF#)
         else Interfaces.Unsigned_32 (N.To_Half (N.From_Bits (Bits))));
   begin
      if not Narrow then
         Put_Bits (Bits);
         return;
      end if;

      Into.all (At_First) := B.Byte (Half and 16#FF#);
      Into.all (At_First + 1) :=
        B.Byte (Interfaces.Shift_Right (Half, 8) and 16#FF#);
      At_Byte := At_Byte + 2;
   end Put_Element;

   procedure Put_Run
     (From : N.Real_Array; First : Element_Count; Count : Element_Count)
   is
      use type Interfaces.Unsigned_32;
      Halves : N.Half_Array (0 .. Count - 1)
        with Import, Address => Into.all (Into.all'First + At_Byte)'Address;
   begin
      for Index in 0 .. Count - 1 loop
         declare
            Bits     : constant Interfaces.Unsigned_32 :=
              N.Bits (From (First + Index));
            Exponent : constant Interfaces.Unsigned_32 :=
              Interfaces.Shift_Right (Bits, 23) and 16#FF#;
         begin
            Halves (Index) :=
              (if (Bits and 16#7FFF_FFFF#) = 0
               then N.Half (Interfaces.Shift_Right (Bits, 16))
               elsif Exponent in 113 .. 142
               then N.Half ((Interfaces.Shift_Right (Bits, 16) and 16#8000#)
                            or Interfaces.Shift_Left (Exponent - 112, 10)
                            or (Interfaces.Shift_Right (Bits, 13) and 16#3FF#))
               else N.To_Half (From (First + Index)));
         end;
      end loop;
      At_Byte := At_Byte + B.Byte_Count (Count) * 2;
   end Put_Run;
begin
   --  What the device wrote and the host was owed, which this
   --  reads: the copy is brought up to date where it is used
   --  rather than at the end of every call.
   declare
      Settled : Boolean;
   begin
      Settle_Cache (Item, Settled);
   end;

   Narrow := Halves_Already;
   Width := (if Narrow then 2 else 4);

   Into := null;
   Status := E.Success;

   if Item.Current not in Ready | Evaluating_Prompt | Generating
     or else Item.Owner = null
   then
      Status := E.Make (E.Lifecycle_Invalid_State);
      return;
   end if;

   --  Not zeroed: every byte of it is written below, and zeroing a
   --  gigabyte first was a second of the save.
   begin
      Into := new B.Byte_Array (1 .. Length);
   exception
      when Storage_Error =>
         Into := null;
   end;
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
                 then 8 * Cache_Precision'Pos (Item.Held_Values) else 0)
              + (if Narrow then Narrow_Elements else 0));

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
         if Narrow and then Item.Held = Exact then
            Put_Run (Item.Keys.all, First,
                     Element_Count (Run_Of (Layer_Index) * KV_Width));
         else
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
                  Put_Element (N.Bits (Item.Keys.all (First + Index)));
               else
                  Put_Element
                    (Interfaces.Unsigned_32
                       (Item.Half_Keys.all (First + Index)));
               end if;
            end loop;
         end if;
      end;
   end loop;

   for Layer_Index in 0 .. Layers - 1 loop
      declare
         First : constant Element_Count :=
           Values_At (Item, Natural (Layer_Index));
      begin
         if Narrow and then Item.Held = Exact then
            Put_Run (Item.Values.all, First,
                     Element_Count (Run_Of (Layer_Index) * V_Width));
         else
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
                  Put_Element (N.Bits (Item.Values.all (First + Index)));
               else
                  Put_Element
                    (Interfaces.Unsigned_32
                       (Item.Half_Values.all (First + Index)));
               end if;
            end loop;
         end if;
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
