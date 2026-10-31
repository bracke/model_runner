separate (Model_Runner.Llama)
procedure Make_Room
  (Item     : in out Session;
   Settings : Configuration;
   Upto     : Element_Count)
is
   KV_Width : constant Element_Count :=
     Element_Count (Settings.KV_Heads * Settings.Head_Size);
   V_Width  : constant Element_Count :=
     Element_Count (Settings.KV_Heads * Settings.Value_Size);
   Width    : constant Element_Count :=
     Element_Count (Settings.Window);

   P : constant Element_Count := Element_Count (Page_Positions);

   --  Whether any layer's rows moved down, which a paged session's
   --  pages do not follow.
   Slid : Boolean := False;

   --  Whether any layer's pages were turned, which its page table on
   --  the device has to be written again to say.
   Turned : Boolean := False;

   --  Whether Layer slides before Upto is written.
   function Sliding (Layer : Natural) return Boolean
   is (Item.Cells.all (Layer) > 0
       and then Upto - Item.Origin.all (Layer) >= Item.Cells.all (Layer));

   --  The lowest position anything will read from here on, which is the
   --  window measured back from the first of the positions about to be
   --  written; and a window's worth behind the newest position, and a
   --  little more: a drafted round runs positions ahead and rewinds to
   --  the last agreed, and the window of a position rewound to reaches
   --  back past one kept for the newest. Kept to the window alone,
   --  gemma-3-4b drafted by Gemma 3 270M stopped with a range check some
   --  1,200 positions in, reading a cell the slide had let go.
   function Window_Start return Element_Count is
     (if Element_Count (Item.Committed) < Width + Rewind_Slack then 0
      else Element_Count (Item.Committed) - Width - Rewind_Slack + 1);

   --  The same, down to a whole number of pages past the layer's origin:
   --  where a paged layer slides by turning its pages over.
   function Page_Start (Layer : Natural) return Element_Count is
     (Item.Origin.all (Layer)
      + (Element_Count'Max (Window_Start, Item.Origin.all (Layer))
         - Item.Origin.all (Layer)) / P * P);

   --  Whether Layer slides by its pages: a session whose rows are in
   --  pages it holds, with a page or more to let go, and room in the
   --  layer's cells for what is kept down to the page and the positions
   --  coming. The pages that held the oldest rows go to the end of the
   --  layer's list, where the positions coming are written, and the rows
   --  between keep the pages they were in -- moved on neither copy of
   --  the device's, so nothing the device wrote has to be read back
   --  first. LFM3's prompt of 1,257 read the whole cache back a batch
   --  through the device's uncached mapping, a tenth of the prompt.
   function Turns (Layer : Natural) return Boolean
   is (Item.Paged
       and then Item.Paged_In
       and then Item.Page_Count /= null
       and then Page_Start (Layer) > Item.Origin.all (Layer)
       and then Upto - Page_Start (Layer) < Item.Cells.all (Layer)
       and then (Page_Start (Layer) - Item.Origin.all (Layer)) / P
                < Item.Page_Count.all (Layer));

   --  Whether a layer slides on the device where its rows lie: a session
   --  in a block of the device's, its rows exact and its keys and values
   --  as wide, so that one submission moves both by the same distance.
   --  The host's copy moves too, and what the device wrote and the host
   --  was not given goes down with the device's: a settle after reads
   --  the positions the layer still holds where they now are. It read
   --  the whole cache back a slide, as a page's did.
   function Device_Moves return Boolean
   is (not Item.Paged
       and then Item.Seat >= 0
       and then Item.Held = Exact
       and then (Item.Values_In_Keys or else KV_Width = V_Width));

   --  Set where a move on the device was refused: the layers after it
   --  slide through the host, settled first.
   Fell_Back : Boolean := False;

begin
   if Item.Cells = null or else Settings.Window = 0 then
      return;
   end if;

   --  What the device wrote and the host has not read back, before any
   --  of it is moved. Asked only when something is about to slide other
   --  than by its pages, so the lazy settle this backend was built
   --  around still holds for every call that does not: a layer slides
   --  about once every batch of positions.
   if Item.Owed_Count > 0 then
      declare
         Sliding : Boolean := False;
      begin
         for Layer in Item.Cells.all'Range loop
            Sliding := Sliding
              or else (Make_Room.Sliding (Layer)
                       and then not Turns (Layer)
                       and then not Device_Moves);
         end loop;

         if Sliding then
            declare
               Settled : Boolean;
            begin
               Settle_Cache (Item, Settled);
            end;
         end if;
      end;
   end if;

   for Layer in Item.Cells.all'Range loop
      declare
         Cells  : constant Element_Count := Item.Cells.all (Layer);
         Origin : constant Element_Count := Item.Origin.all (Layer);
      begin
         --  A layer that holds no cells -- LFM3's convolutions -- has
         --  nothing to slide.
         if Cells > 0 and then Upto - Origin >= Cells then
            declare
               Held  : constant Element_Count :=
                 Element_Count (Item.Committed);
               By_Pages : constant Boolean := Turns (Layer);
               Start : constant Element_Count :=
                 (if By_Pages then Page_Start (Layer) else Window_Start);
               Moved : constant Element_Count :=
                 (if Start >= Held then 0 else Held - Start);

               Keys_Base : constant Element_Count := Keys_At (Item, Layer);
               Vals_Base : constant Element_Count :=
                 Values_At (Item, Layer);
               Rows_Base : constant Element_Count := Rows_At (Item, Layer);

               From : constant Element_Count := Start - Origin;

               On_Device : Boolean := False;
            begin
               if Moved > 0
                 and then not By_Pages
                 and then Device_Moves
                 and then not Fell_Back
               then
                  declare
                     Runs : constant Model_Runner.Backend.Device.Block_Runs :=
                       (if Item.Values_In_Keys
                        then [1 => (At_Value => Keys_Base,
                                    Count    => Moved * KV_Width)]
                        else [(At_Value => Keys_Base,
                               Count    => Moved * KV_Width),
                              (At_Value => Item.Keys.all'Length + Vals_Base,
                               Count    => Moved * V_Width)]);
                  begin
                     Model_Runner.Backend.Device.Move_Cache
                       (From   => Block_Base (Item) + From * KV_Width,
                        Into   => Block_Base (Item),
                        Runs   => Runs,
                        Halves => True,
                        Ok     => On_Device);
                  end;

                  if not On_Device then
                     Fell_Back := True;
                     if Item.Owed_Count > 0 then
                        declare
                           Settled : Boolean;
                        begin
                           Settle_Cache (Item, Settled);
                        end;
                     end if;
                  end if;
               end if;

               if Moved > 0 then
                  case Item.Held is
                     when Exact =>
                        Item.Keys.all
                          (Keys_Base .. Keys_Base + Moved * KV_Width - 1) :=
                          Item.Keys.all
                            (Keys_Base + From * KV_Width
                             .. Keys_Base + (From + Moved) * KV_Width - 1);
                        --  Values in the keys' rows moved with them.
                        if not Item.Values_In_Keys then
                           Item.Values.all
                             (Vals_Base .. Vals_Base + Moved * V_Width - 1) :=
                             Item.Values.all
                               (Vals_Base + From * V_Width
                                .. Vals_Base + (From + Moved) * V_Width - 1);
                        end if;

                     when Halved =>
                        Item.Half_Keys.all
                          (Keys_Base .. Keys_Base + Moved * KV_Width - 1) :=
                          Item.Half_Keys.all
                            (Keys_Base + From * KV_Width
                             .. Keys_Base + (From + Moved) * KV_Width - 1);
                        if not Item.Values_In_Keys then
                           Item.Half_Values.all
                             (Vals_Base .. Vals_Base + Moved * V_Width - 1) :=
                             Item.Half_Values.all
                               (Vals_Base + From * V_Width
                                .. Vals_Base + (From + Moved) * V_Width - 1);
                        end if;

                     when Eighth | Fourth =>
                        --  Whole rows move, so the bytes and the
                        --  scales move by a row's worth of each.
                        declare
                           KB : constant B.Byte_Count :=
                             Row_Bytes (Item.Held, KV_Width);
                           VB : constant B.Byte_Count :=
                             Row_Bytes (Item.Held_Values, V_Width);
                           KS : constant Element_Count :=
                             Blocks_Of (Item.Held, KV_Width);
                           VS : constant Element_Count :=
                             Blocks_Of (Item.Held_Values, V_Width);
                           Row_0 : constant Element_Count :=
                             Keys_Base / KV_Width;
                           V_Row_0 : constant Element_Count :=
                             Vals_Base / V_Width;
                        begin
                           Item.Byte_Keys.all
                             (B.Byte_Count (Row_0) * KB
                              .. B.Byte_Count (Row_0 + Moved) * KB - 1) :=
                             Item.Byte_Keys.all
                               (B.Byte_Count (Row_0 + From) * KB
                                .. B.Byte_Count (Row_0 + From + Moved) * KB
                                   - 1);
                           Item.Byte_Values.all
                             (B.Byte_Count (V_Row_0) * VB
                              .. B.Byte_Count (V_Row_0 + Moved) * VB - 1) :=
                             Item.Byte_Values.all
                               (B.Byte_Count (V_Row_0 + From) * VB
                                .. B.Byte_Count (V_Row_0 + From + Moved) * VB
                                   - 1);

                           Item.Key_Scales.all
                             (Rows_Base * KS .. (Rows_Base + Moved) * KS - 1) :=
                             Item.Key_Scales.all
                               ((Rows_Base + From) * KS
                                .. (Rows_Base + From + Moved) * KS - 1);
                           Item.Value_Scales.all
                             (Rows_Base * VS .. (Rows_Base + Moved) * VS - 1) :=
                             Item.Value_Scales.all
                               ((Rows_Base + From) * VS
                                .. (Rows_Base + From + Moved) * VS - 1);
                        end;
                  end case;
               end if;

               --  And the device's copy of what moved, which is these
               --  same bytes in this session's own block. Only the
               --  exact storage ever reaches a device, which is what
               --  Take_Block asks of a session before it deals it one.
               if By_Pages then
                  declare
                     First : constant Natural :=
                       Natural (Item.Page_First.all (Layer));
                     Count : constant Natural :=
                       Natural (Item.Page_Count.all (Layer));
                     Drop  : constant Natural := Natural (From / P);
                     Was   : constant Cell_Counts :=
                       Item.Pages.all (First .. First + Count - 1);
                  begin
                     for Page in 0 .. Count - 1 loop
                        Item.Pages.all (First + Page) :=
                          Was (Was'First + (Page + Drop) mod Count);
                     end loop;
                  end;
                  Turned := True;
               elsif Moved > 0
                 and then not On_Device
                 and then Item.Seat >= 0
                 and then Item.Held = Exact
               then
                  declare
                     Sent : Boolean;
                  begin
                     Model_Runner.Backend.Device.Put_Cache
                       (Block_Base (Item) + Keys_Base,
                        Item.Keys.all
                          (Keys_Base
                           .. Keys_Base + Moved * KV_Width - 1),
                        Sent);
                     if not Item.Values_In_Keys then
                        Model_Runner.Backend.Device.Put_Cache
                          (Block_Base (Item)
                           + Item.Keys.all'Length + Vals_Base,
                           Item.Values.all
                             (Vals_Base
                              .. Vals_Base + Moved * V_Width - 1),
                           Sent);
                     end if;
                  end;
               elsif Moved > 0
                 and then Item.Seat >= 0
                 and then Item.Held in Eighth | Fourth
               then
                  --  The packed rows that moved, a row at a time.
                  declare
                     Sent : Boolean;
                  begin
                     for Row in 0 .. Moved - 1 loop
                        Put_Packed_Position
                          (Item'Unchecked_Access,
                           Keys_Base + Row * KV_Width,
                           Vals_Base + Row * V_Width,
                           KV_Width, V_Width, Sent);
                     end loop;
                  end;
               end if;

               Item.Origin.all (Layer) := Start;
               Slid := Slid or else (Moved > 0 and then not By_Pages);
            end;
         end if;
      end;
   end loop;

   --  A block has its moved rows sent over above; a paged session's
   --  pages kept the rows where they were, and the next token read them
   --  at the cells the window had moved: gemma-3-4b past 1,536 positions
   --  (its window of 1,024 and a batch) went on in fragments, Gemma 3
   --  270M past 1,024. Given back, they are taken again at the next pass
   --  and written from the host's copy, which the moves made current --
   --  once a batch's worth of positions, which is how often the window
   --  slides.
   if Slid and then Item.Paged and then Item.Paged_In then
      Release_Session_Pages (Item'Unchecked_Access);
   elsif Turned then
      Tables_Of := null;
   end if;
end Make_Room;
