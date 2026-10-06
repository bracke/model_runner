separate (Model_Runner.Llama)
procedure Mixture_Body
  (Item    : in out Session;
   Current : Layer;
   Input   : T.Real_Array_Access;
   Result  : T.Real_Array_Access;
   Status  : out E.Error_Info)
is
   Settings : Configuration renames Item.Owner.Settings;
   Used     : constant Natural := Settings.Experts_Used;

   Chosen : array (0 .. Used - 1) of Natural := [others => 0];
   Share  : array (0 .. Used - 1) of Real := [others => 0.0];
   Taken  : array (0 .. Settings.Experts - 1) of Boolean :=
     [others => False];

   Total  : Real := 0.0;
   Usable : Boolean;

   --  Whether this position's experts are read gathered out of the
   --  stacks the device holds, which is also where it is routed: the
   --  same kernel a batch and a token's whole layer choose through, so
   --  that every road through a mixture on the device chooses alike.
   Gathered : constant Boolean :=
     Item.Owner.all.Stacked
     and then (Current.Expert_Gate_Bias = null)
              = (Current.Expert_Up_Bias = null)
     and then Used <= Model_Runner.Backend.Device.Max_Route

     --  The route kernel softmaxes the scores, and renormalizes the
     --  chosen or leaves them as the model asks (Keep_Route_Shares); a
     --  sigmoid-gated mixture is routed on the host instead.
     and then not Settings.Sigmoid_Gate
     and then T.Is_Present (Current.Gate_Stack)
     and then T.Is_Present (Current.Up_Stack)
     and then T.Is_Present (Current.Down_Stack);
begin
   --  On the pool, one position goes the way a batch does: an expert to
   --  a worker, whole, and the pool woken once a layer. Cut across the
   --  pool a row at a time, the eight experts of a generated token were
   --  twenty-four products of a few hundred rows each, with a wake and
   --  a settle around every one -- and a 35B-A3B token spent 31 ms of
   --  its 73 in them, reading the experts at 22 GB/s where the dense
   --  products read at 30. Dealt whole, a worker walks an expert's
   --  three matrices at its own rate and nine of them together are
   --  bound by the memory again. The same kernels on the same rows in
   --  the same order, so the bits are the bits; and the sum is still
   --  best expert first, which is what Mixture_Batch keeps Ranked for.
   if (Item.Host_Feed
       or else Model_Runner.Backend."="
                 (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_CPU))
     and then Workers_CPU."/=" (Item.Team, null)
     and then Input /= Result
     and then Result.all'Length = Input.all'Length
   then
      declare
         Grouped : Boolean;
      begin
         Result.all := Input.all;
         Mixture_Batch (Item, Current, Result, 1, Grouped, Status);
         if E.Is_Error (Status) or else Grouped then
            return;
         end if;
      end;
   end if;

   if Gathered then
      declare
         Choice : Model_Runner.Backend.Device.Choice_Array
           (0 .. Used - 1);
         Shares : Real_Array (0 .. Element_Count (Used) - 1);
      begin
         if Item.Seen /= null then
            declare
               Which : constant String :=
                 Named_As (Item.Owner.all, Current.Router);
            begin
               if Which /= "" then
                  Item.Seen.Note (Which, Input.all, 1);
               end if;
            end;
         end if;

         Model_Runner.Backend.Device.Dispatch_Route
           (Current.Router, Current.Router_Bias, Settings.Experts, Used,
            Input, 1, Choice, Shares, Status, Item.Stopping);
         if E.Is_Error (Status) then
            return;
         end if;

         for Slot in Chosen'Range loop
            Chosen (Slot) := Choice (Slot);
            Share (Slot) := Shares (Element_Count (Slot));
         end loop;
      end;

      goto Routed;
   end if;

   Product (Item, Current.Router, Input, Item.Routing, Status);
   if E.Is_Error (Status) then
      return;
   end if;

   --  What the router adds before it chooses, where an architecture
   --  states one. It changes which experts are picked and not only their
   --  weights, so it belongs before the softmax rather than after.
   if Current.Router_Bias /= null then
      K.Add
        (Item.Routing.all
           (Item.Routing.all'First
            .. Item.Routing.all'First
               + Element_Count (Settings.Experts) - 1),
         Current.Router_Bias.all);
   end if;

   if Settings.Sigmoid_Gate then
      K.Sigmoid (Item.Routing.all);
   else
      K.Softmax (Item.Routing.all, Usable);
      if not Usable then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;
   end if;

   for Slot in Chosen'Range loop
      declare
         Best : Integer := -1;
      begin
         for Which in Taken'Range loop
            if not Taken (Which)
              and then
                (Best < 0
                 or else Item.Routing (Element_Count (Which))
                         > Item.Routing (Element_Count (Best)))
            then
               Best := Which;
            end if;
         end loop;

         Taken (Best) := True;
         Chosen (Slot) := Best;
         Share (Slot) := Item.Routing (Element_Count (Best));
         Total := Total + Share (Slot);
      end;
   end loop;

   --  The shares came out of a softmax, so they are positive and sum to
   --  one over every expert; over the chosen few they sum to less, and
   --  this puts them back on a scale where the sum below is a weighted
   --  average rather than an arbitrarily shrunken one -- unless the file
   --  says its weights are not renormalized, when the chosen few weight
   --  the sum by their own gate and the shares are left as they came.
   if Settings.Renormalize_Experts then
      if not (Total > 0.0) then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;

      for Slot in Share'Range loop
         Share (Slot) := Share (Slot) / Total;
      end loop;
   end if;

   <<Routed>>

   --  GraniteMoE multiplies the renormalized weights by a scalar it
   --  carries; every other mixture here leaves it at one. Applied where
   --  the host and the device gather rejoin, before the weights reach any
   --  of the sums below, so both backends scale once.
   if Settings.Expert_Scale /= 1.0 then
      for Slot in Share'Range loop
         Share (Slot) := Share (Slot) * Settings.Expert_Scale;
      end loop;
   end if;

   Result.all := [others => 0.0];

   --  Gathered, where the device holds the stacks: the chosen experts'
   --  three projections and the gate between them as one submission of
   --  four dispatches, where a slice at a time was two submissions of
   --  twenty-four. What comes back is each expert's projection down,
   --  and the shares and the sum are applied here in the order they
   --  always were, so the answer is the same sum of the same terms.
   --
   --  Biases and the clamped gate are what the sequence does not do,
   --  so an architecture carrying them takes the road below.
   if Gathered then
      declare
         Width : constant Element_Count :=
           Element_Count (Settings.Embedding);
         Feed  : constant Element_Count :=
           Element_Count (Settings.Expert_Feed);

         --  The gather reads at most Max_Members experts at once, so a
         --  mixture that chose more is read in chunks of that many, each
         --  summed before the next: the shares were renormalized over the
         --  whole chosen set above, so a chunk's partial sum adds to the
         --  same weighted average one gather of them all would give.
         Span : constant Natural :=
           Model_Runner.Backend.Device.Max_Members;
      begin
         if Item.Mixed = null
           or else Item.Mixed.all'Length < Element_Count (Used) * Width
         then
            T.Free (Item.Mixed);
            T.Allocate (Element_Count (Used) * Width, Item.Mixed);
            if Item.Mixed = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
         end if;

         --  What each product was given, where anything asked to be
         --  told: the same names the slice-at-a-time road notes.
         if Item.Seen /= null then
            for Slot in Chosen'Range loop
               declare
                  Which : Expert renames
                    Current.Experts.all (Chosen (Slot));

                  Gate_Name : constant String :=
                    Named_As (Item.Owner.all, Which.Gate);
                  Up_Name   : constant String :=
                    Named_As (Item.Owner.all, Which.Up);
               begin
                  if Gate_Name /= "" then
                     Item.Seen.Note (Gate_Name, Input.all, 1);
                  end if;

                  if Up_Name /= "" then
                     Item.Seen.Note (Up_Name, Input.all, 1);
                  end if;
               end;
            end loop;
         end if;

         declare
            Done : Natural := 0;
         begin
            while Done < Used loop
               declare
                  Reach   : constant Natural :=
                    Natural'Min (Span, Used - Done);
                  Members : Model_Runner.Backend.Device.Member_List :=
                    [others => 0];
               begin
                  for J in 0 .. Reach - 1 loop
                     Members (J + 1) := Chosen (Done + J);
                  end loop;

                  Model_Runner.Backend.Device.Dispatch_Mixture
                    (Current.Gate_Stack, Current.Up_Stack,
                     Current.Down_Stack, Feed, Width, Members, Reach,
                     Gate_Unit (Item.Owner.all), Input, Item.Mixed, Status,
                     Item.Stopping,
                     Alpha => Item.Owner.all.Settings.Gate_Alpha,
                     Limit => Item.Owner.all.Settings.Gate_Limit,
                     Gate_Bias => Current.Expert_Gate_Bias,
                     Up_Bias   => Current.Expert_Up_Bias,
                     Down_Bias => Current.Expert_Down_Bias);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  for J in 0 .. Reach - 1 loop
                     declare
                        From : constant Element_Count :=
                          Item.Mixed.all'First + Element_Count (J) * Width;
                     begin
                        Item.Expert_Row.all
                          (Item.Expert_Row.all'First
                           .. Item.Expert_Row.all'First + Width - 1) :=
                          Item.Mixed.all (From .. From + Width - 1);
                     end;

                     K.Scale (Item.Expert_Row.all, Share (Done + J));
                     K.Add (Result.all, Item.Expert_Row.all);
                  end loop;

                  Done := Done + Reach;
               end;
            end loop;
         end;

         --  On to the shared expert, not out: this road returned
         --  here, and a hybrid mixture's one position on the device
         --  went without its shared expert -- the batch had it, and
         --  the sweep's device pass never built the mixture shape.
         goto Summed;
      end;
   end if;

   --  Every chosen expert's two arms at once.
   --
   --  They all read the same input, so they are a group and a group is
   --  one submission. Two a expert over eight experts and forty-eight
   --  layers is one thousand five hundred and thirty-six submissions a
   --  token, each paying a call this file measured at 64.3 microseconds
   --  before it computes anything -- against one a layer for the dense
   --  path, which was fused for exactly this reason and left the mixture
   --  behind. See the README's `### A mixture, in one submission a
   --  layer`.
   --  One submission holds two arms for at most Max_Members experts --
   --  the device's product sequence is that long -- so a route wider
   --  than that, seventeen experts where the sum reads sixteen and one
   --  more, is spilled into rounds of Max_Members, each its own group.
   --  Every round writes its arms to the same per-expert rooms the sum
   --  below reads, indexed by the true slot, so the spill changes the
   --  number of submissions and nothing else.
   if not Item.Host_Feed and then T."/=" (Item.Expert_Arms, null) then
      declare
         Done : Natural := 0;
      begin
         while Done < Used loop
            declare
               Reach : constant Natural :=
                 Natural'Min
                   (Model_Runner.Backend.Device.Max_Members, Used - Done);
               Pairs : T.View_Group (1 .. 2 * Reach);
               Rooms : T.Target_Group (1 .. 2 * Reach);
            begin
               for J in 0 .. Reach - 1 loop
                  Pairs (2 * J + 1) :=
                    Current.Experts.all (Chosen (Done + J)).Gate;
                  Pairs (2 * J + 2) :=
                    Current.Experts.all (Chosen (Done + J)).Up;
                  Rooms (2 * J + 1) :=
                    Item.Expert_Arms.all (2 * (Done + J) + 1);
                  Rooms (2 * J + 2) :=
                    Item.Expert_Arms.all (2 * (Done + J) + 2);
               end loop;

               Product_Group (Item, Pairs, Input, Rooms, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               Done := Done + Reach;
            end;
         end loop;
      end;
   end if;

   for Slot in Chosen'Range loop
      declare
         Which : Expert renames Current.Experts.all (Chosen (Slot));

         --  This expert's two arms, out of what the group wrote, or the
         --  session's single pair where there is no group.
         Gate_Room : constant T.Real_Array_Access :=
           (if not Item.Host_Feed and then T."/=" (Item.Expert_Arms, null)
            then Item.Expert_Arms.all (2 * Slot + 1) else Item.Gate);
         Up_Room   : constant T.Real_Array_Access :=
           (if not Item.Host_Feed and then T."/=" (Item.Expert_Arms, null)
            then Item.Expert_Arms.all (2 * Slot + 2) else Item.Up);

         Expert_Feed : constant Element_Count :=
           Element_Count (Item.Owner.all.Settings.Expert_Feed);

         At_Feed : constant Element_Count :=
           Element_Count (Chosen (Slot)) * Expert_Feed;

         At_Wide : constant Element_Count :=
           Element_Count (Chosen (Slot))
           * Element_Count (Item.Owner.all.Settings.Embedding);
      begin
         if Item.Host_Feed or else T."=" (Item.Expert_Arms, null) then
            Product (Item, Which.Gate, Input, Gate_Room, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            Product (Item, Which.Up, Input, Up_Room, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         --  The biases, where the architecture carries them. One
         --  expert's are the run of Expert_Feed at its own index of an
         --  array holding every expert's, so what is added is a slice
         --  rather than a whole.
         if Current.Expert_Gate_Bias /= null then
            K.Add
              (Gate_Room.all (Gate_Room.all'First
                              .. Gate_Room.all'First + Expert_Feed - 1),
               Current.Expert_Gate_Bias.all
                 (Current.Expert_Gate_Bias.all'First + At_Feed
                  .. Current.Expert_Gate_Bias.all'First + At_Feed
                     + Expert_Feed - 1));
            K.Add
              (Up_Room.all (Up_Room.all'First
                            .. Up_Room.all'First + Expert_Feed - 1),
               Current.Expert_Up_Bias.all
                 (Current.Expert_Up_Bias.all'First + At_Feed
                  .. Current.Expert_Up_Bias.all'First + At_Feed
                     + Expert_Feed - 1));
         end if;

         --  The gate this architecture states. A mixture used to be
         --  Qwen3_MoE only, which is the plain logistic gate; the
         --  clamped one below reaches the up projection as well as the
         --  gate, so it cannot be an activation followed by a multiply.
         if Item.Owner.all.Settings.Gate_Alpha > 0.0 then
            K.Clamped_Gate
              (Gate_Room.all, Up_Room.all,
               Item.Owner.all.Settings.Gate_Alpha,
               Item.Owner.all.Settings.Gate_Limit);
         else
            Gate_Activation (Item.Owner.all, Gate_Room.all);
            K.Multiply (Gate_Room.all, Up_Room.all);
         end if;

         --  Grouped, the gated vector is laid into the one activation
         --  the group reads and the products follow together below.
         if not Item.Host_Feed and then T."/=" (Item.Expert_Outs, null) then
            Item.Expert_Feeds.all
              (Item.Expert_Feeds.all'First
                 + Element_Count (Slot) * Expert_Feed
               .. Item.Expert_Feeds.all'First
                  + Element_Count (Slot) * Expert_Feed + Expert_Feed - 1)
              := Gate_Room.all
                   (Gate_Room.all'First
                    .. Gate_Room.all'First + Expert_Feed - 1);

            goto Next_Expert;
         end if;

         Product (Item, Which.Down, Gate_Room, Item.Expert_Row, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         if Current.Expert_Down_Bias /= null then
            declare
               Wide : constant Element_Count :=
                 Element_Count (Item.Owner.all.Settings.Embedding);
            begin
               K.Add
                 (Item.Expert_Row.all
                    (Item.Expert_Row.all'First
                     .. Item.Expert_Row.all'First + Wide - 1),
                  Current.Expert_Down_Bias.all
                    (Current.Expert_Down_Bias.all'First + At_Wide
                     .. Current.Expert_Down_Bias.all'First + At_Wide
                        + Wide - 1));
            end;
         end if;

         K.Scale (Item.Expert_Row.all, Share (Slot));
         K.Add (Result.all, Item.Expert_Row.all);

         <<Next_Expert>>
         null;
      end;
   end loop;

   --  And every chosen expert's down projection at once. Each reads its
   --  own stretch of the one activation, which is what the stride on a
   --  group is for, so eight submissions a layer become one.
   --
   --  The bias, the share and the sum stay where they were and in the
   --  order they were in: the products are the same products, batched.
   if not Item.Host_Feed and then T."/=" (Item.Expert_Outs, null) then
      declare
         Downs : T.View_Group (1 .. Used);
         Rooms : T.Target_Group (1 .. Used);

         Wide : constant Element_Count :=
           Element_Count (Settings.Embedding);
      begin
         for Slot in Chosen'Range loop
            Downs (Slot + 1) := Current.Experts.all (Chosen (Slot)).Down;
            Rooms (Slot + 1) := Item.Expert_Outs.all (Slot + 1);
         end loop;

         Product_Group
           (Item, Downs, Item.Expert_Feeds, Rooms, Status,
            Apart => Element_Count (Settings.Expert_Feed));
         if E.Is_Error (Status) then
            return;
         end if;

         for Slot in Chosen'Range loop
            declare
               Mine : T.Real_Array_Access renames
                 Item.Expert_Outs.all (Slot + 1);

               At_Wide : constant Element_Count :=
                 Element_Count (Chosen (Slot)) * Wide;
            begin
               if Current.Expert_Down_Bias /= null then
                  K.Add
                    (Mine.all (Mine.all'First
                               .. Mine.all'First + Wide - 1),
                     Current.Expert_Down_Bias.all
                       (Current.Expert_Down_Bias.all'First + At_Wide
                        .. Current.Expert_Down_Bias.all'First + At_Wide
                           + Wide - 1));
               end if;

               K.Scale (Mine.all, Share (Slot));
               K.Add (Result.all, Mine.all);
            end;
         end loop;
      end;
   end if;

   <<Summed>>
   if T.Is_Present (Current.Shared_Gate) then
      Shared_Expert (Item, Current, Input, Result.all, Status);
   end if;
end Mixture_Body;
