separate (Model_Runner.Llama)
procedure Mamba_Batch
  (Item        : in out Session;
   Source      : Model'Class;
   Current     : Layer;
   Layer_Index : Natural;
   Rows        : T.Real_Array_Access;
   Count       : Element_Count;
   Status      : out E.Error_Info)
is
   --  Every index below is a position, a channel or a state inside
   --  arrays sized from the same three counts; the checks stop the
   --  element loops vectorizing.
   pragma Suppress (Index_Check);
   pragma Suppress (Range_Check);
   pragma Suppress (Overflow_Check);

   Settings : Configuration renames Source.Settings;
   Width : constant Element_Count := Element_Count (Settings.Embedding);
   Inner : constant Element_Count := Element_Count (Settings.Inner_Size);
   State : constant Element_Count := Element_Count (Settings.State_Size);
   Rank  : constant Element_Count := Element_Count (Settings.Time_Rank);
   Taps  : constant Element_Count := Element_Count (Settings.Conv_Kernel);
   Wide  : constant Element_Count := Rank + 2 * State;

   Conv_Base  : constant Element_Count := Conv_At (Settings, Layer_Index);
   State_Base : constant Element_Count := State_At (Settings, Layer_Index);

   XZ, Xc, DBC, DTR, DT, Y : T.Real_Array_Access := null;

   --  A batch of one is a generated token, and takes the session's own
   --  scratch, sized for one position, rather than allocating and
   --  clearing six arrays a layer a token.
   Own : constant Boolean := Count = 1;

   --  Whether a token's step projection goes inside the scan's shares,
   --  sixteen channels an item: its rows must be the channels, whole
   --  panels of them.
   Fused : constant Boolean :=
     Count = 1
     and then Inner mod Fused_Channels = 0
     and then Current.Ssm_Dt.Rows = Inner
     and then Halves_Whole (Current.Ssm_Dt)
     and then Current.DT_Bias /= null;

   procedure Release is
   begin
      if not Own then
         T.Free (XZ); T.Free (Xc); T.Free (DBC);
         T.Free (DTR); T.Free (DT); T.Free (Y);
      end if;
   end Release;

   --  A projection of the batch: the single-vector product for one.
   procedure Project
     (Weight : T.View; From, Into : T.Real_Array_Access) is
   begin
      if Count = 1 then
         Product (Item, Weight, From, Into, Status);
      else
         Product_Batch (Item, Weight, From, Count, Into, Status);
      end if;
   end Project;
begin
   Status := E.Success;

   --  The host's copy of the memory and the state, where a layer before
   --  this one went whole on the device and left them there.
   Fetch_States (Item'Unchecked_Access);
   Item.Ring_Written := True;

   if Own then
      XZ  := Item.Mamba_XZ;
      Xc  := Item.Mamba_X;
      DBC := Item.Mamba_DBC;
      DTR := Item.Mamba_DTR;
      DT  := Item.Mamba_DT;
      Y   := Item.Mamba_Y;
   else
      T.Allocate (Count * 2 * Inner, XZ);
      T.Allocate (Count * Inner, Xc);
      T.Allocate (Count * Wide, DBC);
      T.Allocate (Count * Rank, DTR);
      T.Allocate (Count * Inner, DT);
      T.Allocate (Count * Inner, Y);
   end if;
   if XZ = null or else Xc = null or else DBC = null or else DTR = null
     or else DT = null or else Y = null
   then
      Release;
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;

   --  The inputs projected to the inner activations and their gates.
   Project (Current.Ssm_In, Rows, XZ);
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  The causal convolution, the team's, then the unit. Its cost
   --  counts the logistic unit and the memory's shift beside the taps:
   --  counted as the taps alone, a token's was under the pool's floor
   --  and went on the calling task, 33 us a layer of Jamba where the
   --  pool takes 10.
   declare
      Share : aliased Mamba_Conv_Share :=
        (Count  => Count, Inner => Inner, Stride => 2 * Inner, Shift => 0,
         Taps   => Taps, Base => Conv_Base,
         Memory => Item.Conv_State, Conv => Current.Conv,
         Bias   => Current.Conv_Bias, XZ => XZ, Xc => Xc,
         Unit   => True);
   begin
      Workers_CPU.Dispatch_Shares
        (Item.Team, Inner, Share'Unchecked_Access, Status,
         Cost => Inner * Taps * Count * 4);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
   end;

   --  That projected to the time step, B and C.
   Project (Current.Ssm_X, Xc, DBC);
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  Jamba normalizes the time step and the B and C the projection
   --  produced -- each its own slice of a row -- by root mean square with
   --  a gain of its own, before the scan reads them. Plain Mamba leaves
   --  the three gains null and does not.
   if Current.Ssm_Dt_Norm /= null then
      for P in 0 .. Count - 1 loop
         declare
            procedure RMS (First, Width : Element_Count; Gain : Real_Array)
            is
               Sum : N.Wide_Real := 0.0;
               Inv : N.Wide_Real;
            begin
               for I in 0 .. Width - 1 loop
                  Sum := Sum + N.Wide_Real (DBC (First + I))
                             * N.Wide_Real (DBC (First + I));
               end loop;
               Inv := 1.0 / N.Sqrt (Sum / N.Wide_Real (Width)
                                    + N.Wide_Real (Settings.Epsilon));
               for I in 0 .. Width - 1 loop
                  DBC (First + I) :=
                    Real (N.Wide_Real (DBC (First + I)) * Inv
                          * N.Wide_Real (Gain (Gain'First + I)));
               end loop;
            end RMS;
         begin
            RMS (P * Wide, Rank, Current.Ssm_Dt_Norm.all);
            RMS (P * Wide + Rank, State, Current.Ssm_B_Norm.all);
            RMS (P * Wide + Rank + State, State, Current.Ssm_C_Norm.all);
         end;
      end loop;
   end if;

   --  The time steps projected up to the inner width and biased.
   for P in 0 .. Count - 1 loop
      DTR (P * Rank .. P * Rank + Rank - 1) :=
        DBC (P * Wide .. P * Wide + Rank - 1);
   end loop;
   if not Fused then
      Project (Current.Ssm_Dt, DTR, DT);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
      for P in 0 .. Count - 1 loop
         for C in 0 .. Inner - 1 loop
            DT (P * Inner + C) :=
              DT (P * Inner + C) + Current.DT_Bias.all (C);
         end loop;
      end loop;
   end if;

   if Item.Mamba_Steps = null or else Item.Mamba_Decays = null then
      Release;
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;

   --  The scan, the team's -- for a token, with the step projection
   --  in it, and the steps packed for it once.
   declare
      Packed    : aliased Workers_CPU.Packed_Rows;
      Is_Packed : Boolean := False;
   begin
      if Fused and then Item.Arithmetic (Current.Ssm_Dt.Role) then
         Workers_CPU.Pack
           (Packed, DTR, 1, Rank,
            Super  => Supers (Current.Ssm_Dt)
                      and then Rank mod Model_Runner.Quantization.Integers
                                          .Activation_Super = 0,
            Ok     => Is_Packed,
            Roles  => Item.Arithmetic);
      end if;

      declare
         Share : aliased Mamba_Scan_Share :=
           (Count => Count, Inner => Inner, State => State, Rank => Rank,
            Base  => State_Base,
            H     => Item.Delta_State, A => Current.Ssm_A,
            D     => Current.Ssm_D,
            Xc    => Xc, DT => DT, DBC => DBC, XZ => XZ, Y => Y,
            Fused => Fused, Dt_View => Current.Ssm_Dt,
            Dt_Bias => Current.DT_Bias, DTR => DTR,
            Roles => Item.Arithmetic,
            Packed => (if Is_Packed then Packed'Unchecked_Access else null),
            Steps => Item.Mamba_Steps, Decays => Item.Mamba_Decays,
            Ok => True);
      begin
         Workers_CPU.Dispatch_Shares
           (Item.Team,
            (if Fused then Inner / Fused_Channels else Inner),
            Share'Unchecked_Access, Status,
            Cost => Inner * State * Count * 4);
         Workers_CPU.Unpack (Packed);
         if E.Is_Error (Status) then
            Release;
            return;
         end if;
         if not Share.Ok then
            Release;
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
      end;
   end;

   --  And the projections back, into the rows the residual reads.
   if Count = 1 then
      Project (Current.Linear_Out, Y, Rows);
   else
      declare
         Out_Rows : T.Real_Array_Access;
      begin
         T.Allocate (Count * Width, Out_Rows);
         if Out_Rows = null then
            Release;
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
         Project (Current.Linear_Out, Y, Out_Rows);
         if E.Is_Ok (Status) then
            Rows.all (Rows.all'First .. Rows.all'First + Count * Width - 1) :=
              Out_Rows.all (0 .. Count * Width - 1);
         end if;
         T.Free (Out_Rows);
      end;
   end if;

   Release;
end Mamba_Batch;
