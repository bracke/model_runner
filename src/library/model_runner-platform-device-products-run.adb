separate (Model_Runner.Platform.Device.Products)
procedure Run
  (Item      : in out Engine;
   Steps     : Sequence;
   Vectors   : Model_Runner.Numerics.Real_Array;
   Count     : Positive;
   Target    : out Model_Runner.Numerics.Real_Array;
   Ok        : out Boolean;
   Cancelled : out Boolean;
   Cancel    : Model_Runner.Cancellation.Token_Reference := null;
   Carry_In  : Boolean := False;
   Carry_Out : Boolean := False;
   Kept_Into : Address_List := No_Places;
   Leave_Kept : Boolean := False;
   Origin     : Interfaces.Unsigned_64 := 0;
   Hold       : Boolean := False)
is
   use type System.Storage_Elements.Integer_Address;
   use type Model_Runner.Numerics.Real;

   Ignored : constant Boolean := Set_Asking (Item);
   Narrowed_Run : constant Boolean := Set_Narrow (Item, Steps);
   pragma Unreferenced (Narrowed_Run);

   --  A storage buffer binding may not begin anywhere: a device states
   --  the boundary it wants, and no device asks for more than this.
   --  Rounding every step's share up to it is cheaper than reading the
   --  limit and far cheaper than getting it wrong, which is a validation
   --  failure on some drivers and wrong answers on others.
   Alignment : constant Interfaces.Unsigned_64 := 256;

   --  Where each product's matrix and result ended up.
   type Place is record
      Buffer   : Address := Null_Handle;
      Memory   : Address := Null_Handle;
      Base     : Interfaces.Unsigned_64 := 0;
      Borrowed : Boolean := False;

      --  A streamed stack's mapping and heap, for its buffer to go back
      --  among the spares rather than to the driver.
      Streamed : Boolean := False;
      Mapped   : Address := Null_Handle;
      Tier     : Tier_Index := 1;
      Weight   : Interfaces.Unsigned_64 := 0;
      At_Byte  : Interfaces.Unsigned_64 := 0;
      Bytes    : Interfaces.Unsigned_64 := 0;
   end record;

   Places : array (1 .. Sequence_Limit) of Place;

   --  Whether the result buffer's room is dealt again within the run
   --  (Plan_Reuse), and for each step: the last step that reads its
   --  answer (Natural'Last where the host reads it after the run, or
   --  the next sequence does), the first step that writes it, and the
   --  last reader of the room it took over, which a barrier before its
   --  first write has to have published.
   --
   --  Every step had room of its own, so a batch's buffer was every
   --  step's answer laid end to end: Gemma 4's 26B, thirty-odd steps
   --  of a mixture's layer, held 2.2 MB a position -- 1.1 GB at a
   --  batch of 512 -- which is what capped its batch and kept two of
   --  its layers off the device at a context of 8k.
   Reusing  : Boolean := False;
   Last_Use : array (1 .. Sequence_Limit) of Natural := [others => 0];
   Born     : array (1 .. Sequence_Limit) of Natural := [others => 0];
   Wait_At  : array (1 .. Sequence_Limit) of Natural := [others => 0];

   --  The rooms dealt so far: where each begins, how large it is, and
   --  the last step that reads what was last put in it.
   type Room_Note is record
      At_Byte    : Interfaces.Unsigned_64 := 0;
      Bytes      : Interfaces.Unsigned_64 := 0;
      Free_After : Natural := 0;
   end record;
   Rooms      : array (1 .. Sequence_Limit) of Room_Note;
   Room_Count : Natural := 0;

   --  What the activation buffer has to hold. The first step's own
   --  reading of it, and past that whatever a step reading at an offset
   --  needs -- a residual join reads the residual, which travels behind
   --  the queries in the same array.
   function Vector_Elements return Model_Runner.Numerics.Element_Count;

   function Vector_Elements return Model_Runner.Numerics.Element_Count is
      Most : Model_Runner.Numerics.Element_Count :=
        Model_Runner.Numerics.Element_Count (Steps.Items (1).Columns)
        * Model_Runner.Numerics.Element_Count (Count);
   begin
      for Index in 1 .. Steps.Held loop
         if Steps.Items (Index).Tap_Row > 0 then
            Most := Model_Runner.Numerics.Element_Count'Max
              (Most,
               Model_Runner.Numerics.Element_Count
                 (Tap_Reach (Steps.Items (Index)))
               + Model_Runner.Numerics.Element_Count
                   (Steps.Items (Index).Columns)
                 * Model_Runner.Numerics.Element_Count (Count));
         end if;
         if Steps.Items (Index).Payload_Elements > 0 then
            Most := Model_Runner.Numerics.Element_Count'Max
              (Most, Model_Runner.Numerics.Element_Count (Steps.Items (Index).Payload)
                     + Model_Runner.Numerics.Element_Count (Steps.Items (Index).Payload_Elements));
         end if;
         if Steps.Items (Index).At_Vector > 0 then
            --  What a step reads from the activation is its COLUMNS,
            --  which for a join is its width and for a product is the
            --  vector the matrix takes. It said Rows, and a join's rows
            --  and columns are the same number so nothing noticed --
            --  until a group of down projections read its own stretch of
            --  one activation, where the rows are the answer's width and
            --  the columns are the expert's, and the upload ran off the
            --  end of the array.
            Most := Model_Runner.Numerics.Element_Count'Max
              (Most,
               Model_Runner.Numerics.Element_Count
                 (Steps.Items (Index).At_Vector)
               + Model_Runner.Numerics.Element_Count
                   (Steps.Items (Index).Columns)
                 * Model_Runner.Numerics.Element_Count (Count));
         end if;
      end loop;

      return Most;
   end Vector_Elements;

   Vector_Room  : constant Model_Runner.Numerics.Element_Count :=
     Vector_Elements;

   --  Whether a step goes to the tile kernel. A gather of more than one
   --  member never does: the tile kernel reads one matrix at one base,
   --  and a gather of one is that, at the base of the slice it names.
   --  The slots a listed product's runs may take, with the padding
   --  and a tile's worth past the end for the loads a tile makes
   --  beyond its run.
   function Listed_Slots (Which : Positive) return Natural
   is (Steps.Items (Which).Rows / Steps.Items (Which).Each * Count
       + Tile_Vectors);

   --  Whether a listed product goes to the matrix kernel, every
   --  expert's run as a tile of the half-precision copy that
   --  half_batch.comp lays out from the lists: where the batch is
   --  long enough for the tile at all, and the slice's rows divide
   --  by it. The row kernel walks the runs otherwise.
   --
   --  The wide tile's words at thirty-two vectors, or at sixty-four
   --  where the runs are long (Listed_Wide): a run of thirty-two in a tile of a hundred and twenty-eight
   --  is three quarters padding the instruction multiplies all the
   --  same, and the narrow tile of thirty-two -- one subgroup -- read
   --  slower than either, because it decodes a row into the
   --  instruction's operand once a tile and a subgroup alone hides
   --  none of that.
   function Listed_Tiled (Which : Positive) return Boolean
   is (Steps.Items (Which).Listed
       and then Uses_Matrix
                  (Item, Steps.Items (Which).Packing,
                   Steps.Items (Which).Each,
                   Steps.Items (Which).Columns, Count)
       --  The listed tile steps as the wide one does, whatever the
       --  batch, so the columns have to divide by its step.
       and then Steps.Items (Which).Columns mod Listed_Step = 0
       and then Steps.Items (Which).Each mod Listed_Rows = 0
       and then Listed_Pipeline (Item, Steps.Items (Which).Packing)
                /= Null_Handle);

   --  A product, as against every other kind of step: the tile is
   --  theirs alone, and a question asked of a step's rows and columns
   --  without asking what kind it is would say yes of an attention
   --  step with the right numbers.
   function Is_Product (Which : Positive) return Boolean
   is (not (Steps.Items (Which).Norms or else Steps.Items (Which).Rotates
            or else Steps.Items (Which).Places
            or else Steps.Items (Which).Readies
            or else Steps.Items (Which).Attends
            or else Steps.Items (Which).Routes
            or else Steps.Items (Which).Mixes
            or else Steps.Items (Which).Biases
            or else Steps.Items (Which).Picks
            or else Steps.Items (Which).Convolves
            or else Steps.Items (Which).Rules
            or else Steps.Items (Which).Rwkvs
            or else Steps.Items (Which).Wkvs
            or else Steps.Items (Which).Mambas
            or else Steps.Items (Which).Inverts
            or else Steps.Items (Which).Blends));

   --  Whether an attending step's latent is read by the batch's
   --  compilation, tiles of 128 and one slice a position: a batch of a
   --  tile's rows or more, which is busy enough without slicing.
   function Latent_Batch (Which : Positive) return Boolean;

   --  The few-position pipeline an attending step takes, or none; see
   --  Few_Kernel.
   --  Whether a token's or a check's few positions over heads of 512
   --  take attention_token.comp at its widest (Token_Width_Most), a
   --  group of up to four heads a workgroup, rather than the latent's
   --  kernel, whose tile of sixteen rows a group of four fills a
   --  quarter of: Gemma 4 E4B's global layers 7,186 deep attended at
   --  33 GB/s there.
   function Wide_Token (Which : Positive) return Boolean
   is (Steps.Items (Which).Attends
       and then not Steps.Items (Which).Rows_As_Heads
       and then Count in 1 .. Token_Positions_Most
       and then Steps.Items (Which).Packed.K_Bits = 0
       and then Steps.Items (Which).Head_Size = 512
       and then Steps.Items (Which).Value_Size = 512
       and then Steps.Items (Which).Group_Size in 1 .. Token_Group_Most
       and then Steps.Items (Which).Heads mod Steps.Items (Which).Group_Size = 0
       --  A whole group a workgroup, which reads the group's keys and
       --  values once: the 26B's groups of eight split in two read
       --  them twice and generated 20.5 -> 20.2 7,186 deep.
       and then Token_Rows (Steps.Items (Which).Group_Size, 512)
                = Steps.Items (Which).Group_Size
       and then Token_By_Halves (Item, 1, 512, 512)
       and then Steps.Items (Which).K_Base mod 4 = 0
       and then Steps.Items (Which).V_Base mod 4 = 0
       and then Steps.Items (Which).KV_Width mod 4 = 0
       and then Steps.Items (Which).V_Width mod 4 = 0
       and then Item.Token_Lines
                  (Token_Rows (Steps.Items (Which).Group_Size, 512)) (8)
                /= Null_Handle);

   --  And how many slices it cuts the cache into: more than a narrower
   --  head's, since its workgroups are a group's -- two for E4B's
   --  eight heads -- and few of them keep the part's memory busy.
   Wide_Slices_Most : constant := 32;
   function Wide_Token_Slices (Span : Natural) return Natural
   is (Natural'Max (1, Natural'Min (Wide_Slices_Most, Span / 128)));

   function Few_Line (Which : Positive) return Address
   is (if Steps.Items (Which).Rows_As_Heads or else Wide_Token (Which) then Null_Handle
       elsif Steps.Items (Which).Attends
         and then Steps.Items (Which).Packed.K_Bits = 0
         and then Steps.Items (Which).Causal
         and then Steps.Items (Which).Window = 0
         and then Steps.Items (Which).Sinks = 0
         and then Model_Runner.Numerics."=" (Steps.Items (Which).Max_Bias, 0.0)
         and then Model_Runner.Numerics."=" (Steps.Items (Which).Cap, 0.0)
         and then Latent_Fits
                    (Item, Steps.Items (Which).Head_Size,
                     Steps.Items (Which).Value_Size,
                     Steps.Items (Which).Group_Size)
         and then Reads_Copy
                    (Item, Count, Steps.Items (Which).Head_Size,
                     Steps.Items (Which).Value_Size, False)
       --  An absorbed latent's, at any depth and any count of positions
       --  -- each its own workgroups -- since nothing else attends it.
       then Item.Latent_Attend
       elsif Steps.Items (Which).Attends
         and then Steps.Items (Which).Packed.K_Bits = 0
         and then Steps.Items (Which).Causal
         and then Steps.Items (Which).Window = 0
         and then Model_Runner.Numerics."=" (Steps.Items (Which).Max_Bias, 0.0)
         and then Steps.Items (Which).Last
                  >= Steps.Items (Which).First
                     + (if Count = 1 then Few_Token_Span else Few_Span)
         and then not Attends_By_Matrix
                        (Item, Count, Steps.Items (Which).Head_Size,
                         Steps.Items (Which).Value_Size)
         and then Reads_Copy
                    (Item, Count, Steps.Items (Which).Head_Size,
                     Steps.Items (Which).Value_Size, False)
       then Few_Kernel
              (Item, Count, Steps.Items (Which).Heads,
               Steps.Items (Which).Group_Size,
               Steps.Items (Which).Head_Size,
               Steps.Items (Which).Value_Size)
       else Null_Handle);

   --  attention_token.comp's pipeline for an attending step, or none: a
   --  generated token or a check round's few out of the half-precision
   --  copy, its group of up to eight heads as one workgroup's rows,
   --  heads a multiple of 64 up to 256 for keys and values alike (the
   --  wider for small groups), slopes or none, every base and width on
   --  a word of four.
   function Token_Line (Which : Positive) return Address
   is (if Wide_Token (Which)
       then Item.Token_Lines (Token_Rows (Steps.Items (Which).Group_Size, 512)) (8)
       elsif Steps.Items (Which).Attends
         and then (Steps.Items (Which).Rows_As_Heads
                   or else Count in 1 .. Token_Positions_Most)
         and then Steps.Items (Which).Packed.K_Bits = 0
         and then Few_Line (Which) = Null_Handle
         and then Steps.Items (Which).Head_Size = Steps.Items (Which).Value_Size
         and then Steps.Items (Which).Head_Size in 64 | 128 | 192 | 256
         and then Steps.Items (Which).Group_Size in 1 .. Token_Group_Most
         and then Steps.Items (Which).Heads
                    mod Steps.Items (Which).Group_Size = 0
         and then Token_By_Halves
                    (Item, 1, Steps.Items (Which).Head_Size,
                     Steps.Items (Which).Value_Size)
         --  Read in fours: its bases and widths on fours. Not
         --  Fours_Fit, whose values are held to the pairs' 128: the
         --  token's lanes hold a head of 256 (Token_Rows), and Gemma's
         --  heads of 256 attended on the bundles instead.
         and then Steps.Items (Which).K_Base mod 4 = 0
         and then Steps.Items (Which).V_Base mod 4 = 0
         and then Steps.Items (Which).KV_Width mod 4 = 0
         and then Steps.Items (Which).V_Width mod 4 = 0
       then Item.Token_Lines
              (Token_Rows (Steps.Items (Which).Group_Size,
                           Steps.Items (Which).Head_Size))
              (Steps.Items (Which).Head_Size / 64)
       else Null_Handle);

   --  The same kernel's PACKED compilation for a step over a packed
   --  block, or none: the token's shapes, and the subgroup kernels
   --  bound -- a packed block's bases and widths are on words already.
   function Packed_Token_Line (Which : Positive) return Address
   is (if Steps.Items (Which).Attends
         and then Steps.Items (Which).Relative_At = 0
         and then Count in 1 .. Token_Positions_Most
         and then Steps.Items (Which).Packed.K_Bits /= 0
         and then not Item.Plain_Packing
         and then Steps.Items (Which).Head_Size = Steps.Items (Which).Value_Size
         and then Steps.Items (Which).Head_Size in 64 | 128 | 192 | 256
         and then Steps.Items (Which).Group_Size in 1 .. Token_Group_Most
         and then Steps.Items (Which).Heads
                    mod Steps.Items (Which).Group_Size = 0
       then Item.Packed_Token_Lines
              (Token_Rows (Steps.Items (Which).Group_Size,
                           Steps.Items (Which).Head_Size))
              (Steps.Items (Which).Head_Size / 64)
       else Null_Handle);

   --  How many positions an attending step attends for, and with how
   --  many heads: the batch's, or one position of every row's heads.
   function Attending_Of (Which : Positive) return Natural
   is (if Steps.Items (Which).Rows_As_Heads then 1 else Count);

   function Heads_Attending_Of (Which : Positive) return Natural
   is (if Steps.Items (Which).Rows_As_Heads
       then Steps.Items (Which).Heads * Count
       else Steps.Items (Which).Heads);

   --  Only for groups that fill the tile's rows: the compilation reads
   --  its queries where they lie, and a smaller group's sixteen rows
   --  were the next group's queries, past the batch's at its end.
   --  A packed group's batch on the compilation that holds two tiles
   --  of its positions a workgroup; see Latent_Pack_Pair.
   function Pack_Pair (Which : Positive) return Boolean
   is (Few_Line (Which) = Item.Latent_Attend
       and then not Latent_Batch (Which)
       and then Item.Latent_Packed_Attend /= Null_Handle
       and then Latent_Packed (Steps.Items (Which).Group_Size) > 1
       and then Steps.Items (Which).Head_Size <= Latent_Pack_Head
       and then Count > Latent_Packed (Steps.Items (Which).Group_Size));

   function Latent_Batch (Which : Positive) return Boolean
   is (not Steps.Items (Which).Rows_As_Heads
       and then Steps.Items (Which).Group_Size = Latent_Rows
       and then Count >= Latent_Rows
       and then Item.Latent_Batch_Attend /= Null_Handle
       and then Few_Line (Which) = Item.Latent_Attend);

   function Tiled (Which : Positive) return Boolean
   is (Is_Product (Which)
       and then not Steps.Items (Which).Transposed
       and then not Steps.Items (Which).Glu
       and then Steps.Items (Which).Gathers <= 1
       and then not Steps.Items (Which).Listed
       and then not Steps.Items (Which).Exact
       and then Uses_Matrix
                  (Item, Steps.Items (Which).Packing,
                   Steps.Items (Which).Rows,
                   Steps.Items (Which).Columns, Count,
                   Rounded => Steps.Items (Which).Rounded));

   --  Whether a gather goes to the tile, its members a dispatch's third
   --  dimension (Tile_Product's Members): each member its own slice and
   --  its own stretch of every position, the members in order, a batch
   --  of whole blocks of sixteen -- the tile stores a block of sixteen
   --  positions at once, and a member's run is not padded. A latent's
   --  absorbing and expanding gathers over a prompt's batch, which the
   --  row kernel took at a twentieth of the tile's rate.
   function Member_Tiled (Which : Positive) return Boolean
   is (Is_Product (Which)
       and then not Steps.Items (Which).Transposed
       and then Steps.Items (Which).Gathers > 1
       and then not Steps.Items (Which).Glu
       and then not Steps.Items (Which).Listed
       and then not Steps.Items (Which).Joins
       and then Steps.Items (Which).Routed = 0
       and then Steps.Items (Which).Region_At = 0
       and then Steps.Items (Which).Apart = Steps.Items (Which).Columns
       and then Count mod 16 = 0
       and then (for all Member in 1 .. Steps.Items (Which).Gathers =>
                   Steps.Items (Which).Members (Member) = Member - 1)
       and then Uses_Matrix
                  (Item, Steps.Items (Which).Packing,
                   Steps.Items (Which).Each,
                   Steps.Items (Which).Columns, Count));

   --  Bytes from one tap's matrix to the next, for a tap product.
   function Tap_Stride (Which : Positive) return Interfaces.Unsigned_64
   is (Interfaces.Unsigned_64 (Steps.Items (Which).Rows)
       * Row_Bytes (Steps.Items (Which).Packing, Steps.Items (Which).Columns));

   --  Where a normed tap product's gain lies in its weights' buffer, in
   --  bytes and plus one -- past the nine -- or nought.
   function Gain_Place (Which : Positive) return Interfaces.Unsigned_64
   is (if Steps.Items (Which).Tap_Normed
       then Places (Which).Base + 9 * Tap_Stride (Which) + 1
       else 0);

   --  Whether a tap product would go anywhere but the tile.
   function Taps_Untiled return Boolean
   is (for some Index in 1 .. Steps.Held =>
         Steps.Items (Index).Tap_Row > 0 and then not Tiled (Index));

   --  A gate-and-up step's walk as integers, or none: Q4_K's over
   --  whole super-blocks, Q8_0's at two to four positions.
   function Glu_Dots_Line
     (Packing : Weight_Packing; Columns : Natural) return Address
   is (if Packing = Packed_Q4_K and then Columns mod 256 = 0
       then Item.Glu_Dots_Lines (Count)
       elsif Packing = Packed_Q8_0 and then Count in Multi_Count
       then Item.Q8_Glu_Dots_Lines (Count)
       else Null_Handle);

   --  The step a step reads its activation from, or nought for the
   --  caller's.
   function Reads_From (Which : Positive) return Natural
   is (if Steps.Items (Which).Reads /= 0 then Steps.Items (Which).Reads
       elsif Steps.Items (Which).Chained then Which - 1
       else 0);

   --  The rows a walk that reads its experts' runs by slot reads: every
   --  slot of the step it reads, each a row of its width. Nought for any
   --  other walk, which reads the batch's positions.
   function Slot_Rows (Which : Positive) return Natural
   is (if Steps.Items (Which).Listed
         and then Steps.Items (Which).By_Slot
         and then Reads_From (Which) > 0
         and then Steps.Items (Which).Columns > 0
       then Natural (Places (Reads_From (Which)).Bytes
                     / Interfaces.Unsigned_64 (4 * Steps.Items (Which).Columns))
       else 0);

   --  The rows a step's rounding covers: every slot where its runs are
   --  read by slot, the batch's positions otherwise.
   function Round_Rows (Which : Positive) return Natural
   is (if Slot_Rows (Which) > 0 then Slot_Rows (Which) else Count);

   --  Whether a long batch's listed product splits its experts: those
   --  with at most Split_Most positions walk as integers, the rest go
   --  to the matrix kernel, which skips the short ones. A batch of a
   --  hundred spreads eight hundred choices over 256 experts, three or
   --  four an expert, and a tile of sixty-four decoding the weights for
   --  three is the tile's whole cost: the walk reads them as bytes.
   --  A mixture's experts folded on the matrix tile over a long batch:
   --  the gate stores its answers as halves, a slot at a time, into the
   --  first region; the up reads the copy the gate laid out, applies the
   --  unit to the gate's halves as it stores, and stores the gated
   --  middle as halves into the second; the combination is not run;
   --  and the down reads the middle there, laid out by slot as its own
   --  copy would have been. The f32 arms, the combination's pass over
   --  them and the down's copy of its answer go, and the up's copy of
   --  what the gate's already holds. None of the three splits its short
   --  runs off to a walk: the batch is long enough that they are few.
   function Fold_Gate (G : Natural) return Natural;

   --  A biasing step a folded expert product's store can take in: an
   --  expert's bias over its runs, a row an expert, read from its stack.
   function Fold_Bias (B : Natural; Product : Positive) return Boolean
   is (B in 1 .. Steps.Held
       and then Steps.Items (B).Biases
       and then Steps.Items (B).Reads = Product
       --  The inversion its slots' experts are read from.
       and then Steps.Items (B).Reads_Two in 1 .. Steps.Held
       and then Steps.Items (Steps.Items (B).Reads_Two).Inverts
       and then Steps.Items (B).Base /= System.Null_Address
       and then Model_Runner.Numerics."=" (Steps.Items (B).Cap, 0.0)
       and then Steps.Items (B).Reads_Stride = 0
       and then Steps.Items (B).Reads_At = 0
       and then Steps.Items (B).Each = Steps.Items (Product).Each
       and then not Steps.Items (B).Kept);

   --  The combination of a fold: the gate's arm and the up's, plain
   --  units or, after the two biases, the clamped one too.
   function Fold_Combines
     (C : Natural; Gate, Up : Positive; Clamped : Boolean) return Boolean
   is (C in 1 .. Steps.Held
       and then Steps.Items (C).Blends
       and then (Steps.Items (C).Unit in 0 | 1
                 or else (Clamped and then Steps.Items (C).Unit = 3))
       and then Steps.Items (C).Reads in 0 | Gate
       and then Steps.Items (C).Reads_Two in 0 | Up
       and then not Steps.Items (C).Kept);

   --  And its down: by slot, over the combination.
   function Fold_Downs (D : Natural; Combined, Up : Positive) return Boolean
   is (D in 1 .. Steps.Held
       and then Listed_Tiled (D)
       and then Steps.Items (D).By_Slot
       and then not Steps.Items (D).Exact
       and then Reads_From (D) = Combined
       and then Steps.Items (D).Columns = Steps.Items (Up).Each);

   --  A mixture's experts folded on the matrix tile over a long batch:
   --  the gate stores its answers as halves, a slot at a time, into the
   --  first region; the up reads the copy the gate laid out, applies the
   --  unit to the gate's halves as it stores, and stores the gated
   --  middle as halves into the second; the combination is not run;
   --  and the down reads the middle there, laid out by slot as its own
   --  copy would have been. The f32 arms, the combination's pass over
   --  them and the down's copy of its answer go, and the up's copy of
   --  what the gate's already holds. Where each arm has its experts'
   --  biases after it -- gpt-oss -- the gate and the up add them as
   --  they store and the biasing steps are not run either. None of the
   --  three splits its short runs off to a walk: the batch is long
   --  enough that they are few. One for the plain form, two for the
   --  biased, nought where G does not begin one.
   function Fold_Gate (G : Natural) return Natural is
   begin
      if not
        (G >= 1
         and then G + 3 <= Steps.Held
         and then Listed_Tiled (G)
         and then Listed_Tiled (G + 1)
         and then not Steps.Items (G).By_Slot
         and then not Steps.Items (G + 1).By_Slot
         and then not Steps.Items (G).Exact
         and then not Steps.Items (G + 1).Exact
         and then not Steps.Items (G).Kept
         and then not Steps.Items (G + 1).Kept
         and then not Steps.Items (G).Joins
         and then not Steps.Items (G + 1).Joins
         and then Steps.Items (G).Columns = Steps.Items (G + 1).Columns
         and then Steps.Items (G).Each = Steps.Items (G + 1).Each
         and then Steps.Items (G).Rows = Steps.Items (G + 1).Rows
         and then Steps.Items (G).Gathers = Steps.Items (G + 1).Gathers
         and then Steps.Items (G).Used = Steps.Items (G + 1).Used
         and then Reads_From (G) = Reads_From (G + 1)
         --  Runs long enough that few are short, whichever tile takes
         --  them.
         and then Count * Steps.Items (G).Used
                  >= Fold_Least_Run
                     * Natural'Max (Steps.Items (G).Gathers, 1))
      then
         return 0;
      elsif Fold_Combines (G + 2, G, G + 1, Clamped => False)
        and then Fold_Downs (G + 3, G + 2, G + 1)
      then
         return 1;
      elsif Fold_Bias (G + 2, G)
        and then Fold_Bias (G + 3, G + 1)
        and then Fold_Combines (G + 4, G + 2, G + 3, Clamped => True)
        and then Fold_Downs (G + 5, G + 4, G + 1)
      then
         return 2;
      else
         return 0;
      end if;
   end Fold_Gate;

   --  A step's part in such a fold: the gate one, the up two, the
   --  combination three, the down four, a bias five; nought for any
   --  other step.
   function Fold_Role (Which : Positive) return Natural is
   begin
      for Back in 0 .. 5 loop
         exit when Back >= Which;
         declare
            Form : constant Natural := Fold_Gate (Which - Back);
         begin
            if Form /= 0 then
               case Back is
                  when 0 => return 1;
                  when 1 => return 2;
                  when 2 => return (if Form = 1 then 3 else 5);
                  when 3 => return (if Form = 1 then 4 else 5);
                  when 4 => return (if Form = 2 then 3 else 0);
                  when others => return (if Form = 2 then 4 else 0);
               end case;
            end if;
         end;
      end loop;
      return 0;
   end Fold_Role;

   --  For a folded gate or up, its bias step, or nought: two on in the
   --  biased form, whichever of the two it is.
   function Fold_Bias_Of (Which : Positive) return Natural
   is (if Fold_Role (Which) = 1 and then Fold_Gate (Which) = 2
       then Which + 2
       elsif Fold_Role (Which) = 2 and then Fold_Gate (Which - 1) = 2
       then Which + 2
       else 0);

   --  For a folded up, its combination.
   function Fold_Combination_Of (Which : Positive) return Natural
   is (if Fold_Role (Which) /= 2 then 0
       elsif Fold_Gate (Which - 1) = 2 then Which + 3
       else Which + 1);

   --  Whether a biasing step multiplies an expert's scale into the
   --  answers a listed projection down gave by slot, for the mix right
   --  after it alone to read: the mix takes the scale in as it reads
   --  each slot (mix.comp's table), the step is not run, and its room
   --  is the projection's. Gemma 4's 26B wrote a copy of every slot's
   --  answer to scale it, a tenth of a layer's room a position and
   --  three milliseconds a layer of a batch of 754.
   function Scale_Mixed (S : Positive) return Boolean
   is (S < Steps.Held
       and then Steps.Items (S).Biases
       and then Steps.Items (S).Scales
       and then not Steps.Items (S).Per_Member
       and then not Steps.Items (S).Fresh
       and then not Steps.Items (S).Kept
       and then Steps.Items (S).Base /= System.Null_Address
       and then Model_Runner.Numerics."=" (Steps.Items (S).Cap, 0.0)
       and then Steps.Items (S).Reads_Stride = 0
       and then Steps.Items (S).Reads_At = 0
       and then Steps.Items (S).Reads in 1 .. S - 1
       and then Steps.Items (Steps.Items (S).Reads).Rows = Steps.Items (S).Rows
       and then Steps.Items (S).Reads_Two in 1 .. S - 1
       and then Steps.Items (Steps.Items (S).Reads_Two).Inverts
       and then Steps.Items (Steps.Items (S).Reads_Two).Reads in 1 .. S - 1
       and then Steps.Items (S + 1).Mixes
       and then Steps.Items (S + 1).Reads = S
       and then Steps.Items (S + 1).Reads_Two = Steps.Items (S).Reads_Two
       and then Steps.Items (S + 1).Rows = Steps.Items (S).Each
       --  No other step reads the scaled answers.
       and then (for all Other in S + 2 .. Steps.Held =>
                   Steps.Items (Other).Reads /= S
                   and then Steps.Items (Other).Reads_Two /= S
                   and then Steps.Items (Other).Joined /= S));

   function Mix_Scaled (M : Positive) return Boolean
   is (M > 1 and then Scale_Mixed (M - 1));

   --  Who reads each step's answer, as Reusing says. Counted wide: a
   --  step is taken to read the two before it whatever it names, and
   --  every step it names by Reads, Reads_Two, Joined (and what that
   --  join reads) and Routed. A mixture's folded gate, up, biases,
   --  combination and down write one another's rooms out of order, so
   --  a fold's steps are one: written from its gate, read to its last
   --  reader. A folded join is its product's room. The last two steps
   --  may be carried out to the next sequence, and a kept step is read
   --  by the host after the run, so neither room is dealt again.
   --  A sequence with a step whose shape names other steps of its own
   --  -- the linear, RWKV, Mamba and convolution steps -- or with taps
   --  keeps a room a step, as every sequence did.
   procedure Plan_Reuse is
      procedure Note (Reader, Read : Natural) is
      begin
         if Read in 1 .. Steps.Held then
            Last_Use (Read) := Natural'Max (Last_Use (Read), Reader);
         end if;
      end Note;
   begin
      Reusing := Steps.Held > 2;
      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);
         begin
            if This.Mambas or else This.Rwkvs or else This.Wkvs
              or else This.Convolves or else This.Rules
              or else This.Tap_Row /= 0
            then
               Reusing := False;
            end if;
         end;
      end loop;
      if not (for some Index in 1 .. Steps.Held =>
                Steps.Items (Index).Chained or else Steps.Items (Index).Attends)
      then
         Reusing := False;
      end if;
      if not Reusing then
         return;
      end if;

      for Index in 1 .. Steps.Held loop
         Born (Index) := Index;
         Last_Use (Index) :=
           (if Steps.Items (Index).Kept then Natural'Last else Index);
      end loop;

      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);
         begin
            Note (Index, This.Reads);
            Note (Index, This.Reads_Two);
            Note (Index, This.Routed);
            Note (Index, This.Joined);
            if This.Joined in 1 .. Steps.Held then
               Note (Index, Steps.Items (This.Joined).Reads);
               Note (Index, Steps.Items (This.Joined).Reads_Two);
            end if;
            if Index > 1 then
               Note (Index, Index - 1);
            end if;
            if Index > 2 then
               Note (Index, Index - 2);
            end if;
         end;
      end loop;

      for G in 1 .. Steps.Held loop
         declare
            Form : constant Natural := Fold_Gate (G);
            Last : constant Natural :=
              Natural'Min (Steps.Held, G + (if Form = 1 then 3 else 5));
            Most : Natural := 0;
         begin
            if Form /= 0 then
               for J in G .. Last loop
                  Most := Natural'Max (Most, Last_Use (J));
               end loop;
               for J in G .. Last loop
                  Last_Use (J) := Most;
                  Born (J) := Natural'Min (Born (J), G);
               end loop;
            end if;
         end;
      end loop;

      for Index in 2 .. Steps.Held loop
         if Mix_Scaled (Index) then
            --  The mix reads the routing for each slot's expert.
            Note (Index, Steps.Items (Steps.Items (Index).Reads_Two).Reads);
         end if;
      end loop;

      --  A scale taken into the mix is the projection's room.
      for Index in reverse 2 .. Steps.Held loop
         if Scale_Mixed (Index) then
            declare
               Down : constant Positive := Steps.Items (Index).Reads;
            begin
               Last_Use (Down) := Natural'Max (Last_Use (Down), Last_Use (Index));
            end;
         end if;
      end loop;

      for Index in reverse 2 .. Steps.Held loop
         if Steps.Items (Index).Folded then
            Last_Use (Index - 1) :=
              Natural'Max (Last_Use (Index - 1), Last_Use (Index));
            Born (Index - 1) := Natural'Min (Born (Index - 1), Born (Index));
         end if;
      end loop;

      Last_Use (Steps.Held) := Natural'Last;
      Last_Use (Steps.Held - 1) := Natural'Last;
      --  And the product a folded chain at the end stores for.
      declare
         Back : Natural := Steps.Held;
      begin
         while Back > 1 and then Steps.Items (Back).Folded loop
            Last_Use (Back - 1) := Natural'Last;
            Back := Back - 1;
         end loop;
      end;
   end Plan_Reuse;

   function Split_Listed (Which : Positive) return Boolean
   is (Fold_Role (Which) = 0
       and then Listed_Tiled (Which)
       and then not Steps.Items (Which).Exact
       and then Rounds_Walks (Item) = Rounds_Every
       and then Steps.Items (Which).Columns mod 32 = 0
       and then Steps.Items (Which).Columns <= Round_Columns
       and then Natural'Max (Round_Rows (Which), 8)
                * Steps.Items (Which).Columns / 8 * 9 <= Round_Bytes
       and then Dots_Line (Item, Steps.Items (Which).Packing, Split_Most,
                           Steps.Items (Which).Columns) /= Null_Handle);

   --  The descriptor set a split step's walk binds: one of those past
   --  the sequence's steps, written as a walk's -- its lists where the
   --  walk reads them, where the matrix kernel reads the runs' copy --
   --  or nought where none is left, and the step does not split.
   function Spare_Of (Which : Positive) return Natural is
      Ahead : Natural := 0;
   begin
      if not Split_Listed (Which) then
         return 0;
      end if;
      for Earlier in 1 .. Which loop
         if Split_Listed (Earlier) then
            Ahead := Ahead + 1;
         end if;
      end loop;
      return (if Steps.Held + Ahead <= Sequence_Limit
              then Steps.Held + Ahead else 0);
   end Spare_Of;

   function Splits (Which : Positive) return Boolean
   is (Spare_Of (Which) /= 0);

   --  Whether a product walks as integers over its activations rounded
   --  first: a Q4_K walk of a few positions, its gate and up or any of
   --  them as Round_Walks says, reading its one activation from the
   --  front of what its binding names. See Round_Walks.
   function Dotted (Which : Positive) return Boolean
   is (Count in Many_Count
       and then Is_Product (Which)
       and then not Steps.Items (Which).Exact
       and then Steps.Items (Which).Columns mod 32 = 0
       and then Steps.Items (Which).Columns <= Round_Columns
       and then Rounds_Walks (Item) /= Rounds_None
       and then
         (if Steps.Items (Which).Glu
          then Glu_Dots_Line (Steps.Items (Which).Packing,
                              Steps.Items (Which).Columns)
               /= Null_Handle
          else Rounds_Walks (Item) = Rounds_Every
               and then not Tiled (Which)
               and then not Listed_Tiled (Which)
               --  A mixture's experts each walking their own run: the
               --  runs read the batch's positions by their lists, as
               --  the rounding lays them out -- but not a run laid out
               --  by slot, whose activation is a gathered copy.
               and then (if Steps.Items (Which).Listed
                         then not Steps.Items (Which).By_Slot
                              --  By slot, every slot rounded, which the
                              --  region has to hold.
                              or else (Slot_Rows (Which) > 0
                                       and then Natural'Max (Slot_Rows (Which), 8)
                                                * Steps.Items (Which).Columns / 8 * 9
                                                <= Round_Bytes)
                         else Steps.Items (Which).Gathers = 0
                              and then Steps.Items (Which).Routed = 0)
               and then Dots_Line (Item, Steps.Items (Which).Packing,
                                   Count, Steps.Items (Which).Columns)
                        /= Null_Handle));

   function Reference_Region (Which : Positive) return Interfaces.Unsigned_64 is
     ((Interfaces.Unsigned_64 (Natural'Max (Count, 8))
       * Interfaces.Unsigned_64 (Steps.Items (Which).Columns) * 9 / 8 + 63) / 64 * 64);

   function Reference_Offset (Which : Positive) return Interfaces.Unsigned_64 is
      Offset : Interfaces.Unsigned_64 := 0;
   begin
      --  Device packing is issued immediately before the product that
      --  consumes it. One region is live; host-prepacked sequences still
      --  retain a distinct region per input until their products run.
      if Item.Reference_Round_Line /= Null_Handle then return 0; end if;
      for Index in 1 .. Which - 1 loop Offset := Offset + Reference_Region (Index); end loop;
      return Offset;
   end Reference_Offset;

   function Same_Reference_Input (Left, Right : Positive) return Boolean is
      A : Step renames Steps.Items (Left);
      B : Step renames Steps.Items (Right);
   begin
      return A.Reference_Integer and then B.Reference_Integer and then A.Columns = B.Columns
        and then (A.Packing in Packed_Q8_0 | Packed_Q5_0 | Packed_IQ4_NL | Packed_Q2_0)
               = (B.Packing in Packed_Q8_0 | Packed_Q5_0 | Packed_IQ4_NL | Packed_Q2_0)
        and then Reads_From (Left) = Reads_From (Right)
        and then A.At_Vector = B.At_Vector;
   end Same_Reference_Input;

   function Reference_Dotted (Which : Positive) return Boolean is
     (Steps.Items (Which).Reference_Integer
      and then Item.Reference_Line /= Null_Handle
      and then not Carry_In and then not Carry_Out
      and then (for all Index in 1 .. Steps.Held => Steps.Items (Index).Reference_Integer
        or else (Steps.Items (Index).Blends and then Steps.Items (Index).Unit in 14 .. 19)
        or else (Steps.Items (Index).Attends and then Steps.Items (Index).Relative_At /= 0))
      and then (not Steps.Items (Which).Chained or else Item.Reference_Round_Line /= Null_Handle)
      and then not Steps.Items (Which).Glu and then not Steps.Items (Which).Joins
      and then Steps.Items (Which).Gathers = 0 and then not Steps.Items (Which).Listed
      and then Count <= 128 and then Steps.Items (Which).Columns > 0
      and then (Steps.Items (Which).Packing in Packed_Q4_K | Packed_Q5_K | Packed_Q6_K
                  | Packed_Q8_0 | Packed_Q5_0
        or else (Item.Reference_GSQ_Line /= Null_Handle and then Steps.Items (Which).Packing in
                   Packed_IQ3_S | Packed_IQ3_XXS | Packed_IQ4_NL | Packed_Q2_0))
      and then Steps.Items (Which).Columns mod
        (if Steps.Items (Which).Packing in Packed_Q8_0 | Packed_Q5_0 | Packed_IQ4_NL then 32
         elsif Steps.Items (Which).Packing = Packed_Q2_0 then 64 else 256) = 0
      --  Native bytes are fetched through uint words. Refuse a final partial
      --  word rather than read past an unpadded weight descriptor.
      and then (if Steps.Items (Which).Packing in Packed_Q6_K | Packed_Q8_0 | Packed_Q5_0
                      | Packed_IQ4_NL | Packed_Q2_0 | Packed_IQ3_S | Packed_IQ3_XXS then
        ((Steps.Items (Which).Columns /
          (if Steps.Items (Which).Packing in Packed_Q6_K | Packed_IQ3_S | Packed_IQ3_XXS then 256
           elsif Steps.Items (Which).Packing = Packed_Q2_0 then 64 else 32)) mod 2 = 0
         or else Steps.Items (Which).Rows mod 2 = 0) else True)
      and then (if Item.Reference_Round_Line /= Null_Handle then Reference_Region (Which) <= Round_Bytes
                else Reference_Offset (Steps.Held) + Reference_Region (Steps.Held) <= Round_Bytes));

   --  Whether a walk reads a normalization's answer whole, a position
   --  a row of its width.
   function Reads_Normed (Which, Norm : Positive) return Boolean
   is (Dotted (Which)
       and then Reads_From (Which) = Norm
       and then Steps.Items (Norm).Norms
       and then Steps.Items (Norm).Groups = 1
       and then Steps.Items (Which).Columns = Steps.Items (Norm).Rows);

   --  Whether a normalization rounds its answer for the walks that
   --  read it, sparing them a rounding of their own: where one does.
   function Norm_Rounds (Which : Positive) return Boolean
   is (Steps.Items (Which).Norms
       and then Item.Norm_Round_Line /= Null_Handle
       and then (for some Reader in Which + 1 .. Steps.Held =>
                   Reads_Normed (Reader, Which)));

   --  Whether a walk reads a normalization that rounded for it: its
   --  rounding is there already, in the normalization's region.
   function From_Rounded_Norm (Which : Positive) return Boolean
   is (Reads_From (Which) > 0
       and then Reads_Normed (Which, Reads_From (Which))
       and then Norm_Rounds (Reads_From (Which)));

   --  The stretch of the result buffer a step that readies heads reads:
   --  from the first byte of the steps it names to the last. It is bound
   --  as that and not as the whole buffer, and the offsets it is told are
   --  counted from its front. Bound whole, the validation layer took the
   --  step as reading everything any step before it had written, and
   --  reported the keys' step reading the queries' step unfenced at every
   --  layer -- which it does not read, and which its own sources are
   --  fenced from.
   function Heads_Floor (Which : Positive) return Interfaces.Unsigned_64
   is (if Steps.Items (Which).Reads_Two /= 0
       then Interfaces.Unsigned_64'Min
              (Places (Steps.Items (Which).Reads).At_Byte,
               Places (Steps.Items (Which).Reads_Two).At_Byte)
       else Places (Steps.Items (Which).Reads).At_Byte);

   function Heads_Ceiling (Which : Positive) return Interfaces.Unsigned_64
   is (Interfaces.Unsigned_64'Max
         (Places (Steps.Items (Which).Reads).At_Byte
          + Places (Steps.Items (Which).Reads).Bytes,
          (if Steps.Items (Which).Reads_Two /= 0
           then Places (Steps.Items (Which).Reads_Two).At_Byte
                + Places (Steps.Items (Which).Reads_Two).Bytes
           else 0)));

   --  Bytes one member's slice of a gathered step takes, and where a
   --  gather of one begins: the tile kernel and the single-member row
   --  product both read that slice as a matrix of its own.
   function Slice_Bytes (Which : Positive) return Interfaces.Unsigned_64
   is (Interfaces.Unsigned_64
         (if Steps.Items (Which).Slice_Rows /= 0
          then Steps.Items (Which).Slice_Rows
          else Steps.Items (Which).Each)
       * Row_Bytes (Steps.Items (Which).Packing,
                    Steps.Items (Which).Columns));

   function Slice_Base (Which : Positive) return Interfaces.Unsigned_64
   is (if Steps.Items (Which).Gathers = 1
       then Interfaces.Unsigned_64 (Steps.Items (Which).Members (1))
            * Slice_Bytes (Which)
       else 0);

   Vector_Bytes : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64 (Vector_Room) * 4;

   --  Room the result buffer keeps at its front for the activation a
   --  sequence carries in or leaves behind. Nothing else is placed
   --  there, so a sequence may read what the one before it wrote while
   --  writing its own answers past it.
   --
   --  Wide enough for a tile's store as well as the activation's own
   --  size. Where a join is folded into the product before it, the step
   --  that leaves the answer here is a product rather than a join, and a
   --  product on the matrix kernel stores the columns the rounding
   --  invented beside the real ones. A hundred and ten columns of a
   --  batch rounded to a hundred and twenty-eight is a sixth more than
   --  the activation measures, and the front has to hold it or the carry
   --  is refused and the sequence after this one reads a room nothing
   --  wrote.
   Carry_Room : constant Interfaces.Unsigned_64 :=
     (Interfaces.Unsigned_64'Max
        (Vector_Bytes,
         (if Steps.Held = 0 then 0
          else Interfaces.Unsigned_64 (Steps.Items (Steps.Held).Rows)
               * Interfaces.Unsigned_64 (Whole_Tiles (Item, Count)) * 4))
      + Alignment - 1) / Alignment * Alignment;

   Result_Bytes : Interfaces.Unsigned_64 := Origin + Carry_Room;

   --  Room the angles need, which the widest rotating step decides.
   Turn_Room : Interfaces.Unsigned_64 := 0;

   --  And the fresh weights' room after the widest table (Add_Bias's
   --  Fresh), and where it begins.
   Fresh_Room : Interfaces.Unsigned_64 := 0;
   Fresh_At   : Interfaces.Unsigned_64 := 0;

   --  The clock reading a sequence's matrices are pinned from, so that
   --  acquiring the last of them cannot release the first.
   Pinned : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;

   --  The largest half-precision copy any step of this sequence wants,
   --  which is what the one buffer holding it has to be. Zero when no
   --  step goes to the matrix kernel, and then no buffer is made.
   Half_Bytes   : Interfaces.Unsigned_64 := 0;

   Wanted       : Model_Runner.Numerics.Element_Count := 0;
   Good         : Boolean;

   --  Give back whatever this call borrowed, on every way out.
   procedure Release_All;

   procedure Release_All is
   begin
      --  A device that did not finish still reads what it was given: a
      --  stalled engine leaks it, as Await says, rather than hand it to
      --  the next borrower.
      if Item.Stalled then
         return;
      end if;
      for Index in 1 .. Steps.Held loop
         if Places (Index).Borrowed then
            declare
               Kept : Boolean := False;
            begin
               if Places (Index).Streamed then
                  Keep_Spare
                    (Item, Places (Index).Buffer, Places (Index).Memory,
                     Places (Index).Mapped, Places (Index).Weight,
                     Places (Index).Tier, Kept);
               end if;

               if not Kept then
                  Give_Back_Buffer
                    (Item, Places (Index).Buffer, Places (Index).Memory);
               end if;
            end;
            Places (Index).Borrowed := False;
         end if;
      end loop;
   end Release_All;
begin
   Ok := False;
   for Index in 1 .. Steps.Held loop
      if Steps.Items (Index).Reference_Integer and then not Reference_Dotted (Index) then
         Item.Refused := Shape_Refused;
         Cancelled := False;
         return;
      end if;
   end loop;
   Cancelled := False;

   --  Until the shapes are through, a refusal is a shape's; the
   --  attention step names its own two below.
   Item.Refused := Shape_Refused;

   if Steps.Held = 0 or else not Is_Ready (Item) then
      return;
   end if;

   --  A tap product is the tile's alone: no other kernel reads its
   --  nine matrices.
   if Taps_Untiled then
      return;
   end if;

   --  A head past the attention's room is an absorbed latent's, read by
   --  its own kernel or by none: refused here, the caller attends it
   --  another way rather than a kernel reading past what it holds.
   for Index in 1 .. Steps.Held loop
      if Steps.Items (Index).Attends
        and then (Steps.Items (Index).Value_Size > Attention_Room
                  or else Steps.Items (Index).Head_Size > Attention_Room)
        and then Few_Line (Index) /= Item.Latent_Attend
        and then not Wide_Token (Index)
      then
         return;
      end if;
   end loop;

   Plan_Reuse;

   --  What the whole run needs, and whether it is askable at all. Every
   --  product reads the same activation, so they must agree about how
   --  wide it is; they may differ in every other way.
   for Index in 1 .. Steps.Held loop
      declare
         This : Step renames Steps.Items (Index);

         Wide : constant Interfaces.Unsigned_64 :=
           Row_Bytes (This.Packing, This.Columns);

         --  Vectors this step's answers are given room for: the batch
         --  rounded up to a whole tile where the matrix kernel will run,
         --  and the batch itself everywhere else. The rounding is room
         --  the kernel writes and nothing reads; the read-back below
         --  takes the batch's own share from the front of it.
         Room : constant Natural :=
           (if Tiled (Index) then Whole_Tiles (Item, Count) else Count);

         --  The most slices this step's attending can cut at this
         --  batch, however deep the cache: one where the batch takes
         --  the matrix or tiled kernel, which leaves no records. It was
         --  Slice_Limit whatever was cut, and a prompt's batch of 2,048
         --  on ThinkingCap held 812 MB for records nothing wrote.
         --  A packed step cuts as Packed_Slices does, which the exact
         --  kernels' count did not bound: a tiled batch reserved no
         --  records and the packed kernel cut up to Slice_Limit slices
         --  past its room. Bounded here from the fewest workgroups its
         --  bundles can give -- the most slices -- and by Merged_Slices
         --  at the deepest cache, as the dispatch below is at its own.
         Packed_Most : constant Natural :=
           (if This.Attends and then This.Packed.K_Bits /= 0
            then Natural'Min
                   (Packed_Slices
                      (Item,
                       (This.Heads
                        + Packed_Bundle
                            (Item, Natural'Max (1, This.Group_Size),
                             Packed_Queries (Natural'Max (1, Count)),
                             Natural'Last)
                        - 1)
                       / Packed_Bundle
                           (Item, Natural'Max (1, This.Group_Size),
                            Packed_Queries (Natural'Max (1, Count)),
                            Natural'Last)
                       * ((Natural'Max (1, Count)
                           + Packed_Queries (Natural'Max (1, Count)) - 1)
                          / Packed_Queries (Natural'Max (1, Count))),
                       First    => 0,
                       Last     => Slice_Limit * Slice_Least,
                       Rounding => False),
                    Merged_Slices (This.Heads, Natural'Last))
            else 1);

         Most_Slices : constant Natural :=
           (if This.Attends and then This.Packed.K_Bits /= 0
            then Packed_Most
            --  The latent kernel cuts as Latent_Slices says, the
            --  deepest cache's at its most: one slice where a batch of
            --  its rows or more is attending, which is a prompt's. It
            --  was counted at the few-position kernel's thirty-two, and
            --  Gemma 4's 26B kept 695 MB a batch of 512 for records its
            --  global layers' attention never cut but one of.
            elsif This.Attends
              and then (Latent_Batch (Index)
                        or else Few_Line (Index) = Item.Latent_Attend)
            then (if Latent_Batch (Index) then 1
                  else Natural'Min
                         (Few_Most_Slices,
                          Latent_Slices (2 ** 24, Attending_Of (Index))))
            elsif This.Attends and then Wide_Token (Index)
            then Wide_Token_Slices (2 ** 24)
            elsif This.Attends and then Few_Line (Index) /= Null_Handle
            then Few_Most_Slices
            --  Counted as the dispatch counts them: rows attending as
            --  heads are one position of heads by rows, which the batch
            --  test that leaves no records does not see.
            elsif This.Attends and then Item.Merge_Line /= Null_Handle
            then Natural'Min
                   (Attend_Slices
                      (Item, Attending_Of (Index), This.Head_Size, This.Value_Size,
                       First    => 0,
                       Last     => Slice_Limit * Slice_Least,
                       Rounding => False),
                    Merged_Slices (Heads_Attending_Of (Index), Natural'Last))
            else 1);

         Mine : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (This.Rows)
           * Interfaces.Unsigned_64 (Room) * 4
           --  And after an attending step's answers, room for the
           --  records its slices leave for the merge: a blend and two
           --  numbers a slice, position and head, for the most slices
           --  it can cut.
           --  A few at once leave records however many slices they
           --  cut, one included, and merge them.
           + (if Most_Slices > 1
                or else (This.Attends and then Few_Line (Index) /= Null_Handle)
              then Interfaces.Unsigned_64 (Most_Slices)
                   * Interfaces.Unsigned_64 (Room)
                   * Interfaces.Unsigned_64
                       (This.Rows + 2 * This.Heads) * 4
              else 0);
      begin
         if Tiled (Index) then
            --  What it reads, and what it may be asked to write: a
            --  product whose answer is wanted only in half precision
            --  writes it here rather than into the result buffer.
            --  And as far on as it reads, where it is a tap whose copy
            --  the first tap made long enough for every tap.
            Half_Bytes := Interfaces.Unsigned_64'Max
              (Half_Bytes,
               (Interfaces.Unsigned_64'Max
                  (Interfaces.Unsigned_64 (This.Columns),
                   Interfaces.Unsigned_64 (This.Rows))
                * Interfaces.Unsigned_64 (Room)
                + Interfaces.Unsigned_64 (This.At_Vector)
                + Interfaces.Unsigned_64 (Tap_Reach (This))) * 2);
         elsif Member_Tiled (Index) then
            --  Every member's stretch of every position, rounded up.
            Half_Bytes := Interfaces.Unsigned_64'Max
              (Half_Bytes,
               Interfaces.Unsigned_64 (This.Columns)
               * Interfaces.Unsigned_64 (This.Gathers)
               * Interfaces.Unsigned_64 (Whole_Tiles (Item, Count)) * 2);
         elsif Listed_Tiled (Index) then
            --  The runs' vectors, laid out by slot.
            Half_Bytes := Interfaces.Unsigned_64'Max
              (Half_Bytes,
               Interfaces.Unsigned_64 (This.Columns)
               * Interfaces.Unsigned_64 (Listed_Slots (Index)) * 2);
         end if;

         --  A combining step carries no matrix: it reads the two
         --  results before it and writes its own. Everything the shape
         --  checks below say about a matrix is beside the point for it.
         if This.Places then
            --  A placing step carries no weight and reads no matrix: it
            --  writes what a step before it made into the cache, so what
            --  it needs is a cache to write into.
            if This.Rows = 0
              or else (Item.Cache_Buffer = Null_Handle
                       and then not (Item.Copy_Only
                                     and then Item.Copy_Buffer
                                              /= Null_Handle))
              or else (This.Reads = 0 and then not This.Unpacks
                       and then not This.Fetches)
              or else (This.Fetches and then Item.Fetch_Line = Null_Handle)
              or else This.Reads > Steps.Held
              --  And the kernel that packs, for a packed row, or the
              --  one that unpacks, for a batch's copy of them -- and
              --  room in the copy for what it writes.
              or else (This.Pack.Bits /= 0
                       and then not This.Unpacks
                       and then Pack_Pipeline (Item) = Null_Handle)
              or else (This.Unpacks
                       and then (Item.Unpack_Line = Null_Handle
                                 or else This.Half_At
                                         + Interfaces.Unsigned_64 (This.Cells)
                                           * Interfaces.Unsigned_64 (This.Rows)
                                         > Item.Cache_Bytes / 2))
            then
               return;
            end if;

            Places (Index).Weight := 0;
         elsif This.Rotates then
            --  A rotating step carries a table of two wide numbers a
            --  pair a position, which the device keeps the way it keeps
            --  a matrix -- so everything below about residency serves it
            --  and only the shape check differs.
            if This.Rows = 0
              or else This.Base = System.Null_Address
              or else This.Reads > Steps.Held
            then
               return;
            end if;

            Places (Index).Weight := 0;

            Turn_Room := Interfaces.Unsigned_64'Max
              (Turn_Room,
               Interfaces.Unsigned_64 (This.Turns / 2)
               * Interfaces.Unsigned_64 (Count) * 16);
         elsif This.Norms then
            --  A normalizing step carries a weight of one element a
            --  component, which the device keeps the way it keeps a
            --  matrix -- so everything below about residency serves it
            --  and only the shape check differs.
            if This.Rows = 0
              or else This.Base = System.Null_Address
              or else This.Reads > Steps.Held
              or else Interfaces.Unsigned_64 (This.Span)
                        < Interfaces.Unsigned_64 (This.At_Byte)
                          + Interfaces.Unsigned_64
                              (This.Rows / This.Groups) * 4
                            * (if This.Shifts then 2 else 1)
            then
               return;
            end if;

            --  The weight is one stretch wide, however many stretches
            --  a position is normalized as -- and two, gain then
            --  shift, for the centred normalization.
            Places (Index).Weight :=
              Interfaces.Unsigned_64 (This.Rows / This.Groups) * 4
              * (if This.Shifts then 2 else 1);
         elsif This.Biases then
            --  A biasing step carries the bias stack, which the device
            --  keeps the way it keeps a matrix, and reads a gathered
            --  product and its routing.
            if This.Rows = 0
              or else (This.Base = System.Null_Address
                       and then This.Stack /= 0)
              or else This.Reads = 0
              or else This.Reads > Steps.Held
              or else This.Reads_Two > Steps.Held
              or else Item.Bias_Line = Null_Handle
            then
               return;
            end if;

            Places (Index).Weight :=
              Interfaces.Unsigned_64 (This.Stack * This.Each) * 4;

            --  A fresh weight's place beside the angle tables, counted
            --  from the end of the widest of them once all are known.
            if This.Fresh then
               Places (Index).Base := Fresh_Room;
               Fresh_Room := Fresh_Room + (Places (Index).Weight + 15) / 16 * 16;
            end if;
         elsif This.Attends then
            --  An attention step carries no matrix either, and reads a
            --  cache rather than a weight. What it needs that the shape
            --  checks below cannot say is that the cache is there: a
            --  sequence recorded against a cache the engine does not
            --  hold would dispatch against whatever the binding last
            --  named, which is an answer and a wrong one. Where only the
            --  copy is kept the cache proper is null, but the matrix
            --  kernel reads the copy and a copy-only session has one --
            --  and it is sinkless, so nothing here reads the binary32.
            if Item.Cache_Buffer = Null_Handle
              and then not (Item.Copy_Only
                            and then Item.Copy_Buffer /= Null_Handle)
            then
               Item.Refused := Cache_Refused;
               return;
            end if;

            --  A split copy keeps its values on a binding of their own,
            --  which only the matrix kernel reads. A batch too small for
            --  that kernel -- a generated token -- has no device kernel
            --  that reads the split copy, so it is refused here and
            --  attends on the host out of the host's own cache, as it
            --  did before the copy grew past one buffer.
            if Item.Copy_Split
              and then not Attends_By_Matrix
                             (Item, Count, This.Head_Size, This.Value_Size)
            then
               Item.Refused := Cache_Refused;
               return;
            end if;

            --  And a cache kept as its copy holds no rows in binary32:
            --  a batch the tiled kernel would take -- it reads the cache
            --  proper -- is refused here and attends on the host.
            if Item.Copy_Only
              and then not Reads_Copy
                             (Item, Count, This.Head_Size, This.Value_Size,
                              False)
            then
               Item.Refused := Cache_Refused;
               return;
            end if;

            --  A packed block needs the kernel that reads one, and a
            --  shape that kernel takes.
            if This.Packed.K_Bits /= 0
              and then not Packed_Fits
                             (Item, This.Packed, This.Head_Size,
                              This.Value_Size, This.KV_Width,
                              This.V_Width)
            then
               Item.Refused := Packed_Refused;
               return;
            end if;

            if not Relative_Fits (Item, This.Packed.K_Codec, This.Packed.V_Codec,
                                  This.Relative_At, This.Heads, Count, This.First)
            then Item.Refused := Packed_Refused; return; end if;
            if This.Rows = 0
              or else (not This.Chained and then
                       (This.At_Vector > Vectors'Length
                        or else Model_Runner.Numerics.Element_Count (This.Columns)
                          * Model_Runner.Numerics.Element_Count (Count)
                            > Model_Runner.Numerics.Element_Count (Vectors'Length)
                              - Model_Runner.Numerics.Element_Count (This.At_Vector)))
            then
               return;
            end if;

            Places (Index).Weight := 0;
         elsif This.Readies then
            --  A heads step reads a projection and, placing, the
            --  values' projection; it carries a weight one head wide, a
            --  bias as wide as what it reads, or none, kept like a
            --  normalization's; and it needs the
            --  cache where it places, and the pipeline at all.
            --  A reader of a fused product reads its own rows of it,
            --  every Reads_Stride: the product spans the stride, and the
            --  reader's rows lie inside it. This asked for the product
            --  to be the reader's width whatever the stride, so no
            --  fused-QKV layer ever went whole -- phi3's none of 288 --
            --  and the suite's deep fixture, fused the same way, never
            --  put a layer whole on the device at all.
            if This.Rows = 0
              or else This.Reads not in 1 .. Index - 1
              or else (if This.Reads_Stride = 0
                       then Steps.Items (This.Reads).Rows /= This.Rows
                       else Steps.Items (This.Reads).Rows
                              /= This.Reads_Stride
                            or else This.Reads_At + This.Rows
                                    > This.Reads_Stride)
              or else (This.Reads_Two /= 0
                       and then This.Reads_Two not in 1 .. Index - 1)
              or else (This.Into_Cache
                       and then Item.Cache_Buffer = Null_Handle
                       and then not (Item.Copy_Only
                                     and then Item.Copy_Buffer
                                              /= Null_Handle))
              or else Item.Heads_Line = Null_Handle
              or else (This.Turns > 0 and then This.Turn_Table = System.Null_Address)
              or else (This.Base /= System.Null_Address
                       and then Interfaces.Unsigned_64 (This.Span)
                                < Interfaces.Unsigned_64 (This.At_Byte)
                                  + Interfaces.Unsigned_64
                                      (if This.Bias_Width /= 0
                                       then This.Bias_Width
                                       else This.Head_Size) * 4)
            then
               return;
            end if;

            --  One head wide for a gain, or the whole bias.
            Places (Index).Weight :=
              (if This.Base = System.Null_Address then 0
               else Interfaces.Unsigned_64
                      (if This.Bias_Width /= 0 then This.Bias_Width
                       else This.Head_Size) * 4);

            Turn_Room := Interfaces.Unsigned_64'Max
              (Turn_Room,
               Interfaces.Unsigned_64 (This.Turns / 2)
               * Interfaces.Unsigned_64 (Count) * 16);
         elsif This.Routes then
            --  A routing step reads the router's scores in the step it
            --  names and carries a bias or nothing: with a bias it is
            --  kept like a normalization's weight, one row of Columns.
            if This.Rows = 0
              or else This.Reads not in 1 .. Index - 1
              or else Item.Route_Line = Null_Handle
              or else (This.Base /= System.Null_Address
                       and then Interfaces.Unsigned_64 (This.Span)
                                < Interfaces.Unsigned_64 (This.At_Byte)
                                  + Interfaces.Unsigned_64 (This.Columns)
                                    * 4)
            then
               return;
            end if;

            Places (Index).Weight :=
              (if This.Base = System.Null_Address then 0
               else Interfaces.Unsigned_64 (This.Columns) * 4);
         elsif This.Inverts then
            --  An inverting step reads the routing step it names and
            --  carries no weight.
            if This.Rows = 0
              or else This.Reads not in 1 .. Index - 1
              or else Item.Invert_Line = Null_Handle
            then
               return;
            end if;

            Places (Index).Weight := 0;
         elsif This.Mixes then
            --  A mixing step reads the gathered projection down and
            --  the routing step it names, and a residual where it has
            --  one; it carries no weight.
            if This.Rows = 0
              or else This.Reads not in 1 .. Index - 1
              or else This.Reads_Two not in 1 .. Index - 1
              or else This.Joined > Index - 1
              or else Item.Mix_Line = Null_Handle
            then
               return;
            end if;

            Places (Index).Weight := 0;
         elsif This.Picks then
            --  A picking step reads one step and carries no weight; an
            --  assembling one reads two.
            if This.Rows = 0
              or else This.Reads not in 1 .. Index - 1
              or else (if This.Assembles
                       then This.Reads_Two not in 1 .. Index - 1
                         or else Item.Assemble_Line = Null_Handle
                       else Item.Pick_Line = Null_Handle)
            then
               return;
            end if;

            Places (Index).Weight := 0;
         elsif This.Mambas then
            --  A Mamba2 step carries the layer's pack, whole, and reads
            --  the state buffer and the in-projection's step.
            if This.Rows = 0
              or else This.Base = System.Null_Address
              or else This.Span < 4
              or else This.Reads not in 1 .. Index - 1
              or else This.Mamba.XZ_Step not in 1 .. Index - 1
              or else This.Mamba.Dt_Step > Index - 1
              or else (This.Mamba.Mode = Scan
                       and then This.Mamba.Dt_Step = 0)
              or else Item.State_At = Null_Handle
              or else (if This.Mamba.Mode = Scan
                         and then This.Mamba.Version = 1
                       then Item.Scan1_Line = Null_Handle
                       elsif This.Mamba.Mode = Scan
                       then Item.Scan_Line = Null_Handle
                       else Item.Mamba_Line = Null_Handle)
              or else This.Mamba.Dbc_Step > Index - 1
            then
               return;
            end if;

            Places (Index).Weight := Interfaces.Unsigned_64 (This.Span);
         elsif This.Rwkvs or else This.Wkvs then
            --  An RWKV step carries the layer's pack, whole, as a
            --  norm's weight is kept, and reads the state buffer.
            if This.Rows = 0
              or else This.Base = System.Null_Address
              or else This.Span < 4
              or else This.Reads not in 1 .. Index - 1
              or else Item.State_At = Null_Handle
              or else (if This.Rwkvs then Item.Rwkv_Line = Null_Handle
                       else Item.Wkv_Line = Null_Handle)
              or else (This.Rwkvs
                       and then (This.Rwkv.Low_Step > Index - 1
                                 or else This.Rwkv.B_Step > Index - 1
                                 or else This.Rwkv.C_Step > Index - 1))
              or else (This.Wkvs
                       and then (This.Wkv.K_Step not in 1 .. Index - 1
                                 or else This.Wkv.V_Step
                                         not in 1 .. Index - 1
                                 or else This.Wkv.W_Step
                                         not in 1 .. Index - 1
                                 or else This.Wkv.G_Step
                                         not in 1 .. Index - 1))
            then
               return;
            end if;

            Places (Index).Weight := Interfaces.Unsigned_64 (This.Span);
         elsif This.Convolves or else This.Rules then
            --  A convolving step carries the taps and a rule step the
            --  three rows of the rule's numbers, each as a norm's
            --  weight is kept; both read the state buffer, which has
            --  to be there and hold the ring.
            declare
               Held : constant Interfaces.Unsigned_64 :=
                 (if This.Convolves
                  then Interfaces.Unsigned_64 (This.Linear.Taps)
                       * Interfaces.Unsigned_64 (Conv_Width (This.Linear))
                  else Interfaces.Unsigned_64
                         (2 * This.Linear.Value_Heads + This.Linear.Head));
            begin
               if This.Rows = 0
                 or else This.Base = System.Null_Address
                 or else This.Reads not in 1 .. Index - 1
                 or else Interfaces.Unsigned_64 (This.Span)
                         < Interfaces.Unsigned_64 (This.At_Byte) + Held * 4
                 or else Item.State_At = Null_Handle
                 or else (Interfaces.Unsigned_64 (This.Linear.Table_At)
                          + Interfaces.Unsigned_64 (This.Linear.Runs) * 5)
                         * 4
                         > Item.State_Bytes
                 or else (This.Convolves
                          and then Item.Conv_Line = Null_Handle)
                 or else (This.Rules
                          and then (Item.Rule_Line = Null_Handle
                                    or else This.Linear.Z_Step
                                            not in 1 .. Index - 1
                                    or else This.Linear.Alpha_Step
                                            not in 1 .. Index - 1
                                    or else This.Linear.Beta_Step
                                            not in 1 .. Index - 1))
               then
                  return;
               end if;

               Places (Index).Weight := Held * 4;
            end;
         elsif This.Blends then
            --  Two arms in and one out. A combination takes the two
            --  steps before it; a join names one of them and takes its
            --  residual from a step it names or from the caller's
            --  activation, which is what lets a layer's second join
            --  reach back to its first.
            declare
               Arm : constant Natural :=
                 (if This.Reads_Two /= 0 then This.Reads_Two
                  else Index - 1);
               Other : constant Natural :=
                 (if This.Reads_Two /= 0 or else This.Reads /= 0
                  then This.Reads
                  else Index - 2);
            begin
               --  The seventh unit's second arm is one number a block
               --  of the first; every other unit's is as wide as the
               --  first.
               if (This.Unit in 14 .. 19 and then not Takes_Reference_SiTU (Item))
                 or else (This.Unit = 19 and then This.Payload_Elements /= Count)
                 or else (This.Unit = 12 and then (This.Payload_Elements /= 2 * This.Rows * Count
                                            or else Item.Native_Blend_Line = Null_Handle))
                 or else (This.Unit in 13 | 17 and then
                           (This.Limit not in 3.0 | 4.0
                            or else This.Payload_Elements /= Natural (2.0 * This.Limit - 1.0) * This.Rows))
                 or else This.Rows = 0
                 or else Arm not in 1 .. Index - 1
                 or else Other > Index - 1
                 or else (if This.Unit = 7
                          then Steps.Items (Arm).Rows = 0
                               or else This.Rows
                                       mod Steps.Items (Arm).Rows /= 0
                          else Steps.Items (Arm).Rows /= This.Rows)
                 or else (Other /= 0
                          and then Steps.Items (Other).Rows /= This.Rows)
               then
                  return;
               end if;
            end;

            Places (Index).Weight := 0;
         elsif This.Rows = 0
           or else (not This.Chained
                    and then This.Columns /= Steps.Items (1).Columns)

           --  A chained step reads the rows the step it names made,
           --  or -- a gather laid apart -- one stretch of them a
           --  member, which is what Add_Gathered_Product checked.
           or else (This.Chained
                    and then (if This.Transposed
                              then (if This.Apart > 0 then This.Apart
                                    else This.Each)
                              else This.Columns)
                               * (if This.Apart > 0 then This.Gathers
                                  elsif This.Listed and then This.By_Slot
                                  then This.Rows / This.Each
                                  else 1)
                               /= Steps.Items
                                    ((if This.Reads = 0 then Index - 1
                                      else This.Reads)).Rows)
           or else Wide = 0
           or else Interfaces.Unsigned_64
                     (if This.Gathers > 0 then This.Stack
                      elsif This.Region_Rows /= 0 then This.Region_Rows
                      else This.Rows)
                     * Interfaces.Unsigned_64 (This.Columns) > Max_Elements
           or else Interfaces.Unsigned_64 (This.Columns)
                     * Interfaces.Unsigned_64 (Count) > Max_Elements
           or else This.Base = System.Null_Address
           or else Interfaces.Unsigned_64 (This.Span)
                     < Interfaces.Unsigned_64 (This.At_Byte)
                       + Interfaces.Unsigned_64
                           (if This.Gathers > 0 then This.Stack
                            elsif This.Region_Rows /= 0
                            then This.Region_Rows
                            else This.Rows) * Wide
         then
            return;
         else
            --  A gather uploads and keeps the whole stack, whatever
            --  few of its slices this step reads; a product in a
            --  region -- a gate and up shared -- the whole region.
            Places (Index).Weight :=
              Interfaces.Unsigned_64
                (if This.Gathers > 0 then This.Stack
                 elsif This.Region_Rows /= 0 then This.Region_Rows
                 else This.Rows)
              * Wide;
         end if;
         if Scale_Mixed (Index) then
            --  Taken into the mix after it: nothing written, and the
            --  mix reads the projection's answers where they are.
            Places (Index).At_Byte := Places (This.Reads).At_Byte;
            Places (Index).Bytes := Places (This.Reads).Bytes;
         elsif This.Folded then
            --  A join folded into the product before it writes nothing
            --  of its own: the product's store is the sum, and this
            --  step's place is that store, so a later step naming this
            --  one reads what the product wrote.
            Places (Index).At_Byte := Places (Index - 1).At_Byte;
            Places (Index).Bytes := Places (Index - 1).Bytes;
         else
            declare
               Size  : constant Interfaces.Unsigned_64 :=
                 (Mine + Alignment - 1) / Alignment * Alignment;
               Found : Natural := 0;
            begin
               --  The smallest room free before this step first writes
               --  that holds it, where rooms are dealt again.
               if Reusing then
                  for R in 1 .. Room_Count loop
                     if Rooms (R).Free_After < Born (Index)
                       and then Rooms (R).Bytes >= Size
                       and then (Found = 0
                                 or else Rooms (R).Bytes < Rooms (Found).Bytes)
                     then
                        Found := R;
                     end if;
                  end loop;
               end if;

               if Found /= 0 then
                  Places (Index).At_Byte := Rooms (Found).At_Byte;
                  Wait_At (Born (Index)) :=
                    Natural'Max (Wait_At (Born (Index)), Rooms (Found).Free_After);
                  Rooms (Found).Free_After := Last_Use (Index);
               else
                  Places (Index).At_Byte := Result_Bytes;
                  if Reusing then
                     Room_Count := Room_Count + 1;
                     Rooms (Room_Count) :=
                       (At_Byte => Result_Bytes, Bytes => Size,
                        Free_After => Last_Use (Index));
                  end if;
                  Result_Bytes := Result_Bytes + Size;
               end if;
               Places (Index).Bytes := Mine;
            end;
         end if;

         Wanted := Wanted
           + Model_Runner.Numerics.Element_Count (This.Rows)
             * Model_Runner.Numerics.Element_Count (Count);
      end;
   end loop;

   if Vectors'Length
        < Model_Runner.Numerics.Element_Count (Steps.Items (1).Columns)
          * Model_Runner.Numerics.Element_Count (Count)
     --  Room for every step's answer where any is kept, since each is
     --  indexed past the ones before it; a sequence keeping none, whose
     --  answer stays on the device, writes nothing there.
     or else (Kept_Into'Length = 0 and then Target'Length < Wanted and then not Leave_Kept
              and then (for some Index in 1 .. Steps.Held => Steps.Items (Index).Kept))
   then
      return;
   end if;

   if Kept_Into'Length > 0 then
      declare
         Keeps : Natural := 0;
      begin
         for Index in 1 .. Steps.Held loop
            if Steps.Items (Index).Kept then
               Keeps := Keeps + 1;
            end if;
         end loop;

         if Keeps /= Kept_Into'Length then
            return;
         end if;
      end;
   end if;

   --  The other of the two of everything a submission holds, and the
   --  wait for whatever that slot last handed over -- which is the
   --  sequence before the one before this, long finished in the usual
   --  case. Nothing else waits: the sequence just before this one is
   --  still running, and the device is meant to be.
   Swap_Slots (Item);

   if Item.Pending then
      Await (Item, Good, Cancelled, Cancel);

      if Cancelled or else not Good then
         Ok := Good;
         return;
      end if;
   end if;

   --  Carried out, the last step writes straight into the room the next
   --  sequence reads its activation from, and there is nothing to copy.
   --  Safe because the only step that reads that room is the first join,
   --  which is published by a barrier long before the last step runs.
   if Carry_Out and then Steps.Held > 0
     and then Places (Steps.Held).Bytes <= Carry_Room
   then
      Places (Steps.Held).At_Byte := Origin;

      --  A folded join is the product before it, so moving one moves
      --  both: the store that has to land at the front is the product's
      --  -- past a bias folded there too (Bias_Too), two steps back.
      declare
         Back : Natural := Steps.Held;
      begin
         while Back > 1 and then Steps.Items (Back).Folded loop
            Places (Back - 1).At_Byte := Origin;
            Back := Back - 1;
         end loop;
      end;
   end if;

   --  The shapes are through: what refuses from here is room.
   Item.Refused := Room_Refused;

   Item.Clock := Item.Clock + 1;
   Item.Began := Item.Clock;

   --  A matrix the sequence still in flight is reading may not be given
   --  back either: the floor is the reading that sequence began at,
   --  less one, so that everything it acquired -- one tick each -- is
   --  above it. It used to be one tick below this clock, which pinned
   --  the last matrix that sequence took and none of the others, and a
   --  model that does not fit gave one of those back and uploaded
   --  another matrix into its buffer while the device was still
   --  reading it.
   Pinned :=
     (if Item.Pending_Two and then Item.Began_Two >= 1
      then Item.Began_Two - 1 else Item.Clock);

   --  Every matrix in place before the first dispatch is written down.
   --  This is the whole point of the arrangement: acquiring a matrix can
   --  upload it, evict another, or take the host's own memory, and none
   --  of that may happen between two dispatches that are already
   --  recorded.
   for Index in 1 .. Steps.Held loop
      declare
         This : Step renames Steps.Items (Index);

         --  The storage this step's matrix lies in, read where it lies.
         --  Zero length for the steps that name no matrix, which are
         --  left before the overlay is used.
         Held : Model_Runner.Bytes.Byte_Array (1 .. This.Span)
           with Import, Address => This.Base;
      begin
         --  Neither a combining step nor an attention step names a
         --  matrix: one reads the two results before it, the other reads
         --  the cache the device holds.
         if This.Blends or else This.Attends or else This.Places
           or else This.Rotates or else This.Mixes or else This.Inverts
           or else This.Picks
           or else (This.Routes and then This.Base = System.Null_Address)
           or else (This.Readies and then This.Base = System.Null_Address)
           or else (This.Biases and then This.Base = System.Null_Address)
           or else (This.Biases and then This.Fresh)
         then
            goto Next_Step;
         end if;

         --  A normalizing step's weight is one row of its width, not
         --  the square its Rows and Columns describe -- those say what
         --  it reads and writes, as they do for every step. Handing the
         --  square to the loader is asking it to upload four million
         --  values out of an array of two thousand, which faults in the
         --  driver rather than anywhere this program can see.
         Acquire_Weights_Streamed
           (Item, Held, This.At_Byte, This.Packing,
            (if This.Norms or else This.Rotates or else This.Routes
               or else This.Readies or else This.Biases
               or else This.Convolves or else This.Rules
               or else This.Rwkvs or else This.Wkvs
                 or else This.Mambas
             then 1
             elsif This.Gathers > 0 then This.Stack
             elsif This.Region_Rows /= 0 then This.Region_Rows
             else This.Rows),
            (if This.Norms then This.Rows / This.Groups
             elsif This.Biases then This.Stack * This.Each
             elsif This.Rwkvs or else This.Wkvs or else This.Mambas
             then Natural (This.Span / 4)
             elsif This.Convolves
             then This.Linear.Taps * Conv_Width (This.Linear)
             elsif This.Rules
             then 2 * This.Linear.Value_Heads + This.Linear.Head
             elsif This.Routes then This.Columns
             elsif This.Readies
             then (if This.Bias_Width /= 0 then This.Bias_Width
                   else This.Head_Size)
             elsif This.Rotates
             then This.Turns / 2 * Natural (Count) * 4
             else This.Columns),
            Places (Index).Weight,
            Places (Index).Buffer, Places (Index).Memory,
            Places (Index).Base, Places (Index).Borrowed, Good, This.Key,
            Pinned => Pinned,
            --  Not a bias, though a gathered one follows the experts
            --  chosen: an expert stack's biases are a few hundred
            --  kilobytes the device keeps, and streamed with the stacks
            --  they were copied again every layer of every token --
            --  gpt-oss's 26.5 MB a token, the device waiting on it.
            Stream => not This.Biases
                      and then (This.Gathers > 0 or else This.Listed
                                or else This.Streams),
            Mapped => Places (Index).Mapped,
            Tier => Places (Index).Tier);
         Places (Index).Streamed :=
           Places (Index).Borrowed
           and then not This.Biases
           and then (This.Gathers > 0 or else This.Listed
                     or else This.Streams);
         if Places (Index).Streamed then
            Item.Streamed := Item.Streamed + 1;
         end if;
         if not Good then
            Release_All;
            return;
         end if;

         --  A product whose rows begin inside the region it uploads
         --  reads from there: every dispatch below counts from Base,
         --  and every binding ends at Base and Weight, which stays the
         --  region's end.
         if This.Region_At /= 0 then
            Places (Index).Base :=
              Places (Index).Base + Interfaces.Unsigned_64 (This.Region_At);
            Places (Index).Weight :=
              Places (Index).Weight
              - Interfaces.Unsigned_64 (This.Region_At);
         end if;
      end;

      <<Next_Step>>
   end loop;

   --  A bias folded into its product is read row for row as the
   --  product's residual, which is right for one position only, and is
   --  bound at its own offset, which the device has to allow.
   for Index in 1 .. Steps.Held loop
      if Steps.Items (Index).Biases and then Steps.Items (Index).Folded
        and then (Count /= 1
                  or else Item.Aligned = 0
                  or else Places (Index).Base mod Item.Aligned /= 0)
      then
         Item.Refused := Shape_Refused;
         Release_All;
         return;
      end if;
      --  A bias beside a join is added by the half-precision wave
      --  kernel alone, the one a plain half product of one position
      --  takes; any other would store the residual without it.
      if Steps.Items (Index).Bias_Too /= 0
        and then (Count /= 1
                  or else Steps.Items (Index).Packing not in Half_Packing
                  or else not Waved (Item, Steps.Items (Index).Packing, 1)
                  or else Row_Line (Item, 1, Steps.Items (Index).Packing,
                                    Steps.Items (Index).Columns)
                          /= Item.Half_Wave_Lines (Steps.Items (Index).Packing)
                  or else Dotted (Index))
      then
         Item.Refused := Shape_Refused;
         Release_All;
         return;
      end if;
   end loop;

   --  The two that change every call, grown when they have to -- after
   --  the sequence before is done with them: one handed over without a
   --  wait still reads the activation and writes the halves, and a
   --  buffer given back under it is a buffer it reads after it is gone.
   --  And what is recorded is what is there: a size kept for a buffer
   --  given back and not taken again had the next call bind nothing.
   if Item.Vector_Bytes < Vector_Bytes then
      Settle (Item, Good);
      if not Good then
         Release_All;
         return;
      end if;
      Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
      Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
      Item.Vector_Bytes := 0;
      Take (Item, Vector_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
            Good);
      if not Good then
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         Release_All;
         return;
      end if;
      Item.Vector_Bytes := Vector_Bytes;
   end if;

   if Item.Result_Bytes < Result_Bytes then
      --  A sequence carrying in reads its activation from the front
      --  of this buffer, where the one before left it; a buffer that
      --  grows here is a new buffer, and the front has to come with
      --  it. It did not, and a hybrid's linear layer -- whose
      --  sequence is smaller than the attention layer's after it --
      --  carried its answer into a buffer the next layer threw away
      --  on the first batch of a new length: every answer past a
      --  hundred and twenty-eight positions was noise. The sequence
      --  before may still be writing the front, so it is waited for.
      declare
         Was_Buffer : Address := Item.Result_Buffer;
         Was_Memory : Address := Item.Result_Memory;
         Was_At     : Address := Item.Result_At;
         Was_Bytes  : constant Interfaces.Unsigned_64 := Item.Result_Bytes;
         Carrying   : constant Boolean :=
           Carry_In and then Was_Buffer /= Null_Handle
           and then Was_Bytes >= Origin + Vector_Bytes;
      begin
         --  Either way the sequence before may still be writing it.
         Settle (Item, Good);
         if not Good then
            Release_All;
            return;
         end if;
         if Carrying then
            Standing (Item, Was_Memory, Was_At, Was_Bytes, Good);
            if not Good then
               Release_All;
               return;
            end if;
         else
            Unmap_Standing (Item, Was_Memory, Was_At);
            Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
         end if;

         Item.Result_Buffer := Null_Handle;
         Item.Result_Memory := Null_Handle;
         Item.Result_At := Null_Handle;
         Item.Result_Bytes := 0;

         Take (Item, Result_Bytes, Item.Result_Buffer, Item.Result_Memory,
               Good, Read => True);
         if not Good then
            Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
            if Carrying then
               Unmap_Standing (Item, Was_Memory, Was_At);
               Give_Back_Buffer (Item, Was_Buffer, Was_Memory);
            end if;
            Release_All;
            return;
         end if;
         Item.Result_Bytes := Result_Bytes;

         if Carrying then
            Standing (Item, Item.Result_Memory, Item.Result_At,
                      Item.Result_Bytes, Good);
            if Good then
               declare
                  use System.Storage_Elements;
                  Was : Model_Runner.Bytes.Byte_Array
                    (1 .. Model_Runner.Bytes.Byte_Count (Vector_Bytes))
                    with Import,
                         Address => To_Address (To_Integer (Was_At) + Integer_Address (Origin));
                  Now : Model_Runner.Bytes.Byte_Array
                    (1 .. Model_Runner.Bytes.Byte_Count (Vector_Bytes))
                    with Import,
                         Address => To_Address (To_Integer (Item.Result_At) + Integer_Address (Origin));
               begin
                  Now := Was;
               end;
            end if;

            Unmap_Standing (Item, Was_Memory, Was_At);
            Give_Back_Buffer (Item, Was_Buffer, Was_Memory);

            if not Good then
               Release_All;
               return;
            end if;
         end if;
      end;
   end if;

   --  Two regions of it, because a gated feed-forward has both its arms
   --  alive at once and the products that make them cannot both write at
   --  the front. Everything else uses the first and the second stands
   --  empty.
   Item.Half_Region := Half_Bytes;

   if Item.Half_Bytes < 3 * Half_Bytes then
      Settle (Item, Good);
      if not Good then
         Release_All;
         return;
      end if;
      Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
      Item.Half_Bytes := 0;
      Take (Item, 3 * Half_Bytes,
            Item.Half_Buffer, Item.Half_Memory, Good);
      if not Good then
         Give_Back_Buffer (Item, Item.Half_Buffer, Item.Half_Memory);
         Release_All;
         return;
      end if;
      Item.Half_Bytes := 3 * Half_Bytes;
   end if;

   --  And the room the integer walks' rounding writes, the first time
   --  any walk rounds; it is one size whatever the model.
   if Item.Round_Buffer = Null_Handle
     and then (for some Index in 1 .. Steps.Held =>
                 Dotted (Index) or else Reference_Dotted (Index) or else Splits (Index))
   then
      Take (Item, Round_Room, Item.Round_Buffer, Item.Round_Memory,
            Good);
      if not Good then
         Give_Back_Buffer (Item, Item.Round_Buffer, Item.Round_Memory);
         Release_All;
         return;
      end if;
   end if;

   --  The fresh weights after the angles, a line apart.
   if Fresh_Room > 0 then
      Fresh_At := (Turn_Room + 255) / 256 * 256;
      Turn_Room := Fresh_At + Fresh_Room;
      for Index in 1 .. Steps.Held loop
         if Steps.Items (Index).Biases and then Steps.Items (Index).Fresh then
            Places (Index).Base := Places (Index).Base + Fresh_At;
         end if;
      end loop;
   end if;

   --  And the angles, where anything turns: written into a standing
   --  mapping as the activation is, because they change every call.
   if Turn_Room > 0 then
      if Item.Turn_Bytes < Turn_Room then
         Unmap_Standing (Item, Item.Turn_Memory, Item.Turn_At);
         Give_Back_Buffer (Item, Item.Turn_Buffer, Item.Turn_Memory);
         Item.Turn_Bytes := 0;
         Take (Item, Turn_Room, Item.Turn_Buffer, Item.Turn_Memory, Good);
         if not Good then
            --  As the Round buffer: none kept that has no memory.
            Give_Back_Buffer (Item, Item.Turn_Buffer, Item.Turn_Memory);
            Release_All;
            return;
         end if;
         Item.Turn_Bytes := Turn_Room;
      end if;

      Standing (Item, Item.Turn_Memory, Item.Turn_At, Item.Turn_Bytes,
                Good);
      if not Good then
         Release_All;
         return;
      end if;

      --  Each table holds the angles of every position the batch has,
      --  or the copy below would read past it: the sequence is refused.
      for Index in 1 .. Steps.Held loop
         if (Steps.Items (Index).Rotates or else Steps.Items (Index).Readies)
           and then Model_Runner.Bytes.Byte_Count
                      (Interfaces.Unsigned_64 (Steps.Items (Index).Turns / 2)
                       * Interfaces.Unsigned_64 (Count) * 16)
                    > (if Steps.Items (Index).Readies
                       then Steps.Items (Index).Turn_Span
                       else Steps.Items (Index).Span)
         then
            Release_All;
            return;
         end if;
      end loop;

      for Index in 1 .. Steps.Held loop
         if Steps.Items (Index).Rotates or else Steps.Items (Index).Readies
         then
            declare
               Span : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count
                   (Interfaces.Unsigned_64 (Steps.Items (Index).Turns / 2)
                    * Interfaces.Unsigned_64 (Count) * 16);

               From : Model_Runner.Bytes.Byte_Array (1 .. Span)
                 with Import,
                      Address =>
                        (if Steps.Items (Index).Readies
                         then Steps.Items (Index).Turn_Table
                         else Steps.Items (Index).Base);

               Into : Model_Runner.Bytes.Byte_Array (1 .. Span)
                 with Import, Address => Item.Turn_At;
            begin
               Into := From;
            end;
         end if;
      end loop;

      --  And each fresh weight at its place.
      for Index in 1 .. Steps.Held loop
         if Steps.Items (Index).Biases and then Steps.Items (Index).Fresh then
            declare
               use type System.Storage_Elements.Storage_Offset;
               Span : constant Model_Runner.Bytes.Byte_Count :=
                 Model_Runner.Bytes.Byte_Count (Places (Index).Weight);
               From : Model_Runner.Bytes.Byte_Array (1 .. Span)
                 with Import, Address => Steps.Items (Index).Base;
               Into : Model_Runner.Bytes.Byte_Array (1 .. Span)
                 with Import,
                      Address =>
                        Item.Turn_At
                        + System.Storage_Elements.Storage_Offset
                            (Places (Index).Base);
            begin
               Into := From;
            end;
         end if;
      end loop;
   end if;

   --  The activation goes over once, however many products read it --
   --  and not at all where the sequence before this one left it on the
   --  device.
   declare
      Wanted : Model_Runner.Numerics.Real_Array
        renames Vectors (Vectors'First
                         .. Vectors'First + Vector_Room - 1);
   begin
      if Carry_In then
         Good := True;
      else
         --  The host is about to write a buffer a submission may still
         --  be reading.
         Settle (Item, Good);

         if Good then
            Standing (Item, Item.Vector_Memory, Item.Vector_At,
                      Item.Vector_Bytes, Good);
         end if;
      end if;

      if Good and then not Carry_In then
         declare
            Room : Model_Runner.Numerics.Real_Array (Wanted'Range)
              with Import, Address => Item.Vector_At;
         begin
            Room := Wanted;
         end;
      end if;
   end;
   if not Good then
      Release_All;
      return;
   end if;

   if Steps.Held > 0 and then Reference_Dotted (1) and then Item.Reference_Round_Line /= Null_Handle then
      for Index in 1 .. Steps.Held loop
         if Reference_Dotted (Index) and then not Steps.Items (Index).Chained then
         declare
            package N renames Model_Runner.Numerics;
            This : Step renames Steps.Items (Index);
            First : constant N.Element_Count := N.Element_Count (This.At_Vector);
            Elements : constant N.Element_Count := N.Element_Count (Count) * N.Element_Count (This.Columns);
         begin
            if Interfaces.Unsigned_64 (First) + Interfaces.Unsigned_64 (Elements)
              > Interfaces.Unsigned_64 (Vectors'Length)
            then Release_All; return; end if;
            for Value of Vectors (Vectors'First + First .. Vectors'First + First + Elements - 1) loop
               if not N.Is_Finite (Value) then Release_All; return; end if;
            end loop;
         end;
         end if;
      end loop;
   end if;

   if Steps.Held > 0 and then Reference_Dotted (1) and then Item.Reference_Round_Line = Null_Handle then
      declare
         package QI renames Model_Runner.Quantization.Integers;
         package N renames Model_Runner.Numerics;
         use System.Storage_Elements;
         Where : Address := Null_Handle;
      begin
         Map_Memory (Item, Item.Round_Memory, Round_Room, Where, Good);
         if Good then
            for Index in 1 .. Steps.Held loop
               declare
                  This : Step renames Steps.Items (Index);
                  Elements : constant N.Element_Count := N.Element_Count (Count) * N.Element_Count (This.Columns);
                  Blocks : constant N.Element_Count := Elements / 32;
                  Source : constant N.Element_Count := N.Element_Count (This.At_Vector);
                  Base : constant Address := To_Address
                    (To_Integer (Where) + Integer_Address (Reference_Offset (Index)));
                  Values : QI.Signed_Array (0 .. Elements - 1) with Import, Address => Base;
                  Scales : N.Real_Array (0 .. Blocks - 1) with Import,
                    Address => To_Address (To_Integer (Base)
                      + Integer_Address (Natural'Max (Count, 8)) * Integer_Address (This.Columns));
                  Totals : QI.Sum_Array (0 .. Blocks - 1);
                  Halves : QI.Sum_Array (0 .. Blocks * 2 - 1);
               begin
                  if Interfaces.Unsigned_64 (Source) + Interfaces.Unsigned_64 (Elements)
                    > Interfaces.Unsigned_64 (Vectors'Length)
                  then Good := False; exit; end if;
                  QI.Quantize_Vectors
                    (Vectors (Vectors'First + Source .. Vectors'First + Source + Elements - 1),
                     N.Element_Count (Count), N.Element_Count (This.Columns), Values, Scales, Totals, Halves,
                     Good, Super => This.Packing in Packed_Q4_K | Packed_Q5_K | Packed_Q6_K
                       | Packed_IQ3_S | Packed_IQ3_XXS,
                     Reference_Rounding => True,
                     Half_Scales => This.Packing in Packed_Q8_0 | Packed_Q5_0 | Packed_IQ4_NL | Packed_Q2_0);
                  exit when not Good;
               end;
            end loop;
         end if;
         Unmap_Standing (Item, Item.Round_Memory, Where);
         if not Good then Release_All; return; end if;
      exception
         when others => Unmap_Standing (Item, Item.Round_Memory, Where); raise;
      end;
   end if;

   --  One set per product, each pointed at its own matrix and its own
   --  share of the result. A descriptor update is not recorded, so all
   --  of them are made before anything is.
   declare
      Update : constant Update_Sets_Call :=
        To_Update_Sets (Point ("vkUpdateDescriptorSets"));

      Told  : aliased Buffer_Info_Array;
      Notes : aliased Write_Array;

      --  Where a step reads from: a step it names, the step before it
      --  when it is chained, or the caller's activation -- at an offset
      --  into it, because a residual travels beside the queries rather
      --  than in a buffer of its own.
      function Source_Of (Index : Positive; Named : Natural)
        return Buffer_Info
      is
         This : Step renames Steps.Items (Index);

         From : constant Natural :=
           (if Named /= 0 then Named
            elsif This.Chained then Index - 1
            else 0);

         Skip : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (This.At_Vector) * 4;
      begin
         if From = 0 then
            --  The activation: what the host sent, or what the sequence
            --  before this one left at the front of the result buffer.
            if Carry_In then
               return (Buffer => Item.Result_Buffer, Offset => Origin + Skip,
                       Extent => Vector_Bytes - Skip);
            end if;

            return (Buffer => Item.Vector_Buffer, Offset => Skip,
                    Extent => Vector_Bytes - Skip);
         else
            return (Buffer => Item.Result_Buffer,
                    Offset => Places (From).At_Byte,
                    Extent => Places (From).Bytes);
         end if;
      end Source_Of;
   begin
      if Update = null then
         Release_All;
         return;
      end if;

      for Index in 1 .. Steps.Held loop
         --  A step of a layer whose pages are in the second copy reads
         --  and writes that one where it would the first.
         Item.Use_Second := Steps.Items (Index).Pages_At >= Second_Table;

         if Steps.Items (Index).Attends then
            --  The cache the engine holds, the queries where the
            --  activation was written, and this step's own share of the
            --  result: the same three the single call binds, in the same
            --  order, because they are the same kernel.
            Told (1) := Cache_Descriptor (Item);
            --  The queries: where the activation was written, or --
            --  for a chained attention -- what the step before it wrote,
            --  which never left the device.
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);
            Told (5) := Told (3);

            Told (6) := Copy_Descriptor (Item);
            Told (7) := Values_Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 7, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Places then
            --  What it writes, and the cache it writes into -- which is
            --  bound where every other step binds its own room out. A
            --  fetch's room is its own, as every other step's is.
            Told (1) := Cache_Descriptor (Item);
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (if Steps.Items (Index).Fetches
               then (Buffer => Item.Result_Buffer,
                     Offset => Places (Index).At_Byte,
                     Extent => Places (Index).Bytes)
               else Cache_Descriptor (Item));
            Told (4) := Half_Descriptor (Item);
            Told (5) := Told (3);

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Rotates then
            --  The table, what it turns, and its own room out.
            Told (1) :=
              (Buffer => Item.Turn_Buffer, Offset => 0,
               Extent => Item.Turn_Bytes);
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);
            Told (5) := Told (3);

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Readies then
            --  The head weight or nothing, the whole result buffer --
            --  the projections it reads are named by offset in the
            --  push block -- its own room or the cache out, and the
            --  angle table where a product binds its residual.
            Told (3) :=
              (if Steps.Items (Index).Into_Cache
               then Cache_Descriptor (Item)
               else (Buffer => Item.Result_Buffer,
                     Offset => Places (Index).At_Byte,
                     Extent => Places (Index).Bytes));
            Told (1) :=
              (if Steps.Items (Index).Base = System.Null_Address
               then Told (3)
               else (Buffer => Places (Index).Buffer, Offset => 0,
                     Extent =>
                       Places (Index).Base + Places (Index).Weight));
            Told (2) :=
              (Buffer => Item.Result_Buffer,
               Offset => Heads_Floor (Index),
               Extent => Heads_Ceiling (Index) - Heads_Floor (Index));
            --  Binding three is the cache read-only where a head step
            --  places into a paged cache -- it reads the page table
            --  there -- and the half batch otherwise. The one buffer
            --  cannot be bound both writeonly and readonly at the same
            --  binding without a driver dropping the writes, so the
            --  readable view is here.
            --  Unpaged, the step reads nothing there and is given a
            --  word of the vectors the host writes, not the half batch
            --  a normalization before it may just have written.
            Told (4) :=
              (if Steps.Items (Index).Into_Cache
                  and then Steps.Items (Index).Page_Shift /= 0
               then Cache_Descriptor (Item)
               else (Buffer => Item.Vector_Buffer, Offset => 0,
                     Extent => 4));
            Told (5) :=
              (Buffer => Item.Turn_Buffer, Offset => 0,
               Extent => Item.Turn_Bytes);

            Told (6) := Copy_Descriptor (Item);
            Told (7) := Values_Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 7, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Routes then
            --  The bias where there is one -- and where there is not,
            --  the step's own room, bound and never read -- the scores
            --  it reads, and its own room out.
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (1) :=
              (if Steps.Items (Index).Base = System.Null_Address
               then Told (3)
               else (Buffer => Places (Index).Buffer, Offset => 0,
                     Extent =>
                       Places (Index).Base + Places (Index).Weight));
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (4) := Half_Descriptor (Item);
            Told (5) := Told (3);

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Inverts then
            --  The routing step's choice in, its own room out.
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (1) := Told (3);
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (4) := Half_Descriptor (Item);
            Told (5) := Told (3);

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Convolves or else Steps.Items (Index).Rules
           or else Steps.Items (Index).Rwkvs or else Steps.Items (Index).Wkvs
           or else Steps.Items (Index).Mambas
         then
            --  The weight, the rows it reads, its own room out, the
            --  whole of the result buffer for the rule's other rows,
            --  and the state buffer.
            Told (1) :=
              (Buffer => Places (Index).Buffer, Offset => 0,
               Extent => Places (Index).Base + Places (Index).Weight);
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) :=
              (Buffer => Item.Result_Buffer, Offset => 0,
               Extent => Item.Result_Bytes);
            Told (5) :=
              (Buffer => Item.State_Buffer, Offset => 0,
               Extent => Item.State_Bytes);

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Picks then
            --  The step it takes apart, and its own room out -- or the
            --  two an assembling step reads.
            Told (1) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (2) :=
              (if Steps.Items (Index).Assembles
               then Source_Of (Index, Steps.Items (Index).Reads_Two)
               else Told (1));
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);
            Told (5) := Told (3);

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Mixes then
            --  The routing step's choice, the gathered projection
            --  down, its own room out, and the residual where there
            --  is one.
            Told (1) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Steps.Items (Index).Reads_Two).At_Byte,
               Extent => Places (Steps.Items (Index).Reads_Two).Bytes);
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);
            Told (5) :=
              (if Steps.Items (Index).Joined /= 0
               then (Buffer => Item.Result_Buffer,
                     Offset =>
                       Places (Steps.Items (Index).Joined).At_Byte,
                     Extent =>
                       Places (Steps.Items (Index).Joined).Bytes)
               else Told (3));

            Told (6) := Copy_Descriptor (Item);

            --  A scale taken in: the scales' stack, and the routing
            --  that says each slot's expert.
            if Mix_Scaled (Index) then
               declare
                  Scale : constant Positive := Index - 1;
                  Route : constant Positive :=
                    Steps.Items (Steps.Items (Index).Reads_Two).Reads;
               begin
                  Told (4) :=
                    (Buffer => Places (Scale).Buffer, Offset => 0,
                     Extent => Places (Scale).Base + Places (Scale).Weight);
                  Told (6) :=
                    (Buffer => Item.Result_Buffer,
                     Offset => Places (Route).At_Byte,
                     Extent => Places (Route).Bytes);
               end;
            end if;

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Norms then
            --  The weight, what it normalizes, and its own room out.
            Told (1) :=
              (Buffer => Places (Index).Buffer, Offset => 0,
               Extent => Places (Index).Base + Places (Index).Weight);
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);

            --  And the residual, where a join was folded into it.
            Told (5) :=
              (if Steps.Items (Index).Joins
               then Source_Of
                      (Steps.Items (Index).Joined,
                       Steps.Items (Steps.Items (Index).Joined).Reads)
               else Told (3));

            Told (6) := Copy_Descriptor (Item);

            --  And where it rounds its answer, for the walks that
            --  read it: the normalizations' region.
            Told (7) :=
              (Buffer => Item.Round_Buffer, Offset => Normed_At,
               Extent => Round_Bytes);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, (if Norm_Rounds (Index) then 7 else 6),
                    Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Biases then
            --  The bias stack, the gathered answers it is added to,
            --  its own room out, and the routing that says which
            --  expert each answer is. A bound with no bias binds its
            --  source at nought too, and does not read it there.
            Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
            Told (1) :=
              (if Steps.Items (Index).Base = System.Null_Address
               then Told (2)
               elsif Steps.Items (Index).Fresh
               then (Buffer => Item.Turn_Buffer, Offset => 0,
                     Extent => Item.Turn_Bytes)
               else (Buffer => Places (Index).Buffer, Offset => 0,
                     Extent =>
                       Places (Index).Base + Places (Index).Weight));
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);
            Told (5) :=
              (if Steps.Items (Index).Reads_Two /= 0
               then (Buffer => Item.Result_Buffer,
                     Offset =>
                       Places (Steps.Items (Index).Reads_Two).At_Byte,
                     Extent =>
                       Places (Steps.Items (Index).Reads_Two).Bytes)
               else Told (3));

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         if Steps.Items (Index).Blends then
            --  Two arms in, its own room out. A combination's arms are
            --  the two results before it; a join's are the ones it
            --  names, one of which may be the caller's own activation.
            Told (1) :=
              (if Steps.Items (Index).Reads_Two = 0
                 and then Steps.Items (Index).Reads = 0
               then (Buffer => Item.Result_Buffer,
                     Offset => Places (Index - 2).At_Byte,
                     Extent => Places (Index - 2).Bytes)
               else Source_Of (Index, Steps.Items (Index).Reads));
            Told (2) :=
              (if Steps.Items (Index).Reads_Two = 0
               then (Buffer => Item.Result_Buffer,
                     Offset => Places (Index - 1).At_Byte,
                     Extent => Places (Index - 1).Bytes)
               else (Buffer => Item.Result_Buffer,
                     Offset =>
                       Places (Steps.Items (Index).Reads_Two).At_Byte,
                     Extent =>
                       Places (Steps.Items (Index).Reads_Two).Bytes));
            Told (3) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Index).At_Byte,
               Extent => Places (Index).Bytes);
            Told (4) := Half_Descriptor (Item);
            Told (5) :=
              (if Steps.Items (Index).Payload_Elements = 0 then Told (3)
               elsif Carry_In then
                 (Buffer => Item.Result_Buffer,
                  Offset => Origin + Interfaces.Unsigned_64 (Steps.Items (Index).Payload) * 4,
                  Extent => Interfaces.Unsigned_64 (Steps.Items (Index).Payload_Elements) * 4)
               else
                 (Buffer => Item.Vector_Buffer,
                  Offset => Interfaces.Unsigned_64 (Steps.Items (Index).Payload) * 4,
                  Extent => Interfaces.Unsigned_64 (Steps.Items (Index).Payload_Elements) * 4));

            Told (6) := Copy_Descriptor (Item);

            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Index);
               Notes (Binding).Binding := C.unsigned (Binding - 1);
               Notes (Binding).Buffers := Told (Binding)'Address;
            end loop;

            Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
            goto Next_Set;
         end if;

         Told (1) :=
           (Buffer => Places (Index).Buffer, Offset => 0,
            Extent => Places (Index).Base + Places (Index).Weight);
         --  What this product reads: the activation the caller sent,
         --  or -- for a chained one -- the result the product before it
         --  wrote, which never left the device.
         Told (2) := Source_Of (Index, Steps.Items (Index).Reads);
         Told (3) :=
           (Buffer => Item.Result_Buffer,
            Offset => Places (Index).At_Byte,
            Extent => Places (Index).Bytes);

         --  The half-precision copy, or -- for a gather routed on the
         --  device -- the routing step's choice, bound where the row
         --  kernel reads its members from.
         --  A listed product on the matrix kernel reads the runs'
         --  half-precision copy here and its lists at the residual's
         --  binding; on the row kernel it reads the lists here.
         --  A row product that is not routed reads nothing here, and is
         --  given a word of the vectors the host writes rather than the
         --  whole half-precision copy: bound whole, the validation layer
         --  took every row product after a normalization as reading the
         --  halves that normalization had just written.
         Told (4) :=
           --  A bias folded beside a join (Bias_Too): its rows, which
           --  the product's store adds with the residual.
           (if Steps.Items (Index).Bias_Too /= 0
            then (Buffer => Places (Steps.Items (Index).Bias_Too).Buffer,
                  Offset => Places (Steps.Items (Index).Bias_Too).Base,
                  Extent => Interfaces.Unsigned_64
                              (Steps.Items (Steps.Items (Index).Bias_Too).Each) * 4)
            elsif Steps.Items (Index).Routed /= 0
              and then not Listed_Tiled (Index)
            then (Buffer => Item.Result_Buffer,
                  Offset => Places (Steps.Items (Index).Routed).At_Byte,
                  Extent => Places (Steps.Items (Index).Routed).Bytes)
            elsif Tiled (Index) or else Listed_Tiled (Index)
              or else Member_Tiled (Index)
            then Half_Descriptor (Item)
            else (Buffer => Item.Vector_Buffer, Offset => 0,
                  Extent => 4));

         --  And the residual, where a join was folded into this product:
         --  what the join would have read as its first arm, bound where
         --  the product's store can add it.
         Told (5) :=
           --  A bias folded into the product: the bias itself, where
           --  the device keeps it, bound from its first value.
           (if Steps.Items (Index).Joins
              and then Steps.Items (Steps.Items (Index).Joined).Biases
            then (Buffer => Places (Steps.Items (Index).Joined).Buffer,
                  Offset => Places (Steps.Items (Index).Joined).Base,
                  Extent => Interfaces.Unsigned_64
                              (Steps.Items (Steps.Items (Index).Joined).Each) * 4)
            elsif Steps.Items (Index).Joins
            then Source_Of
                   (Steps.Items (Index).Joined,
                    Steps.Items (Steps.Items (Index).Joined).Reads)
            --  A listed product's kernels read the lists at the
            --  residual's binding, which a listed product never has.
            elsif Steps.Items (Index).Listed
            then (Buffer => Item.Result_Buffer,
                  Offset => Places (Steps.Items (Index).Routed).At_Byte,
                  Extent => Places (Steps.Items (Index).Routed).Bytes)
            else Told (3));

         --  And bounded to the columns the batch really holds. A tile
         --  stores the columns the rounding invented as well as the real
         --  ones, so it would read a residual for them too -- and what
         --  lies there is whatever the step before last left, since a
         --  join writes only the real ones. Bounded here, those reads
         --  fall outside the range the descriptor names and answer zero,
         --  which is what the invented columns are meant to hold.
         if Steps.Items (Index).Joins then
            Told (5).Extent :=
              Interfaces.Unsigned_64'Min
                (Told (5).Extent,
                 Interfaces.Unsigned_64 (Steps.Items (Index).Rows)
                 * Interfaces.Unsigned_64 (Count) * 4);
         end if;

         Told (6) := Copy_Descriptor (Item);

         --  A folded expert product's biases, where its store adds them:
         --  the bias step's stack, at the binding the tile reads them.
         if Listed_Tiled (Index) and then Fold_Bias_Of (Index) /= 0 then
            Told (6) :=
              (Buffer => Places (Fold_Bias_Of (Index)).Buffer, Offset => 0,
               Extent => Places (Fold_Bias_Of (Index)).Base
                         + Places (Fold_Bias_Of (Index)).Weight);
         end if;

         --  And the rounded activations, for a walk that reads them:
         --  its own rounding's, or the normalization's it reads.
         Told (7) :=
           (Buffer => Item.Round_Buffer,
            Offset => (if From_Rounded_Norm (Index) then Normed_At else 0),
            Extent => Round_Bytes);

         for Binding in Told'Range loop
            Notes (Binding).Target := Item.Sets (Index);
            Notes (Binding).Binding := C.unsigned (Binding - 1);
            Notes (Binding).Buffers := Told (Binding)'Address;
         end loop;

         Update (Item.Logical,
                 (if Dotted (Index) or else Reference_Dotted (Index) or else Splits (Index) then 7 else 6),
                 Notes'Address, 0, Null_Handle);

         --  And a split step's walk's set: the same, but the lists where
         --  the walk reads them, at binding three.
         if Splits (Index) then
            Told (4) :=
              (Buffer => Item.Result_Buffer,
               Offset => Places (Steps.Items (Index).Routed).At_Byte,
               Extent => Places (Steps.Items (Index).Routed).Bytes);
            for Binding in Told'Range loop
               Notes (Binding).Target := Item.Sets (Spare_Of (Index));
            end loop;
            Update (Item.Logical, 7, Notes'Address, 0, Null_Handle);
         end if;

         <<Next_Set>>
      end loop;
      Item.Use_Second := False;
   end;

   --  Every product in one command buffer. They read the same activation
   --  and write disjoint parts of the result, so nothing between them
   --  waits for anything and no barrier is needed -- what is saved is a
   --  submission and a fence for each product after the first.
   declare
      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      --  Steps whose results a barrier has already published.
      Fenced : Natural := 0;

      --  The last step whose walk read the rounded activations, which
      --  the next rounding may not overwrite until it has; not known at
      --  the start, where the sequence before may still be reading.
      Rounded_At : Natural := Natural'Last;
      Reference_Packed_At : Natural := 0;

      --  And the last that read the normalizations' region, which the
      --  next normalization to round may not overwrite until it has.
      Normed_Read_At : Natural := Natural'Last;

      --  The last step that wrote the cache, which an attending step
      --  reads without naming: its queries come from a step it names and
      --  its keys come from the cache, so the rule below cannot see the
      --  dependency and is told about it here.
      Cached : Natural := 0;

      Bind_Pipeline : constant Bind_Pipeline_Call :=
        To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
      Bind_Sets : constant Bind_Sets_Call :=
        To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
      Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
      Dispatch : constant Dispatch_Call :=
        To_Dispatch (Point ("vkCmdDispatch"));

      --  Whether this run stamps its steps, and what with. Looked up
      --  only when it does, for the reason Barrier is.
      Stamping : constant Boolean :=
        Item.Timing and then Item.Queries /= Null_Handle;
      Reset_Queries : Reset_Queries_Call := null;
      Write_Stamp   : Write_Stamp_Call := null;
      --  Looked up when something chains or reference packing feeds a product.
      --  Resolving an entry point
      --  is not free, and a sequence of products that share an activation
      --  -- which is every sequence the engine names today -- would
      --  otherwise pay for a barrier it never records.
      Chains : Boolean := False;

      Barrier : Barrier_Call := null;

      Wall : aliased Memory_Barrier;

      Began : aliased Command_Begin_Info;

      --  Which step's answer the half-precision copy of the batch now
      --  holds, and how long that answer's vectors are. Minus one is
      --  none. A layer asks for seven products from four activations,
      --  so three of the seven find the copy already made and skip it.
      Half_From : Integer := -1;
      Half_Wide : Natural := 0;

      --  Which steps write only the half-precision copy. Worked out
      --  below from what reads each of them.
      Halved    : array (1 .. Sequence_Limit) of Boolean :=
        [others => False];

      --  And which region of the half-precision buffer each writes
      --  into. Three, because a gated feed-forward has three answers
      --  alive at once: the normalization both arms read, and the arms.
      Region    : array (1 .. Sequence_Limit) of Natural :=
        [others => 0];

      --  A convolution's taps: tiled products of the activation, each
      --  reading it from further on (At_Vector), joined as they go.
      --  The first converts the activation to halves once, Reach
      --  values past its own vectors -- as far as the last tap reads --
      --  and the rest read that copy where their vectors begin. Each
      --  converted its own stretch before, eight times out of nine
      --  what the tap before had: a decoder's full-size 3x3 spent a
      --  third of its time so.
      Reach     : array (1 .. Sequence_Limit) of Natural :=
        [others => 0];
      Shifted   : array (1 .. Sequence_Limit) of Boolean :=
        [others => False];

      --  How far past its own vectors a product's fresh copy reaches:
      --  for the taps after it, or a tap product's own last tap.
      function Copy_Reach (Which : Positive) return Interfaces.Unsigned_64
      is (Interfaces.Unsigned_64
            (Natural'Max (Reach (Which), Tap_Reach (Steps.Items (Which)))));

      --  The combining steps of gated feed-forwards whose projection up
      --  makes the combination itself, in its own store: such a step is
      --  not dispatched, and its answer sits where the projection up
      --  wrote. Gated names, for that projection up, the gate arm's
      --  step.
      Merged    : array (1 .. Sequence_Limit) of Boolean :=
        [others => False];
      Gated     : array (1 .. Sequence_Limit) of Natural :=
        [others => 0];

      --  The taps, found: a tiled product of the activation at its
      --  front leads, and every tiled product of the activation at the
      --  same width after it reads its copy, until a step of any other
      --  kind -- which may write the copy's front -- but for the joins
      --  folded between them, which dispatch nothing.
      procedure Find_Taps is
         Leader : Natural := 0;
      begin
         for Index in 1 .. Steps.Held loop
            declare
               This : Step renames Steps.Items (Index);
               Of_Activation : constant Boolean :=
                 Tiled (Index)
                 and then not This.Tap_Normed
                 and then This.Reads = 0
                 and then not This.Chained
                 and then not Halved (Index)
                 and then Gated (Index) = 0;
            begin
               if This.Folded then
                  null;
               elsif Of_Activation and then This.At_Vector = 0
                 and then Leader = 0
               then
                  Leader := Index;
               elsif Of_Activation and then Leader /= 0
                 and then This.Columns = Steps.Items (Leader).Columns
               then
                  Shifted (Index) := True;
                  Reach (Leader) :=
                    Natural'Max (Reach (Leader), This.At_Vector);
               elsif Of_Activation and then This.At_Vector = 0 then
                  Leader := Index;
               else
                  Leader := 0;
               end if;
            end;
         end loop;
      end Find_Taps;

      --  A walk's activations rounded where it reads them, for it to
      --  multiply as integers: after a barrier where a walk before may
      --  still be reading the last rounding, and before one, so that
      --  the walk reads this one whole.
      procedure Round_For (Index : Positive) is
         This : Step renames Steps.Items (Index);

         --  The rows rounded: the batch's positions, or a mixture's
         --  every slot where its runs are read by slot.
         Rows : constant Natural := Round_Rows (Index);

         --  Rows says where the scales go: past room for eight rows, or
         --  for as many as are rounded where that is more.
         Shape : aliased Shape_Constants :=
           (Rows    => C.unsigned (Rows),
            Columns => C.unsigned (This.Columns),
            Count   => C.unsigned (Rows),
            First   => 0,
            Packing => 0,
            Base    => 0,
            Joins   => 0,
            Table   => 0,
            others  => <>);
      begin
         --  Rounded already by the normalization it reads, which a
         --  barrier has published: only noted, for the next
         --  normalization that rounds to wait for.
         if From_Rounded_Norm (Index) then
            Normed_Read_At := Index;
            return;
         end if;

         if Rounded_At > Fenced then
            Barrier
              (Item.Buffer, Pipeline_Stage_Compute,
               Pipeline_Stage_Compute, 0, 1, Wall'Address,
               0, Null_Handle, 0, Null_Handle);
            Fenced := Index - 1;
         end if;

         Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Round_Line);
         Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
               Product_Bytes, Shape'Address);
         Dispatch
           (Item.Buffer,
            C.unsigned ((Rows * This.Columns / 32 + 63) / 64), 1, 1);

         Barrier
           (Item.Buffer, Pipeline_Stage_Compute,
            Pipeline_Stage_Compute, 0, 1, Wall'Address,
            0, Null_Handle, 0, Null_Handle);
         Rounded_At := Index;
      end Round_For;
   begin
      if Reset_Buffer = null or else Start = null or else Stop = null
        or else Bind_Pipeline = null or else Bind_Sets = null
        or else Push = null or else Dispatch = null
      then
         Release_All;
         return;
      end if;

      --  And where a step attends: its slices are put together after a
      --  barrier, and a few positions deep take their pipeline only
      --  with one -- a lone attention step was neither, as no step of a
      --  model's is.
      for Index in 1 .. Steps.Held loop
         Chains := Chains or else Steps.Items (Index).Chained
           or else Steps.Items (Index).Attends or else Steps.Items (Index).Blends;
      end loop;

      if Chains or else (Item.Reference_Round_Line /= Null_Handle
        and then (for some Index in 1 .. Steps.Held => Reference_Dotted (Index)))
      then
         Barrier := To_Barrier (Point ("vkCmdPipelineBarrier"));
         if Barrier = null then
            Release_All;
            return;
         end if;
      end if;

      if Stamping then
         Reset_Queries :=
           To_Reset_Queries (Point ("vkCmdResetQueryPool"));
         Write_Stamp := To_Write_Stamp (Point ("vkCmdWriteTimestamp"));
         if Reset_Queries = null or else Write_Stamp = null then
            Release_All;
            return;
         end if;
      end if;

      if Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         Release_All;
         return;
      end if;

      --  Every stamp this run may write is cleared first, and the one
      --  before the first dispatch written; the pool must be reset in
      --  the command buffer before it is written in it.
      if Stamping then
         Reset_Queries
           (Item.Buffer, Item.Queries, 0, C.unsigned (Sequence_Limit + 1));
         Write_Stamp (Item.Buffer, Pipeline_Stage_Bottom, Item.Queries, 0);
      end if;

      Bind_Pipeline
        (Item.Buffer, Bind_Point_Compute, Row_Line (Item, Count));

      --  Whether a step's answer is wanted only in half precision --
      --  which is to say every step that reads it is a tiled product,
      --  and no tiled product reads the binary32 form.
      --
      --  A step like that need not write the binary32 at all. It writes
      --  the half-precision copy where the conversion would have put it
      --  and the conversion does not run: two bytes a value instead of
      --  four, and a whole pass over the activation that does not
      --  happen. That is the case the fusing measured earlier did not
      --  cover -- there the normalization wrote both, so the work moved
      --  rather than went.
      declare
         function Only_Halved (Which : Natural) return Boolean is
            Asked : Natural := 0;
            Last  : Natural := Which;
         begin
            if Steps.Items (Which).Kept then
               return False;
            end if;

            for Later in Which + 1 .. Steps.Held loop
               declare
                  That : Step renames Steps.Items (Later);

                  Reads_It : constant Boolean :=
                    That.Reads = Which
                    or else That.Reads_Two = Which
                    or else ((That.Chained or else That.Blends
                              or else That.Attends)
                             and then That.Reads = 0
                             and then Later = Which + 1)

                    --  A combining step that names neither arm reads
                    --  the two before it, so the further one is two
                    --  back and not one.
                    or else (That.Blends
                             and then That.Reads = 0
                             and then That.Reads_Two = 0
                             and then Later = Which + 2);
               begin
                  if Reads_It then
                     Asked := Asked + 1;
                     Last := Later;

                     if not Tiled (Later) then
                        return False;
                     end if;
                  end if;
               end;
            end loop;

            --  Nothing reading it is not a licence to write nothing.
            if Asked = 0 then
               return False;
            end if;

            --  And the copy has to hold this answer until the last of
            --  them has read it: a step written only as halves has no
            --  binary32 form to convert again from. Between this step
            --  and its last reader, nothing else may write the front
            --  of the half-precision buffer -- a normalization, a
            --  combination or an attention that would be halved, or a
            --  tiled product converting some other step's answer into
            --  it. A parallel block reads the normalization on the way
            --  in for its feed-forward after attention has been and
            --  gone, and Falcon on the device answered nonsense over
            --  the tile for as long as this went unasked.
            for Between in Which + 1 .. Last - 1 loop
               declare
                  That : Step renames Steps.Items (Between);

                  Reads_It : constant Boolean :=
                    That.Reads = Which
                    or else ((That.Chained or else That.Blends
                              or else That.Attends)
                             and then That.Reads = 0
                             and then Between = Which + 1);
               begin
                  if That.Norms or else That.Blends or else That.Attends
                    or else ((Tiled (Between) or else Member_Tiled (Between))
                             and then not Reads_It)
                  then
                     return False;
                  end if;
               end;
            end loop;

            return True;
         end Only_Halved;
      begin
         for Which in 1 .. Steps.Held loop
            Halved (Which) :=
              not Steps.Items (Which).Folded
              and then
              (Steps.Items (Which).Norms
               or else Steps.Items (Which).Blends

               --  Attention only where the tile kernel is the one that
               --  will run: the scalar one writes the blend the way it
               --  always has, and the engine picks between them by the
               --  same test.
               or else (Steps.Items (Which).Attends
                        and then not Steps.Items (Which).Rows_As_Heads
                        and then Steps.Items (Which).Packed.K_Bits = 0
                        and then Attends_By_Matrix
                                   (Item, Count,
                                    Steps.Items (Which).Head_Size,
                                    Steps.Items (Which).Value_Size)))
              and then Item.Half_Buffer /= Null_Handle
              and then Item.Half_Bytes
                       >= Interfaces.Unsigned_64 (Steps.Items (Which).Rows)
                          * Interfaces.Unsigned_64 (Whole_Tiles (Item, Count)) * 2
              and then Only_Halved (Which);
         end loop;

         --  And the two arms of a gated feed-forward. Their only reader
         --  is the step that combines them, and where that step reads
         --  half precision they need write nothing else. Both are alive
         --  at once, so the nearer one goes to the second region.
         for Which in 1 .. Steps.Held loop
            if not Halved (Which)
              and then not Steps.Items (Which).Kept
              and then Tiled (Which)
            then
               declare
                  Only : Integer := -1;
                  Many : Boolean := False;
               begin
                  for Later in Which + 1 .. Steps.Held loop
                     declare
                        That : Step renames Steps.Items (Later);

                        Reads_It : constant Boolean :=
                          That.Reads = Which
                          or else That.Reads_Two = Which
                          or else ((That.Chained or else That.Blends
                                    or else That.Attends)
                                   and then That.Reads = 0
                                   and then Later = Which + 1)
                          or else (That.Blends
                                   and then That.Reads = 0
                                   and then That.Reads_Two = 0
                                   and then Later = Which + 2);
                     begin
                        if Reads_It then
                           if Only = -1 then
                              Only := Later;
                           else
                              Many := True;
                           end if;
                        end if;
                     end;
                  end loop;

                  --  The two elementwise units and the units alone
                  --  read their arms as halves; the join adds an
                  --  activation the host may have sent, and the head
                  --  gate and the shared expert's scaling each read
                  --  an arm no product made.
                  if not Many
                    and then Only > 0
                    and then Steps.Items (Only).Blends
                    and then Steps.Items (Only).Unit in 0 | 1 | 3 | 4 | 5 | 9 | 10
                    and then Halved (Only)
                  then
                     Halved (Which) := True;

                     --  Neither arm may sit where the normalization
                     --  they both read is still sitting.
                     Region (Which) := (if Which = Only - 1 then 2 else 1);
                  end if;
               end;
            end if;
         end loop;

         --  A combination of two halved arms by the plain units, the
         --  gate two steps back and the up arm one, is made by the
         --  projection up: it reads the gate arm at its store and
         --  stores the combination where its own arm would have gone.
         --  The projection down then reads its operand there.
         for Which in 3 .. Steps.Held loop
            declare
               That : Step renames Steps.Items (Which);
            begin
               if That.Blends
                 and then Halved (Which)
                 and then That.Unit in 0 | 1
                 and then That.Reads in 0 | Which - 2
                 and then That.Reads_Two in 0 | Which - 1
                 and then Halved (Which - 2)
                 and then Halved (Which - 1)
                 and then Tiled (Which - 1)
                 and then not Steps.Items (Which - 1).Joins
                 and then Region (Which - 2) /= 0
                 and then Region (Which - 1) /= 0
               then
                  Merged (Which) := True;
                  Gated (Which - 1) := Which - 2;
                  Region (Which) := Region (Which - 1);
               end if;
            end;
         end loop;
      end;

      Find_Taps;

      for Index in 1 .. Steps.Held loop
         declare
            This : Step renames Steps.Items (Index);

            Bound : aliased Address := Item.Sets (Index);
            First : Natural := 0;

            --  Which step this one reads, filled in below beside the
            --  barrier that decides the same thing.
            Reading : Natural := 0;

            --  What the half-precision copy held when this step began.
            --  It is invalidated first and re-established only by a
            --  tiled product, so a step of any other kind -- which may
            --  have written what the copy holds -- leaves it invalid.
            Was_From : constant Integer := Half_From;
            Was_Wide : constant Natural := Half_Wide;
         begin
            --  A folded join is not dispatched at all: the product
            --  before it stored the sum, and this step's place is that
            --  store. Nothing is bound, nothing is pushed, and the
            --  half-precision copy is left as the product left it.
            if This.Folded then
               goto Next_Dispatch;
            end if;

            --  Nor a folded mixture's combination, which its up stored,
            --  nor its biases, which its gate and up added (Fold_Role).
            if Fold_Role (Index) in 3 | 5 or else Scale_Mixed (Index) then
               goto Next_Dispatch;
            end if;

            --  Nor a merged combination, whose answer the projection up
            --  stored; the copy now holds it, in that product's region.
            if Merged (Index) then
               Half_From := Index;
               Half_Wide := This.Rows;
               goto Next_Dispatch;
            end if;

            --  The copy is not invalidated here. It once was, at every
            --  step, and re-established only by a tiled product -- so a
            --  step of any other kind between two products of the same
            --  normalization, a projection's bias say, had the second
            --  convert the normalization's binary32 answer again, and a
            --  normalization written only as halves has no such answer:
            --  every Qwen2 batch over the tile read zeros for its keys.
            --  The copy holds what it held until something writes its
            --  front, and the steps that do say so below.

            --  A chained product reads what the one before it wrote, so
            --  the device is told to finish writing before it starts
            --  reading. Products of the same activation share nothing and
            --  get no barrier, which is why this is here and not around
            --  the whole loop.
            --  A barrier before a step that reads something not yet
            --  published, and not otherwise.
            --
            --  Every step that reads an earlier result needs one --
            --  a join reading a projection two steps back exactly as a
            --  chained product does -- but one barrier publishes every
            --  step before it, so a second reader of the same result
            --  needs nothing. Fencing every reader instead serialized the two
            --  arms of a gated feed-forward, which used to run together
            --  and are the bulk of a layer.
            declare
               --  A product with a join folded into it reads the
               --  residual the join named, which is a step nothing else
               --  in this step says it reads. A routing step says Joins
               --  for the bias it adds and names no step, which read
               --  step nought here and stopped a batch of a mixture
               --  with a router bias the first time one reached the
               --  device.
               Joined : constant Natural :=
                 (if This.Joins and then This.Joined /= 0
                    and then not Steps.Items (This.Joined).Biases
                  then Steps.Items (This.Joined).Reads else 0);

               --  A gather routed on the device reads the routing
               --  step's choice as well, which no other field of the
               --  step says.
               --  A rule step reads the gate, alpha and beta rows as
               --  well, which its shape names.
               Ruled : constant Natural :=
                 (if This.Rules
                  then Natural'Max
                         (This.Linear.Z_Step,
                          Natural'Max (This.Linear.Alpha_Step,
                                       This.Linear.Beta_Step))
                  else 0);

               --  An RWKV step reads the steps its shape names; a save
               --  overwrites what the shifts before it read, so it
               --  waits for everything before it.
               Small : constant Natural :=
                 (if This.Rwkvs and then This.Rwkv.Mode = Save
                  then Index - 1
                  elsif This.Rwkvs
                  then Natural'Max
                         (This.Rwkv.Low_Step,
                          Natural'Max (This.Rwkv.B_Step,
                                       This.Rwkv.C_Step))
                  elsif This.Wkvs
                  then Natural'Max
                         (Natural'Max (This.Wkv.K_Step, This.Wkv.V_Step),
                          Natural'Max (This.Wkv.W_Step, This.Wkv.G_Step))
                  elsif This.Mambas and then This.Mamba.Mode = Save
                  then Index - 1
                  elsif This.Mambas
                  then Natural'Max
                         (This.Mamba.XZ_Step,
                          Natural'Max (This.Mamba.Dt_Step,
                                       This.Mamba.Dbc_Step))
                  else 0);

               Source : constant Natural :=
                 Natural'Max
                   (Natural'Max
                      (Natural'Max (Joined, Small),
                       Natural'Max (This.Routed, Ruled)),
                    Natural'Max
                      (Natural'Max
                         (This.Reads,
                          (if This.Reads_Two /= 0 then This.Reads_Two
                           elsif This.Blends then Index - 1 else 0)),
                       (if This.Blends and then This.Reads_Two = 0
                        then Index - 1
                        elsif This.Chained and then This.Reads = 0
                        then Index - 1
                        else 0)));
               --  What a product reads as its operand, which is what
               --  the half-precision copy holds for it or is made from:
               --  the step it names, the one before where it is chained
               --  and names none, or the activation. Not Source, which
               --  is the latest step it reads at all: a product with a
               --  join folded into it reads the join's residual too, and
               --  where that residual was made after the operand -- a
               --  bias added to it between the operand and the product
               --  -- the copy was taken to hold the wrong answer and the
               --  operand converted again from a binary32 form that a
               --  step written only as halves never wrote: Whisper's
               --  projection down read nonsense over the tile.
               Operand : constant Natural :=
                 (if This.Reads /= 0 then This.Reads
                  elsif This.Chained then Index - 1
                  else 0);

               --  Whether this step writes the front of the
               --  half-precision buffer: a tiled product converting
               --  some answer other than the one the copy holds, or a
               --  normalization, combination or attention written as
               --  halves. The step before may still be reading that
               --  front -- a tiled product reads its operand there --
               --  and a step whose own sources are long fenced would
               --  otherwise overwrite it under that read. Falcon's
               --  projection up reads the normalization on the way in,
               --  fenced twelve steps back, and converted it over the
               --  attention the projection out was still reading.
               Writes_Copy : constant Boolean :=
                 (if This.Norms or else This.Blends or else This.Attends
                  then Halved (Index)
                  elsif This.Rotates or else This.Places
                    or else This.Readies or else This.Routes
                    or else This.Mixes or else This.Biases
                    or else This.Inverts or else This.Picks
                    or else This.Convolves or else This.Rules
                    or else This.Rwkvs or else This.Wkvs
                 or else This.Mambas
                  then False
                  else Member_Tiled (Index)
                       or else (Tiled (Index)
                                and then (Was_From /= Operand
                                          or else Was_Wide /= This.Columns)));

               Wanted : constant Natural :=
                 Natural'Max
                   (Natural'Max
                      (Gated (Index),
                       --  A folded up reads the gate's halves.
                       (if Fold_Role (Index) = 2 then Index - 1 else 0)),
                    Natural'Max
                      (Wait_At (Index),
                       (if Writes_Copy then Index - 1
                        elsif This.Attends then Natural'Max (Source, Cached)
                        else Source)));
            begin
               Reading := (if Is_Product (Index) then Operand else Source);
               if Wanted > Fenced then
                  Barrier
                    (Item.Buffer, Pipeline_Stage_Compute,
                     Pipeline_Stage_Compute, 0, 1, Wall'Address,
                     0, Null_Handle, 0, Null_Handle);
                  Fenced := Index - 1;
               end if;

               if (This.Places and then not This.Fetches)
                 or else (This.Readies and then This.Into_Cache)
               then
                  Cached := Index;
               end if;
            end;

            Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                       Bound'Address, 0, Null_Handle);

            if This.Attends and then This.Packed.K_Bits /= 0 then
               --  Over a packed block: the one kernel that reads one,
               --  a workgroup a head of a position, as the single call
               --  dispatches it -- and no slices, no merge, no
               --  half-precision copy, which are the exact kernels'.
               --  Or attention_token.comp's walk over the packed rows,
               --  a workgroup a group of heads and a position, where
               --  the step's shape is one it takes.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  (if Packed_Token_Line (Index) /= Null_Handle
                   then Packed_Token_Line (Index)
                   else Packed_Pipeline (Item)));

               declare
                  Walked : constant Boolean :=
                    Packed_Token_Line (Index) /= Null_Handle;

                  --  A round's rows share no keys, so a workgroup
                  --  takes one position's heads and no more.
                  Queries : constant Positive :=
                    Packed_Queries (Count);
                  --  The bundle is what makes a packed round bearable:
                  --  a workgroup of eight heads unpacks the key it
                  --  reads once and dots it into eight queries. A
                  --  round dispatched a workgroup a head instead --
                  --  two hundred and fifty-six of them rather than
                  --  thirty-two, which looked like the parallelism the
                  --  exact kernel gets -- read 4.59 ms a layer against
                  --  1.36, because what a packed row costs is the
                  --  unpacking and that is paid once a bundle.
                  Bundle  : constant Positive :=
                    Packed_Bundle (Item, This.Group_Size, Queries,
                                   This.Last - This.First + 1);

                  Shape : aliased Packed_Constants :=
                    (Heads      => C.unsigned (This.Heads),
                     Head_Size  => C.unsigned (This.Head_Size),
                     Value_Size => C.unsigned (This.Value_Size),
                     Group_Size => C.unsigned (This.Group_Size),
                     First      => C.unsigned (This.First),
                     Last       => C.unsigned (This.Last),
                     K_Bytes    => C.unsigned (This.Packed.K_Bytes),
                     V_Bytes    => C.unsigned (This.Packed.V_Bytes),
                     KV_Width   => C.unsigned (This.KV_Width),
                     V_Width    => C.unsigned (This.V_Width),
                     KS_At      => C.unsigned (This.Packed.KS_At),
                     VS_At      => C.unsigned (This.Packed.VS_At),
                     K_Blocks   => C.unsigned (This.Packed.K_Blocks),
                     V_Blocks   => C.unsigned (This.Packed.V_Blocks),
                     K_Bits     => C.unsigned (This.Packed.K_Bits),
                     V_Bits     => C.unsigned (This.Packed.V_Bits),
                     Scale      => C.C_float (This.Scale),
                     Cap        => C.C_float (This.Cap),
                     Max_Bias   => C.C_float (This.Max_Bias),
                     Positions  => C.unsigned (Count),
                     Window     => C.unsigned (This.Window),
                     Causal     => (if This.Causal then 1 else 0),
                     Bundle     => C.unsigned (Bundle),
                     Queries    => C.unsigned (Queries),
                     Table_At   => 0,
                     Sinks_At   => C.unsigned (This.Sinks),

                     --  A cache in pages, from the step's own fields,
                     --  which Add_Attention carries as it does for the
                     --  exact kernels. Zero shift is a cache in blocks.
                     Pages_At       => C.unsigned (This.Pages_At mod Second_Table),
                     Page_Shift     => C.unsigned (This.Page_Shift),
                     First_Position => C.unsigned (This.First_Position),
                     K_Codec => C.unsigned
                       (Cache_Codec'Pos (This.Packed.K_Codec)),
                     V_Codec => C.unsigned
                       (Cache_Codec'Pos (This.Packed.V_Codec)), Relative_At => C.unsigned (This.Relative_At));

                  --  The workgroups across the heads and down the
                  --  positions: the walk's a group, or the part of one
                  --  Token_Rows gives, at every position.
                  Across : constant Positive :=
                    (if Walked
                     then This.Heads
                          / Token_Rows (This.Group_Size, This.Head_Size)
                     else (This.Heads + Bundle - 1) / Bundle);
                  Down   : constant Positive :=
                    (if Walked then Count
                     else (Count + Queries - 1) / Queries);

                  --  No more than Merged_Slices gives the heads at this
                  --  depth, as the exact kernel's -- and so never past
                  --  the records Mine gave the step room for.
                  Slices : constant Natural :=
                    (if Barrier = null or else This.Relative_At /= 0 then 1
                     else Natural'Min
                            (Packed_Slices
                               (Item, Across * Down,
                                This.First, This.Last,
                                Rounding => False),
                             Merged_Slices
                               (This.Heads, (if This.Last >= This.First then This.Last - This.First + 1 else 0))));
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Packed_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Across),
                            C.unsigned (Down), C.unsigned (Slices));

                  --  The slices put together, as the exact kernel's
                  --  are: the records lie where merge.comp reads them.
                  if Slices > 1 then
                     declare
                        Merged : aliased Merge_Constants :=
                          (Heads      => C.unsigned (This.Heads),
                           Value_Size => C.unsigned (This.Value_Size),
                           Positions  => C.unsigned (Count),
                           Slices     => C.unsigned (Slices));
                     begin
                        Barrier
                          (Item.Buffer, Pipeline_Stage_Compute,
                           Pipeline_Stage_Compute, 0, 1, Wall'Address,
                           0, Null_Handle, 0, Null_Handle);
                        Bind_Pipeline
                          (Item.Buffer, Bind_Point_Compute,
                           Item.Merge_Line);
                        Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                              Merge_Bytes, Merged'Address);
                        Dispatch
                          (Item.Buffer, C.unsigned (This.Heads),
                           C.unsigned (Count), 1);
                     end;
                  end if;
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Attends then
               --  The attention kernel, and back again afterwards, as
               --  the combining step does.
               --  A batch whose rows attend as heads (Rows_As_Heads)
               --  is one position of every row's heads, on the token
               --  kernel alone.
               if This.Rows_As_Heads and then Token_Line (Index) = Null_Handle then
                  Release_All;
                  return;
               end if;
               --  A round takes the kernel whose block is one query. A
               --  block of more reads a cached key once and dots it into
               --  every query of the block, and rows of a round do not
               --  share a cache.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  (if Latent_Batch (Index) then Item.Latent_Batch_Attend
                   elsif Few_Line (Index) /= Null_Handle and then Barrier /= null
                   then Few_Line (Index)
                   elsif Token_Line (Index) /= Null_Handle
                   then Token_Line (Index)
                   else
                  Attend_Kernel (Item, Attending_Of (Index), This.Head_Size,
                                 This.Value_Size, This.Group_Size,
                                 Rounding => False,
                                 K_Base => This.K_Base,
                                 V_Base => This.V_Base,
                                 KV_Width => This.KV_Width,
                                 V_Width => This.V_Width,
                                 Span => Chosen_Span (This.First, This.Last, This.Window),
                                 Causal => This.Causal)));

               declare
                  Few : constant Boolean :=
                    Few_Line (Index) /= Null_Handle and then Barrier /= null;

                  Shape : aliased Attention_Constants :=
                    (Heads      => C.unsigned (Heads_Attending_Of (Index)),
                     Head_Size  => C.unsigned (This.Head_Size),
                     Value_Size => C.unsigned (This.Value_Size),
                     Group_Size => C.unsigned (This.Group_Size),
                     First      => C.unsigned (This.First),
                     Last       => C.unsigned (This.Last),
                     --  A base counted in elements of whichever the
                     --  kernel reads: the half-precision copy where the
                     --  matrix kernel is the one that will run, and the
                     --  cache proper otherwise. A round is never that
                     --  kernel however many rows it has, so it reads the
                     --  cache proper as it always did.
                     --  The copy has a buffer of its own, so a base
                     --  into it is the same number as into the cache:
                     --  what was added here was where the copy began
                     --  inside one buffer, and there is no such place
                     --  now. Kept as an addition of the copy's front,
                     --  which is nought, so that a copy put somewhere
                     --  else again is a change in one place.
                     K_Base     =>
                       C.unsigned
                         (Interfaces.Unsigned_64 (This.K_Base)
                          + (if Reads_Copy
                                  (Item, Attending_Of (Index), This.Head_Size,
                                   This.Value_Size, False)
                             then Copy_At (Item)
                             else 0)),
                     --  Where the copy is split the values are a buffer
                     --  of their own, so the base is off its front, which
                     --  is the keys' end taken away.
                     V_Base     =>
                       C.unsigned
                         (Interfaces.Unsigned_64 (This.V_Base)
                          + (if Reads_Copy
                                  (Item, Attending_Of (Index), This.Head_Size,
                                   This.Value_Size, False)
                             then Copy_At (Item)
                             else 0)
                          - (if Item.Copy_Split
                               and then Interfaces.Unsigned_64 (This.V_Base)
                                        >= Item.Copy_Keys_Halves
                             then Item.Copy_Keys_Halves
                             else 0)),
                     KV_Width   => C.unsigned (This.KV_Width),
                     V_Width    => C.unsigned (This.V_Width),
                     Scale      => C.C_float (This.Scale),
                     Cap        => C.C_float (This.Cap),

                     --  Run's Count is how many positions attend: a
                     --  batch of activations is a batch of positions,
                     --  and a workgroup goes to each head of each.
                     Positions  => C.unsigned (Attending_Of (Index)),
                     Window     => C.unsigned (This.Window),
                     --  The flag in the low bit and, above it, how many
                     --  positions the half-precision copy is to hold --
                     --  zero for none. One word rather than two because
                     --  this block may not grow: widening it by a field
                     --  once corrupted this device's answers, which
                     --  docs/measured-figures.txt records and nobody has
                     --  explained.
                     Causal     =>
                       C.unsigned
                         ((if This.Causal then 1 else 0)
                          + (if Halved (Index)
                             then 2 * Whole_Tiles (Item, Attending_Of (Index)) else 0)),
                     Max_Bias   => C.C_float (This.Max_Bias),
                     Table_At   => 0,
                     Sinks_At   => C.unsigned (This.Sinks),
                     Pages_At   => C.unsigned (This.Pages_At mod Second_Table),
                     Page_Shift => C.unsigned (This.Page_Shift));

                  Across : constant C.unsigned :=
                    Attend_Heads
                      (Item, Heads_Attending_Of (Index), This.Group_Size, Attending_Of (Index),
                       This.Head_Size, This.Value_Size,
                       Rounding => False,
                       K_Base => This.K_Base, V_Base => This.V_Base,
                       KV_Width => This.KV_Width,
                       V_Width => This.V_Width,
                       Span => (if This.Last >= This.First then This.Last - This.First + 1 else 0));

                  --  As many slices as the cache gives, but no more than
                  --  Merged_Slices gives the heads at this depth.
                  Slices : constant Natural :=
                    (if Barrier = null then 1
                     elsif Wide_Token (Index)
                     then Wide_Token_Slices (This.Last - This.First + 1)
                     elsif Latent_Batch (Index) then 1
                     elsif Few and then Few_Line (Index) = Item.Latent_Attend
                     then Latent_Slices
                            (This.Last - This.First + 1, Attending_Of (Index),
                             Heads_Attending_Of (Index)
                             / Natural'Max (1, This.Group_Size))
                     elsif Few
                     then Few_Slices
                            (Heads_Attending_Of (Index) / Natural'Max (1, This.Group_Size),
                             This.Last - This.First + 1,
                             Wide => This.Head_Size > Matrix_Wide_Head
                                     or else This.Value_Size
                                             > Matrix_Wide_Head)
                     else Natural'Min
                            (Attend_Slices
                               (Item, Attending_Of (Index), This.Head_Size,
                                This.Value_Size, This.First, This.Last,
                                Rounding => False),
                             Merged_Slices
                               (Heads_Attending_Of (Index),
                                (if This.Last >= This.First then This.Last - This.First + 1 else 0))));
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Attention_Bytes, Shape'Address);
                  declare
                     Seated : constant Natural :=
                       (if Halved (Index) then Whole_Tiles (Item, Attending_Of (Index))
                        else Attending_Of (Index));
                     Down   : constant C.unsigned :=
                       Attend_Groups
                         (Item, Seated, This.Head_Size, This.Value_Size,
                          Rounding => False,
                          Span => Chosen_Span
                                    (This.First, This.Last, This.Window),
                          Causal => This.Causal);
                  begin
                     --  The matrix kernel takes its blocks along the
                     --  first axis and its heads along the second; see
                     --  attention_matrix.comp. A few at once take a
                     --  group of heads along the first and a slice of
                     --  the cache along the second.
                     if Token_Line (Index) /= Null_Handle then
                        --  A token's flash attention: a group of heads a
                        --  workgroup, or a part of one, a position down
                        --  the second axis and its slices down the third.
                        Dispatch
                          (Item.Buffer,
                           C.unsigned
                             (Heads_Attending_Of (Index)
                              / Token_Rows (This.Group_Size, This.Head_Size)),
                           C.unsigned (Attending_Of (Index)), C.unsigned (Slices));
                     elsif Few then
                        --  A latent's token or few on the compilation that
                        --  splits the key between the subgroups, for a
                        --  latent whose heads fill the tile's rows: it
                        --  reads their queries where they lie, staging
                        --  none. It was taken below twelve workgroups,
                        --  when it staged them too and its 41 KB held a
                        --  unit to one workgroup; at 23 KB, two, it is the
                        --  quicker at any depth. DeepSeek-Coder-V2-Lite's
                        --  attention a layer 4,175 deep 158.7 -> 147.5
                        --  us, 31,161 deep 840 -> 731.
                        if Few_Line (Index) = Item.Latent_Attend
                          and then not Latent_Batch (Index)
                          and then Item.Latent_Split_Attend /= Null_Handle
                          and then This.Group_Size = Latent_Rows
                          and then This.Head_Size = Latent_Head
                        then
                           Bind_Pipeline
                             (Item.Buffer, Bind_Point_Compute,
                              Item.Latent_Split_Attend);
                        elsif Pack_Pair (Index) then
                           Bind_Pipeline
                             (Item.Buffer, Bind_Point_Compute,
                              Item.Latent_Packed_Attend);
                        end if;
                        --  The latent's positions each their own
                        --  workgroups, down the third axis.
                        Dispatch
                          (Item.Buffer,
                           C.unsigned
                             (Heads_Attending_Of (Index)
                              / Natural'Max (1, This.Group_Size)),
                           C.unsigned (Slices),
                           C.unsigned
                             (if Latent_Batch (Index)
                              then (Attending_Of (Index) + Latent_Pair - 1) / Latent_Pair
                              elsif Pack_Pair (Index)
                              then (Attending_Of (Index)
                                    + Latent_Pack_Pair * Latent_Packed (This.Group_Size) - 1)
                                   / (Latent_Pack_Pair * Latent_Packed (This.Group_Size))
                              elsif Few_Line (Index) = Item.Latent_Attend
                              then (Attending_Of (Index)
                                    + Latent_Packed (This.Group_Size) - 1)
                                   / Latent_Packed (This.Group_Size)
                              else 1));
                     elsif Attends_By_Matrix
                          (Item, Seated, This.Head_Size, This.Value_Size)
                     then
                        Dispatch (Item.Buffer, Down, Across,
                                  C.unsigned (Slices));
                     else
                        Dispatch (Item.Buffer, Across, Down,
                                  C.unsigned (Slices));
                     end if;
                  end;

                  --  The slices put together, once every one of them
                  --  has left its record: a workgroup a head of a
                  --  position, reading the same result region it
                  --  writes. A few at once always leave records.
                  if Slices > 1 or else Few then
                     declare
                        Merged : aliased Merge_Constants :=
                          (Heads      => C.unsigned (This.Heads),
                           Value_Size => C.unsigned (This.Value_Size),
                           Positions  => C.unsigned (Count),
                           Slices     => C.unsigned (Slices));
                     begin
                        Barrier
                          (Item.Buffer, Pipeline_Stage_Compute,
                           Pipeline_Stage_Compute, 0, 1, Wall'Address,
                           0, Null_Handle, 0, Null_Handle);
                        Bind_Pipeline
                          (Item.Buffer, Bind_Point_Compute,
                           Item.Merge_Line);
                        Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                              Merge_Bytes, Merged'Address);
                        Dispatch
                          (Item.Buffer, C.unsigned (This.Heads),
                           C.unsigned (Count), 1);
                     end;
                  end if;
               end;

               if Halved (Index) then
                  Half_From := Index;
                  Half_Wide := This.Rows;
               end if;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Places and then This.Unpacks then
               --  A packed layer unpacked into the copy, for the matrix
               --  kernel: a workgroup a row, Cells of them, and not
               --  Count -- the rows are the cache's, not the batch's.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Unpack_Line);

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Pack.Row_Bytes),
                     Count   => C.unsigned (This.Cells),
                     First   => C.unsigned (This.Pack.At_Byte),
                     Packing => C.unsigned (This.Pack.Bits),
                     Base    => C.unsigned (This.Pack.At_Scale),
                     Joins   => C.unsigned (This.Pack.Blocks),
                     Table   => C.unsigned (This.Half_At),

                     --  A cache in pages, in the three words after: the
                     --  layer's page table, the shift and the first
                     --  row's position, which unpack.comp reads to
                     --  gather a session's scattered pages into the
                     --  copy. A gather's members, in every other step.
                     Members =>
                       [0 => C.unsigned (This.Pages_At mod Second_Table),
                        1 => C.unsigned (This.Page_Shift),
                        2 => C.unsigned (This.First_Position),
                        3 => C.unsigned (Cache_Codec'Pos (This.Pack.Codec)),
                        others => 0],
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (This.Cells), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Places and then This.Pack.Bits /= 0 then
               --  Packed as it is placed: the row's bytes and scales
               --  where the packed attention reads them, through the
               --  kernel that rounds as the host rounds.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Pack_Pipeline (Item));

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Pack.Row_Bytes),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (This.Pack.At_Byte),
                     Packing => C.unsigned (This.Pack.Bits),
                     Base    => C.unsigned (This.Pack.At_Scale),
                     Joins   => C.unsigned (This.Pack.Blocks),
                     Table   => 0,

                     --  A cache in pages, in the three words after the
                     --  table: the batch's page table, the shift and
                     --  the first row's position, which pack.comp reads
                     --  as place.comp does. A gather's members, in every
                     --  other step's reading of this block.
                     Members =>
                       [0 => C.unsigned (This.Pages_At mod Second_Table),
                        1 => C.unsigned (This.Page_Shift),
                        2 => C.unsigned (This.First_Position),
                        3 => C.unsigned (Cache_Codec'Pos (This.Pack.Codec)),
                        others => 0],
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Places then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  (if This.Fetches then Item.Fetch_Line
                   else Item.Place_Line));

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Stride),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (This.At_First),
                     --  One where there is a copy of the cache to
                     --  write and nought where there is not, which is
                     --  a device that would never read one. Two where
                     --  only the copy is kept: write it and skip the
                     --  cache proper, whose binding is a stand-in.
                     Packing =>
                       (if Item.Copy_Buffer /= Null_Handle
                        then (if Item.Copy_Only then 2 else 1)
                        else 0),

                     --  Where the half-precision copy of the cache
                     --  begins, in halves of its own buffer, which is
                     --  the one thing this kernel needs that the others
                     --  put nothing in.
                     Base    =>
                       C.unsigned (Copy_At (Item)),
                     Joins   => 0,

                     --  A round's per-row table, which this is the one
                     --  kind of step that reads: every row of a round
                     --  goes into its own member's block at its own
                     --  position, and neither follows from the first
                     --  row's place.
                     Table   => 0,

                     --  And a cache in pages, in the three words after
                     --  it, which the kernel reads as the batch's page
                     --  table, the page's shift and the first row's
                     --  position: a gather's members, in every other
                     --  step's reading of this block.
                     Members =>
                       [0 => C.unsigned (This.Pages_At mod Second_Table),
                        1 => C.unsigned (This.Page_Shift),
                        2 => C.unsigned (This.First_Position),
                        others => 0],
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Rotates then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Turn_Line);

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Heads),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (This.Turns),
                     Packing => (if This.Pairs = Split then 1 else 0),

                     --  The table begins where the buffer does: it is
                     --  written for this call and nothing else is in it.
                     Base    => 0,
                     Joins   => 0, Table => 0, others => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);

                  --  A workgroup to a position, as the normalization
                  --  does: the pairs of one position are what its lanes
                  --  divide between them.
                  Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Readies then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Heads_Line);

               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  Shape : aliased Heads_Constants :=
                    (Heads     => C.unsigned (This.Heads),
                     Head_Size => C.unsigned (This.Head_Size),
                     Rotary    => C.unsigned (This.Turns),
                     Pairing   => (if This.Pairs = Split then 1 else 0),
                     Count     => C.unsigned (Count),
                     Normed    =>
                       (if This.Base /= System.Null_Address
                          and then This.Bias_Width = 0
                        then 1
                        else 0),
                     Epsilon   => Bits (This.Epsilon),
                     Base      => C.unsigned (Places (Index).Base / 4),
                     From      =>
                       C.unsigned
                         (Natural
                            ((Places (This.Reads).At_Byte
                              - Heads_Floor (Index)) / 4)
                          + This.Reads_At),
                     Into      =>
                       (if This.Into_Cache then C.unsigned (This.At_First)
                        else 0),
                     Stride    =>
                       (if This.Into_Cache then C.unsigned (This.Stride)
                        else C.unsigned (This.Rows)),
                     Turn_Base => 0,
                     --  The copy's front, which is nought: it has a
                     --  buffer of its own and this kernel writes into
                     --  it from there.
                     Half_Base =>
                       (if This.Into_Cache
                        then C.unsigned (Copy_At (Item))
                        else 0),
                     --  Into the cache, and a copy of it to write:
                     --  a device that would never read one has none,
                     --  and what is at that binding instead is not
                     --  this kernel's to write. Two where only the copy
                     --  is kept: write the copy and skip the cache
                     --  proper, whose binding is a stand-in the kernel
                     --  must not write past.
                     Halves    =>
                       (if This.Into_Cache
                          and then Item.Copy_Buffer /= Null_Handle
                        then (if Item.Copy_Only then 2 else 1)
                        else 0),
                     V_From    =>
                       (if This.Reads_Two /= 0
                        then C.unsigned
                               (Natural
                                  ((Places (This.Reads_Two).At_Byte
                                    - Heads_Floor (Index)) / 4)
                                + This.V_Reads_At)
                        else 0),
                     V_Width   => C.unsigned (This.V_Rows),
                     --  Where the copy is split the values are their own
                     --  buffer, so a value's place is off its front, the
                     --  keys' end taken away.
                     V_Into    =>
                       C.unsigned
                         (Interfaces.Unsigned_64 (This.V_At_First)
                          - (if Item.Copy_Split
                               and then Interfaces.Unsigned_64
                                          (This.V_At_First)
                                        >= Item.Copy_Keys_Halves
                             then Item.Copy_Keys_Halves
                             else 0)),
                     V_Stride  => C.unsigned (This.V_Stride),
                     Pages_At       => C.unsigned (This.Pages_At mod Second_Table),
                     Page_Shift     => C.unsigned (This.Page_Shift),
                     First_Position => C.unsigned (This.First_Position),
                     Src_Stride     => C.unsigned (This.Reads_Stride),
                     V_Src_Stride   => C.unsigned (This.V_Reads_Stride),
                     Biased         =>
                       (if This.Bias_Width /= 0 then 1 else 0),
                     Bias_Base      => C.unsigned (Places (Index).Base / 4),
                     V_Bias_Base    =>
                       C.unsigned (Places (Index).Base / 4
                                   + Interfaces.Unsigned_64
                                       (This.V_Bias_At)));
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Heads_Bytes, Shape'Address);

                  --  A workgroup to a head of a position, and one more
                  --  a position for the values placed with the keys.
                  Dispatch
                    (Item.Buffer,
                     C.unsigned (Count * This.Heads
                                 + (if This.V_Rows > 0 then Count
                                    else 0)),
                     1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Inverts then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Invert_Line);

               declare
                  --  Runs padded to the tile's sixteen only where a batch
                  --  is long enough for the tile; the walks read a run's
                  --  real positions alone (see Add_Listed_Product).
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Columns),
                     Columns => C.unsigned (This.Used),
                     Count   => C.unsigned (Count),
                     First   => (if Count < Tile_Least then 1 else 0),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);

                  --  One workgroup for the whole batch.
                  Dispatch (Item.Buffer, 1, 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Routes then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Route_Line);

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Columns),
                     Columns => C.unsigned (This.Used),
                     Count   => C.unsigned (Count),
                     Base    => C.unsigned (Places (Index).Base / 4),
                     Joins   =>
                       (if This.Base /= System.Null_Address
                        then (if Keeps_Route_Shares (Item) then 3 else 1)
                        else (if Keeps_Route_Shares (Item) then 2 else 0)),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);

                  --  An invocation a position, each choosing alone.
                  Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Mixes then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Mix_Line);

               declare
                  Whole : constant Natural := This.Rows * Count;

                  --  A mix over listed answers is told so through
                  --  Base, and the expert count through First, which
                  --  says where the inversion's runs lie.
                  Listed : constant Boolean :=
                    Steps.Items (This.Reads_Two).Inverts;

                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Used),
                     Count   => C.unsigned (Count),
                     First   =>
                       (if Listed
                        then C.unsigned
                               (Steps.Items (This.Reads_Two).Columns)
                        else 0),
                     Base    => (if Listed then 1 else 0),
                     Joins   => (if This.Joined /= 0 then 1 else 0),
                     Table   =>
                       (if Mix_Scaled (Index)
                        then C.unsigned (Places (Index - 1).Base / 4 + 1)
                        else 0),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer, C.unsigned ((Whole + 255) / 256), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Mambas then
               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  function Groups (Of_Many, Each : Natural) return Natural
                  is ((Of_Many + Each - 1) / Each);

                  M : Mamba2_Shape renames This.Mamba;

                  Shape : aliased constant Shape_Constants :=
                    (Rows    => C.unsigned (Mamba2_Mode'Pos (M.Mode)),
                     Columns => C.unsigned (M.DXBC),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (M.Inner),
                     Packing => C.unsigned (M.In_Out),
                     Base    => C.unsigned (Places (Index).Base / 4),
                     Joins   => C.unsigned (M.Taps),
                     Table   => C.unsigned (M.Heads),
                     Members =>
                       [0  => C.unsigned (Places (M.XZ_Step).At_Byte / 4),
                        1  => C.unsigned (M.Conv_At),
                        2  => C.unsigned (M.Bias_At),
                        3  => C.unsigned (M.Dt_At),
                        4  => C.unsigned (M.A_At),
                        5  => C.unsigned (M.D_At),
                        6  => C.unsigned (M.Gain_At),
                        7  => C.unsigned (M.Memory_At),
                        8  => C.unsigned (M.State_At),
                        9  => C.unsigned (M.State),
                        10 => C.unsigned (M.Groups),
                        11 => C.unsigned (M.Head),
                        12 => Bits (M.Epsilon),
                        13 => (if M.Dt_Step = 0 then 0
                               else C.unsigned
                                      (Places (M.Dt_Step).At_Byte / 4)),
                        14 => C.unsigned (M.X_At),
                        15 => (if M.Dbc_Step = 0 then 0
                               else C.unsigned
                                      (Places (M.Dbc_Step).At_Byte / 4))],
                     Stride  => C.unsigned (M.Rank),
                     others  => <>);
               begin
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     (if M.Mode = Scan and then M.Version = 1
                      then Item.Scan1_Line
                      elsif M.Mode = Scan then Item.Scan_Line
                      else Item.Mamba_Line));
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);

                  case M.Mode is
                     when Conv =>
                        Dispatch
                          (Item.Buffer, C.unsigned (Groups (M.DXBC, 256)),
                           C.unsigned (Groups (Count, 16)), 1);
                     when Save =>
                        Dispatch
                          (Item.Buffer, C.unsigned (Groups (M.DXBC, 256)),
                           1, 1);
                     when Scan =>
                        if M.Version = 1 then
                           Dispatch
                             (Item.Buffer,
                              C.unsigned (Groups (M.Inner, 64)), 1, 1);
                        else
                           Dispatch
                             (Item.Buffer, C.unsigned (M.Heads), 1, 1);
                        end if;
                     when Gate =>
                        Dispatch
                          (Item.Buffer, C.unsigned (Count),
                           C.unsigned (M.Groups), 1);
                     when Dbc_Norm =>
                        Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
                  end case;
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Rwkvs or else This.Wkvs then
               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  function At_Of (Which : Natural) return C.unsigned
                  is (if Which = 0 then 0
                      else C.unsigned (Places (Which).At_Byte / 4));

                  function Groups (Of_Many, Each : Natural) return Natural
                  is ((Of_Many + Each - 1) / Each);

                  Shape : aliased Shape_Constants;
               begin
                  if This.Wkvs then
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute, Item.Wkv_Line);
                     Shape :=
                       (Rows    => C.unsigned (This.Wkv.Heads),
                        Columns => C.unsigned (This.Wkv.Head),
                        Count   => C.unsigned (Count),
                        Base    => C.unsigned (Places (Index).Base / 4),
                        Members =>
                          [0 => At_Of (This.Wkv.K_Step),
                           1 => At_Of (This.Wkv.V_Step),
                           2 => At_Of (This.Wkv.W_Step),
                           3 => At_Of (This.Wkv.G_Step),
                           4 => C.unsigned (This.Wkv.U_At),
                           5 => C.unsigned (This.Wkv.Gain_At),
                           6 => C.unsigned (This.Wkv.Shift_At),
                           7 => C.unsigned (This.Wkv.State_At),
                           8 => Bits (This.Wkv.Floor),
                           others => 0],
                        others  => <>);
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer, C.unsigned (This.Wkv.Heads), 1, 1);
                  else
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute, Item.Rwkv_Line);
                     Shape :=
                       (Rows    =>
                          C.unsigned (Rwkv_Mode'Pos (This.Rwkv.Mode)),
                        Columns => C.unsigned (This.Rwkv.Width),
                        Count   => C.unsigned (Count),
                        First   => C.unsigned (This.Rwkv.Streams),
                        Packing => C.unsigned (This.Rwkv.Low),
                        Base    => C.unsigned (Places (Index).Base / 4),
                        Members =>
                          [0 => At_Of (This.Rwkv.Low_Step),
                           1 => C.unsigned (This.Rwkv.Lerp_At),
                           2 => C.unsigned (This.Rwkv.Map_At),
                           3 => C.unsigned (This.Rwkv.Bias_At),
                           4 => At_Of (This.Rwkv.B_Step),
                           5 => At_Of (This.Rwkv.C_Step),
                           6 => C.unsigned (This.Rwkv.State_At),
                           7 => Bits (This.Rwkv.Scale),
                           8 => C.unsigned (This.Rwkv.State_Two),
                           others => 0],
                        others  => <>);
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);

                     --  A token's shift or decay through a map reads it
                     --  eight lanes an element: thirty-two elements a
                     --  workgroup, and one position.
                     if Count = 1 and then This.Rwkv.Low > 0
                       and then This.Rwkv.Mode in Shift | Decay
                     then
                        Dispatch
                          (Item.Buffer,
                           C.unsigned
                             (Groups ((if This.Rwkv.Mode = Shift
                                       then This.Rwkv.Streams
                                       else 1) * This.Rwkv.Width, 32)),
                           1, 1);
                     else
                        case This.Rwkv.Mode is
                           when Shift =>
                              Dispatch
                                (Item.Buffer,
                                 C.unsigned
                                   (Groups (This.Rwkv.Streams
                                            * This.Rwkv.Width, 256)),
                                 C.unsigned (Groups (Count, 16)), 1);
                           when Decay =>
                              Dispatch
                                (Item.Buffer,
                                 C.unsigned (Groups (This.Rwkv.Width, 256)),
                                 C.unsigned (Groups (Count, 16)), 1);
                           when Tanh | Squared_Relu | Finish =>
                              declare
                                 Blocks : constant Natural :=
                                   Groups (Count * This.Rwkv.Width, 256);
                                 Across : constant Natural :=
                                   Natural'Min (Blocks, 65_535);
                              begin
                                 Dispatch
                                   (Item.Buffer, C.unsigned (Across),
                                    C.unsigned (Groups (Blocks, Across)), 1);
                              end;
                           when Save =>
                              Dispatch
                                (Item.Buffer,
                                 C.unsigned (Groups (This.Rwkv.Width, 256)),
                                 1, 1);
                        end case;
                     end if;
                  end if;
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Convolves then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Conv_Line);

               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  --  The convolution, then the memories, with a
                  --  barrier between: a position's memory may land in
                  --  the slot another position is still reading.
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Linear.Mix),
                     Columns => C.unsigned (This.Linear.Head),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (This.Linear.Table_At),
                     Packing => C.unsigned (This.Linear.Taps),
                     Base    => C.unsigned (Places (Index).Base / 4),
                     Joins   => 0,
                     Table   => C.unsigned (This.Linear.Unit_Blocks),
                     Members =>
                       [0 => C.unsigned (This.Linear.Region_At),
                        1 => C.unsigned (This.Linear.Every),
                        2 => C.unsigned (This.Linear.Runs),
                        3 => Bits (This.Linear.Epsilon),
                        4 => Boolean'Pos (This.Linear.Gated),
                        others => 0],
                     others  => <>);

                  Blocks : constant Natural :=
                    Conv_Width (This.Linear) / This.Linear.Head;
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Blocks),
                            C.unsigned (Count), 1);

                  Barrier
                    (Item.Buffer, Pipeline_Stage_Compute,
                     Pipeline_Stage_Compute, 0, 1, Wall'Address,
                     0, Null_Handle, 0, Null_Handle);

                  Shape.Joins := 1;
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Blocks),
                            C.unsigned (Count), 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Rules then
               --  A head of a hundred and twenty-eight keeps its state
               --  in registers for the run: see rule_held.comp.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  (if This.Linear.Head = Held_Rule_Head
                     and then Count <= Single_Rule_Most
                     and then Item.Single_Rule_Line /= Null_Handle
                   then Item.Single_Rule_Line
                   elsif This.Linear.Head = Held_Rule_Head
                     and then Item.Held_Rule_Line /= Null_Handle
                   then Item.Held_Rule_Line else Item.Rule_Line));

               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Linear.Mix),
                     Columns => C.unsigned (This.Linear.Head),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (This.Linear.Table_At),
                     Packing => C.unsigned (This.Linear.Key_Heads),
                     Base    => C.unsigned (This.Linear.Key_Width),
                     Joins   => C.unsigned (Places (Index).Base / 4),
                     Table   => C.unsigned (This.Linear.Value_Heads),
                     Members =>
                       [0 => C.unsigned (This.Linear.Region_At),
                        1 => C.unsigned (This.Linear.Every),
                        2 => C.unsigned (This.Linear.Runs),
                        3 => C.unsigned
                               (Places (This.Linear.Z_Step).At_Byte / 4),
                        4 => C.unsigned
                               (Places (This.Linear.Alpha_Step).At_Byte
                                / 4),
                        5 => C.unsigned
                               (Places (This.Linear.Beta_Step).At_Byte / 4),
                        6 => Bits (This.Linear.Scale),
                        7 => Bits (This.Linear.Epsilon),
                        8 => C.unsigned (This.Linear.Record_At),
                        others => 0],
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer, C.unsigned (This.Linear.Value_Heads),
                     C.unsigned (This.Linear.Runs), 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Assembles then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Assemble_Line);

               declare
                  --  A workgroup a position: the heads, the positions,
                  --  then A's and B's stretch, offset, head stride and
                  --  position stride, in the order the shader reads.
                  Words : Member_Words := [others => 0];
                  Shape : aliased Shape_Constants;
               begin
                  Words (0) := C.unsigned (This.Shapes (7));
                  Words (1) := C.unsigned (This.Shapes (8));
                  Shape :=
                    (Rows    => C.unsigned (This.Which),
                     Columns => C.unsigned (Count),
                     Count   => C.unsigned (This.Shapes (1)),
                     First   => C.unsigned (This.Shapes (2)),
                     Packing => C.unsigned (This.Shapes (3)),
                     Base    => C.unsigned (This.Shapes (4)),
                     Joins   => C.unsigned (This.Shapes (5)),
                     Table   => C.unsigned (This.Shapes (6)),
                     Members => Words,
                     others  => <>);
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  --  A workgroup a thousand elements of a position.
                  Dispatch
                    (Item.Buffer, C.unsigned (Count),
                     C.unsigned (Natural'Max (1, (This.Rows + 1023) / 1024)), 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Picks then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Pick_Line);

               declare
                  --  A workgroup a position: the row it writes, the
                  --  stretch, which of each group, and how many a
                  --  group holds.
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Each),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (This.Which),
                     Packing => C.unsigned (This.Among),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Count), 1, 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Biases then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Bias_Line);

               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  --  A workgroup a member: a position's rank, or a
                  --  slot of the inversion's runs, which is every
                  --  answer the source made.
                  Members : constant Natural :=
                    This.Rows * Count / This.Each;

                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Each),
                     Columns => C.unsigned (This.Used),
                     Count   => C.unsigned (Count),
                     First   =>
                       (if This.Reads_Two /= 0
                          and then Steps.Items (This.Reads_Two).Inverts
                        then C.unsigned
                               (Steps.Items (This.Reads_Two).Columns)
                        else 0),

                     --  Listed, where the host chose the members and
                     --  no routing step did.
                     Packing =>
                       (if This.Reads_Two = 0 and then This.Used > 0
                        then 1 else 0),

                     --  Where the stack begins in the buffer it shares
                     --  with whatever else the device kept, in
                     --  elements, as a norm's weight is found.
                     Base    => C.unsigned (Places (Index).Base / 4),

                     --  A slice of a fused source: how far apart two
                     --  positions lie in it, and where this reader's rows
                     --  begin. Zero stride is a bias over the whole
                     --  source, a position every Each.
                     Joins   => C.unsigned (This.Reads_Stride),
                     Table   => C.unsigned (This.Reads_At),
                     Members =>
                       [for Which in Member_Words'Range =>
                          C.unsigned (This.Members (Which + 1))],

                     --  The bound, by its bits, and whether there is no
                     --  bias to add before it.
                     Stride  => Bits (This.Cap),
                     Apart   =>
                       C.unsigned
                         (Natural'(if This.Base = System.Null_Address then 1 else 0)
                          + (if This.Scales then 2 else 0)
                          + (if This.Per_Member then 4 else 0)),
                     others  => <>);

                  --  Few members are spread down the second axis, a
                  --  stretch of 256 of the slice a workgroup, until
                  --  there are about as many workgroups as the device
                  --  wants.
                  Spread : constant Natural :=
                    (if Members >= Want_Workgroups then 1
                     else Natural'Max
                            (1, Natural'Min
                                  ((This.Each + 255) / 256,
                                   Want_Workgroups
                                   / Natural'Max (1, Members))));
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (Members),
                            C.unsigned (Spread), 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Norms then
               --  Rounding its answer too, for the walks that read it,
               --  once the walks that read the last such rounding are
               --  done with it.
               if Norm_Rounds (Index) and then Barrier /= null then
                  if Normed_Read_At > Fenced then
                     Barrier
                       (Item.Buffer, Pipeline_Stage_Compute,
                        Pipeline_Stage_Compute, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);
                     Fenced := Index - 1;
                  end if;
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Norm_Round_Line);
               else
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Norm_Line);
               end if;

               declare
                  function Bits is new Ada.Unchecked_Conversion
                    (Model_Runner.Numerics.Real, C.unsigned);

                  --  A stretch to a workgroup: a position, or each of
                  --  the Groups a position is normalized as, which lie
                  --  one after another exactly as positions do.
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows / This.Groups),
                     --  One for the centred normalization with a
                     --  shift, in the slot the products' shape holds
                     --  their columns in.
                     Columns => (if This.Shifts then 1 else 0),
                     Count   => C.unsigned (Count * This.Groups),
                     First   => Bits (This.Epsilon),

                     --  Positions the half-precision copy is to hold,
                     --  and zero where there is none to write.
                     Packing =>
                       (if Halved (Index)
                        then C.unsigned
                               (Whole_Tiles (Item, Count) * This.Groups)
                        else 0),

                     --  Where the weight begins in the buffer it shares
                     --  with whatever else the device kept, in elements
                     --  rather than bytes because this one reads floats.
                     Base    =>
                       C.unsigned (Places (Index).Base / 4),
                       Joins   => (if This.Joins then 1 else 0),
                       Table   => 0, others => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);

                  --  A workgroup to a position: its lanes fetch the
                  --  row together and one of them adds it up in order.
                  --  See the shader. Over the rounded-up count where
                  --  the copy is being written, because the positions
                  --  past the batch write the zeros it needs.
                  Dispatch
                    (Item.Buffer,
                     C.unsigned ((if Halved (Index)
                                  then Whole_Tiles (Item, Count) else Count)
                                 * This.Groups),
                     1, 1);
               end;

               if Halved (Index) then
                  Half_From := Index;
                  Half_Wide := This.Rows;
               end if;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            if This.Blends then
               --  The other kernel, and back again afterwards. Bound per
               --  step rather than once, because a sequence may go back
               --  and forth between the two.
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  (if This.Unit in 14 .. 19 then Item.Reference_Activation_Line
                   elsif This.Unit = 12 then Item.Native_Blend_Line else Item.Blend_Line));

               declare
                  --  Every value both arms hold, not one position's
                  --  worth: the combining is elementwise and the arms of
                  --  a batch are as long as the batch is.
                  Span : constant Natural := This.Rows * Count;
                  Room : constant Natural :=
                    This.Rows * Whole_Tiles (Item, Count);

                  Over : constant Natural :=
                    (if Halved (Index) then Room else Span);

                  --  Where the two arms are. A gated pair whose
                  --  products were told to write half precision is read
                  --  out of the half-precision buffer instead of through
                  --  bindings nought and one, and half the bytes cross.
                  Gate_Step : constant Natural :=
                    (if This.Reads /= 0 then This.Reads
                     elsif Index > 2 then Index - 2 else 0);
                  Up_Step   : constant Natural :=
                    (if This.Reads_Two /= 0 then This.Reads_Two
                     elsif Index > 1 then Index - 1 else 0);

                  Arms : constant Boolean :=
                    This.Unit /= 2
                    and then Gate_Step in 1 .. Steps.Held
                    and then Up_Step in 1 .. Steps.Held
                    and then Halved (Gate_Step)
                    and then Halved (Up_Step);

                  function Sits (Which : Natural)
                    return Interfaces.Unsigned_64
                  is (Interfaces.Unsigned_64 (Region (Which))
                      * (Item.Half_Region / 2) + 1);

                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (Span),
                     Columns => C.unsigned (This.Unit),
                     Count   =>
                       (if Halved (Index) then C.unsigned (Room) else 0),
                     First   =>
                       (if Arms then C.unsigned (Sits (Gate_Step))
                        else 0),
                     Packing =>
                       (if Arms then C.unsigned (Sits (Up_Step))
                        else 0),

                     --  How wide a block is, for the unit that reads
                     --  one number a block: a position's whole row, or
                     --  a head where the second arm is one a head.
                     Base    =>
                       C.unsigned
                         (if This.Unit = 7 and then Up_Step in 1 .. Steps.Held
                            and then Steps.Items (Up_Step).Rows > 0
                          then This.Rows / Steps.Items (Up_Step).Rows
                          else This.Rows),

                     --  The clamped gate's slope and limit, by their
                     --  bits, in the two words after the base.
                     Joins   => Float_Bits (C.C_float (This.Alpha)),
                     Table   => Float_Bits (C.C_float (This.Limit)),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer,
                     C.unsigned ((Over + Group_Size - 1)
                                 / Group_Size), 1, 1);
               end;

               if Halved (Index) then
                  Half_From := Index;
                  Half_Wide := This.Rows;
               end if;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            --  A feed-forward's gate and up at once, the unit between
            --  them: two rows of each a workgroup for one position,
            --  four for a few.
            if This.Glu then
               declare
                  One  : constant Boolean := Count = 1;
                  Q8   : constant Boolean := This.Packing = Packed_Q8_0;
                  MX   : constant Boolean := This.Packing = Packed_MXFP4;
                  Short : constant Boolean :=
                    Q8 and then Q8_Short (Item, This.Packing, Count,
                                          This.Columns);
                  --  Rows of each matrix a workgroup carries: half what
                  --  the plain compilation carries of one.
                  Band : constant Natural :=
                    (if Q8 then (if One and then not Short then 1 else 2)
                     elsif One then 1 else 4);
                  --  A mixture's gate and up, routed: one position,
                  --  an expert a workgroup layer, as a gather is.
                  Gathered : constant Boolean := This.Gathers > 0;
                  --  Or its walk as integers; see Round_Walks.
                  Rounds : constant Boolean :=
                    Dotted (Index) and then Barrier /= null
                    and then not Gathered;
                  Line : constant Address :=
                    (if Rounds then Glu_Dots_Line (This.Packing, This.Columns)
                     elsif MX then Item.MX_Glu_Line
                     elsif not Q8
                     then (if One then Item.Glu_Line
                           else Item.Glu_Many_Lines (Count))
                     elsif not One then Item.Q8_Glu_Multi_Lines (Count)
                     elsif Short then Item.Q8_Glu_Short_Line
                     else Item.Q8_Glu_Line);
                  --  Rows a workgroup layer covers: an expert's slice,
                  --  or the whole of a feed-forward's.
                  Wide : constant Natural :=
                    (if Gathered then This.Each else This.Rows);
                  --  A gathered pair's up arm is the joins word, the
                  --  stride its slices'; see row_product_super.comp.
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (Wide),
                     Columns => C.unsigned (This.Columns),
                     Count   => C.unsigned (Count),
                     First   => 0,
                     Packing =>
                       C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base    => C.unsigned (Places (Index).Base),
                     Joins   =>
                       (if Gathered then C.unsigned (This.Pair_At) else 0),
                     Table   => C.unsigned (This.Unit),
                     --  MXFP4's pair: where its biases lie, in bytes
                     --  and plus one, nought for none, and the clamped
                     --  gate's slope and limit by their bits.
                     Members =>
                       (if MX then Pair_Words (This, Places (Index).Base)
                        else [others => 0]),
                     Stride  =>
                       (if Gathered then C.unsigned (Slice_Bytes (Index))
                        else C.unsigned (This.Pair_At)),
                     Apart   => 0,
                     Routed  => (if Gathered then 1 else 0));
               begin
                  if Gathered and then (Count /= 1 or else Q8) then
                     Release_All;
                     return;
                  end if;

                  if Rounds then
                     Round_For (Index);
                  end if;

                  Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Line);
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer,
                     C.unsigned ((Wide + Band - 1) / Band), 1,
                     C.unsigned (if Gathered then This.Gathers else 1));
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            --  A gather read down its columns: a run of 64 columns of a
            --  member a workgroup, its positions in fours.
            if This.Transposed then
               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Each),
                     Columns => C.unsigned (This.Columns),
                     Count   => C.unsigned (Count),
                     First   => 0,
                     Packing =>
                       C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base    => C.unsigned (Places (Index).Base),
                     Joins   => 0,
                     Table   => 0,
                     Members => [others => 0],
                     Stride  => C.unsigned (Slice_Bytes (Index)),
                     Apart   => C.unsigned (This.Apart),
                     Routed  => 0);
               begin
                  for Member in 1 .. This.Gathers loop
                     Shape.Members (Member - 1) :=
                       C.unsigned (This.Members (Member));
                  end loop;
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute, Item.Fold_Line);
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer,
                     C.unsigned ((This.Columns + 63) / 64),
                     C.unsigned
                       ((Count + Fold_Positions - 1) / Fold_Positions),
                     C.unsigned (This.Gathers));
                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count));
               end;
               goto Next_Dispatch;
            end if;

            --  A batch the tile would take, counted by whether it did.
            if Count >= Tile_Least
              and then Is_Product (Index)
              and then not Steps.Items (Index).Listed
              and then Steps.Items (Index).Gathers <= 1
            then
               if Tiled (Index) then
                  Tiled_Count := Tiled_Count + 1;
               else
                  Untiled_Count := Untiled_Count + 1;
               end if;
            end if;

            if Tiled (Index) then
               declare
                  Done : Boolean;

                  --  The copy still describes this activation if the
                  --  product before this one converted the same answer
                  --  at the same width, and nothing has run in between.
                  --  A normed copy is no other product's, nor theirs its.
                  Again : constant Boolean :=
                    not This.Tap_Normed
                    and then (Shifted (Index)
                              or else (Was_From = Reading
                                       and then Was_Wide = This.Columns));
               begin
                  Tile_Product
                    (Item, This.Rows, This.Columns, Count,
                     Whole_Tiles (Item, Count), This.Packing,
                     Places (Index).Base + Slice_Base (Index),
                     Fresh => not Again,
                     Reach => Copy_Reach (Index),
                     Into =>
                       (if Halved (Index)
                        then Interfaces.Unsigned_64 (Region (Index))
                             * (Item.Half_Region / 2) + 1
                        else 0),
                     Joins => This.Joins,
                     Good => Done,
                     From =>
                       (if Shifted (Index)
                        then Interfaces.Unsigned_64 (This.At_Vector)
                        elsif Again and then Reading in Merged'Range
                             and then Merged (Reading)
                        then Interfaces.Unsigned_64 (Region (Reading))
                             * (Item.Half_Region / 2)
                        else 0),
                     Gate_At =>
                       (if Gated (Index) /= 0
                        then Interfaces.Unsigned_64
                               (Region (Gated (Index)))
                             * (Item.Half_Region / 2) + 1
                        else 0),
                     Unit =>
                       (if Gated (Index) /= 0
                        then Steps.Items (Index + 1).Unit else 0),
                     Tap_Row => This.Tap_Row,
                     Tap_Bytes => Tap_Stride (Index),
                     Gain_At => Gain_Place (Index),
                     Epsilon => This.Tap_Epsilon);

                  if not Done then
                     Release_All;
                     return;
                  end if;

                  --  A tap's copy is the activation's, which no later
                  --  step but another tap reads; the leader's is the
                  --  activation's as any product's is.
                  if Shifted (Index) or else This.Tap_Normed then
                     Half_From := -1;
                  else
                     Half_From := Reading;
                  end if;
                  Half_Wide := This.Columns;
               end;

               goto Next_Dispatch;
            end if;

            if Member_Tiled (Index) then
               declare
                  Done : Boolean;
               begin
                  Tile_Product
                    (Item, This.Each, This.Columns, Count,
                     Whole_Tiles (Item, Count), This.Packing,
                     Places (Index).Base,
                     Fresh => True, Reach => 0, Into => 0,
                     Joins => False, Good => Done,
                     Members => This.Gathers,
                     Slice => Slice_Bytes (Index));
                  if not Done then
                     Release_All;
                     return;
                  end if;

                  --  The copy holds every member's stretch, which no
                  --  other product reads as its own.
                  Half_From := -1;
                  Half_Wide := This.Columns;
               end;

               goto Next_Dispatch;
            end if;

            --  More binary32 vectors than that go to the binary32 tile.
            if This.Gathers = 0
              and then not This.Listed
              and then not Thin (Item, This.Packing, This.Rows,
                                 This.Columns, Count, Places (Index).Base)
              and then F32_Tiled
                         (Item, This.Packing, This.Rows, Count,
                          Places (Index).Base)
            then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.F32_Tile_Line);

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Columns),
                     Count   => C.unsigned (Count),
                     First   => 0,
                     Packing =>
                       C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base    => C.unsigned (Places (Index).Base),
                     Joins   => (if This.Joins then 1 else 0),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer,
                            C.unsigned ((This.Rows + 63) / 64),
                            C.unsigned ((Count + 63) / 64), 1);
               end;

               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count));
               goto Next_Dispatch;
            end if;

            --  A few binary32 rows against a few vectors go to the
            --  thin kernel, a workgroup a row: the row kernel gave a
            --  mixture's router four workgroups.
            if This.Gathers = 0
              and then Thin (Item, This.Packing, This.Rows, This.Columns,
                             Count, Places (Index).Base)
            then
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute, Item.Thin_Line);

               declare
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Rows),
                     Columns => C.unsigned (This.Columns),
                     Count   => C.unsigned (Count),
                     First   => 0,
                     Packing =>
                       C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base    => C.unsigned (Places (Index).Base),
                     Joins   => (if This.Joins then 1 else 0),
                     others  => <>);
               begin
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned (This.Rows),
                            C.unsigned (Count), 1);
               end;

               goto Next_Dispatch;
            end if;

            if Reference_Dotted (Index) then
               declare
                  Shape : aliased Shape_Constants :=
                    (Rows => C.unsigned (This.Rows), Columns => C.unsigned (This.Columns),
                     Count => C.unsigned (Count), First => C.unsigned (Reference_Offset (Index) / 4),
                     Packing => C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base => C.unsigned (Places (Index).Base),
                     Table => C.unsigned (Reference_Offset (Index) / 4
                       + Interfaces.Unsigned_64 (Natural'Max (Count, 8))
                         * Interfaces.Unsigned_64 (This.Columns) / 4), others => <>);
               begin
                  if Item.Reference_Round_Line /= Null_Handle
                    and then not (Reference_Packed_At + 1 = Index
                      and then Reference_Packed_At > 0 and then Same_Reference_Input (Reference_Packed_At, Index))
                  then
                     if Index > 1 then
                        --  The preceding product must finish reading the
                        --  shared packed region before the packer reuses it.
                        declare
                           use type C.unsigned;
                           Reuse : aliased Memory_Barrier :=
                             (Wrote => Access_Shader_Read + Access_Shader_Write,
                              Reads => Access_Shader_Read + Access_Shader_Write, others => <>);
                        begin
                           Barrier (Item.Buffer, Pipeline_Stage_Compute, Pipeline_Stage_Compute, 0,
                                    1, Reuse'Address, 0, Null_Handle, 0, Null_Handle);
                        end;
                     end if;
                     Bind_Pipeline (Item.Buffer, Bind_Point_Compute, Item.Reference_Round_Line);
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0, Product_Bytes, Shape'Address);
                     Dispatch (Item.Buffer, C.unsigned ((Count * This.Columns /
                       (if This.Packing in Packed_Q8_0 | Packed_Q5_0 | Packed_IQ4_NL | Packed_Q2_0
                        then 32 else 256) + 63) / 64), 1, 1);
                     Barrier (Item.Buffer, Pipeline_Stage_Compute, Pipeline_Stage_Compute, 0,
                              1, Wall'Address, 0, Null_Handle, 0, Null_Handle);
                  end if;
                  if Item.Reference_Round_Line /= Null_Handle
                    and then Reference_Packed_At + 1 = Index and then Reference_Packed_At > 0
                    and then Same_Reference_Input (Reference_Packed_At, Index)
                  then Item.Reference_Packing_Reused := Item.Reference_Packing_Reused + 1; end if;
                  Reference_Packed_At := Index;
                  Bind_Pipeline (Item.Buffer, Bind_Point_Compute,
                    (if This.Packing in Packed_IQ3_S | Packed_IQ3_XXS | Packed_IQ4_NL | Packed_Q2_0
                     then Item.Reference_GSQ_Line else Item.Reference_Line));
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0, Product_Bytes, Shape'Address);
                  Dispatch (Item.Buffer, C.unsigned ((This.Rows + 7) / 8), C.unsigned (Count), 1);
               end;
               goto Next_Dispatch;
            end if;

            --  Bound here rather than left to whatever the step
            --  before it bound: the row kernel is chosen by the format
            --  as well as by the batch, and only a product knows its
            --  format. A walk that multiplies as integers rounds its
            --  activations first; see Round_Walks.
            if Dotted (Index) and then Barrier /= null then
               Round_For (Index);
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Dots_Line (Item, This.Packing, Count, This.Columns));
            else
               Bind_Pipeline
                 (Item.Buffer, Bind_Point_Compute,
                  Row_Line (Item, Count, This.Packing, This.Columns));
            end if;

            --  A listed product on the matrix kernel: the runs'
            --  vectors laid out by slot in half precision first, then
            --  every expert's tiles down the third axis.
            if Listed_Tiled (Index) and then Barrier /= null then
               declare
                  Slots  : constant Natural := Listed_Slots (Index);
                  Wide   : constant Boolean :=
                    Listed_Wide (Item, This.Packing, Count, This.Used,
                                 This.Gathers);
                  Vectors : constant Positive :=
                    (if Wide then Listed_Wide_Vectors else Listed_Vectors);

                  --  Its part in a folded mixture (Fold_Role), and the
                  --  two regions the fold's halves go to, in halves.
                  Role : constant Natural := Fold_Role (Index);
                  Region_One : constant Interfaces.Unsigned_64 :=
                    Item.Half_Region / 2;
                  Region_Two : constant Interfaces.Unsigned_64 :=
                    Item.Half_Region;
                  Halved_Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Columns),
                     Columns => C.unsigned (Slots),
                     Count   => C.unsigned (Count),
                     First   => 0,
                     Packing => 0,
                     Base    => C.unsigned (This.Gathers),
                     Joins   => 0,
                     Table   => 0,
                     Members => [others => 0],
                     Stride  => 0,
                     Apart   => 0,
                     Routed  => (if This.By_Slot then 3 else 2));
                  Shape : aliased Shape_Constants :=
                    (Rows    => C.unsigned (This.Each),
                     Columns => C.unsigned (This.Columns),
                     Count   => C.unsigned (Count),
                     --  Folded, the gate stores into the first region
                     --  and the up into the second, as halves.
                     First   =>
                       (case Role is
                          when 1 => C.unsigned (Region_One + 1),
                          when 2 => C.unsigned (Region_Two + 1),
                          when others => 0),
                     Packing =>
                       C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base    => C.unsigned (Places (Index).Base),
                     Joins   => 0,
                     --  The up's unit, on the gate's halves.
                     Table   =>
                       (if Role = 2
                        then C.unsigned
                               (Steps.Items (Fold_Combination_Of (Index)).Unit)
                        else 0),
                     Members => [0 => C.unsigned (This.Gathers),
                                 1 => (if Splits (Index)
                                       then C.unsigned (Split_Most) else 0),
                                 --  And the down's operand, the middle
                                 --  the up stored.
                                 2 => (if Role = 4 then C.unsigned (Region_Two)
                                       else 0),
                                 --  The experts' biases a folded gate or
                                 --  up adds, in floats and plus one, at
                                 --  the binding its bias step's stack is.
                                 3 => (if Fold_Bias_Of (Index) /= 0
                                       then C.unsigned
                                              (Places (Fold_Bias_Of (Index)).Base
                                               / 4 + 1)
                                       else 0),
                                 --  And the clamped unit's slope and
                                 --  limit, by their bits.
                                 4 => (if Role = 2
                                       then Float_Bits
                                              (C.C_float
                                                 (Steps.Items
                                                    (Fold_Combination_Of (Index)).Alpha))
                                       else 0),
                                 5 => (if Role = 2
                                       then Float_Bits
                                              (C.C_float
                                                 (Steps.Items
                                                    (Fold_Combination_Of (Index)).Limit))
                                       else 0),
                                 others => 0],
                     Stride  => C.unsigned (Slice_Bytes (Index)),
                     Apart   =>
                       (if Role = 2 then C.unsigned (Region_One + 1) else 0),
                     Routed  => (if This.By_Slot then 3 else 2));
               begin
                  --  Folded, the up reads the copy the gate laid out
                  --  and the down the middle the up stored: neither
                  --  lays out its own.
                  if Role not in 2 | 4 then
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute, Item.Halve_Line);
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Halved_Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Slots * This.Columns / 2 + Group_Size - 1)
                           / Group_Size), 1, 1);

                     Barrier
                       (Item.Buffer, Pipeline_Stage_Compute,
                        Pipeline_Stage_Compute, 0, 1, Wall'Address,
                        0, Null_Handle, 0, Null_Handle);
                  end if;

                  --  What the copy's front holds now is the runs' own
                  --  layout, which no plain product reads as its copy.
                  Half_From := -1;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     (if Wide then Listed_Wide_Pipeline (Item, This.Packing)
                      else Listed_Pipeline (Item, This.Packing)));
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer,
                     C.unsigned (This.Each / Listed_Rows),
                     C.unsigned
                       ((Count + 15 + Vectors - 1) / Vectors),
                     C.unsigned (This.Gathers));

                  --  And the short runs, walked as integers over the
                  --  step's activations rounded: the walk skips the runs
                  --  longer than its vectors, which the tile took.
                  if Splits (Index) then
                     declare
                        Spare : aliased Address :=
                          Item.Sets (Spare_Of (Index));
                     begin
                        Bind_Sets (Item.Buffer, Bind_Point_Compute,
                                   Item.Layout, 0, 1, Spare'Address, 0,
                                   Null_Handle);
                     end;
                     Round_For (Index);
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute,
                        Dots_Line (Item, This.Packing, Split_Most,
                                   This.Columns));
                     declare
                        Walk : aliased Shape_Constants :=
                          (Rows    => C.unsigned (This.Each),
                           Columns => C.unsigned (This.Columns),
                           Count   => C.unsigned (Split_Most),
                           First   => 0,
                           Packing =>
                             C.unsigned (Weight_Packing'Pos (This.Packing)),
                           Base    => C.unsigned (Places (Index).Base),
                           Joins   => 0,
                           Table   => C.unsigned (Round_Rows (Index)),
                           Members => [0 => C.unsigned (This.Gathers),
                                       others => 0],
                           Stride  => C.unsigned (Slice_Bytes (Index)),
                           Apart   => 0,
                           Routed  => (if This.By_Slot then 3 else 2));
                     begin
                        Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                              Product_Bytes, Walk'Address);
                        Dispatch
                          (Item.Buffer,
                           C.unsigned
                             ((Row_Reach (Item, This.Packing, Split_Most,
                                          This.Each, This.Columns)
                                 * Row_Lane_Count (Item, This.Packing,
                                                   Split_Most)
                               + Row_Width (Item, This.Packing, Split_Most)
                               - 1)
                              / Row_Width (Item, This.Packing, Split_Most)),
                           1,
                           C.unsigned (This.Gathers));
                     end;
                     Bind_Sets (Item.Buffer, Bind_Point_Compute,
                                Item.Layout, 0, 1, Bound'Address, 0,
                                Null_Handle);
                  end if;

                  Bind_Pipeline
                    (Item.Buffer, Bind_Point_Compute,
                     Row_Line (Item, Count, This.Packing, This.Columns));
               end;

               goto Next_Dispatch;
            end if;

            --  A listed product is one dispatch, every expert down
            --  the third axis and each walking its own run; the rows
            --  the shader is told are one expert's. Where the batch
            --  chooses fewer than there are, the third axis is the
            --  most it can choose, each workgroup finding its expert
            --  in the invert step's list of those with a run.
            --  And there, where the batch is longer than two, two
            --  passes: the runs of one and two on the walk for two,
            --  the longer on the batch's own. A check of four to six
            --  positions over Qwen3.6-35B-A3B's 256 experts runs one
            --  or two positions an expert, and the batch's walk worked
            --  out every one of its vectors for each. A third pass,
            --  the runs of one on the walk for one, measured level
            --  (50.3 against 51.0 tokens a second drafted).
            if This.Listed then
               declare
                  Short : constant Boolean :=
                    Count * This.Used < This.Gathers;
                  Rounds : constant Boolean :=
                    Dotted (Index) and then Barrier /= null;
                  Narrow : constant := 2;
                  Narrow_Line : constant Address :=
                    (if not Short or else Count <= Narrow then Null_Handle
                     elsif Rounds
                     then Dots_Line
                            (Item, This.Packing, Narrow, This.Columns)
                     else Row_Line
                            (Item, Narrow, This.Packing, This.Columns));

                  --  One pass: the walk for Width vectors over the
                  --  runs longer than Floor and, where Ceiling is not
                  --  nought, no longer than it.
                  procedure Walk (Width, Floor, Ceiling : Natural) is
                     Shape : aliased Shape_Constants :=
                       (Rows    => C.unsigned (This.Each),
                        Columns => C.unsigned (This.Columns),
                        Count   => C.unsigned (Count),
                        First   => 0,
                        Packing =>
                          C.unsigned (Weight_Packing'Pos (This.Packing)),
                        Base    => C.unsigned (Places (Index).Base),
                        Joins   => 0,
                        --  Where an integer walk by slot finds its
                        --  rounding's scales, in rows.
                        Table   =>
                          (if Rounds
                           then C.unsigned (Slot_Rows (Index)) else 0),
                        Members =>
                          [0  => C.unsigned (This.Gathers),
                           13 => C.unsigned (Ceiling),
                           14 => C.unsigned (Floor),
                           15 =>
                             (if Short
                              then C.unsigned
                                     (Used_List_At
                                        (This.Gathers, Count,
                                         This.Used) + 1)
                              else 0),
                           others => 0],
                        Stride  => C.unsigned (Slice_Bytes (Index)),
                        Apart   => 0,
                        Routed  => (if This.By_Slot then 3 else 2));
                  begin
                     Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                           Product_Bytes, Shape'Address);
                     Dispatch
                       (Item.Buffer,
                        C.unsigned
                          ((Row_Reach (Item, This.Packing, Width,
                                       Natural (Shape.Rows), This.Columns)
                              * Row_Lane_Count (Item, This.Packing, Width)
                            + Row_Width (Item, This.Packing, Width) - 1)
                           / Row_Width (Item, This.Packing, Width)),
                        1,
                        C.unsigned
                          (if Short then Count * This.Used
                           else This.Gathers));
                  end Walk;
               begin
                  if Narrow_Line /= Null_Handle then
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute, Narrow_Line);
                     Walk (Narrow, 0, Narrow);
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute,
                        (if Rounds
                         then Dots_Line
                                (Item, This.Packing, Count, This.Columns)
                         else Row_Line
                                (Item, Count, This.Packing,
                                 This.Columns)));
                     Walk (Count, Narrow, 0);
                  else
                     Walk (Count, 0, 0);
                  end if;
               end;

               goto Next_Dispatch;
            end if;

            while First < Count loop
               declare
                  --  A gather's members ride in the push block and its
                  --  count is the third dispatch dimension; the rows
                  --  the shader is told are one slice's. A gather of
                  --  one is pushed as the plain product on that slice,
                  --  which is the same words the tile kernel is given.
                  Sliced : constant Boolean := This.Gathers = 1;
                  Spread : constant Boolean := This.Gathers > 1;

                  --  As two walks, where the batch goes that way; see
                  --  Split_Half.
                  Half  : constant Natural :=
                    Split_Half (Item, This.Packing, Count);
                  Carry : constant Natural :=
                    (if Half = 0 then Count
                     elsif First = 0 then Half
                     else Count - Half);

                  Shape : aliased Shape_Constants :=
                    (Rows    =>
                       C.unsigned
                         (if This.Gathers > 0 then This.Each
                          else This.Rows),
                     Columns => C.unsigned (This.Columns),
                     Count   => C.unsigned (Count),
                     First   => C.unsigned (First),
                     Packing =>
                       C.unsigned (Weight_Packing'Pos (This.Packing)),
                     Base    =>
                       C.unsigned
                         (Places (Index).Base
                          + (if Sliced then Slice_Base (Index) else 0)),
                     --  The residual, and a bias beside it: the second
                     --  bit, read from the routing binding (Bias_Too).
                     Joins   => (if This.Bias_Too /= 0 then 3
                                 elsif This.Joins then 1 else 0),
                     Table   => 0,
                     Members => [others => 0],
                     Stride  =>
                       (if Spread then C.unsigned (Slice_Bytes (Index))
                        else 0),
                     Apart   =>
                       (if Spread then C.unsigned (This.Apart) else 0),
                     Routed  => (if This.Routed /= 0 then 1 else 0));
               begin
                  if Spread then
                     for Member in 1 .. This.Gathers loop
                        Shape.Members (Member - 1) :=
                          C.unsigned (This.Members (Member));
                     end loop;
                  end if;

                  if Half > 0 then
                     Bind_Pipeline
                       (Item.Buffer, Bind_Point_Compute,
                        Row_Line (Item, Carry, This.Packing, This.Columns));
                  end if;
                  Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
                        Product_Bytes, Shape'Address);
                  Dispatch
                    (Item.Buffer,
                     C.unsigned
                       ((Row_Reach (Item, This.Packing, Carry,
                                    Natural (Shape.Rows), This.Columns)
                           * Row_Lane_Count (Item, This.Packing, Carry)
                         + Row_Width (Item, This.Packing, Carry) - 1)
                        / Row_Width (Item, This.Packing, Carry)),
                     1,
                     C.unsigned (if Spread then This.Gathers else 1));

                  First := First
                    + (if Half > 0 then Carry else Row_Group (Item, Count));
               end;
            end loop;

            <<Next_Dispatch>>
            --  After this step's last dispatch, folded or not: a folded
            --  join dispatched nothing and its interval says so.
            if Stamping then
               Write_Stamp
                 (Item.Buffer, Pipeline_Stage_Bottom, Item.Queries,
                  C.unsigned (Index));
            end if;
         end;
      end loop;

      if Stop (Item.Buffer) /= 0 then
         Release_All;
         return;
      end if;
   end;

   --  Once, for all of them -- and handed over rather than waited for.
   --  A sequence that keeps nothing and leaves its answer on the device
   --  is one the host has no reason to wait for, and not waiting is the
   --  whole of this: the device starts the next one the moment it
   --  finishes this, instead of standing idle while the host wakes up,
   --  records and submits.
   declare
      --  Held, a kept answer is the caller's to wait for.
      Holding    : constant Boolean := Hold and then Leave_Kept;
      Reads_Back : Boolean := not Carry_Out and then not Holding;
   begin
      for Index in 1 .. Steps.Held loop
         --  A borrowed matrix is given back at the end of this call, and
         --  it may not be given back while the device is still reading
         --  it -- so a sequence that borrowed anything waits.
         Reads_Back :=
           Reads_Back
           or else (Steps.Items (Index).Kept and then not Holding)
           or else Places (Index).Borrowed;
      end loop;

      --  A timed sequence is waited for, so that its stamps can be read
      --  now rather than kept until this slot comes round again.
      Reads_Back := Reads_Back or else Item.Timing;

      Hand_Over (Item, Good);

      if Good and then Reads_Back then
         Await (Item, Good, Cancelled, Cancel);
      end if;
   end;

   if not Good then
      Release_All;
      return;
   end if;

   --  What the stamps latched, scaled to microseconds. Read after the
   --  fence, so the wait flag is a formality; a device that answers the
   --  read with anything but success leaves the line empty rather than
   --  publishing ticks it did not write.
   if Item.Timing and then Item.Queries /= Null_Handle then
      declare
         Results : constant Query_Results_Call :=
           To_Query_Results (Point ("vkGetQueryPoolResults"));

         type Stamp_Array is
           array (0 .. Sequence_Limit) of aliased Interfaces.Unsigned_64
           with Convention => C;

         Stamps : aliased Stamp_Array := [others => 0];
      begin
         Item.Line := (others => <>);

         if Results /= null
           and then Results
             (Item.Logical, Item.Queries, 0, C.unsigned (Steps.Held + 1),
              Interfaces.Unsigned_64 ((Steps.Held + 1) * 8),
              Stamps'Address, 8,
              C.unsigned (Query_Result_64 + Query_Result_Wait)) = 0
         then
            Item.Line.Held := Steps.Held;
            for Index in 1 .. Steps.Held loop
               Item.Line.Steps (Index) :=
                 (if Stamps (Index) >= Stamps (Index - 1)
                  then Float (Stamps (Index) - Stamps (Index - 1))
                       * Item.Tick / 1000.0
                  else 0.0);
            end loop;
            Item.Line.Whole :=
              (if Stamps (Steps.Held) >= Stamps (0)
               then Float (Stamps (Steps.Held) - Stamps (0))
                    * Item.Tick / 1000.0
               else 0.0);
         end if;
      end;
   end if;

   --  And what came out, product by product, out of the one mapping.
   Item.Kept_At := Null_Handle;
   declare
      Good_Map : Boolean;
      Filled   : Model_Runner.Numerics.Element_Count := Target'First;
      Placed   : Natural := 0;
   begin
      Standing (Item, Item.Result_Memory, Item.Result_At,
                Item.Result_Bytes, Good_Map);
      if not Good_Map then
         Release_All;
         return;
      end if;

      for Index in 1 .. Steps.Held loop
         declare
            Mine : constant Model_Runner.Numerics.Element_Count :=
              Model_Runner.Numerics.Element_Count (Steps.Items (Index).Rows)
              * Model_Runner.Numerics.Element_Count (Count);

            Slice : Model_Runner.Numerics.Real_Array
              (Filled .. Filled + Mine - 1)
              with Import,
                   Address =>
                     System.Storage_Elements.To_Address
                       (System.Storage_Elements.To_Integer
                          (Item.Result_At)
                        + System.Storage_Elements.Integer_Address
                            (Places (Index).At_Byte));
         begin
            --  A step whose answer nothing on the host reads is not
            --  copied out. The room it would have taken is still stepped
            --  over, so what a caller indexes does not depend on what it
            --  kept -- and for a gated feed-forward that is three
            --  answers of the four left where they were written.
            if Steps.Items (Index).Kept and then Leave_Kept then
               if Item.Kept_At = Null_Handle then
                  Item.Kept_At := Slice'Address;
               end if;
            elsif Steps.Items (Index).Kept and then Kept_Into'Length > 0
            then
               Placed := Placed + 1;
               declare
                  Place : Model_Runner.Numerics.Real_Array (Slice'Range)
                    with Import,
                         Address =>
                           Kept_Into (Kept_Into'First + Placed - 1);
               begin
                  Place := Slice;
               end;
            elsif Steps.Items (Index).Kept then
               Target (Slice'Range) := Slice;
            end if;

            Filled := Filled + Mine;
         end;
      end loop;

   end;

   Release_All;
   Item.Refused := Not_Refused;
   Ok := True;
end Run;
