separate (Model_Runner.Llama)
procedure Mixture_Batch_Body
  (Item    : in out Session;
   Current : Layer;
   Rows    : T.Real_Array_Access;
   Count   : Element_Count;
   Ok      : out Boolean;
   Status  : out E.Error_Info)
is
   Settings : Configuration renames Item.Owner.Settings;

   Used   : constant Natural := Settings.Experts_Used;
   Many   : constant Natural := Settings.Experts;
   Width  : constant Element_Count := Element_Count (Settings.Embedding);
   Feed   : constant Element_Count :=
     Element_Count (Settings.Expert_Feed);

   Wide   : constant Element_Count := Count * Width;

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
   On_Pool : constant Boolean :=
     (Item.Host_Feed
      or else Model_Runner.Backend."="
                (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_CPU))
     and then Workers_CPU."/=" (Item.Team, null);

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
   if Item.Owner.all.Stacked
     and then Model_Runner.Backend."="
                (Item.Owner.Able.Kind,
                 Model_Runner.Backend.Backend_Device)
     and then Used <= Model_Runner.Backend.Device.Max_Route

     --  The route kernel softmaxes, and renormalizes or not as the model
     --  asks; a sigmoid-gated mixture is routed on the host, as one
     --  position's is.
     and then not Settings.Sigmoid_Gate
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
   if Count <= Model_Runner.Backend.Device.Front_Route_Most
     and then Item.Owner.all.Split_Feed
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

         Taken : array (0 .. Many - 1) of Boolean := [others => False];
         Total : Real := 0.0;
      begin
         if Current.Router_Bias /= null then
            K.Add (Scores, Current.Router_Bias.all);
         end if;

         if Settings.Sigmoid_Gate then
            K.Sigmoid (Scores);
         else
            K.Softmax (Scores, Usable);
            if not Usable then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;
         end if;

         for Slot in 0 .. Used - 1 loop
            declare
               Best : Integer := -1;
            begin
               for Which in Taken'Range loop
                  if not Taken (Which)
                    and then
                      (Best < 0
                       or else Scores (Scores'First + Element_Count (Which))
                               > Scores
                                   (Scores'First + Element_Count (Best)))
                  then
                     Best := Which;
                  end if;
               end loop;

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
                    Item.Pick_Share.all (At_Share) / Total;
               end;
            end loop;
         end if;
      end;
   end loop;

   <<Chosen>>

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
         Chunk_Size : constant := 16;

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
         Packed_Super : Workers_CPU.Packed_Rows;
         Packed_Plain : Workers_CPU.Packed_Rows;
         Has_Super    : Boolean := False;
         Has_Plain    : Boolean := False;

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
            In_Room  : T.Real_Array_Access;
            A_Room   : T.Real_Array_Access;
            B_Room   : T.Real_Array_Access;
            Out_Room : T.Real_Array_Access;
         begin
            T.Allocate (Element_Count (Widest) * Width, In_Room);
            T.Allocate
              (Element_Count (Widest) * Element_Count'Max (Feed, Shared_Feed),
               A_Room);
            T.Allocate
              (Element_Count (Widest) * Element_Count'Max (Feed, Shared_Feed),
               B_Room);
            T.Allocate (Element_Count (Widest) * Width, Out_Room);

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

                        Expert_At : Expert renames
                          Current.Experts.all (Which);
                     begin
                        begin
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

                           --  The two arms from the packed rows where
                           --  the pool packed them, gathered by member,
                           --  and from the rows as they are otherwise.
                           declare
                              Picked : Model_Runner.Shares.Member_Rows
                                (0 .. Members_Held - 1);
                              Done   : Boolean;
                           begin
                              for Index in Picked'Range loop
                                 Picked (Index) :=
                                   Listed (Start + Index) / Used;
                              end loop;

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
                                 Workers_CPU.Dispatch_Batch
                                   (null, Expert_At.Gate, In_Room, Held,
                                    A_Room, Local, Roles => Item.Arithmetic);
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
                                 Workers_CPU.Dispatch_Batch
                                   (null, Expert_At.Up, In_Room, Held,
                                    B_Room, Local, Roles => Item.Arithmetic);
                                 if E.Is_Error (Local) then
                                    Share.Ok := False;
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

                                 if Settings.Gate_Alpha > 0.0 then
                                    K.Clamped_Gate
                                      (Gate_Part, Up_Part,
                                       Settings.Gate_Alpha,
                                       Settings.Gate_Limit);
                                 else
                                    Gate_Activation
                                      (Item.Owner.all, Gate_Part);
                                    K.Multiply (Gate_Part, Up_Part);
                                 end if;
                              end;
                           end loop;

                           Workers_CPU.Dispatch_Batch
                             (null, Expert_At.Down, A_Room, Held, Out_Room,
                              Local, Roles => Item.Arithmetic);
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
                                 Mine := Out_Room.all
                                   (From_At .. From_At + Width - 1);

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

            T.Free (In_Room);
            T.Free (A_Room);
            T.Free (B_Room);
            T.Free (Out_Room);
         end Run;

         Share : aliased Expert_Share;
      begin
         for Which in 0 .. Many - 1 loop
            Starts (Which) := Filled;

            for Where in 0 .. Natural (Count) - 1 loop
               for Slot in 0 .. Used - 1 loop
                  if Item.Pick_Which.all (Where * Used + Slot) = Which then
                     Listed (Filled) := Where * Used + Slot;
                     Filled := Filled + 1;
                     Counts (Which) := Counts (Which) + 1;
                  end if;
               end loop;
            end loop;

            --  What each product was given, where anything asked to be
            --  told, said here on the submitting task as the road below
            --  says it.
            if Item.Seen /= null and then Counts (Which) > 0 then
               declare
                  Expert_At : Expert renames Current.Experts.all (Which);
                  Gate_Name : constant String :=
                    Named_As (Item.Owner.all, Expert_At.Gate);
                  Up_Name   : constant String :=
                    Named_As (Item.Owner.all, Expert_At.Up);
                  Down_Name : constant String :=
                    Named_As (Item.Owner.all, Expert_At.Down);
               begin
                  --  The gathered input is not built yet on this task;
                  --  a watcher is told the positions' own rows instead,
                  --  which is what the products read, gathered.
                  if Gate_Name /= "" or else Up_Name /= ""
                    or else Down_Name /= ""
                  then
                     Item.Seen.Note
                       ((if Gate_Name /= "" then Gate_Name
                         elsif Up_Name /= "" then Up_Name
                         else Down_Name),
                        Rows.all (Rows.all'First
                                  .. Rows.all'First + Count * Width - 1),
                        Count);
                  end if;
               end;
            end if;
         end loop;

         --  The runs: each expert's members in Chunk_Size at a time.
         for Which in Counts'Range loop
            declare
               Done : Natural := 0;
            begin
               while Done < Counts (Which) loop
                  Chunk_Expert (Chunks) := Which;
                  Chunk_Start (Chunks) := Starts (Which) + Done;
                  Chunk_Count (Chunks) :=
                    Natural'Min (Chunk_Size, Counts (Which) - Done);
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
                    Natural'Min (Chunk_Size, Natural (Count) - Done);
                  Widest := Natural'Max (Widest, Chunk_Count (Chunks));
                  Done := Done + Chunk_Count (Chunks);
                  Chunks := Chunks + 1;
               end loop;
            end;
         end if;

         for Which in 0 .. Many - 1 loop
            if Counts (Which) > 0 then
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
              (Packed_Super, Rows, Count, Width, True, Has_Super, Roles => Item.Arithmetic);
         end if;
         if Has_Plain then
            Workers_CPU.Pack
              (Packed_Plain, Rows, Count, Width, False, Has_Plain, Roles => Item.Arithmetic);
         end if;

         --  The experts by size, largest first, in the order the
         --  workers take them.
         declare
            Sorted : array (0 .. Chunks - 1) of Natural;
         begin
            for Which in Sorted'Range loop
               Sorted (Which) := Which;
            end loop;

            for Outer in 1 .. Chunks - 1 loop
               declare
                  Moving : constant Natural := Sorted (Outer);
                  Inner  : Integer := Outer - 1;
               begin
                  while Inner >= 0
                    and then Chunk_Count (Sorted (Inner))
                             < Chunk_Count (Moving)
                  loop
                     Sorted (Inner + 1) := Sorted (Inner);
                     Inner := Inner - 1;
                  end loop;
                  Sorted (Inner + 1) := Moving;
               end;
            end loop;

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

         if Chunks > 0 then
            Workers_CPU.Dispatch_Shares
              (Item.Team, Element_Count (Chunks), Share'Unchecked_Access,
               Status,
               Cost => Count * Element_Count (Used) * Feed * Width * 3);
         end if;

         Workers_CPU.Unpack (Packed_Super);
         Workers_CPU.Unpack (Packed_Plain);

         if E.Is_Error (Status) then
            return;
         end if;

         if not Share.Ok then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
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
            if Item.Owner.all.Stacked
              and then (Current.Expert_Gate_Bias = null)
                       = (Current.Expert_Up_Bias = null)
              and then Model_Runner.Backend."="
                         (Item.Owner.Able.Kind,
                          Model_Runner.Backend.Backend_Device)
              and then T.Is_Present (Current.Gate_Stack)
              and then T.Is_Present (Current.Up_Stack)
              and then T.Is_Present (Current.Down_Stack)
            then
               if Item.Seen /= null then
                  declare
                     Room : constant Element_Count := Held * Width;
                     Gate_Name : constant String :=
                       Named_As (Item.Owner.all, Expert_At.Gate);
                     Up_Name   : constant String :=
                       Named_As (Item.Owner.all, Expert_At.Up);
                  begin
                     if Gate_Name /= "" then
                        Item.Seen.Note
                          (Gate_Name,
                           Item.Gather_In.all
                             (Item.Gather_In.all'First
                              .. Item.Gather_In.all'First + Room - 1),
                           Held);
                     end if;

                     if Up_Name /= "" then
                        Item.Seen.Note
                          (Up_Name,
                           Item.Gather_In.all
                             (Item.Gather_In.all'First
                              .. Item.Gather_In.all'First + Room - 1),
                           Held);
                     end if;
                  end;
               end if;

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
               Item.Gather_In, Held, Item.Gather_A, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Product_Slice
              (Item, Expert_At.Up, Current.Up_Stack, Feed, Which,
               Item.Gather_In, Held, Item.Gather_B, Status);
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

                  if Settings.Gate_Alpha > 0.0 then
                     K.Clamped_Gate
                       (Gate_Part, Up_Part,
                        Settings.Gate_Alpha, Settings.Gate_Limit);
                  else
                     Gate_Activation (Item.Owner.all, Gate_Part);
                     K.Multiply (Gate_Part, Up_Part);
                  end if;
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
