separate (Model_Runner.Llama)
procedure RWKV6_Batch
  (Item        : in out Session;
   Source      : Model'Class;
   Current     : Layer;
   Layer_Index : Natural;
   Cur         : T.Real_Array_Access;
   Acts        : T.Real_Array_Access;
   Count       : Element_Count;
   Into        : T.Real_Array_Access;
   Whole       : out Boolean;
   Status      : out E.Error_Info)
is
   pragma Suppress (Index_Check);
   pragma Suppress (Range_Check);
   pragma Suppress (Overflow_Check);

   Settings : Configuration renames Source.Settings;
   RW    : constant Element_Count := Element_Count (Settings.Embedding);
   Heads : constant Element_Count := Element_Count (Settings.Ssm_Heads);
   HN    : constant Element_Count := Element_Count (Settings.Head_Dim);
   D_TM  : constant Element_Count := Element_Count (Settings.Mix_Extra);
   D_Dec : constant Element_Count := Element_Count (Settings.Decay_Extra);
   Feed  : constant Element_Count := Element_Count (Settings.Feed_Forward);
   Rows  : constant Element_Count := Count * RW;

   Conv_Base  : constant Element_Count := Conv_At (Settings, Layer_Index);
   State_Base : constant Element_Count := State_At (Settings, Layer_Index);

   Mem : Real_Array renames Item.Conv_State.all;
   C0  : constant Element_Count := Cur.all'First;
   A0  : constant Element_Count := Acts.all'First;

   Sx, Xs, WL, Lora, Xw, Xk, Xv, Xr, Xg, D1, Ww : T.Real_Array_Access;
   Rr, Kk, Vv, Gg, Y, Inp, N2, CK, CR, CV : T.Real_Array_Access;

   procedure Release is
   begin
      T.Free (Sx); T.Free (Xs); T.Free (WL); T.Free (Lora);
      T.Free (Xw); T.Free (Xk); T.Free (Xv); T.Free (Xr); T.Free (Xg);
      T.Free (D1); T.Free (Ww); T.Free (Rr); T.Free (Kk); T.Free (Vv);
      T.Free (Gg); T.Free (Y); T.Free (Inp); T.Free (N2);
      T.Free (CK); T.Free (CR); T.Free (CV);
   end Release;

   procedure Project
     (Weight : T.View; From, Target : T.Real_Array_Access) is
   begin
      if Count = 1 then
         Product (Item, Weight, From, Target, Status);
      else
         Product_Batch (Item, Weight, From, Count, Target, Status);
      end if;
   end Project;

   procedure Table
     (Tab : T.Real_Array_Access; Rows_Of, Width_Of : Element_Count;
      X : T.Real_Array_Access; X_Stride : Element_Count;
      Target : T.Real_Array_Access; Out_Stride : Element_Count;
      Kind : Natural;
      Seg_Rows  : Element_Count := 0;
      Seg_Width : Element_Count := 0;
      Bias : T.Real_Array_Access := null)
   is
      Share : aliased Table_Share :=
        (Tab        => Tab, Width => Width_Of, X => X,
         X_Stride   => X_Stride,
         Seg_Rows   => (if Seg_Rows = 0 then Rows_Of else Seg_Rows),
         Seg_Width  => Seg_Width, Count => Count, Out_Rows => Target,
         Out_Stride => Out_Stride, Kind => Kind, Bias => Bias);
   begin
      if E.Is_Ok (Status) then
         Workers_CPU.Dispatch_Shares
           (Item.Team, Rows_Of, Share'Unchecked_Access, Status,
            Cost => Rows_Of * Width_Of * Count);
      end if;
   end Table;

   --  Stream S of the time mix's shift, for every position, into Target:
   --  the input moved toward the position before by the stream's own
   --  mix, fixed and data-dependent.
   procedure Stream (S : Element_Count; Target : T.Real_Array_Access) is
   begin
      for P in 0 .. Count - 1 loop
         for C in 0 .. RW - 1 loop
            Target (P * RW + C) :=
              Cur (C0 + P * RW + C)
              + Sx (P * RW + C)
                * (Current.Rwkv_Lerp_Fused.all (S * RW + C)
                   + Lora (P * 5 * RW + S * RW + C));
         end loop;
      end loop;
   end Stream;
begin
   Status := E.Success;
   Whole := False;

   --  The block whole on the device, where it runs there: the state
   --  seated in the device's room and the shift rows and heads read and
   --  written there, one submission a block. Refused, the state comes
   --  home first and the host takes the block.
   if Model_Runner.Backend."="
        (Item.Owner.Able.Kind, Model_Runner.Backend.Backend_Device)
     and then Current.Rwkv_Pack /= null
     and then Item.Kept_States = 0
     and then HN = Model_Runner.Backend.Device.Rwkv_Head
     and then Heads * HN = RW
     and then Model_Runner.Backend.Device.Runs_Rwkv
   then
      declare
         Seated : Boolean;
         Ran    : Boolean := False;
         P      : constant Rwkv_Places := Rwkv_Places_Of (Settings);
         Halve  : constant Boolean :=
           Settings.Rescale_Every > 0
           and then (Layer_Index + 1) mod Settings.Rescale_Every = 0;
      begin
         Send_States (Item'Unchecked_Access, Seated);
         if Seated then
            Model_Runner.Backend.Device.Rwkv_Layer
              ((Width       => Natural (RW),
                Heads       => Natural (Heads),
                Head        => Natural (HN),
                Mix_Rank    => Natural (D_TM),
                Decay_Rank  => Natural (D_Dec),
                Feed        => Natural (Feed),
                Pack        => Current.Rwkv_Pack,
                First_Norm  => Natural (P.First_Norm),
                Second_Norm => Natural (P.Second_Norm),
                Plain_Mix   => Natural (P.Plain_Mix),
                Stream_Mix  => Natural (P.Stream_Mix),
                Stream_Map  => Natural (P.Stream_Map),
                Decay_Bias  => Natural (P.Decay_Bias),
                Decay_Map   => Natural (P.Decay_Map),
                Bonus       => Natural (P.Bonus),
                Out_Norm    => Natural (P.Out_Norm),
                Channel_Mix => Natural (P.Channel_Mix),
                Mix_Down    => Current.Rwkv_TM_W1,
                Decay_Down  => Current.Rwkv_Decay_W1,
                Receptance  => Current.Rwkv_R,
                Key         => Current.Rwkv_K,
                Value       => Current.Rwkv_V,
                Gate        => Current.Rwkv_G,
                Output      => Current.Rwkv_TM_Out,
                Channel_Key   => Current.Rwkv_CM_K,
                Channel_Value => Current.Rwkv_CM_V,
                Channel_Receptance => Current.Rwkv_CM_R,
                Shift_At    => Natural (Item.State_Base + Conv_Base),
                State_At    =>
                  Natural (Item.State_Base)
                  + Linear_State_At (Item, Layer_Index),
                Epsilon     => Settings.Epsilon,
                Floor       => 64.0e-5,
                Scale       => (if Halve then 0.5 else 1.0)),
               Acts.all (A0 .. A0 + Rows - 1), Count,
               Into.all (Into.all'First .. Into.all'First + Rows - 1),
               Ran, Item.Stopping);
         end if;

         if Ran then
            Whole := True;
            return;
         end if;

         --  Whatever the device did with the state before it refused,
         --  the host's copy is the one the host goes on from.
         Fetch_States (Item'Unchecked_Access);
         Item.Ring_Written := True;
      end;
   else
      Fetch_States (Item'Unchecked_Access);
      Item.Ring_Written := True;
   end if;

   T.Allocate (Rows, Sx);       T.Allocate (Rows, Xs);
   T.Allocate (Count * 5 * D_TM, WL);
   T.Allocate (Count * 5 * RW, Lora);
   T.Allocate (Rows, Xw);       T.Allocate (Rows, Xk);
   T.Allocate (Rows, Xv);       T.Allocate (Rows, Xr);
   T.Allocate (Rows, Xg);       T.Allocate (Count * D_Dec, D1);
   T.Allocate (Rows, Ww);       T.Allocate (Rows, Rr);
   T.Allocate (Rows, Kk);       T.Allocate (Rows, Vv);
   T.Allocate (Rows, Gg);       T.Allocate (Rows, Y);
   T.Allocate (Rows, Inp);      T.Allocate (Rows, N2);
   T.Allocate (Count * Feed, CK);
   T.Allocate (Rows, CR);       T.Allocate (Rows, CV);
   if Sx = null or else Xs = null or else WL = null or else Lora = null
     or else Xw = null or else Xk = null or else Xv = null
     or else Xr = null or else Xg = null or else D1 = null
     or else Ww = null or else Rr = null or else Kk = null
     or else Vv = null or else Gg = null or else Y = null
     or else Inp = null or else N2 = null or else CK = null
     or else CR = null or else CV = null
   then
      Release;
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;

   --  === Time mix ===
   --  Each position's shift against the one before -- the first against
   --  the ln1 output the last batch left in the first slot -- and the
   --  plain mix that feeds the data-dependent one.
   for P in 0 .. Count - 1 loop
      for C in 0 .. RW - 1 loop
         declare
            Before : constant Real :=
              (if P = 0 then Mem (Conv_Base + C)
               else Cur (C0 + (P - 1) * RW + C));
            Here   : constant Real := Cur (C0 + P * RW + C);
         begin
            Sx (P * RW + C) := Before - Here;
            Xs (P * RW + C) :=
              Here + Sx (P * RW + C) * Current.Rwkv_Lerp_X.all (C);
         end;
      end loop;
   end loop;

   --  The data-dependent mix: five ranks through a tanh, then each
   --  stream's ranks back to the model width through its own map.
   Table (Current.Rwkv_TM_W1, 5 * D_TM, RW, Xs, RW, WL, 5 * D_TM, 1);
   Table (Current.Rwkv_TM_W2, 5 * RW, D_TM, WL, 5 * D_TM, Lora, 5 * RW, 0,
          Seg_Rows => RW, Seg_Width => D_TM);
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  Receptance, key, value and the gate, each from its own stream.
   Stream (3, Xr);
   Stream (1, Xk);
   Stream (2, Xv);
   Stream (4, Xg);
   Stream (0, Xw);
   Project (Current.Rwkv_R, Xr, Rr);
   if E.Is_Ok (Status) then
      Project (Current.Rwkv_K, Xk, Kk);
   end if;
   if E.Is_Ok (Status) then
      Project (Current.Rwkv_V, Xv, Vv);
   end if;
   if E.Is_Ok (Status) then
      Project (Current.Rwkv_G, Xg, Gg);
   end if;

   --  The decay a channel: its stream through two low projections and a
   --  tanh, biased, and the double exponential that keeps it in (0, 1).
   Table (Current.Rwkv_Decay_W1, D_Dec, RW, Xw, RW, D1, D_Dec, 1);
   Table (Current.Rwkv_Decay_W2, RW, D_Dec, D1, D_Dec, Ww, RW, 2,
          Bias => Current.Rwkv_Decay);
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  The recurrence, the team's.
   declare
      Share : aliased Wkv_Share :=
        (Count => Count, RW => RW, HN => HN, Base => State_Base,
         St    => Item.Delta_State, U => Current.Rwkv_First,
         R     => Rr, K_Row => Kk, V => Vv, W => Ww, Y => Y);
   begin
      Workers_CPU.Dispatch_Shares
        (Item.Team, Heads, Share'Unchecked_Access, Status,
         Cost => Heads * HN * HN * Count * 3);
   end;
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  Its normalization and the gate, a share of the positions each.
   declare
      Share : aliased Wkv_Out_Share :=
        (RW => RW, HN => HN, Gain => Current.Rwkv_TM_LN,
         Shift => Current.Rwkv_TM_LN_Bias, G => Gg, Y => Y);
   begin
      Workers_CPU.Dispatch_Shares
        (Item.Team, Count, Share'Unchecked_Access, Status,
         Cost => Rows * 4);
   end;
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  The way out of the time mix, and the first residual.
   Project (Current.Rwkv_TM_Out, Y, N2);
   if E.Is_Error (Status) then
      Release;
      return;
   end if;
   for I in 0 .. Rows - 1 loop
      Inp (I) := N2 (I) + Acts (A0 + I);
   end loop;

   --  The last position's ln1 output, kept for the next batch's shift.
   Mem (Conv_Base .. Conv_Base + RW - 1) :=
     Cur (C0 + (Count - 1) * RW .. C0 + Count * RW - 1);

   --  === Channel mix ===
   --  ln2 of the first residual a position, and its shift against the
   --  position before -- the first against the second slot's.
   for P in 0 .. Count - 1 loop
      Normalize
        (Source, Inp (P * RW .. P * RW + RW - 1),
         Current.Second_Attention_Norm.all,
         Current.Second_Attention_Norm_Bias,
         N2 (P * RW .. P * RW + RW - 1));
   end loop;
   for P in 0 .. Count - 1 loop
      for C in 0 .. RW - 1 loop
         declare
            Before : constant Real :=
              (if P = 0 then Mem (Conv_Base + RW + C)
               else N2 ((P - 1) * RW + C));
            Here   : constant Real := N2 (P * RW + C);
            Shift  : constant Real := Before - Here;
         begin
            Xk (P * RW + C) :=
              Here + Shift * Current.Rwkv_CM_Lerp_K.all (C);
            Xr (P * RW + C) :=
              Here + Shift * Current.Rwkv_CM_Lerp_R.all (C);
         end;
      end loop;
   end loop;
   Mem (Conv_Base + RW .. Conv_Base + 2 * RW - 1) :=
     N2 ((Count - 1) * RW .. Count * RW - 1);

   --  The key's stream squared-ReLU'd, the receptance's through a
   --  sigmoid, and the value of the key weighted by it.
   Project (Current.Rwkv_CM_K, Xk, CK);
   if E.Is_Ok (Status) then
      for I in 0 .. Count * Feed - 1 loop
         CK (I) := (if CK (I) > 0.0 then CK (I) * CK (I) else 0.0);
      end loop;
      Project (Current.Rwkv_CM_R, Xr, CR);
   end if;
   if E.Is_Ok (Status) then
      Project (Current.Rwkv_CM_V, CK, CV);
   end if;
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  The second residual, and the rescale every so many layers that
   --  keeps the residual from growing without bound over the depth.
   declare
      Halve : constant Boolean :=
        Settings.Rescale_Every > 0
        and then (Layer_Index + 1) mod Settings.Rescale_Every = 0;
   begin
      for I in 0 .. Rows - 1 loop
         declare
            Value : constant Real :=
              Inp (I)
              + Real (1.0 / (1.0 + N.Exp (-N.Wide_Real (CR (I)))))
                * CV (I);
         begin
            Into (Into.all'First + I) :=
              (if Halve then Value * 0.5 else Value);
         end;
      end loop;
   end;

   Release;
end RWKV6_Batch;
