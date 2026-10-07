separate (Model_Runner.Llama)
procedure Shift
  (Item   : in out Session;
   Source : Model'Class;
   Keep   : Natural;
   Drop   : Positive;
   Status : out E.Error_Info)
is
   Settings : constant Configuration := Source.Settings;

   Head_Size : constant Element_Count :=
     Element_Count (Settings.Head_Size);
   KV_Heads  : constant Element_Count :=
     Element_Count (Settings.KV_Heads);
   KV_Width  : constant Element_Count := KV_Heads * Head_Size;
   V_Width   : constant Element_Count :=
     KV_Heads * Element_Count (Settings.Value_Size);

   Moved : Natural;
begin
   --  What the device wrote and the host was owed, which this
   --  reads: the copy is brought up to date where it is used
   --  rather than at the end of every call.
   declare
      Settled : Boolean;
   begin
      Settle_Cache (Item, Settled);
   end;

   Status := E.Success;

   --  A hybrid's linear layers hold no positions to move: their state
   --  is everything before it at once, and a context with the middle
   --  taken out is a context they never saw. Refused by name, and the
   --  caller re-evaluates what it keeps.
   if Hybrid (Settings.Kind) then
      Status := E.Make (E.Arch_Unsupported_Feature);
      E.Add_Text (Status, "feature", "shift", E.Param_Identifier);
      return;
   end if;

   if Item.Current = Closed or else Item.Current = Failed then
      Status := E.Make (E.Lifecycle_Invalid_State);
      E.Add_Text
        (Status, "state",
         Model_Runner.Text.To_Lower (Session_State'Image (Item.Current)),
         E.Param_Identifier);
      return;
   end if;

   if Keep + Drop > Item.Committed then
      Status := E.Make (E.Tensor_Shape_Mismatch);
      E.Add_Integer (Status, "input", Long_Long_Integer (Keep + Drop));
      E.Add_Integer
        (Status, "expected", Long_Long_Integer (Item.Committed));
      return;
   end if;

   Moved := Item.Committed - Keep - Drop;

   --  Every layer, every moved position: the key turned back by the angle
   --  Drop stands for and written where it now belongs, the value copied.
   --
   --  A LAYER THAT SLIDES A WINDOW DOES NOT HOLD WHAT THIS PROMISES TO
   --  KEEP. The first Keep positions are the ones a caller must not lose
   --  and they are the first ones a window drops, so on a slid layer the
   --  front of the cache is not there to be kept and the arithmetic that
   --  assumed it was went below zero -- this raised rather than shifted,
   --  on every architecture that slides, for any context long enough to
   --  have slid. Which is the whole of what the window was built for.
   --
   --  What a shift means to such a layer is only a renumbering. It holds
   --  the newest positions and those are exactly the ones that survive,
   --  so each key is turned back by the angle Drop stands for and stays
   --  in the cell it is in; what moves is the layer's origin, by Drop.
   --  The rows move only where a layer straddles the hole -- where its
   --  origin falls inside the dropped range -- and then only far enough
   --  to close it.
   for Index in Item.Owner.Layers'Range loop
      declare
         Layer : constant Natural := Natural (Index);

         --  The lowest position this layer still holds, before and
         --  after. Zero and zero for a layer that holds everything,
         --  which is what this was before a window slid.
         Low : constant Element_Count :=
           (if Item.Origin = null then 0 else Item.Origin.all (Layer));

         Settled : constant Element_Count :=
           (if Low <= Element_Count (Keep) then Low
            elsif Low >= Element_Count (Keep + Drop)
            then Low - Element_Count (Drop)
            else Element_Count (Keep));

         Base : constant Element_Count :=
           Keys_At (Item, Layer);
         V_Base : constant Element_Count :=
           Values_At (Item, Layer);
         Rows_Base : constant Element_Count :=
           Rows_At (Item, Layer);
      begin
         for Step in 0 .. Moved - 1 loop
            declare
               --  What the position was and what it becomes.
               Held_At : constant Element_Count :=
                 Element_Count (Keep + Drop + Step);
               Ends_At : constant Element_Count :=
                 Element_Count (Keep + Step);

               --  Where the two sit in this layer, which is not the
               --  positions themselves for a layer that slides a window
               --  -- and for one that has slid past this position, is
               --  nowhere at all.
               Absent : constant Boolean := Held_At < Low;

               Was : constant Element_Count :=
                 (if Absent then 0 else Held_At - Low);
               Now : constant Element_Count :=
                 (if Absent then 0 else Ends_At - Settled);

               From : constant Element_Count := Base + Was * KV_Width;
               Into : constant Element_Count := Base + Now * KV_Width;

               V_From : constant Element_Count := V_Base + Was * V_Width;
               V_Into : constant Element_Count := V_Base + Now * V_Width;
            begin
               if not Absent then
                  if Item.Held in Eighth | Fourth then
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Key_Row.all (Offset) :=
                          Unpack (Item.Byte_Keys.all, From + Offset,
                                  KV_Width, Item.Key_Scales.all, Item.Held);
                     end loop;
                  elsif Item.Held = Exact then
                     Item.Key_Row.all (0 .. KV_Width - 1) :=
                       Item.Keys.all (From .. From + KV_Width - 1);
                  else
                     for Offset in 0 .. KV_Width - 1 loop
                        Item.Key_Row.all (Offset) :=
                          N.To_Real (Item.Half_Keys.all (From + Offset));
                     end loop;
                  end if;

                  K.Apply_Rotary
                    (Item.Key_Row.all, KV_Heads, Head_Size,
                     Element_Count (Settings.Rotary), Drop,
                     Turn_Base (Settings, Natural (Index)),
                     Turn_Scaling (Settings, Natural (Index)), Turns (Source),
                     Settings.Pairing, Backwards => True);

                  if Item.Held in Eighth | Fourth then
                     --  Turned back and written again, which is a second
                     --  rounding of a row that was already rounded once.
                     --  A rolling context in this storage loses a little
                     --  more of what it keeps every time it rolls, and that
                     --  is the price of the storage rather than a fault in
                     --  the shift.
                     Pack_Row
                       (Item.Key_Row.all (0 .. KV_Width - 1),
                        Item.Byte_Keys.all, Into, KV_Width,
                        Item.Key_Scales.all, Item.Held);

                     --  The values move whole, bytes and scales.
                     declare
                        VB : constant B.Byte_Count :=
                          Row_Bytes (Item.Held_Values, V_Width);
                        VS : constant Element_Count :=
                          Blocks_Of (Item.Held_Values, V_Width);
                        From_Byte : constant B.Byte_Count :=
                          Byte_Of (Item.Held_Values, V_From, V_Width);
                        Into_Byte : constant B.Byte_Count :=
                          Byte_Of (Item.Held_Values, V_Into, V_Width);
                     begin
                        Item.Byte_Values.all (Into_Byte .. Into_Byte + VB - 1) :=
                          Item.Byte_Values.all (From_Byte .. From_Byte + VB - 1);
                        Item.Value_Scales.all
                          ((Rows_Base + Now) * VS .. (Rows_Base + Now + 1) * VS - 1) :=
                          Item.Value_Scales.all
                            ((Rows_Base + Was) * VS .. (Rows_Base + Was + 1) * VS - 1);
                     end;
                  elsif Item.Held = Exact then
                     Item.Keys.all (Into .. Into + KV_Width - 1) :=
                       Item.Key_Row.all (0 .. KV_Width - 1);
                     Item.Values.all (V_Into .. V_Into + V_Width - 1) :=
                       Item.Values.all (V_From .. V_From + V_Width - 1);
                  else
                     Model_Runner.Kernels.To_Halves
                       (Item.Key_Row.all (0 .. KV_Width - 1),
                        Item.Half_Keys.all (Into .. Into + KV_Width - 1));
                     for Offset in 0 .. V_Width - 1 loop
                        Item.Half_Values.all (V_Into + Offset) :=
                          Item.Half_Values.all (V_From + Offset);
                     end loop;
                  end if;
               end if;
            end;
         end loop;

         if Item.Origin /= null then
            Item.Origin.all (Layer) := Settled;
         end if;
      end;
   end loop;

   --  And the device's copy, which every edit above has just made stale.
   --
   --  It always had been. A block is filled once when it is granted and
   --  kept up to date a position at a time as positions are written, so
   --  nothing carried a shift's edits across -- a rolling context on the
   --  device attended to the conversation it had before the roll, with
   --  no error and no sign. A shift happens once a context, so the whole
   --  cache goes over rather than the rows that moved.
   if Item.Seat >= 0 and then Item.Held = Exact then
      declare
         Sent : Boolean;
      begin
         Model_Runner.Backend.Device.Put_Cache
           (Block_Base (Item), Item.Keys.all, Sent);

         if Sent then
            Model_Runner.Backend.Device.Put_Cache
              (Block_Base (Item) + Item.Keys.all'Length,
               Item.Values.all, Sent);
         end if;
      end;
   end if;

   --  A paged session's pages held the same stale rows, and nothing sent
   --  them over either: Gemma 3 rolling its context on the device went
   --  on from the conversation before the roll, mid-sentence. Given back,
   --  they are taken again at the next pass and written from the host's
   --  copy, which the edits above made current.
   if Item.Paged and then Item.Paged_In then
      Release_Session_Pages (Item'Unchecked_Access);
   end if;

   --  And the history, which is what a restored context is checked
   --  against and what a prefix comparison reads.
   for Step in 0 .. Moved - 1 loop
      Item.History.all (Keep + Step) :=
        Item.History.all (Keep + Drop + Step);
   end loop;

   --  And the marks, moved with the tokens and turned back by Drop
   --  in every part, as the keys were.
   if Item.Marks /= null then
      for Step in 0 .. Moved - 1 loop
         declare
            Was : constant Rope_Mark := Item.Marks.all (Keep + Drop + Step);
         begin
            Item.Marks.all (Keep + Step) :=
              (Place => (T => Integer'Max (0, Was.Place.T - Drop),
                         H => Integer'Max (0, Was.Place.H - Drop),
                         W => Integer'Max (0, Was.Place.W - Drop)),
               Next  => Integer'Max (0, Was.Next - Drop));
         end;
      end loop;
      Item.Marked := Natural'Min (Item.Marked, Keep + Moved);
   end if;

   Item.Committed := Keep + Moved;
   Item.Check_At := 0;

   --  A packed block went stale the same way and was not sent over
   --  either -- only an exact block is, above: Gemma 3 at q4 or q8
   --  rolling its context in a block went on mid-sentence as the paged
   --  session had. Written again from the host's packed copy, which is
   --  current, up to the count just committed.
   if Item.Seat >= 0 and then Item.Held in Eighth | Fourth then
      declare
         Written : Boolean;
      begin
         Write_Block
           (Item'Unchecked_Access, Block_Base (Item), Written);
      end;
   end if;
end Shift;
