separate (Model_Runner.Llama)
procedure Take_Pages
  (Item         : Session_Access;
   Upto         : Element_Count;
   Ok           : out Boolean;
   Write_Tables : Boolean := True)
is
   use type Model_Runner.Backend.Backend_Kind;

   KV_Width : Element_Count;
   V_Width  : Element_Count;
begin
   Ok := False;

   if Item = null
     or else not Item.Paged
     or else Item.Owner = null
     or else Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_Device
     or else Item.Held not in Exact | Halved | Eighth | Fourth
     or else Item.Pages = null
     --  A cache dealt in blocks and one dealt in pages both grow from
     --  the front of the one buffer, so a device holds one kind or the
     --  other, not both at once. Where a block is held, a paged session
     --  is refused its pages and attends on the host until the blocks
     --  are given back; nothing already this session's is disturbed,
     --  since Paged_In means its pages are already dealt.
     or else (not Item.Paged_In and then Block_Taken > 0)
   then
      return;
   end if;

   --  Every page of the pool is one size, because the slots the owner
   --  array counts are that size: a base is turned back into a slot by
   --  dividing by it, in Close and where a session is turned out. Two
   --  models of different key and value widths would size their pages
   --  differently, so a session whose page is not the size the held
   --  pages are is refused while any are held and attends on the host --
   --  the pool serves one geometry at a time, as it serves one kind.
   --  Where none are held the size is the new session's.
   declare
      --  A page holds a position's keys and values -- in full for an
      --  exact session, or its four packed regions for a packed one,
      --  which is a smaller page again. The pool serves one of these at
      --  a time, so a page that is not the held size is refused.
      Want : constant Element_Count :=
        (if Item.Held in Eighth | Fourth
         then Packed_Page_Layout (Item.all).Span
         else Element_Count (Page_Positions) * Page_Row (Item.all));
   begin
      --  A smaller page takes a slot of the held size and uses the front
      --  of it: its tables hold bases, which a slot's is, and a slot is
      --  found again by dividing by the held size. A larger one would
      --  overrun its slot, and is refused while any are held. Gemma 3
      --  4B's page is four times its 270M draft's: refused, the draft
      --  attended on the host and the drafted run read 17.0 tokens a
      --  second where blocks read 19.8.
      if not Item.Paged_In
        and then Pages_In_Use > 0
        and then Want > Page_Elements
      then
         return;
      end if;

      if Pages_In_Use = 0 then
         Page_Elements := Want;
      end if;
   end;

   V_Width := Element_Count (Item.Owner.Settings.KV_Heads
                             * Item.Owner.Settings.Value_Size);
   KV_Width := Page_Row (Item.all) - V_Width;

   --  Already reaching this position, which every layer's ask but the
   --  first of a token does: the pages are all dealt, so there is no
   --  layer to walk, no reserve to grow and nothing to write. Stamped
   --  above still, so a page turned out elsewhere is the one nobody has
   --  read for longest.
   if Item.Paged_In
     and then Upto <= Element_Count (Item.Paged_Upto)
     and then Tables_Of = Item
     and then Tables_Front = Pages_Taken + Pages_Taken_Second
   then
      Ok := True;
      return;
   end if;

   --  Whether this session's later layers keep their pages in the second
   --  copy: decided at its first pages, by whether its whole context would
   --  fit one copy's slots. Only an exact sinkless session, which keeps
   --  its rows as the copy alone; the layers split by how many hold pages,
   --  half and half.
   if not Item.Paged_In
     and then (for all Layer in Item.Page_Count.all'Range =>
                 Item.Page_Count.all (Layer) = 0)
   then
      Item.Second_From := Natural'Last;

      declare
         Whole  : Element_Count := 0;
         Paging : Natural := 0;
      begin
         for Layer in 0 .. Item.Page_Count.all'Last loop
            if not Linear (Item.Owner.Settings, Layer) then
               Whole := Whole
                 + Pages_Wanted
                     (Item.all, Layer,
                      Element_Count (Natural'Max (1, Item.Context)) - 1);
               Paging := Paging + 1;
            end if;
         end loop;

         if Write_Tables
           and then Item.Held in Exact | Halved
           and then Sink_Footprint (Item.Owner.Settings) = 0
           and then Whole > Element_Count (Pool_Slots)
         then
            declare
               Seen : Natural := 0;
            begin
               for Layer in 0 .. Item.Page_Count.all'Last loop
                  if not Linear (Item.Owner.Settings, Layer) then
                     Seen := Seen + 1;
                     if Seen > Paging / 2 then
                        Item.Second_From := Layer;
                        exit;
                     end if;
                  end if;
               end loop;
            end;
         end if;
      end;
   end if;

   --  All the pages asked for or none: dealt a layer at a time until the
   --  slots ran out, a reach past the pool's cap left the first layers
   --  holding pages for the whole of it and the last none, and every
   --  batch after that was refused a page and attended on the host.
   --  Qwen3 8B, at a context of 34,816 its keys and values asked for
   --  ahead, read a prompt of 32k at seven tokens a second. Each pool
   --  against its own slots.
   declare
      More, More_Second : Element_Count := 0;
      Held_First, Held_Second : Natural := 0;
   begin
      for Layer in 0 .. Item.Page_Count.all'Last loop
         if not Linear (Item.Owner.Settings, Layer) then
            declare
               Extra : constant Element_Count :=
                 Element_Count'Max
                   (0, Pages_Wanted (Item.all, Layer, Upto)
                       - Item.Page_Count.all (Layer));
            begin
               if Layer >= Item.Second_From then
                  More_Second := More_Second + Extra;
               else
                  More := More + Extra;
               end if;
            end;
         end if;
      end loop;

      for Slot in Page_Owner'Range loop
         if Page_Owner (Slot) /= null then
            if Slot < Page_Cap then
               Held_First := Held_First + 1;
            else
               Held_Second := Held_Second + 1;
            end if;
         end if;
      end loop;

      if More > Element_Count (Pool_Slots - Natural'Min (Pool_Slots, Held_First))
        or else More_Second
                > Element_Count (Pool_Slots - Natural'Min (Pool_Slots, Held_Second))
      then
         return;
      end if;
   end;

   --  Each layer up to the page its highest new position reaches. A
   --  page is a slot at the front the buffer has not dealt, and taking
   --  it may grow how far the buffer is dealt and so the reserve.
   for Layer in 0 .. Item.Page_Count.all'Last loop
      if not Linear (Item.Owner.Settings, Layer) then
         declare
            Want : constant Element_Count :=
              Pages_Wanted (Item.all, Layer, Upto);
            First : constant Element_Count := Item.Page_First.all (Layer);
         begin
            while Item.Page_Count.all (Layer) < Want loop
               declare
                  Low  : constant Natural :=
                    (if Layer >= Item.Second_From then Page_Cap else 0);
                  High : constant Natural := Low + Pool_Slots;
                  Slot : Natural := Low;
               begin
                  while Slot < High and then Page_Owner (Slot) /= null
                  loop
                     Slot := Slot + 1;
                  end loop;

                  if Slot >= High then
                     --  No slot free: what has been dealt stays, and the
                     --  layer holds fewer pages than it wanted, which the
                     --  caller reads as the cache being full.
                     return;
                  end if;

                  Page_Owner (Slot) := Item;
                  Pages_In_Use := Pages_In_Use + 1;
                  Item.Pages.all
                    (Natural (First) + Natural (Item.Page_Count.all (Layer)))
                    := Slot_Base (Slot);
                  Item.Page_Count.all (Layer) :=
                    Item.Page_Count.all (Layer) + 1;
                  if Slot < Page_Cap then
                     Pages_Taken :=
                       Element_Count'Max
                         (Pages_Taken, Slot_Base (Slot) + Page_Elements);
                  else
                     Pages_Taken_Second :=
                       Element_Count'Max
                         (Pages_Taken_Second,
                          Slot_Base (Slot) + Page_Elements - Second_Copy);
                  end if;
               end;
            end loop;
         end;
      end if;
   end loop;

   --  Room for every page dealt, the per-layer page tables past them --
   --  a table a layer, its pages and the over-read's padding -- and a
   --  layer's sinks past that; and the tables laid out and written, all
   --  at once. A table a layer at its own place, read by that layer's
   --  whole layer, rather than one table rewritten a layer: the write is
   --  once a token where the pages grow and not once a layer. Where the
   --  buffer's front has moved under another session the tables move
   --  with it, so their places are worked out afresh here each time.
   --
   --  A round's members do not write their tables here: the next member
   --  takes a page where this one's table sat, so a round lays them out
   --  once its members are all seated, past its per-row table, and gives
   --  only the room for the write back to a member come again.
   if Write_Tables then
      declare
         Where : Element_Count := 0;
         Words : Natural := 0;
      begin
         --  A layer whose pages are in the second copy names its table
         --  with Second_Table added, which is how the step that reads it
         --  knows which copy to read.
         for Layer in Item.Page_Count.all'Range loop
            Item.Page_Table_At.all (Layer) :=
              Where
              + (if Layer >= Item.Second_From
                 then Model_Runner.Backend.Device.Second_Table else 0);
            if not Linear (Item.Owner.Settings, Layer) then
               declare
                  Count : constant Natural :=
                    Natural (Item.Page_Count.all (Layer)) + Page_Table_Pad;
               begin
                  Where := Where + Element_Count (Count);
                  Words := Words + Count;
               end;
            end if;
         end loop;

         --  The tables are at the front, the rows past it: the binary32
         --  buffer reaches as far as the pages, and where the session's
         --  rows are read only as halves the device keeps the front and
         --  the copy alone. A model with sinks, or a packed cache, reads
         --  the binary32 and keeps it whole.
         if Element_Count (Words) > Page_Front then
            return;
         end if;

         Model_Runner.Backend.Device.Reserve_Cache
           (Pages_Taken + Sink_Footprint (Item.Owner.Settings),
            Copy_Upto => Pages_Taken, Ok => Ok,
            Allow_Copy_Only =>
              Sink_Footprint (Item.Owner.Settings) = 0
              and then Item.Held in Exact | Halved,
            Front => Page_Front);
         if not Ok then
            return;
         end if;

         if Pages_Taken_Second > 0 then
            Model_Runner.Backend.Device.Reserve_Second_Cache
              (Pages_Taken_Second, Ok);
            if not Ok then
               return;
            end if;
         end if;

         declare
            Table : Model_Runner.Backend.Device.Word_List
                      (1 .. Natural'Max (Words, 1));
         begin
            for Layer in Item.Page_Count.all'Range loop
               if not Linear (Item.Owner.Settings, Layer) then
                  declare
                     First : constant Element_Count :=
                       Item.Page_First.all (Layer);
                     Held  : constant Element_Count :=
                       Item.Page_Count.all (Layer);
                     Off   : constant Natural :=
                       Natural (Item.Page_Table_At.all (Layer)
                                mod Model_Runner.Backend.Device.Second_Table);
                  begin
                     --  The layer's pages, and the padding a masked
                     --  over-read reads, each pointing at a real page.
                     for Page in 0 .. Natural (Held) + Page_Table_Pad - 1
                     loop
                        --  A page's base in its own copy's numbering.
                        Table (Off + Page + 1) :=
                          Natural
                            (Item.Pages.all
                               (Natural
                                  (First
                                   + Element_Count'Min
                                       (Element_Count (Page),
                                        Element_Count'Max (Held, 1) - 1)))
                             mod Second_Copy);
                     end loop;
                  end;
               end if;
            end loop;

            Model_Runner.Backend.Device.Put_Table (0, Table, Ok);
            if not Ok then
               return;
            end if;
            Tables_Of := Item;
            Tables_Front := Pages_Taken + Pages_Taken_Second;
         end;
      end;
   else
      --  A round member: room for its pages and the widest layer's
      --  table the round will write past them, and the sinks.
      declare
         Widest : Element_Count := 0;
      begin
         for Layer in Item.Page_Count.all'Range loop
            Widest :=
              Element_Count'Max (Widest, Item.Page_Count.all (Layer));
         end loop;

         Model_Runner.Backend.Device.Reserve_Cache
           (Pages_Taken + Widest + Element_Count (Page_Table_Pad)
            + Sink_Footprint (Item.Owner.Settings),
            Copy_Upto => Pages_Taken, Ok => Ok);
         if not Ok then
            return;
         end if;
      end;
   end if;

   --  What was committed before this session held these pages -- an
   --  evicted session come back -- written into them a page at a time.
   --  Nothing to write for a session that has only grown, whose new
   --  pages the place step of this pass fills.
   if not Item.Paged_In and then Item.Committed > 0 then
      declare
         Written : Boolean := True;
      begin
         --  Every layer that holds pages, which is every non-linear one
         --  including the blocks past the stack -- Page_Count runs to
         --  Layers + Next_Layers - 1, and pages are dealt for all of
         --  them, so all of them are written back, not the stack alone.
         for Layer in Item.Page_Count.all'Range loop
            if not Linear (Item.Owner.Settings, Layer) then
               if Item.Held in Exact | Halved then
                  Write_Pages_Layer
                    (Item.all, Layer, KV_Width, V_Width,
                     Element_Count (Item.Committed), Written);
               else
                  Write_Packed_Pages_Layer
                    (Item.all, Layer, KV_Width, V_Width,
                     Element_Count (Item.Committed), Written);
               end if;
               exit when not Written;
            end if;
         end loop;
         if not Written then
            Ok := False;
            return;
         end if;
      end;
   end if;

   Item.Paged_In := True;
   Item.Paged_Upto := Natural (Upto);
   Ok := True;
end Take_Pages;
