with Ada.Unchecked_Deallocation;
separate (Model_Runner.Llama)
procedure Mixture_Batch_Body
  (Item    : in out Session;
   Current : Layer;
   Rows    : T.Real_Array_Access;
   Count   : Element_Count;
   Ok      : out Boolean;
   Status  : out E.Error_Info)
is
   use type Model_Runner.GGUF.Tensor_Type;
   Settings : Configuration renames Item.Owner.Settings;

   Reference_Arithmetic : constant Boolean := Settings.Kind = Inkling2_Loop
     and then (for some Role of Item.Arithmetic => Role);

   Used   : constant Natural := Settings.Experts_Used;
   Many   : constant Natural := Settings.Experts;
   Width  : constant Element_Count := Element_Count (Settings.Embedding);
   Feed   : constant Element_Count :=
     Element_Count (Settings.Expert_Feed);

   Wide   : constant Element_Count := Count * Width;

   --  Experts retained as individual slices.  A split mixture may run these
   --  on the device while every other expert remains on the processor.  The
   --  policy replacement pass below gives back only slices admitted for this
   --  cache before it admits their hotter replacements.
   Resident_Experts : Expert_Flags (0 .. Many - 1) := [others => False];

   --  Whether the device made the shared expert's answer for this one
   --  position after the layer's front half; asked once, and cleared.
   Given_Shared : constant Boolean :=
     Item.Shared_Ready
     and then Count = 1
     and then T.Is_Present (Current.Shared_Gate)
     and then Item.Shared_Given /= null
     and then Item.Shared_Given.all'Length >= Width;

   --  Whether the experts are dealt to the pool's workers below, an
   --  expert to a worker -- in which case the shared expert goes with
   --  them, as chunks of the same job, rather than as three products
   --  of its own cut across the pool with a wake and a settle around
   --  each. Three megabytes a layer beside the experts' thirty-five,
   --  and 0.14 ms a layer of a four-row batch where the bytes were
   --  0.09 -- and on a token, the same three dispatches for one row.
   --  Not while a watcher listens: the workers run the kernels directly,
   --  and the road an expert at a time below tells each expert its rows.
   On_Pool : constant Boolean :=
     (Item.Host_Feed
      or else Model_Runner.Backend."="
                (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_CPU))
     and then Workers_CPU."/=" (Item.Team, null)
     and then Item.Seen = null;

   --  Whether the shared expert goes as three products of its own, cut
   --  across the whole pool, rather than as one item of the experts'
   --  job: off the pool, and for a token. A token's shared expert is
   --  one item, and one worker read all of it -- twice an expert's
   --  bytes where each of the others read one expert -- while the rest
   --  of the pool waited on that worker every layer.
   --  Whether a token's shared expert goes into the experts' job cut
   --  by rows: its gate and up as two halves, taken first, and its down
   --  as two halves taken last, each waiting for both of the first. Six
   --  experts on a pool of eight left two of it idle through the job,
   --  and the shared expert's three products after it each paid a wake
   --  and a settle: 236 and 747 us a layer of DeepSeek-V2-Lite, both
   --  at 46 GB/s of the box's 48. A row range of a matrix is a range of
   --  its panels, so the halves are whole panels: rows a multiple of
   --  sixteen.
   Shared_Split : constant Boolean :=
     On_Pool
     and then Count = 1
     and then T.Is_Present (Current.Shared_Gate)
     and then not Given_Shared
     and then Halves_Whole (Current.Shared_Gate)
     and then Halves_Whole (Current.Shared_Up)
     and then Halves_Whole (Current.Shared_Down)
     and then Current.Shared_Gate.Rows = Element_Count (Settings.Shared_Feed)
     and then Current.Shared_Down.Rows = Width;

   Shared_Apart : constant Boolean :=
     not On_Pool or else (Count = 1 and then not Shared_Split);

   --  The shared expert's feed width, where there is one; the experts'
   --  otherwise, so the rooms below are never too narrow.
   Shared_Feed : constant Element_Count :=
     (if T.Is_Present (Current.Shared_Gate)
      then Element_Count (Settings.Shared_Feed) else Feed);

   --  Take a buffer if there is not one, or a wider one if what there is
   --  is too narrow. A session does not know how wide a batch it will be
   --  handed, and every one of these is sized by that.
   procedure Ensure
     (Room : in out T.Real_Array_Access; Length : Element_Count) is
   begin
      if Room = null or else Room.all'Length < Length then
         T.Free (Room);
         T.Allocate (Length, Room);
      end if;
   end Ensure;

   procedure Ensure_Choices
     (Room : in out Choice_Access; Length : Natural)
   is
      procedure Release is
        new Ada.Unchecked_Deallocation (Choice_List, Choice_Access);
   begin
      if Room = null or else Room.all'Length < Length then
         if Room /= null then
            Release (Room);
         end if;

         Room := new Choice_List (0 .. Length - 1);
      end if;
   end Ensure_Choices;

   Usable : Boolean;
begin
   Item.Shared_Ready := False;
   Ok := False;
   Status := E.Success;

   Ensure (Item.Route_Rows, Count * Element_Count (Many));
   Ensure (Item.Pick_Share, Count * Element_Count (Used));
   Ensure (Item.Gather_In, Wide);
   Ensure (Item.Gather_A, Count * Feed);
   Ensure (Item.Gather_B, Count * Feed);
   Ensure (Item.Gather_Out, Wide);
   Ensure (Item.Ranked, Count * Element_Count (Used) * Width);
   Ensure_Choices (Item.Pick_Which, Natural (Count) * Used);
   Ensure_Choices (Item.Gathered, Natural (Count));

   if Item.Route_Rows = null or else Item.Pick_Share = null
     or else Item.Gather_In = null or else Item.Gather_A = null
     or else Item.Gather_B = null or else Item.Gather_Out = null
     or else Item.Ranked = null
     or else Item.Pick_Which = null or else Item.Gathered = null
   then
      --  Not an error: the caller runs the positions one at a time,
      --  which is what it did before any of this existed.
      return;
   end if;

   --  The shared expert's answer as the device made it after the
   --  front half, scaled already: a gate of one, and nothing for the
   --  pool to deal.
   if Given_Shared then
      Ensure (Item.Shared_Rows_A, Count * Element_Count (Settings.Shared_Feed));
      Ensure (Item.Shared_Rows_B, Count * Element_Count (Settings.Shared_Feed));
      Ensure (Item.Shared_Rows_Out, Wide + Count);
      if Item.Shared_Rows_Out = null or else Item.Shared_Rows_A = null
        or else Item.Shared_Rows_B = null
      then
         return;
      end if;

   --  The shared expert over the whole batch, while the rows are still
   --  the input: its answer and its gate a row, added in at the end
   --  once the chosen experts have been summed into the rows.
   elsif T.Is_Present (Current.Shared_Gate) then
      declare
         Shared : constant Element_Count :=
           Element_Count (Settings.Shared_Feed);
      begin
         Ensure (Item.Shared_Rows_A, Count * Shared);
         Ensure (Item.Shared_Rows_B, Count * Shared);
         Ensure (Item.Shared_Rows_Out, Wide + Count);

         if Item.Shared_Rows_A = null or else Item.Shared_Rows_B = null
           or else Item.Shared_Rows_Out = null
         then
            return;
         end if;

         --  The gates first, after the answer's room: one number a
         --  row, the sigmoid of the router row against the input.
         for Which in 0 .. Count - 1 loop
            Item.Shared_Rows_Out.all (Wide + Which) :=
              Shared_Weight
                (Current.Shared_Router, Rows.all,
                 Rows.all'First + Which * Width);
         end loop;

         --  Its answer, unless the pool will make it below among the
         --  experts' chunks.
         if Shared_Apart then
            Product_Batch
              (Item, Current.Shared_Gate, Rows, Count, Item.Shared_Rows_A,
               Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Product_Batch
              (Item, Current.Shared_Up, Rows, Count, Item.Shared_Rows_B,
               Status);
            if E.Is_Error (Status) then
               return;
            end if;

            K.SiLU (Item.Shared_Rows_A.all (0 .. Count * Shared - 1));
            K.Multiply
              (Item.Shared_Rows_A.all (0 .. Count * Shared - 1),
               Item.Shared_Rows_B.all (0 .. Count * Shared - 1));

            Product_Batch
              (Item, Current.Shared_Down, Item.Shared_Rows_A, Count,
               Item.Shared_Rows_Out, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;
      end;
   end if;

   --  Routed on the device where the device holds the stacks, through
   --  the kernel a token's whole layer routes through, so that a prompt
   --  and a token choose the same experts with the same shares: the
   --  host's softmax sums in binary64 and the device's in binary32,
   --  and a share a bit apart is an answer a bit apart.
   if (Item.Owner.all.Stacked or else Current.Mixture_Held)
     and then Model_Runner.Backend."="
                (Item.Owner.Able.Kind,
                 Model_Runner.Backend.Backend_Device)
     and then Used <= Model_Runner.Backend.Device.Max_Route

     --  The route kernel softmaxes, and renormalizes or not as the model
     --  asks; a sigmoid-gated mixture is routed on the host, as one
     --  position's is, and so is one that chooses by a bias it does not
     --  weight by.
     and then not Settings.Sigmoid_Gate
     and then Current.Select_Bias = null
     and then not Grouped (Settings)
   then
      declare
         Choice : Model_Runner.Backend.Device.Choice_Array
           (0 .. Natural (Count) * Used - 1);
      begin
         if Item.Seen /= null then
            declare
               Which : constant String :=
                 Named_As (Item.Owner.all, Current.Router);
            begin
               if Which /= "" then
                  Item.Seen.Note
                    (Which,
                     Rows.all (Rows.all'First
                               .. Rows.all'First + Count * Width - 1),
                     Count);
               end if;
            end;
         end if;

         Model_Runner.Backend.Device.Dispatch_Route
           (Current.Router, Current.Router_Bias, Many, Used, Rows, Count,
            Choice,
            Item.Pick_Share.all
              (Item.Pick_Share.all'First
               .. Item.Pick_Share.all'First
                  + Count * Element_Count (Used) - 1),
            Status, Item.Stopping);
         if E.Is_Error (Status) then
            return;
         end if;

         for Index in Choice'Range loop
            Item.Pick_Which.all (Index) := Choice (Index);
         end loop;

         goto Chosen;
      end;
   end if;

   --  A token or a short batch whose front half the device ran chose
   --  there too, where it was handed the router: taken rather than
   --  routed again.
   --
   --  Not for a sigmoid-gated mixture, nor one with a selection bias: the
   --  front half routes by the softmax and its own choosing, and taken, a
   --  sigmoid-gated model under split feed was weighted by shares it does
   --  not compute.
   if Count <= Model_Runner.Backend.Device.Front_Route_Most
     and then not Settings.Sigmoid_Gate
     and then Current.Select_Bias = null
     and then not Grouped (Settings)
     and then Item.Owner.all.Split_Feed
     and then not Item.On_Host
     and then Model_Runner.Backend."="
                (Item.Owner.Able.Kind,
                 Model_Runner.Backend.Backend_Device)
   then
      declare
         Choice : Model_Runner.Backend.Device.Choice_Array
           (0 .. Natural (Count) * Used - 1);
         Found  : Boolean;
      begin
         Model_Runner.Backend.Device.Take_Front_Route
           (Current.Router, Used, Positive (Count), Choice,
            Item.Pick_Share.all
              (Item.Pick_Share.all'First
               .. Item.Pick_Share.all'First
                  + Count * Element_Count (Used) - 1),
            Found);
         if Found then
            for Index in Choice'Range loop
               Item.Pick_Which.all (Index) := Choice (Index);
            end loop;
            goto Chosen;
         end if;
      end;
   end if;

   --  Every position's router scores at once, which is one product where
   --  it was one a position.
   Product_Batch
     (Item, Current.Router, Rows, Count, Item.Route_Rows, Status);
   if E.Is_Error (Status) then
      return;
   end if;

   --  And the choosing, position by position, exactly as one position's
   --  mixture chooses: the bias before the softmax because it changes
   --  which experts are picked, the largest few in order, and the shares
   --  put back on a scale where their sum is one.
   for Where in 0 .. Count - 1 loop
      declare
         At_Row : constant Element_Count :=
           Item.Route_Rows.all'First + Where * Element_Count (Many);

         Scores : T.Real_Array renames
           Item.Route_Rows.all (At_Row .. At_Row + Element_Count (Many) - 1);

         Taken : Expert_Flags (0 .. Many - 1) := [others => False];
         Total : Real := 0.0;
         Fast_Picks : Choice_List (0 .. 7);
         Fast_Select : constant Boolean := Settings.Kind = Inkling2_Loop and then Many = 128
           and then Used = 8 and then Current.Select_Bias = null and then not Grouped (Settings);
      begin
         if Current.Router_Bias /= null then
            K.Add (Scores, Current.Router_Bias.all);
         end if;

         if Settings.Sigmoid_Gate then
            if Reference_Arithmetic then
               for Value of Scores loop Value := Reference_Sigmoid (Value); end loop;
            else
               K.Sigmoid (Scores);
            end if;
         else
            K.Softmax (Scores, Usable);
            if not Usable then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;
         end if;

         --  The best few groups' experts alone, where the model chooses so.
         if Grouped (Settings) then
            declare
               Picks : Real_Array (0 .. Element_Count (Many) - 1);
            begin
               for Which in Taken'Range loop
                  Picks (Element_Count (Which)) :=
                    Scores (Scores'First + Element_Count (Which))
                    + (if Current.Select_Bias = null then 0.0
                       else Current.Select_Bias
                              (Current.Select_Bias'First
                               + Element_Count (Which)));
               end loop;
               Keep_Groups (Settings, Picks, Taken);
            end;
         end if;

         if Fast_Select then Pick_Eight_Of_128 (Scores, Fast_Picks); end if;
         for Slot in 0 .. Used - 1 loop
            declare
               Best : Integer := -1;

               --  What an expert is chosen by: its score, and the
               --  selection bias where the layer carries one.
               function Pick (Which : Natural) return Real
               is (Scores (Scores'First + Element_Count (Which))
                   + (if Current.Select_Bias = null then 0.0
                      else Current.Select_Bias
                             (Current.Select_Bias'First
                              + Element_Count (Which))));
            begin
               if Fast_Select then
                  Best := Fast_Picks (Slot);
               else
               for Which in Taken'Range loop
                  if not Taken (Which)
                    and then (Best < 0 or else Pick (Which) > Pick (Best))
                  then
                     Best := Which;
                  end if;
               end loop;

               end if;
               Taken (Best) := True;
               Item.Pick_Which.all (Natural (Where) * Used + Slot) := Best;
               Item.Pick_Share.all
                 (Item.Pick_Share.all'First
                  + Where * Element_Count (Used) + Element_Count (Slot)) :=
                 Scores (Scores'First + Element_Count (Best));
               Total := Total
                 + Scores (Scores'First + Element_Count (Best));
            end;
         end loop;

         if Reference_Arithmetic then
            declare
               Wide_Total : N.Wide_Real := 0.0;
            begin
               for Slot in 0 .. Used - 1 loop
                  Wide_Total := Wide_Total + N.Wide_Real
                    (Item.Pick_Share.all
                       (Item.Pick_Share.all'First + Where * Element_Count (Used) + Element_Count (Slot)));
               end loop;
               Total := Real (Wide_Total);
            end;
         end if;

         if Settings.Renormalize_Experts then
            if not (Total > 0.0) then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;

            for Slot in 0 .. Used - 1 loop
               declare
                  At_Share : constant Element_Count :=
                    Item.Pick_Share.all'First
                    + Where * Element_Count (Used) + Element_Count (Slot);
               begin
                  Item.Pick_Share.all (At_Share) :=
                    Item.Pick_Share.all (At_Share)
                      / (Total + (if Settings.Kind = Inkling2_Loop then 1.0E-20 else 0.0));
               end;
            end loop;
         end if;
      end;
   end loop;

   <<Chosen>>

   --  A prompt is the best warm-up trace available: every selected expert
   --  is recorded in position and rank order, before grouping rearranges
   --  the work by expert below.
   for Index in 0 .. Natural (Count) * Used - 1 loop
      declare
         Ignored : Model_Runner.Expert_Cache.Observation_Outcome;
      begin
         Model_Runner.Expert_Cache.Observe
           (Item.Expert_Policy, Current.Number,
            Item.Pick_Which.all (Index), Ignored);
      end;
   end loop;

   --  A split mixture ordinarily leaves every expert on the processor.
   --  First make physical residency agree with the replacement policy, then
   --  warm its candidates.  The views below are individual expert slices in
   --  a host-fed split mixture: they cannot be attention matrices or a whole
   --  resident expert stack.  Hold_Expert rolls a partial admission back and
   --  never evicts an unrelated matrix, so replacement remains inside the
   --  cache's explicit reserve.
   if On_Pool
     and then (Settings.Kind /= Inkling2_Loop
       or else (Reference_Arithmetic and then Count <= 128
                and then Item.Owner.Runtime_Pairs = null
                and then Model_Runner.Backend.Device.Takes_Reference_Mixture))
     and then Item.Host_Feed
     and then Item.Owner.Expert_Cache_Room > 0
     and then Model_Runner.Backend."="
                (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
     and then not Item.Owner.all.Stacked
     and then not Current.Mixture_Held
     and then Item.Seen = null
     and then Current.Expert_Gate_Bias = null
     and then Current.Expert_Up_Bias = null
     and then Current.Expert_Down_Bias = null
   then
      --  Logical eviction used to leave the old three matrices resident.
      --  Once the reserve filled, no newly hot expert could therefore be
      --  admitted.  Reclaim non-residents before considering admissions so
      --  the physical cache continues to follow the routing policy.
      for Which in Resident_Experts'Range loop
         if not Model_Runner.Expert_Cache.Is_Resident
                  (Item.Expert_Policy, Current.Number, Which)
         then
            declare
               Gate, Up, Down : T.View;
               Trouble        : E.Error_Info;
               Bytes          : Interfaces.Unsigned_64;
            begin
               Device_Expert_Views
                 (Current, Which, Feed, Width, Gate, Up, Down, Trouble);
               if E.Is_Error (Trouble) then
                  Status := Trouble;
                  return;
               end if;

               if not Gate.Interleaved
                 and then not Up.Interleaved
                 and then not Down.Interleaved
                 and then Model_Runner.Backend.Device.Expert_Held
                            (Gate, Up, Down)
               then
                  Bytes :=
                    Interfaces.Unsigned_64 (Gate.Rows)
                      * Interfaces.Unsigned_64 (T.Row_Bytes (Gate))
                    + Interfaces.Unsigned_64 (Up.Rows)
                      * Interfaces.Unsigned_64 (T.Row_Bytes (Up))
                    + Interfaces.Unsigned_64 (Down.Rows)
                      * Interfaces.Unsigned_64 (T.Row_Bytes (Down));
                  Model_Runner.Backend.Device.Give_Back (Gate);
                  Model_Runner.Backend.Device.Give_Back (Up);
                  Model_Runner.Backend.Device.Give_Back (Down);
                  Item.Expert_Cache_Used :=
                    Item.Expert_Cache_Used
                    - Interfaces.Unsigned_64'Min
                        (Item.Expert_Cache_Used, Bytes);
               end if;
            end;
         end if;
      end loop;

      for Which in Resident_Experts'Range loop
         if Model_Runner.Expert_Cache.Is_Resident
              (Item.Expert_Policy, Current.Number, Which)
         then
            declare
               Gate, Up, Down : T.View;
               Trouble        : E.Error_Info;
               Bytes          : Interfaces.Unsigned_64;
               Was_Held       : Boolean;
            begin
               Device_Expert_Views
                 (Current, Which, Feed, Width, Gate, Up, Down, Trouble);
               if E.Is_Error (Trouble) then
                  Status := Trouble;
                  return;
               end if;

               if Gate.Interleaved or else Up.Interleaved
                 or else Down.Interleaved
               then
                  goto Next_Candidate;
               end if;

               Bytes :=
                 Interfaces.Unsigned_64 (Gate.Rows)
                   * Interfaces.Unsigned_64 (T.Row_Bytes (Gate))
                 + Interfaces.Unsigned_64 (Up.Rows)
                   * Interfaces.Unsigned_64 (T.Row_Bytes (Up))
                 + Interfaces.Unsigned_64 (Down.Rows)
                   * Interfaces.Unsigned_64 (T.Row_Bytes (Down));
               Was_Held :=
                 Model_Runner.Backend.Device.Expert_Held (Gate, Up, Down);

               if Was_Held then
                  Resident_Experts (Which) := True;
               elsif Bytes <= Item.Owner.Expert_Cache_Room
                              - Interfaces.Unsigned_64'Min
                                  (Item.Expert_Cache_Used,
                                   Item.Owner.Expert_Cache_Room)
               then
                  Model_Runner.Backend.Device.Hold_Expert
                    (Gate, Up, Down, Resident_Experts (Which));
                  if Resident_Experts (Which) then
                     Item.Expert_Cache_Used :=
                       Item.Expert_Cache_Used + Bytes;
                     Item.Expert_Cache_Admissions :=
                       Item.Expert_Cache_Admissions + 1;
                  end if;
               end if;
               <<Next_Candidate>>
               null;
            end;
         end if;
      end loop;
   end if;

   --  GraniteMoE's scalar on the weights, applied where the host choice
   --  and the device route rejoin, before the pool or the ranked sum
   --  below reads them, so every position's shares are scaled once.
   if Settings.Expert_Scale /= 1.0 then
      for Index in 0 .. Count * Element_Count (Used) - 1 loop
         Item.Pick_Share.all (Item.Pick_Share.all'First + Index) :=
           Item.Pick_Share.all (Item.Pick_Share.all'First + Index)
           * Settings.Expert_Scale;
      end loop;
   end if;

   --  Gemma4's scale an expert on what the expert projects down, taken on
   --  its share where the share meets it, so the sum below is the same
   --  sum of the same terms.
   if Current.Expert_Down_Scale /= null then
      for Index in 0 .. Count * Element_Count (Used) - 1 loop
         Item.Pick_Share.all (Item.Pick_Share.all'First + Index) :=
           Item.Pick_Share.all (Item.Pick_Share.all'First + Index)
           * Current.Expert_Down_Scale.all
               (Current.Expert_Down_Scale.all'First
                + Element_Count (Item.Pick_Which.all (Natural (Index))));
      end loop;
   end if;

   if Reference_Arithmetic and then Count = 1 and then Item.Seen = null
     and then Item.Owner.Runtime_Pairs = null and then Item.Owner.Expert_Cache_Room > 0
     and then Model_Runner.Backend."=" (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
     and then Model_Runner.Backend.Device.Takes_Reference_Mixture
     and then Used <= 8
     and then not T.Is_Present (Current.Shared_Gate)
   then
      declare
         Gates, Ups, Downs : T.View_Group (1 .. Used);
         Shares : Real_Array (0 .. Element_Count (Used) - 1);
         All_Held : Boolean := True;
      begin
         for Slot in 0 .. Used - 1 loop
            declare
               Which : constant Natural := Item.Pick_Which (Item.Pick_Which.all'First + Slot);
            begin
               if not Resident_Experts (Which) then All_Held := False; exit; end if;
               Device_Expert_Views (Current, Which, Feed, Width,
                                   Gates (Slot + 1), Ups (Slot + 1), Downs (Slot + 1), Status);
               if E.Is_Error (Status) then return; end if;
               Shares (Element_Count (Slot)) := Item.Pick_Share (Item.Pick_Share.all'First + Element_Count (Slot));
            end;
         end loop;
         if All_Held then
            Ensure (Item.Expert_Row, Width);
            if Item.Expert_Row = null then Status := E.Make (E.Memory_Allocation_Failed); return; end if;
            Model_Runner.Backend.Device.Dispatch_Reference_Mixture
              (Gates, Ups, Downs, Shares, Rows, Item.Expert_Row,
               Settings.Inkling.Gate_Softcap, Settings.Inkling.Up_Softcap, Status, Item.Stopping);
            if E.Is_Error (Status) then return; end if;
            Rows.all (Rows.all'First .. Rows.all'First + Width - 1) := Item.Expert_Row.all (0 .. Width - 1);
            Item.Expert_Cache_Device_Runs := Item.Expert_Cache_Device_Runs + 1;
            Ok := True;
            return;
         end if;
      end;
   end if;

   --  The common ordered expert set may vary its shares per token. Other
   --  route layouts keep the gathered resident/CPU path and its host sum.
   if Reference_Arithmetic and then Count in 2 .. 128 and then Used <= 8
     and then Model_Runner.Backend."=" (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
     and then Item.Seen = null and then Item.Owner.Runtime_Pairs = null
     and then not T.Is_Present (Current.Shared_Gate)
     and then Current.Expert_Gate_Bias = null and then Current.Expert_Up_Bias = null
     and then Current.Expert_Down_Bias = null
     and then Model_Runner.Backend.Device.Takes_Reference_Mixture
     and then (for all Pick in 0 .. Natural (Count) * Used - 1 =>
       Resident_Experts (Item.Pick_Which (Pick))
       and then Item.Pick_Which (Pick) = Item.Pick_Which (Pick mod Used))
   then
      declare
         Gates, Ups, Downs : T.View_Group (1 .. Used);
         Shares : Real_Array (0 .. Count * Element_Count (Used) - 1);
      begin
         for Slot in 0 .. Used - 1 loop
            Device_Expert_Views (Current, Item.Pick_Which (Slot), Feed, Width,
                                 Gates (Slot + 1), Ups (Slot + 1), Downs (Slot + 1), Status);
            if E.Is_Error (Status) then return; end if;
            for Token in 0 .. Count - 1 loop
               Shares (Element_Count (Slot) * Count + Token) := Item.Pick_Share (Token * Element_Count (Used)
                 + Element_Count (Slot));
            end loop;
         end loop;
         Ensure (Item.Expert_Row, Count * Width);
         if Item.Expert_Row = null then Status := E.Make (E.Memory_Allocation_Failed); return; end if;
         Model_Runner.Backend.Device.Dispatch_Reference_Mixture
           (Gates, Ups, Downs, Shares, Rows, Item.Expert_Row,
            Settings.Inkling.Gate_Softcap, Settings.Inkling.Up_Softcap, Status, Item.Stopping,
            Count => Positive (Count));
         if E.Is_Error (Status) then return; end if;
         Rows.all (Rows.all'First .. Rows.all'First + Count * Width - 1) :=
           Item.Expert_Row.all (0 .. Count * Width - 1);
         Item.Expert_Cache_Device_Runs := Item.Expert_Cache_Device_Runs + 1;
         Item.Inkling_Batched_Reductions := Item.Inkling_Batched_Reductions + 1;
         Ok := True;
         return;
      end;
   end if;

   if Reference_Arithmetic and then (Count = 1 or else Count > 128) then
      Resident_Experts := [others => False];
   end if;

   --  On the pool, an expert to a worker rather than a row to a worker.
   --
   --  An expert's product on a prompt is a handful of vectors by a few
   --  hundred rows, and the pool cut every one of the three hundred a
   --  layer across eight workers -- eight wakes and eight settles a
   --  product for a share of a few thousand rows each, which is where
   --  Qwen3-30B-A3B's prompt sat at 71 tokens a second against
   --  llama.cpp's 108 with the products themselves the same. Shared by
   --  expert, each worker gathers, multiplies, gates and scatters its
   --  own experts whole, serially, and the pool is woken once a layer.
   --
   --  The sum is still the sum below, in rank order: a worker writes
   --  each answer to the place its position and rank name, and no two
   --  experts share one, so the workers never write where another
   --  reads. The products a worker runs serially are the products the
   --  pool would have cut, so the bits are the bits.
   if On_Pool then
      declare
         --  Every expert's members, gathered once: where each expert's
         --  run begins in Listed and how long it is.
         Listed : Choice_List (0 .. Natural (Count) * Used - 1);
         Starts : array (0 .. Many - 1) of Natural := [others => 0];
         Counts : array (0 .. Many - 1) of Natural := [others => 0];
         Filled : Natural := 0;
         Active : array (0 .. Many - 1) of Natural;
         Active_Count : Natural := 0;

         --  The items of the job: an expert's members in runs of at
         --  most Chunk_Size, so that a run is about the same work as
         --  the next whatever the expert. Dealt whole, an expert
         --  chosen by eighty positions beside one chosen by two left
         --  the pool half idle -- the shares are cut by count -- and
         --  the samples said so: as many workers waiting for a share
         --  as in a kernel. In runs, the shares are level to a run.
         --
         --  Order says which run each item of the job is, the runs
         --  dealt into the shares largest first and back and forth.
         Chunk_Size : constant Positive :=
           (if Settings.Kind /= Inkling2_Loop then 16
            elsif Reference_Arithmetic then (if Count <= 16 then 4 elsif Count < 64 then 16 else 32)
            elsif Count <= 16 then 4 elsif Count < 64 then 8 else 16);

         type Cost_Table is array (Natural range <>) of Interfaces.Unsigned_64;
         Expert_Bytes : Cost_Table (0 .. Many) := [others => 1];
         Least_Bytes : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;

         function Weight_Bytes (Weight : T.View) return Interfaces.Unsigned_64 is
           (Interfaces.Unsigned_64 (Weight.Rows) * Interfaces.Unsigned_64 (T.Row_Bytes (Weight)));

         function Format_Chunk (Which : Natural) return Positive is
           (if not Reference_Arithmetic or else Which >= Many then Chunk_Size
            elsif Counts (Which) <= 4 then Positive'Max (1, Counts (Which))
            elsif Counts (Which) <= 8 then 4
            elsif Current.Experts (Which).Gate.Format in Model_Runner.GGUF.Type_Q4_K
              | Model_Runner.GGUF.Type_Q5_K | Model_Runner.GGUF.Type_Q6_K
              then (if Counts (Which) <= 16 or else Count < 64 then 8 else 16)
            elsif Width > 4096 then Positive'Min (16, Chunk_Size)
            else Chunk_Size);

         function Chunk_For (Which : Natural) return Positive is
           (if Settings.Kind /= Inkling2_Loop then Chunk_Size
            else Positive (Interfaces.Unsigned_64'Max (1, Interfaces.Unsigned_64'Min
              (Interfaces.Unsigned_64 (Format_Chunk (Which)),
               Interfaces.Unsigned_64 (Format_Chunk (Which)) * Least_Bytes / Expert_Bytes (Which)))));

         --  And the shared expert's, one for every Chunk_Size rows of
         --  the batch, its number being Many: the expert past the last.
         Dealing_Shared : constant Boolean :=
           T.Is_Present (Current.Shared_Gate) and then not Given_Shared
           and then not Shared_Apart and then not Shared_Split;

         --  A token's shared expert cut by rows: the item numbers past
         --  the shared expert's own, a half its start.
         Split_Gate_Up : constant Natural := Many + 1;
         Split_Down    : constant Natural := Many + 2;

         Most_Chunks : constant Natural :=
           Natural (Count) * Used + Many + Natural (Count) + 4;

         Chunk_Expert : array (0 .. Most_Chunks - 1) of Natural;
         Chunk_Start  : array (0 .. Most_Chunks - 1) of Natural;
         Chunk_Count  : array (0 .. Most_Chunks - 1) of Natural;
         Chunks       : Natural := 0;

         Order  : array (0 .. Most_Chunks - 1) of Natural;
         Widest : Natural := 0;

         --  The layer's rows quantized once, for the gates and ups to
         --  gather out of: one packing where every expert's gate and up
         --  want the same sums, two where a mixture's formats differ in
         --  that. Where the pool does not quantize, neither is packed
         --  and the rows go to the products as they are.
         Packed_Super : Workers_CPU.Packed_Rows renames Item.Mixture_Super;
         Packed_Plain : Workers_CPU.Packed_Rows renames Item.Mixture_Plain;
         Has_Super    : Boolean := False;
         Has_Plain    : Boolean := False;

         type Prepared_Expert_List is array (Positive range <>) of Expert;
         Prepared : Prepared_Expert_List
           (1 .. (if Settings.Kind = Inkling2_Loop then Many else 0));
         Prepared_Ready : Boolean := False;

         function Metadata_Slot (Which, Arm : Natural) return Natural is
           (Settings.Layers * (Inkling_Weight_Role'Pos (Inkling_Weight_Role'Last) + 1)
            + (Current.Number * Settings.Experts + Which) * 3 + Arm);

         function With_Metadata (Weight : T.View; Which, Arm : Natural) return T.View is
            Result : T.View := Weight;
         begin
            if Reference_Arithmetic and then Item.Arithmetic (T.Role_Feed_Forward)
              and then Workers_CPU.Byte_Products
              and then Item.Inkling_Scale_Data /= null
            then Result.Scales := Item.Inkling_Scale_Data (Metadata_Slot (Which, Arm)); end if;
            return Result;
         end With_Metadata;

         --  Scores depend on this visit's routes and policy state, which
         --  are fixed until all metadata admission finishes before workers.
         Score_Ready : array (0 .. Many * 3 - 1) of Boolean := [others => False];
         Scores : Cost_Table (0 .. Many * 3 - 1) := [others => 0];
         function Metadata_Priority (Expert, Part : Natural) return Interfaces.Unsigned_64 is
            Index : constant Natural := Expert * 3 + Part;
         begin
            if not Score_Ready (Index) then
               declare
                  W : constant T.View := (case Part is
                    when 0 => Current.Experts (Expert).Gate,
                    when 1 => Current.Experts (Expert).Up,
                    when others => Current.Experts (Expert).Down);
                  Fields : constant Interfaces.Unsigned_64 :=
                    (if W.Format = Model_Runner.GGUF.Type_Q6_K then 5 else 6);
                  Operations : constant Interfaces.Unsigned_64 :=
                    (if W.Format = Model_Runner.GGUF.Type_Q6_K then 20 else 48);
                  Uses : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Counts (Expert)) * 1024
                    + Expert_Cache.Score (Item.Expert_Policy, Current.Number, Expert);
               begin
                  Scores (Index) := (if T.Reference_Scale_Count (W) = 0 then 0
                                     else Uses * Operations * 1024 / (Fields * 4));
                  Score_Ready (Index) := True;
               end;
            end if;
            return Scores (Index);
         end Metadata_Priority;

         procedure Prepare_Metadata (Weight : T.View; Which, Arm : Natural) is
            Size : constant Element_Count := T.Reference_Scale_Count (Weight);
            Slot : constant Natural := Metadata_Slot (Which, Arm);
            Limit : constant Interfaces.Unsigned_64 := 128 * 1024 * 1024;
            Share : constant Interfaces.Unsigned_64 :=
              Limit / Interfaces.Unsigned_64 (Settings.Inkling.End_Layer - Settings.Inkling.First_Layer);
            Floor : constant Interfaces.Unsigned_64 := Share / 2;
            Cap : constant Interfaces.Unsigned_64 := Share * 2;
            Needed : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Size) * 4;
            Base : constant Natural := Settings.Layers
              * (Inkling_Weight_Role'Pos (Inkling_Weight_Role'Last) + 1);
            Buffer : T.Real_Array_Access := null;
            Value, Lowest, Reserved : Interfaces.Unsigned_64;
            Victim : Natural;
            Found : Boolean;
            function Room return Boolean is
            begin
               Reserved := 0;
               for Layer in Settings.Inkling.First_Layer .. Settings.Inkling.End_Layer - 1 loop
                  if Layer /= Current.Number and then Item.Inkling_Layer_Scale_Bytes (Layer) < Floor then
                     Reserved := Reserved + Floor - Item.Inkling_Layer_Scale_Bytes (Layer);
                  end if;
               end loop;
               return Needed <= Cap - Interfaces.Unsigned_64'Min
                 (Cap, Item.Inkling_Layer_Scale_Bytes (Current.Number))
                 and then Reserved <= Limit - Item.Inkling_Scale_Bytes
                 and then Needed <= Limit - Item.Inkling_Scale_Bytes - Reserved;
            end Room;
         begin
            if not Reference_Arithmetic or else not Item.Arithmetic (T.Role_Feed_Forward)
              or else not Workers_CPU.Byte_Products or else Item.Inkling_Scale_Data = null
              or else Size = 0
              or else Current.Number not in Settings.Inkling.First_Layer .. Settings.Inkling.End_Layer - 1
              or else Needed > Cap
            then return; end if;
            Value := Metadata_Priority (Which, Arm);
            Item.Inkling_Scale_Priorities (Slot) := Value;
            if Item.Inkling_Scale_Data (Slot) /= null then return; end if;
            while not Room loop
               Found := False; Lowest := Value; Victim := 0;
               for Layer in Settings.Inkling.First_Layer .. Settings.Inkling.End_Layer - 1 loop
                  for Expert in 0 .. Many - 1 loop
                     if Layer /= Current.Number or else Expert /= Which then
                        for Part in 0 .. 2 loop
                           declare
                              Candidate : constant Natural := Base + (Layer * Many + Expert) * 3 + Part;
                           begin
                              if Item.Inkling_Scale_Data (Candidate) /= null then
                                 declare
                                    Bytes : constant Interfaces.Unsigned_64 :=
                                      Interfaces.Unsigned_64 (Item.Inkling_Scale_Data (Candidate).all'Length) * 4;
                                    Score : constant Interfaces.Unsigned_64 :=
                                      (if Layer = Current.Number then Metadata_Priority (Expert, Part)
                                       else Item.Inkling_Scale_Priorities (Candidate));
                                 begin
                                    if (Layer = Current.Number or else
                                         Item.Inkling_Layer_Scale_Bytes (Layer) >= Floor + Bytes)
                                      and then (Item.Inkling_Layer_Scale_Bytes (Current.Number) + Needed <= Cap
                                                or else Layer = Current.Number)
                                      and then Score < Lowest
                                    then Found := True; Lowest := Score; Victim := Candidate; end if;
                                 end;
                              end if;
                           end;
                        end loop;
                     end if;
                  end loop;
               end loop;
               exit when not Found;
               declare
                  Owner : constant Natural := (Victim - Base) / (Many * 3);
                  Bytes : constant Interfaces.Unsigned_64 :=
                    Interfaces.Unsigned_64 (Item.Inkling_Scale_Data (Victim).all'Length) * 4;
               begin
                  Item.Inkling_Layer_Scale_Bytes (Owner) := Item.Inkling_Layer_Scale_Bytes (Owner) - Bytes;
                  Item.Inkling_Scale_Bytes := Item.Inkling_Scale_Bytes - Bytes;
                  T.Free (Item.Inkling_Scale_Data (Victim));
               end;
            end loop;
            if not Room then return; end if;
            T.Allocate (Size, Buffer);
            if Buffer = null then return; end if;
            T.Decode_Reference_Scales (Weight, Buffer.all, Status);
            if E.Is_Error (Status) then T.Free (Buffer); return; end if;
            Item.Inkling_Scale_Data (Slot) := Buffer;
            Item.Inkling_Layer_Scale_Bytes (Current.Number) := Item.Inkling_Layer_Scale_Bytes (Current.Number) + Needed;
            Item.Inkling_Scale_Bytes := Item.Inkling_Scale_Bytes + Needed;
         end Prepare_Metadata;

         Residents_Done : Boolean := False;
         procedure Run_Resident (Result : out E.Error_Info) is
         begin
            Result := E.Success;
            Residents_Done := True;
            if Reference_Arithmetic then
               declare
                  Finished : Expert_Flags (Resident_Experts'Range) := [others => False];
                  Gates, Ups, Downs : T.View_Group (1 .. 10);
                  Inputs, Outputs : T.Target_Group (1 .. 10);
                  Experts : array (1 .. 10) of Natural;
                  Grouped : Natural;
               begin
                  Ensure (Item.Gather_In, Count * Width * Element_Count (Used));
                  Ensure (Item.Gather_Out, Count * Width * Element_Count (Used));
                  if Item.Gather_In = null or else Item.Gather_Out = null then
                     Result := E.Make (E.Memory_Allocation_Failed); return;
                  end if;
                  for Which in Resident_Experts'Range loop
                     if Resident_Experts (Which) and then Counts (Which) > 0 and then not Finished (Which) then
                        declare
                           Held : constant Element_Count := Element_Count (Counts (Which));
                        begin
                           Grouped := 0;
                           for Other in Which .. Resident_Experts'Last loop
                              if Resident_Experts (Other) and then Counts (Other) = Counts (Which)
                                and then not Finished (Other)
                              then
                                 Grouped := Grouped + 1; Experts (Grouped) := Other; Finished (Other) := True;
                                 Device_Expert_Views (Current, Other, Feed, Width,
                                   Gates (Grouped), Ups (Grouped), Downs (Grouped), Result);
                                 if E.Is_Error (Result) then return; end if;
                                 declare
                                    First : constant Element_Count := Element_Count (Grouped - 1) * Held * Width;
                                 begin
                                    Inputs (Grouped) := Item.Gather_In.all (First .. First + Held * Width - 1)
                                      'Unrestricted_Access;
                                    Outputs (Grouped) := Item.Gather_Out.all (First .. First + Held * Width - 1)
                                      'Unrestricted_Access;
                                    for Member in 0 .. Counts (Other) - 1 loop
                                       declare
                                          Pick : constant Natural := Listed (Starts (Other) + Member);
                                          At_Row : constant Element_Count := Element_Count (Pick / Used) * Width;
                                       begin
                                          Inputs (Grouped).all (First + Element_Count (Member) * Width
                                            .. First + Element_Count (Member + 1) * Width - 1) :=
                                            Rows.all (Rows.all'First + At_Row .. Rows.all'First + At_Row + Width - 1);
                                       end;
                                    end loop;
                                 end;
                                 exit when Grouped = 10;
                              end if;
                           end loop;
                           if Grouped = 1 then
                              Model_Runner.Backend.Device.Dispatch_Reference_Expert
                                (Gates (1), Ups (1), Downs (1), Inputs (1), Held, Outputs (1),
                                 Settings.Inkling.Gate_Softcap, Settings.Inkling.Up_Softcap, Result, Item.Stopping);
                           else
                           Model_Runner.Backend.Device.Dispatch_Reference_Experts
                             (Gates (1 .. Grouped), Ups (1 .. Grouped), Downs (1 .. Grouped),
                              Inputs (1 .. Grouped), Held, Outputs (1 .. Grouped),
                              Settings.Inkling.Gate_Softcap, Settings.Inkling.Up_Softcap, Result, Item.Stopping);
                           end if;
                           if E.Is_Error (Result) then return; end if;
                           Item.Expert_Cache_Device_Runs := Item.Expert_Cache_Device_Runs + 1;
                           for Group in 1 .. Grouped loop
                              for Member in 0 .. Counts (Experts (Group)) - 1 loop
                                 declare
                                    Pick : constant Natural := Listed (Starts (Experts (Group)) + Member);
                                    From : constant Element_Count := Outputs (Group).all'First
                                      + Element_Count (Member) * Width;
                                    Into : constant Element_Count := Item.Ranked.all'First
                                      + Element_Count (Pick) * Width;
                                 begin
                                    Item.Ranked.all (Into .. Into + Width - 1) :=
                                      Outputs (Group).all (From .. From + Width - 1);
                                 end;
                              end loop;
                           end loop;
                        end;
                     end if;
                  end loop;
               end;
               return;
            end if;
         --  The experts admitted from spare device budget were omitted
         --  from the pool's job.  Run each once over all positions that
         --  chose it, using its individually resident slices rather than
         --  uploading the layer's complete stacks.
         for Which in Resident_Experts'Range loop
            if Resident_Experts (Which) and then Counts (Which) > 0 then
               declare
                  Gate, Up, Down : T.View;
                  Trouble        : E.Error_Info;
                  Held           : constant Element_Count :=
                    Element_Count (Counts (Which));
               begin
                  Device_Expert_Views
                    (Current, Which, Feed, Width, Gate, Up, Down, Trouble);
                  if E.Is_Error (Trouble) then
                     Result := Trouble;
                     return;
                  end if;

                  for Index in 0 .. Counts (Which) - 1 loop
                     declare
                        Pick : constant Natural :=
                          Listed (Starts (Which) + Index);
                        Where : constant Element_Count :=
                          Element_Count (Pick / Used);
                        From : constant Element_Count :=
                          Rows.all'First + Where * Width;
                        Into : constant Element_Count :=
                          Item.Gather_In.all'First
                          + Element_Count (Index) * Width;
                     begin
                        Item.Gather_In.all (Into .. Into + Width - 1) :=
                          Rows.all (From .. From + Width - 1);
                     end;
                  end loop;

                  if Reference_Arithmetic then
                     Model_Runner.Backend.Device.Dispatch_Reference_Expert
                       (Gate, Up, Down, Item.Gather_In, Held, Item.Gather_Out,
                        Settings.Inkling.Gate_Softcap, Settings.Inkling.Up_Softcap, Result, Item.Stopping);
                  else
                  Model_Runner.Backend.Device.Dispatch_Expert
                    (Gate, Up, Down, Feed, Width, 0,
                     Gate_Unit (Item.Owner.all),
                     Item.Gather_In, Held, Item.Gather_Out, Result,
                     Item.Stopping,
                     Alpha => Settings.Gate_Alpha,
                     Limit => Settings.Gate_Limit);
                  end if;
                  if E.Is_Error (Result) then
                     return;
                  end if;
                  Item.Expert_Cache_Device_Runs :=
                    Item.Expert_Cache_Device_Runs + 1;

                  for Index in 0 .. Counts (Which) - 1 loop
                     declare
                        Pick : constant Natural :=
                          Listed (Starts (Which) + Index);
                        From : constant Element_Count :=
                          Item.Gather_Out.all'First
                          + Element_Count (Index) * Width;
                        Into : constant Element_Count :=
                          Item.Ranked.all'First
                          + Element_Count (Pick) * Width;
                     begin
                        Item.Ranked.all (Into .. Into + Width - 1) :=
                          Item.Gather_Out.all (From .. From + Width - 1);
                     end;
                  end loop;
               end;
            end if;
         end loop;
         end Run_Resident;

         type Expert_Share is limited new Workers_CPU.Task_Item with
            record
               Ok   : Boolean := True;

               --  The next item a worker takes, largest first: taken as
               --  each worker comes free rather than dealt out before, so
               --  that no worker waits on another's long run of experts.
               --  Dealt, a drafted round's check of four positions -- a
               --  score of experts of one to four positions each --
               --  took its slowest share 2.3 ms a layer where the whole
               --  of the work was 1.4 ms a worker.
               Next : aliased Take_Counter := 0;
               Scratch_Next : aliased Take_Counter := 0;

               --  The halves of a split shared expert's gate and up
               --  that are done, which its down waits for.
               Shared_Done : aliased Take_Counter := 0;
            end record;

         overriding procedure Run
           (Share : in out Expert_Share;
            From  : Element_Count;
            To    : Element_Count);

         overriding procedure Run
           (Share : in out Expert_Share;
            From  : Element_Count;
            To    : Element_Count)
         is
            Local : E.Error_Info;

            --  Room for the widest expert, taken once a share rather
            --  than once an expert.
            Slot : constant Natural := 4 * Natural (Takes.Atomic_Fetch_And_Add (Share.Scratch_Next, 1));
            In_Room : T.Real_Array_Access renames Item.Expert_Work (Slot);
            A_Room : T.Real_Array_Access renames Item.Expert_Work (Slot + 1);
            B_Room : T.Real_Array_Access renames Item.Expert_Work (Slot + 2);
            Out_Room : T.Real_Array_Access renames Item.Expert_Work (Slot + 3);
            Packed_In : Workers_CPU.Packed_Rows renames Item.Expert_Packed (Slot / 2);
            Packed_Down : Workers_CPU.Packed_Rows renames Item.Expert_Packed (Slot / 2 + 1);
            procedure Activate (Gate : in out Real_Array; Up : Real_Array; Peaks : out Real_Array) is
            begin
               Expert_Activation (Item.Owner.all, Gate, Up, Reference_Arithmetic,
                                  Block_Peaks => Peaks'Unrestricted_Access);
            end Activate;
            procedure Activate_Super (First : Element_Count; Into : out Real_Array) is
            begin
               Into := A_Room.all (A_Room.all'First + First .. A_Room.all'First + First + Into'Length - 1);
               Expert_Activation
                 (Item.Owner.all, Into,
                  B_Room.all (B_Room.all'First + First .. B_Room.all'First + First + Into'Length - 1), True);
            end Activate_Super;
         begin
            Ensure (In_Room, Element_Count (Widest) * Width);
            Ensure (A_Room, Element_Count (Widest) * Element_Count'Max (Feed, Shared_Feed));
            Ensure (B_Room, Element_Count (Widest) * Element_Count'Max (Feed, Shared_Feed));
            Ensure (Out_Room, Element_Count (Widest) * Width);

            if In_Room = null or else A_Room = null
              or else B_Room = null or else Out_Room = null
            then
               Share.Ok := False;
            end if;

            loop
               declare
                  --  Which item this worker takes next, whatever range
                  --  the pool cut for it: every worker takes until none
                  --  are left.
                  Index_Of : constant Natural :=
                    Natural (Takes.Atomic_Fetch_And_Add (Share.Next, 1));
               begin
                  exit when Index_Of >= Chunks;
                  if Chunk_Expert (Order (Index_Of)) = Split_Gate_Up then
                     --  Half of the shared expert's gate and up rows and
                     --  the gated middle over them, into its row; told
                     --  done whatever came of it, since its down waits.
                     if Share.Ok then
                        declare
                           Half : constant Element_Count :=
                             Element_Count (Settings.Shared_Feed) / 2;
                           Start : constant Element_Count :=
                             Element_Count
                               (Chunk_Start (Order (Index_Of))) * Half;
                           Picked : constant Model_Runner.Shares.Member_Rows
                             (0 .. 0) := [0];
                           Arms : constant T.View_Group :=
                             [Row_Slice (Current.Shared_Gate, Start, Half),
                              Row_Slice (Current.Shared_Up, Start, Half)];
                           Into : constant T.Group_Room :=
                             [A_Room, B_Room];
                           Done : Boolean;
                        begin
                           In_Room.all (In_Room.all'First
                                        .. In_Room.all'First + Width - 1)
                             := Rows.all (Rows.all'First
                                          .. Rows.all'First + Width - 1);

                           for Arm in Arms'Range loop
                              Done := False;
                              if Supers (Arms (Arm)) and then Has_Super then
                                 Workers_CPU.Multiply_Packed
                                   (Arms (Arm), Packed_Super, Picked,
                                    Into (Arm), Done);
                              elsif not Supers (Arms (Arm))
                                and then Has_Plain
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Arms (Arm), Packed_Plain, Picked,
                                    Into (Arm), Done);
                              end if;

                              if not Done then
                                 Workers_CPU.Dispatch_Batch
                                   (null, Arms (Arm), In_Room, 1,
                                    Into (Arm), Local,
                                    Roles => Item.Arithmetic);
                                 if E.Is_Error (Local) then
                                    Share.Ok := False;
                                 end if;
                              end if;
                           end loop;

                           declare
                              Gate_Part : T.Real_Array renames
                                A_Room.all (A_Room.all'First
                                            .. A_Room.all'First + Half - 1);
                              Up_Part : T.Real_Array renames
                                B_Room.all (B_Room.all'First
                                            .. B_Room.all'First + Half - 1);
                           begin
                              K.SiLU (Gate_Part);
                              K.Multiply (Gate_Part, Up_Part);
                              Item.Shared_Rows_A.all
                                (Item.Shared_Rows_A.all'First + Start
                                 .. Item.Shared_Rows_A.all'First + Start
                                    + Half - 1) := Gate_Part;
                           end;
                        end;
                     end if;

                     declare
                        Unused : constant Take_Counter :=
                          Takes.Atomic_Fetch_And_Add (Share.Shared_Done, 1);
                     begin
                        null;
                     end;
                  elsif Chunk_Expert (Order (Index_Of)) = Split_Down then
                     --  Half of the shared expert's down rows, once both
                     --  halves of its middle are in: they were taken
                     --  before every expert, so the wait is short.
                     while Takes.Atomic_Fetch_And_Add (Share.Shared_Done, 0)
                           < 2
                     loop
                        null;
                     end loop;

                     if Share.Ok then
                        declare
                           Half : constant Element_Count := Width / 2;
                           Start : constant Element_Count :=
                             Element_Count
                               (Chunk_Start (Order (Index_Of))) * Half;
                        begin
                           Workers_CPU.Dispatch_Batch
                             (null, Row_Slice (Current.Shared_Down, Start, Half),
                              Item.Shared_Rows_A, 1, Out_Room, Local,
                              Roles => Item.Arithmetic);
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           else
                              Item.Shared_Rows_Out.all
                                (Item.Shared_Rows_Out.all'First + Start
                                 .. Item.Shared_Rows_Out.all'First + Start
                                    + Half - 1) :=
                                Out_Room.all (Out_Room.all'First
                                              .. Out_Room.all'First
                                                 + Half - 1);
                           end if;
                        end;
                     end if;
                  elsif Share.Ok and then Chunk_Expert (Order (Index_Of)) = Many
                  then
                     --  The shared expert over a run of the batch's rows:
                     --  the same three products an expert is, over the
                     --  rows themselves rather than a gathering of them,
                     --  and its answer put where the sums below read the
                     --  shared expert's -- a row's own place, at its gate.
                     declare
                        Chunk : constant Natural := Order (Index_Of);
                        Start : constant Natural := Chunk_Start (Chunk);
                        Members_Held : constant Natural :=
                          Chunk_Count (Chunk);
                        Held : constant Element_Count :=
                          Element_Count (Members_Held);
                        Picked : Model_Runner.Shares.Member_Rows
                          (0 .. Members_Held - 1);
                        Done   : Boolean;
                     begin
                        for Index in 0 .. Members_Held - 1 loop
                           declare
                              At_In : constant Element_Count :=
                                Rows.all'First
                                + Element_Count (Start + Index) * Width;
                              At_Room : constant Element_Count :=
                                In_Room.all'First
                                + Element_Count (Index) * Width;
                           begin
                              In_Room.all (At_Room .. At_Room + Width - 1)
                                := Rows.all (At_In .. At_In + Width - 1);
                              Picked (Index) := Start + Index;
                           end;
                        end loop;

                        Done := False;
                        if Supers (Current.Shared_Gate) and then Has_Super
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Gate, Packed_Super, Picked,
                              A_Room, Done);
                        elsif not Supers (Current.Shared_Gate)
                          and then Has_Plain
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Gate, Packed_Plain, Picked,
                              A_Room, Done);
                        end if;

                        if not Done then
                           Workers_CPU.Dispatch_Batch
                             (null, Current.Shared_Gate, In_Room, Held,
                              A_Room, Local, Roles => Item.Arithmetic);
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           end if;
                        end if;

                        Done := False;
                        if Supers (Current.Shared_Up) and then Has_Super
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Up, Packed_Super, Picked,
                              B_Room, Done);
                        elsif not Supers (Current.Shared_Up)
                          and then Has_Plain
                        then
                           Workers_CPU.Multiply_Packed
                             (Current.Shared_Up, Packed_Plain, Picked,
                              B_Room, Done);
                        end if;

                        if not Done then
                           Workers_CPU.Dispatch_Batch
                             (null, Current.Shared_Up, In_Room, Held,
                              B_Room, Local, Roles => Item.Arithmetic);
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           end if;
                        end if;

                        --  The gated middle, as the batch off the pool
                        --  and one position both take it: the logistic
                        --  unit, whatever the experts' own is.
                        K.SiLU (A_Room.all (A_Room.all'First
                                            .. A_Room.all'First
                                               + Held * Shared_Feed - 1));
                        K.Multiply
                          (A_Room.all (A_Room.all'First
                                       .. A_Room.all'First
                                          + Held * Shared_Feed - 1),
                           B_Room.all (B_Room.all'First
                                       .. B_Room.all'First
                                          + Held * Shared_Feed - 1));

                        Workers_CPU.Dispatch_Batch
                          (null, Current.Shared_Down, A_Room, Held,
                           Out_Room, Local, Roles => Item.Arithmetic);
                        if E.Is_Error (Local) then
                           Share.Ok := False;
                        end if;

                        for Index in 0 .. Members_Held - 1 loop
                           declare
                              From_At : constant Element_Count :=
                                Out_Room.all'First
                                + Element_Count (Index) * Width;
                              Into : constant Element_Count :=
                                Item.Shared_Rows_Out.all'First
                                + Element_Count (Start + Index) * Width;
                           begin
                              Item.Shared_Rows_Out.all
                                (Into .. Into + Width - 1) :=
                                Out_Room.all (From_At .. From_At + Width - 1);
                           end;
                        end loop;
                     end;
                  elsif Share.Ok then
                     declare
                        Chunk : constant Natural := Order (Index_Of);
                        Which : constant Natural := Chunk_Expert (Chunk);
                        Start : constant Natural := Chunk_Start (Chunk);
                        Members_Held : constant Natural :=
                          Chunk_Count (Chunk);

                        Held : constant Element_Count :=
                          Element_Count (Members_Held);

                        Expert_At : constant Expert :=
                          (if Prepared_Ready then Prepared (Which + 1) else Current.Experts.all (Which));
                        Fused_Down : constant Boolean := Reference_Arithmetic
                          and then Current.Expert_Gate_Bias = null and then Current.Expert_Up_Bias = null
                          and then Expert_At.Down.Format in Model_Runner.GGUF.Type_Q8_0 | Model_Runner.GGUF.Type_Q5_0
                            | Model_Runner.GGUF.Type_Q4_K | Model_Runner.GGUF.Type_Q5_K
                            | Model_Runner.GGUF.Type_Q6_K
                          and then Item.Arithmetic (T.Role_Feed_Forward);
                        Direct_Down : Boolean := False;
                     begin
                        begin
                           --  The two arms from the packed rows where
                           --  the pool packed them, gathered by member,
                           --  and from the rows as they are otherwise.
                           declare
                              Picked : Model_Runner.Shares.Member_Rows
                                (0 .. Members_Held - 1);
                              Done   : Boolean;
                              Pair_Done : Boolean := False;
                              Gathered_Input : Boolean := False;
                              procedure Gather_Input is
                              begin
                                 if Gathered_Input then return; end if;
                                 for Index in 0 .. Members_Held - 1 loop
                                    declare
                                       Pick : constant Natural :=
                                         Listed (Start + Index);
                                       Where : constant Element_Count :=
                                         Element_Count (Pick / Used);
                                       At_In : constant Element_Count :=
                                         Rows.all'First + Where * Width;
                                       At_Room : constant Element_Count :=
                                         In_Room.all'First
                                         + Element_Count (Index) * Width;
                                    begin
                                       In_Room.all (At_Room .. At_Room + Width - 1)
                                         := Rows.all (At_In .. At_In + Width - 1);
                                    end;
                                 end loop;

                                 Gathered_Input := True;
                              end Gather_Input;

                           begin
                              for Index in Picked'Range loop
                                 Picked (Index) :=
                                   Listed (Start + Index) / Used;
                              end loop;

                              if Supers (Expert_At.Gate) and then Supers (Expert_At.Up) and then Has_Super then
                                 Workers_CPU.Multiply_Packed_Pair
                                   (Expert_At.Gate, Expert_At.Up, Packed_Super, Picked,
                                    A_Room, B_Room, Packed_In, Pair_Done);
                              elsif not Supers (Expert_At.Gate) and then not Supers (Expert_At.Up)
                                and then Has_Plain
                              then
                                 Workers_CPU.Multiply_Packed_Pair
                                   (Expert_At.Gate, Expert_At.Up, Packed_Plain, Picked,
                                    A_Room, B_Room, Packed_In, Pair_Done);
                              end if;
                              if not Pair_Done then
                              Done := False;
                              if Supers (Expert_At.Gate) and then Has_Super
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Gate, Packed_Super, Picked,
                                    A_Room, Done);
                              elsif not Supers (Expert_At.Gate)
                                and then Has_Plain
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Gate, Packed_Plain, Picked,
                                    A_Room, Done);
                              end if;

                              if not Done then
                                 if Settings.Kind = Inkling2_Loop
                                   and then (for all Role of Item.Arithmetic => not Role)
                                   and then not Expert_At.Gate.Interleaved
                                 then
                                    Local := E.Success;
                                    T.Mat_Mul_Range
                                      (Expert_At.Gate, Rows.all, Held, A_Room.all,
                                       0, Expert_At.Gate.Rows - 1, Members => Picked);
                                 else
                                 Gather_Input;
                                 Workers_CPU.Dispatch_Batch
                                   (null, Expert_At.Gate, In_Room, Held,
                                    A_Room, Local, Roles => Item.Arithmetic);
                                 end if;
                                 if E.Is_Error (Local) then
                                    Share.Ok := False;
                                 end if;
                              end if;

                              Done := False;
                              if Supers (Expert_At.Up) and then Has_Super
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Up, Packed_Super, Picked,
                                    B_Room, Done);
                              elsif not Supers (Expert_At.Up)
                                and then Has_Plain
                              then
                                 Workers_CPU.Multiply_Packed
                                   (Expert_At.Up, Packed_Plain, Picked,
                                    B_Room, Done);
                              end if;

                              if not Done then
                                 if Settings.Kind = Inkling2_Loop
                                   and then (for all Role of Item.Arithmetic => not Role)
                                   and then not Expert_At.Up.Interleaved
                                 then
                                    Local := E.Success;
                                    T.Mat_Mul_Range
                                      (Expert_At.Up, Rows.all, Held, B_Room.all,
                                       0, Expert_At.Up.Rows - 1, Members => Picked);
                                 else
                                 Gather_Input;
                                 Workers_CPU.Dispatch_Batch
                                   (null, Expert_At.Up, In_Room, Held,
                                    B_Room, Local, Roles => Item.Arithmetic);
                                 end if;
                                 if E.Is_Error (Local) then
                                    Share.Ok := False;
                                 end if;
                              end if;
                              end if;
                           end;

                           for Index in 0 .. Members_Held - 1 loop
                              declare
                                 At_Arm : constant Element_Count :=
                                   Element_Count (Index) * Feed;

                                 Gate_Part : T.Real_Array renames
                                   A_Room.all
                                     (A_Room.all'First + At_Arm
                                      .. A_Room.all'First + At_Arm + Feed
                                         - 1);

                                 Up_Part : T.Real_Array renames
                                   B_Room.all
                                     (B_Room.all'First + At_Arm
                                      .. B_Room.all'First + At_Arm + Feed
                                         - 1);

                                 At_Feed : constant Element_Count :=
                                   Element_Count (Which) * Feed;
                              begin
                                 if Current.Expert_Gate_Bias /= null then
                                    K.Add
                                      (Gate_Part,
                                       Current.Expert_Gate_Bias.all
                                         (Current.Expert_Gate_Bias.all'First
                                            + At_Feed
                                          .. Current.Expert_Gate_Bias.all'First
                                             + At_Feed + Feed - 1));
                                    K.Add
                                      (Up_Part,
                                       Current.Expert_Up_Bias.all
                                         (Current.Expert_Up_Bias.all'First
                                            + At_Feed
                                          .. Current.Expert_Up_Bias.all'First
                                             + At_Feed + Feed - 1));
                                 end if;

                                 if not Fused_Down then
                                    Expert_Activation (Item.Owner.all, Gate_Part, Up_Part, Reference_Arithmetic);
                                 end if;
                              end;
                           end loop;

                           if Fused_Down then
                              declare
                                 Done : Boolean;
                              begin
                                 Workers_CPU.Pack
                                   (Packed_Down, A_Room, Held, Feed, Supers (Expert_At.Down), Done,
                                    Roles => Item.Arithmetic, Reference_Arithmetic => True,
                                    Half_Scales => not Supers (Expert_At.Down),
                                    Produce => (if Supers (Expert_At.Down) then null else Activate'Unrestricted_Access),
                                    Up => B_Room,
                                    Transform => (if Supers (Expert_At.Down)
                                                  then Activate_Super'Unrestricted_Access else null));
                                 if Done then
                                    declare
                                       Destinations : Model_Runner.Shares.Member_Rows (0 .. Members_Held - 1);
                                    begin
                                       for I in Destinations'Range loop Destinations (I) := Listed (Start + I); end
                        loop;
                                       Workers_CPU.Multiply_Packed_Whole
                                         (Expert_At.Down, Packed_Down, Item.Ranked.all, Direct_Down, Destinations);
                                       if not Direct_Down then
                                          Workers_CPU.Multiply_Packed_Whole
                                            (Expert_At.Down, Packed_Down, Out_Room.all, Done);
                                       end if;
                                    end;
                                 end if;
                                 Local := (if Done then E.Success else E.Make (E.Memory_Allocation_Failed));
                              end;
                           else
                           Workers_CPU.Dispatch_Batch
                             (null, Expert_At.Down, A_Room, Held, Out_Room,
                              Local, Roles => Item.Arithmetic);
                           end if;
                           if E.Is_Error (Local) then
                              Share.Ok := False;
                           end if;

                           for Index in 0 .. Members_Held - 1 loop
                              declare
                                 Pick : constant Natural :=
                                   Listed (Start + Index);

                                 From_At : constant Element_Count :=
                                   Out_Room.all'First
                                   + Element_Count (Index) * Width;

                                 Into : constant Element_Count :=
                                   Item.Ranked.all'First
                                   + Element_Count (Pick) * Width;

                                 Mine : T.Real_Array renames
                                   Item.Ranked.all (Into .. Into + Width - 1);

                                 At_Wide : constant Element_Count :=
                                   Element_Count (Which) * Width;
                              begin
                                 if not Direct_Down then
                                 Mine := Out_Room.all
                                   (From_At .. From_At + Width - 1);
                                 end if;

                                 if Current.Expert_Down_Bias /= null then
                                    K.Add
                                      (Mine,
                                       Current.Expert_Down_Bias.all
                                         (Current.Expert_Down_Bias.all'First
                                            + At_Wide
                                          .. Current.Expert_Down_Bias.all'First
                                             + At_Wide + Width - 1));
                                 end if;
                              end;
                           end loop;
                        end;
                     end;
                  end if;
               end;
            end loop;

            if Settings.Kind /= Inkling2_Loop then
               Workers_CPU.Unpack (Packed_In); Workers_CPU.Unpack (Packed_Down);
               T.Free (In_Room); T.Free (A_Room); T.Free (B_Room); T.Free (Out_Room);
            end if;
         exception
            when others =>
               Workers_CPU.Unpack (Packed_In); Workers_CPU.Unpack (Packed_Down);
               raise;
         end Run;

         Share : aliased Expert_Share;
         Cache_Plan : constant Boolean := Reference_Arithmetic and then Count <= 16
           and then Item.Inkling_Plans /= null and then Item.Owner.Runtime_Pairs = null
           and then not T.Is_Present (Current.Shared_Gate)
           and then (for all Held of Resident_Experts => not Held)
           and then Model_Runner.Backend."=" (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_CPU);
         Plan_Hit : Boolean := False;
         procedure Save (Into : in out Choice_Access; Values : Choice_List) is
            procedure Release is new Ada.Unchecked_Deallocation (Choice_List, Choice_Access);
         begin
            if Into = null or else Into.all'Length /= Values'Length then
               Release (Into); Into := new Choice_List (Values'Range);
            end if;
            Into.all := Values;
         end Save;
      begin
         if Cache_Plan then
            declare
               Plan : Inkling_Route_Plan renames Item.Inkling_Plans (Item.Inkling_Plan_Slot);
            begin
               Plan_Hit := Plan.Count = Natural (Count) and then Plan.Choices /= null
                 and then Plan.Choices.all'Length = Natural (Count) * Used
                 and then (for all I in Plan.Choices.all'Range => Plan.Choices (I) = Item.Pick_Which (I));
               if Plan_Hit then
                  Item.Inkling_Plan_Hits := Item.Inkling_Plan_Hits + 1;
                  Filled := Plan.Filled; Active_Count := Plan.Active_Count;
                  for I in Listed'Range loop Listed (I) := Plan.Listed (I); end loop;
                  for I in Starts'Range loop Starts (I) := Plan.Starts (I); Counts (I) := Plan.Counts (I); end loop;
                  for I in 0 .. Active_Count - 1 loop Active (I) := Plan.Active (I); end loop;
               else Item.Inkling_Plan_Misses := Item.Inkling_Plan_Misses + 1; end if;
            end;
         end if;
         if not Plan_Hit then
         if Settings.Kind = Inkling2_Loop and then Count = 1 then
            declare
               Ranks : array (0 .. Used - 1) of Natural := [for I in 0 .. Used - 1 => I];
            begin
               for Outer in 1 .. Used - 1 loop
                  declare
                     Moving : constant Natural := Ranks (Outer);
                     Inner : Integer := Outer - 1;
                  begin
                     while Inner >= 0 and then Item.Pick_Which (Ranks (Inner)) > Item.Pick_Which (Moving) loop
                        Ranks (Inner + 1) := Ranks (Inner); Inner := Inner - 1;
                     end loop;
                     Ranks (Inner + 1) := Moving;
                  end;
               end loop;
               for Slot in Ranks'Range loop
                  declare
                     Which : constant Natural := Item.Pick_Which (Ranks (Slot));
                  begin
                     Counts (Which) := 1; Starts (Which) := Slot; Listed (Slot) := Ranks (Slot);
                     Active (Active_Count) := Which; Active_Count := Active_Count + 1;
                  end;
               end loop;
               Filled := Used;
            end;
         else
         --  Stable counting buckets: preserve token/selection-slot order
         --  within each expert without scanning all selections per expert.
         for Pick in 0 .. Natural (Count) * Used - 1 loop
            Counts (Item.Pick_Which.all (Pick)) := Counts (Item.Pick_Which.all (Pick)) + 1;
         end loop;
         for Which in Counts'Range loop
            if Counts (Which) > 0 then
               Active (Active_Count) := Which; Active_Count := Active_Count + 1;
            end if;
            Starts (Which) := Filled;
            Filled := Filled + Counts (Which);
         end loop;
         declare
            Next : array (Counts'Range) of Natural := [for Which in Counts'Range => Starts (Which)];
         begin
            for Pick in 0 .. Natural (Count) * Used - 1 loop
               declare
                  Which : constant Natural := Item.Pick_Which.all (Pick);
               begin
                  Listed (Next (Which)) := Pick;
                  Next (Which) := Next (Which) + 1;
               end;
            end loop;
         end;
         end if;

         end if;

         if Settings.Kind = Inkling2_Loop then
            for Index in 0 .. Active_Count - 1 loop
               declare
                  Which : constant Natural := Active (Index);
               begin
               if Counts (Which) > 0 and then not Resident_Experts (Which) then
                  Prepare_Metadata (Current.Experts (Which).Gate, Which, 0);
                  if E.Is_Error (Status) then return; end if;
                  Prepare_Metadata (Current.Experts (Which).Up, Which, 1);
                  if E.Is_Error (Status) then return; end if;
                  Prepare_Metadata (Current.Experts (Which).Down, Which, 2);
                  if E.Is_Error (Status) then return; end if;
                  Expert_Bytes (Which) := Interfaces.Unsigned_64'Max (1,
                    Weight_Bytes (Current.Experts (Which).Gate)
                    + Weight_Bytes (Current.Experts (Which).Up)
                    + Weight_Bytes (Current.Experts (Which).Down));
                  Least_Bytes := Interfaces.Unsigned_64'Min (Least_Bytes, Expert_Bytes (Which));
               end if;
               end;
            end loop;
            if Least_Bytes = Interfaces.Unsigned_64'Last then Least_Bytes := 1; end if;
            if Dealing_Shared then
               Expert_Bytes (Many) := Interfaces.Unsigned_64'Max (1,
                 Weight_Bytes (Current.Shared_Gate) + Weight_Bytes (Current.Shared_Up)
                 + Weight_Bytes (Current.Shared_Down));
            end if;
         end if;

         if Plan_Hit then
            declare
               Plan : Inkling_Route_Plan renames Item.Inkling_Plans (Item.Inkling_Plan_Slot);
            begin
               Chunks := Plan.Chunks; Widest := Plan.Widest;
               for I in 0 .. Chunks - 1 loop
                  Chunk_Expert (I) := Plan.Chunk_Expert (I); Chunk_Start (I) := Plan.Chunk_Start (I);
                  Chunk_Count (I) := Plan.Chunk_Count (I); Order (I) := Plan.Ordering (I);
               end loop;
            end;
         else
         --  The runs: each expert's members in Chunk_Size at a time.
         for Index in 0 .. Active_Count - 1 loop
            declare
               Which : constant Natural := Active (Index);
               Done : Natural := 0;
            begin
               while not Resident_Experts (Which)
                 and then Done < Counts (Which)
               loop
                  Chunk_Expert (Chunks) := Which;
                  Chunk_Start (Chunks) := Starts (Which) + Done;
                  Chunk_Count (Chunks) :=
                    Natural'Min (Chunk_For (Which), Counts (Which) - Done);
                  Widest := Natural'Max (Widest, Chunk_Count (Chunks));
                  Done := Done + Chunk_Count (Chunks);
                  Chunks := Chunks + 1;
               end loop;
            end;
         end loop;

         --  The rows packed once, for each kind of sums a gate or up
         --  in this layer wants.
         if Dealing_Shared then
            declare
               Done : Natural := 0;
            begin
               while Done < Natural (Count) loop
                  Chunk_Expert (Chunks) := Many;
                  Chunk_Start (Chunks) := Done;
                  Chunk_Count (Chunks) :=
                    Natural'Min (Chunk_For (Many), Natural (Count) - Done);
                  Widest := Natural'Max (Widest, Chunk_Count (Chunks));
                  Done := Done + Chunk_Count (Chunks);
                  Chunks := Chunks + 1;
               end loop;
            end;
         end if;

         end if;

         for Index in 0 .. Active_Count - 1 loop
            declare
               Which : constant Natural := Active (Index);
            begin
            if Counts (Which) > 0 and then not Resident_Experts (Which) then
               if Supers (Current.Experts.all (Which).Gate)
                 or else Supers (Current.Experts.all (Which).Up)
               then
                  Has_Super := True;
               end if;
               if not Supers (Current.Experts.all (Which).Gate)
                 or else not Supers (Current.Experts.all (Which).Up)
               then
                  Has_Plain := True;
               end if;
            end if;
            end;
         end loop;

         --  The split shared expert's four items: its gate and up
         --  halves, then its down halves.
         if Shared_Split then
            for Half in 0 .. 1 loop
               Chunk_Expert (Chunks) := Split_Gate_Up;
               Chunk_Start (Chunks) := Half;
               Chunk_Count (Chunks) := 1;
               Chunks := Chunks + 1;
            end loop;
            for Half in 0 .. 1 loop
               Chunk_Expert (Chunks) := Split_Down;
               Chunk_Start (Chunks) := Half;
               Chunk_Count (Chunks) := 1;
               Chunks := Chunks + 1;
            end loop;
            Widest := Natural'Max (Widest, 1);
         end if;

         if Dealing_Shared or else Shared_Split then
            if Supers (Current.Shared_Gate) or else Supers (Current.Shared_Up)
            then
               Has_Super := True;
            end if;
            if not Supers (Current.Shared_Gate)
              or else not Supers (Current.Shared_Up)
            then
               Has_Plain := True;
            end if;
         end if;

         if Has_Super then
            Workers_CPU.Pack
              (Packed_Super, Rows, Count, Width, True, Has_Super, Roles => Item.Arithmetic,
               Reference_Arithmetic => Reference_Arithmetic);
         end if;
         if Has_Plain then
            Workers_CPU.Pack
              (Packed_Plain, Rows, Count, Width, False, Has_Plain, Roles => Item.Arithmetic,
               Reference_Arithmetic => Reference_Arithmetic, Half_Scales => Reference_Arithmetic);
         end if;

         --  The experts by size, largest first, in the order the
         --  workers take them.
         if Chunks > 0 and then not Plan_Hit then
            declare
               type Chunk_Order is array (Natural range <>) of Natural;
               Sorted : Chunk_Order (0 .. Chunks - 1);
               Costs : Cost_Table (0 .. Chunks - 1);
               function Work_Cost (Index : Natural) return Interfaces.Unsigned_64 is
                 (if Settings.Kind /= Inkling2_Loop then Interfaces.Unsigned_64 (Chunk_Count (Index))
                  elsif Chunk_Expert (Index) <= Many then
                    Expert_Bytes (Chunk_Expert (Index))
                      * ((if Reference_Arithmetic then 0 else 1)
                         + Interfaces.Unsigned_64 ((Chunk_Count (Index) + 7) / 8))
                      + Interfaces.Unsigned_64 (Chunk_Count (Index)) * Interfaces.Unsigned_64 (Width + Feed) * 4
                  else Interfaces.Unsigned_64 (Chunk_Count (Index)));
            begin
               for Which in Sorted'Range loop
                  Sorted (Which) := Which; Costs (Which) := Work_Cost (Which);
               end loop;

               if Settings.Kind = Inkling2_Loop then
                  declare
                     Merged : Chunk_Order (Sorted'Range);
                     Run_Size : Natural := 1;
                  begin
                     while Run_Size < Chunks loop
                        declare
                           Left : Natural := 0;
                        begin
                           while Left < Chunks loop
                              declare
                                 Middle : constant Natural := Natural'Min (Left + Run_Size, Chunks);
                                 Right : constant Natural := Natural'Min (Middle + Run_Size, Chunks);
                                 I : Natural := Left;
                                 J : Natural := Middle;
                              begin
                                 for Into in Left .. Right - 1 loop
                                    if J >= Right or else
                                      (I < Middle and then Costs (Sorted (I)) >= Costs (Sorted (J)))
                                    then
                                       Merged (Into) := Sorted (I); I := I + 1;
                                    else
                                       Merged (Into) := Sorted (J); J := J + 1;
                                    end if;
                                 end loop;
                                 Left := Right;
                              end;
                           end loop;
                        end;
                        Sorted := Merged; Run_Size := Run_Size * 2;
                     end loop;
                  end;
               else
               for Outer in 1 .. Chunks - 1 loop
                  declare
                     Moving : constant Natural := Sorted (Outer);
                     Inner  : Integer := Outer - 1;
                  begin
                     while Inner >= 0
                       and then Costs (Sorted (Inner)) < Costs (Moving)
                     loop
                        Sorted (Inner + 1) := Sorted (Inner);
                        Inner := Inner - 1;
                     end loop;
                     Sorted (Inner + 1) := Moving;
                  end;
               end loop;

               end if;

               for Rank in Sorted'Range loop
                  Order (Rank) := Sorted (Rank);
               end loop;

               --  A split shared expert's gate and up halves first and its
               --  down halves last, the experts between, so that nothing
               --  takes a down half before both middles are taken.
               if Shared_Split then
                  declare
                     Placed : Natural := 0;
                  begin
                     for Pass in 1 .. 3 loop
                        for Rank in Sorted'Range loop
                           if (Pass = 1
                               and then Chunk_Expert (Sorted (Rank))
                                        = Split_Gate_Up)
                             or else (Pass = 2
                                      and then Chunk_Expert (Sorted (Rank))
                                               < Split_Gate_Up)
                             or else (Pass = 3
                                      and then Chunk_Expert (Sorted (Rank))
                                               = Split_Down)
                           then
                              Order (Placed) := Sorted (Rank);
                              Placed := Placed + 1;
                           end if;
                        end loop;
                     end loop;
                  end;
               end if;
            end;
         end if;

         if Cache_Plan and then not Plan_Hit then
            declare
               Plan : Inkling_Route_Plan renames Item.Inkling_Plans (Item.Inkling_Plan_Slot);
            begin
               Plan.Count := 0;
               Save (Plan.Choices, Item.Pick_Which.all (0 .. Natural (Count) * Used - 1));
               Save (Plan.Listed, Listed);
               Save (Plan.Starts, Choice_List (Starts)); Save (Plan.Counts, Choice_List (Counts));
               Save (Plan.Active, Choice_List (Active (0 .. Active_Count - 1)));
               Save (Plan.Chunk_Expert, Choice_List (Chunk_Expert (0 .. Chunks - 1)));
               Save (Plan.Chunk_Start, Choice_List (Chunk_Start (0 .. Chunks - 1)));
               Save (Plan.Chunk_Count, Choice_List (Chunk_Count (0 .. Chunks - 1)));
               Save (Plan.Ordering, Choice_List (Order (0 .. Chunks - 1)));
               Plan.Count := Natural (Count); Plan.Filled := Filled; Plan.Active_Count := Active_Count;
               Plan.Chunks := Chunks; Plan.Widest := Widest;
            end;
         end if;

         if Settings.Kind = Inkling2_Loop then
            for Index in 0 .. Active_Count - 1 loop
               declare
                  Which : constant Natural := Active (Index);
                  View : Expert renames Prepared (Which + 1);
               begin
                  View := Current.Experts (Which);
                  View.Gate := With_Metadata (View.Gate, Which, 0);
                  View.Up := With_Metadata (View.Up, Which, 1);
                  View.Down := With_Metadata (View.Down, Which, 2);
               end;
            end loop;
            Prepared_Ready := True;
         end if;

         if Chunks > 0 then
            Workers_CPU.Dispatch_Shares
              (Item.Team, Element_Count (Chunks), Share'Unchecked_Access,
               Status,
               Cost => Count * Element_Count (Used) * Feed * Width * 3,
               Team_Size => (if Reference_Arithmetic then Natural'Min
                 (Chunks, Natural (Workers_CPU.Worker_Total (Item.Team.all)) + 1) else 0),
               Alongside => (if Reference_Arithmetic
                 and then (for some Held of Resident_Experts => Held)
                 then Run_Resident'Unrestricted_Access else null));
         end if;

         if Settings.Kind /= Inkling2_Loop then
            Workers_CPU.Unpack (Packed_Super);
            Workers_CPU.Unpack (Packed_Plain);
         end if;

         if E.Is_Error (Status) then
            return;
         end if;

         if not Share.Ok then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;

         if not Residents_Done then
            Run_Resident (Status);
            if E.Is_Error (Status) then return; end if;
         end if;
      end;

      goto Summed;
   end if;

   --  And every expert once, with all the positions that chose it.
   for Which in 0 .. Many - 1 loop
      declare
         Members : Natural := 0;
      begin
         for Where in 0 .. Natural (Count) - 1 loop
            for Slot in 0 .. Used - 1 loop
               if Item.Pick_Which.all (Where * Used + Slot) = Which then
                  Item.Gathered.all (Members) := Where * Used + Slot;
                  Members := Members + 1;
               end if;
            end loop;
         end loop;

         if Members = 0 then
            goto Next_Expert;
         end if;

         declare
            Expert_At : Expert renames Current.Experts.all (Which);

            Held : constant Element_Count := Element_Count (Members);
         begin
            --  Gathered: the chosen positions' vectors, end to end.
            for Index in 0 .. Members - 1 loop
               declare
                  Where : constant Element_Count :=
                    Element_Count (Item.Gathered.all (Index) / Used);

                  From : constant Element_Count :=
                    Rows.all'First + Where * Width;

                  Into : constant Element_Count :=
                    Item.Gather_In.all'First
                    + Element_Count (Index) * Width;
               begin
                  Item.Gather_In.all (Into .. Into + Width - 1) :=
                    Rows.all (From .. From + Width - 1);
               end;
            end loop;

            --  The whole of this expert as one submission, where the
            --  device holds the stacks and the architecture puts
            --  nothing between the products that the device cannot:
            --  the gate through the same kernel a token's gathered
            --  mixture puts it through, which is what keeps a prompt
            --  and a token agreeing to the bit.
            if (Item.Owner.all.Stacked or else Current.Mixture_Held)
              and then (Current.Expert_Gate_Bias = null)
                       = (Current.Expert_Up_Bias = null)
              and then Model_Runner.Backend."="
                         (Item.Owner.Able.Kind,
                          Model_Runner.Backend.Backend_Device)
              and then T.Is_Present (Current.Gate_Stack)
              and then T.Is_Present (Current.Up_Stack)
              and then T.Is_Present (Current.Down_Stack)
              and then Item.Seen = null
            then

               Model_Runner.Backend.Device.Dispatch_Expert
                 (Current.Gate_Stack, Current.Up_Stack,
                  Current.Down_Stack, Feed, Width, Which,
                  Gate_Unit (Item.Owner.all), Item.Gather_In, Held,
                  Item.Gather_Out, Status, Item.Stopping,
                     Alpha => Item.Owner.all.Settings.Gate_Alpha,
                     Limit => Item.Owner.all.Settings.Gate_Limit,
                     Gate_Bias => Current.Expert_Gate_Bias,
                     Up_Bias   => Current.Expert_Up_Bias,
                     Down_Bias => Current.Expert_Down_Bias);
               if E.Is_Error (Status) then
                  return;
               end if;

               goto Scatter;
            end if;

            Product_Slice
              (Item, Expert_At.Gate, Current.Gate_Stack, Feed, Which,
               Item.Gather_In, Held, Item.Gather_A, Status,
               Gates => Current.Gate_Stack, Ups => Current.Up_Stack);
            if E.Is_Error (Status) then
               return;
            end if;

            Product_Slice
              (Item, Expert_At.Up, Current.Up_Stack, Feed, Which,
               Item.Gather_In, Held, Item.Gather_B, Status,
               Gates => Current.Gate_Stack, Ups => Current.Up_Stack);
            if E.Is_Error (Status) then
               return;
            end if;

            --  The biases and the gate, a member at a time on its own
            --  stretch, which is what one position's mixture does to one.
            for Index in 0 .. Members - 1 loop
               declare
                  At_Arm : constant Element_Count :=
                    Element_Count (Index) * Feed;

                  Gate_Part : T.Real_Array renames
                    Item.Gather_A.all
                      (Item.Gather_A.all'First + At_Arm
                       .. Item.Gather_A.all'First + At_Arm + Feed - 1);

                  Up_Part : T.Real_Array renames
                    Item.Gather_B.all
                      (Item.Gather_B.all'First + At_Arm
                       .. Item.Gather_B.all'First + At_Arm + Feed - 1);

                  At_Feed : constant Element_Count :=
                    Element_Count (Which) * Feed;
               begin
                  if Current.Expert_Gate_Bias /= null then
                     K.Add
                       (Gate_Part,
                        Current.Expert_Gate_Bias.all
                          (Current.Expert_Gate_Bias.all'First + At_Feed
                           .. Current.Expert_Gate_Bias.all'First + At_Feed
                              + Feed - 1));
                     K.Add
                       (Up_Part,
                        Current.Expert_Up_Bias.all
                          (Current.Expert_Up_Bias.all'First + At_Feed
                           .. Current.Expert_Up_Bias.all'First + At_Feed
                              + Feed - 1));
                  end if;

                  Expert_Activation (Item.Owner.all, Gate_Part, Up_Part, Reference_Arithmetic);
               end;
            end loop;

            Product_Slice
              (Item, Expert_At.Down, Current.Down_Stack, Width, Which,
               Item.Gather_A, Held, Item.Gather_Out, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            <<Scatter>>

            --  Scattered back, each to the place its position and its
            --  rank name, so the sums below are in the order they were.
            for Index in 0 .. Members - 1 loop
               declare
                  Pick : constant Natural := Item.Gathered.all (Index);

                  From : constant Element_Count :=
                    Item.Gather_Out.all'First
                    + Element_Count (Index) * Width;

                  Into : constant Element_Count :=
                    Item.Ranked.all'First + Element_Count (Pick) * Width;

                  Mine : T.Real_Array renames
                    Item.Ranked.all (Into .. Into + Width - 1);

                  At_Wide : constant Element_Count :=
                    Element_Count (Which) * Width;
               begin
                  Mine := Item.Gather_Out.all (From .. From + Width - 1);

                  if Current.Expert_Down_Bias /= null then
                     K.Add
                       (Mine,
                        Current.Expert_Down_Bias.all
                          (Current.Expert_Down_Bias.all'First + At_Wide
                           .. Current.Expert_Down_Bias.all'First + At_Wide
                              + Width - 1));
                  end if;
               end;
            end loop;
         end;

         <<Next_Expert>>
         null;
      end;
   end loop;

   <<Summed>>

   --  The shared expert the device was making meanwhile, at a gate of
   --  one since its answer is scaled already; or, where it was not
   --  made after all, the host's own, from the rows the mixture read.
   if Given_Shared then
      declare
         Fetched : Boolean;
         Shared  : constant Element_Count :=
           Element_Count (Settings.Shared_Feed);
      begin
         Model_Runner.Backend.Device.Finish_Shared
           (Item.Shared_Given, Fetched);

         if Fetched then
            Item.Shared_Rows_Out.all (0 .. Width - 1) :=
              Item.Shared_Given.all
                (Item.Shared_Given.all'First
                 .. Item.Shared_Given.all'First + Width - 1);
            Item.Shared_Rows_Out.all (Wide) := 1.0;
         else
            Item.Shared_Rows_Out.all (Wide) :=
              Shared_Weight
                (Current.Shared_Router, Rows.all, Rows.all'First);

            Product_Batch
              (Item, Current.Shared_Gate, Rows, 1, Item.Shared_Rows_A,
               Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Product_Batch
              (Item, Current.Shared_Up, Rows, 1, Item.Shared_Rows_B,
               Status);
            if E.Is_Error (Status) then
               return;
            end if;
            K.SiLU (Item.Shared_Rows_A.all (0 .. Shared - 1));
            K.Multiply
              (Item.Shared_Rows_A.all (0 .. Shared - 1),
               Item.Shared_Rows_B.all (0 .. Shared - 1));
            Product_Batch
              (Item, Current.Shared_Down, Item.Shared_Rows_A, 1,
               Item.Shared_Rows_Out, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;
      end;
   end if;

   --  And the sums, a position at a time and best expert first, which is
   --  the order one position's mixture adds them in and the reason the
   --  answers were kept apart rather than accumulated as they came.
   for Where in 0 .. Count - 1 loop
      declare
         At_Row : constant Element_Count := Rows.all'First + Where * Width;

         Into : T.Real_Array renames
           Rows.all (At_Row .. At_Row + Width - 1);
      begin
         if Reference_Arithmetic then
            declare
               Pick : constant Element_Count := Where * Element_Count (Used);
               First : constant Element_Count := Item.Ranked.all'First + Pick * Width;
            begin
               --  Raw expert scratch is dead after this reduction. Accumulate
               --  in rank order with separate binary32 multiply/add stages;
               --  avoid writing scaled expert rows or intermediate sums.
               K.Weighted_Sum
                 (Into, Item.Ranked.all (First .. First + Element_Count (Used) * Width - 1),
                  Item.Pick_Share.all
                    (Item.Pick_Share.all'First + Pick .. Item.Pick_Share.all'First + Pick + Element_Count (Used) - 1));
            end;
         else
            Into := [others => 0.0];

            for Slot in 0 .. Used - 1 loop
               declare
                  Pick : constant Element_Count :=
                    Where * Element_Count (Used) + Element_Count (Slot);

                  From : constant Element_Count :=
                    Item.Ranked.all'First + Pick * Width;

                  Mine : T.Real_Array renames
                    Item.Ranked.all (From .. From + Width - 1);
               begin
                  K.Scale
                    (Mine,
                     Item.Pick_Share.all (Item.Pick_Share.all'First + Pick));
                  K.Add (Into, Mine);
               end;
            end loop;

         end if;

         --  And the shared expert's answer for this row, at its gate.
         if T.Is_Present (Current.Shared_Gate) then
            declare
               Scale : constant Real :=
                 Item.Shared_Rows_Out.all (Wide + Where);
            begin
               for C in 0 .. Width - 1 loop
                  Into (Into'First + C) :=
                    Into (Into'First + C)
                    + Scale * Item.Shared_Rows_Out.all (Where * Width + C);
               end loop;
            end;
         end if;
      end;
   end loop;

   Ok := True;
end Mixture_Batch_Body;
