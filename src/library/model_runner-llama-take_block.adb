separate (Model_Runner.Llama)
procedure Take_Block (Item : Session_Access; Ok : out Boolean)
is
   use type Model_Runner.Backend.Backend_Kind;

   Seat : Natural := 0;
begin
   Ok := False;

   if Item = null
     or else Item.Owner = null
     or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
     or else Item.Paged
     or else (Item.Held = Exact
              and then (Item.Keys = null or else Item.Values = null))
     or else Item.Held = Halved
     --  A head wider than the room the device's attention keeps is
     --  attended on the processor whatever the cache holds, so the
     --  cache is not put there: it was, and written every position,
     --  for kernels that would refuse every layer that read it.
     or else (Model_Runner.Backend.Device.Attention_Head_Room > 0
              and then
                (Item.Owner.Settings.Head_Size
                 > Model_Runner.Backend.Device.Attention_Head_Room
                 or else Item.Owner.Settings.Value_Size
                         > Model_Runner.Backend.Device.Attention_Head_Room))
     or else (Item.Held in Eighth | Fourth
              and then (Item.Byte_Keys = null or else Item.Byte_Values = null
                        or else Item.Key_Scales = null
                        or else Item.Value_Scales = null
                        or else not Model_Runner.Backend.Device.Attends_Packed
                        --  And a shape that kernel reads: it takes four
                        --  elements of a row at a time out of one word,
                        --  so a head is a whole number of fours. A model
                        --  whose heads are another shape used to take a
                        --  block of the device's cache, have it written
                        --  every position, and have every layer's
                        --  sequence built and refused at its attention
                        --  step -- the uploads of a cache nothing there
                        --  would read.
                        or else not
                          Model_Runner.Backend.Device.Attends_Packed_Heads
                            (Item.Owner.Settings.Head_Size,
                             Item.Owner.Settings.Value_Size)))
   then
      return;
   end if;

   Blocks_Were_Held := False;

   --  A block is the whole context at once: room for it first, where the
   --  device holds feed-forward layers only until the cache wants it.
   if not (Item.Seat >= 0 and then Block_Holder (Item.Seat) = Item) then
      Room_For_Cache (Item.all, Item.Context);
   end if;

   --  Already this session's, which is every call after the first:
   --  there is nothing to ask the device and nothing to write. Stamped
   --  as it goes, so that the block another session takes where every
   --  one is held is the one nobody has read for longest.
   if Item.Seat >= 0 and then Block_Holder (Item.Seat) = Item then
      Ok := True;
      return;
   end if;

   --  A session with nothing to keep has nothing to be given.
   if Block_Span_Of (Item.all) = 0 then
      return;
   end if;

   --  And a block is not dealt while pages are: the two grow from the
   --  front of the one buffer, so a device holds one kind or the other.
   --  A block session that finds pages held attends on the host until
   --  they are given back.
   if Pages_In_Use > 0 then
      return;
   end if;

   --  The lowest free one. A closed session gives its block back, so
   --  what a long-running server deals out is the sessions it has open
   --  rather than the sessions it has ever opened.
   while Seat < Block_Holder'Length
     and then Block_Holder (Seat) /= null
   loop
      Seat := Seat + 1;
   end loop;

   --  None free: the device's blocks are all held, so this session
   --  attends on the host until one comes back. A block is given up
   --  when its session closes, so what is dealt out is the sessions
   --  open at once, not the sessions ever opened -- and a personal
   --  tool holds one or two.
   if Seat >= Block_Holder'Length then
      Blocks_Were_Held := True;
      return;
   end if;

   declare
      --  What this session keeps, and where it goes: the first gap in
      --  the buffer that holds it, from the front, past every block held
      --  that overlaps -- which is how a ring is placed in the room of
      --  rings, and for the same reason. A block used to be its seat
      --  times one dealt width, so a short-context session behind a long
      --  one took a block the long one's size and a session wanting more
      --  than the dealt width was refused the cache for as long as any
      --  session of that width was open.
      Span : constant Element_Count := Block_Span_Of (Item.all);

      Base : Element_Count := First_Block_Gap (Span);

      Written : Boolean := True;
   begin
      --  Where that gap is past what the buffer has been dealt to while
      --  there is a gap below it, the blocks are moved down instead of
      --  the buffer growing -- as the room of rings moves its seats,
      --  and for the same reason: blocks are the size of the sessions
      --  in them and come back in whatever order those sessions close.
      if Base + Span > Block_Taken then
         declare
            Taken : Element_Count := 0;
            Moved : Boolean;
         begin
            for Which in Block_Holder'Range loop
               if Block_Holder (Which) /= null then
                  Taken :=
                    Taken
                    + (Block_Span_Of (Block_Holder (Which).all)
                       + Block_Alignment - 1)
                      / Block_Alignment * Block_Alignment;
               end if;
            end loop;

            if Block_Taken - Taken >= Span then
               Compact_Blocks (Span, Moved);

               if Moved then
                  Base := First_Block_Gap (Span);
               end if;
            end if;
         end;
      end if;

      declare
         --  Room for this block and every block held, for the table a
         --  round reads past them, and for a layer's sinks past that.
         Wanted : constant Element_Count :=
           Element_Count'Max (Base + Span, Block_Taken)
           + Element_Count (Model_Runner.Backend.Device.Table_Room)
           + Sink_Footprint (Item.Owner.Settings);

         --  And how far the halves are read: this block's need and
         --  every held block's, which for a packed one is the room a
         --  layer unpacks into and not the block.
         Copy_Upto : Element_Count := Base + Copy_Span_Of (Item.all);
      begin
         for Which in Block_Holder'Range loop
            if Block_Holder (Which) /= null then
               Copy_Upto :=
                 Element_Count'Max
                   (Copy_Upto,
                    Block_Holder (Which).Cache_Base
                    + Copy_Span_Of (Block_Holder (Which).all));
            end if;
         end loop;

         --  Where the model learned no sinks, the cache proper is only
         --  ever written on the device and never read -- the matrix
         --  kernel attends out of the half-precision copy -- so a
         --  context whose binary32 cache would not fit one storage
         --  buffer may keep just the copy and still attend on the
         --  device. A model with sinks reads the binary32, and a round
         --  reads it too, so neither takes this.
         --  Where the keys end and the values begin in the copy, in
         --  halves: the copy is every layer's keys and then every
         --  layer's values, so the keys' length is the boundary. A
         --  context wide enough that even the copy will not fit one
         --  buffer splits there, keeping the two halves apart.
         Model_Runner.Backend.Device.Reserve_Cache
           (Wanted, Copy_Upto, Ok,
            Allow_Copy_Only => Sink_Footprint (Item.Owner.Settings) = 0,
            Keys_Upto =>
              (if Item.Keys = null then 0 else Item.Keys.all'Length));
         if not Ok then
            return;
         end if;

         if Base + Span > Block_Taken then
            Block_Taken := Base + Span;
         end if;
      end;

      Item.Cache_Base := Base;

      Write_Block (Item, Base, Written);

      if not Written then
         Ok := False;
         return;
      end if;

      Item.Seat := Seat;
      Block_Holder (Seat) := Item;
      Ok := True;
   end;
end Take_Block;
