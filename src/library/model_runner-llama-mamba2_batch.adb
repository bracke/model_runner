separate (Model_Runner.Llama)
procedure Mamba2_Batch
  (Item        : in out Session;
   Source      : Model'Class;
   Current     : Layer;
   Layer_Index : Natural;
   Rows        : T.Real_Array_Access;
   Count       : Element_Count;
   Whole       : out Boolean;
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
   Taps  : constant Element_Count := Element_Count (Settings.Conv_Kernel);
   Group : constant Element_Count := Element_Count (Settings.Groups);
   Heads : constant Element_Count := Element_Count (Settings.Ssm_Heads);
   Wide  : constant Element_Count := Element_Count (Settings.Head_Dim);

   DXBC   : constant Element_Count := Inner + 2 * Group * State;
   In_Out : constant Element_Count := Inner + DXBC + Heads;

   Conv_Base  : constant Element_Count := Conv_At (Settings, Layer_Index);
   State_Base : constant Element_Count := State_At (Settings, Layer_Index);

   Own : constant Boolean := Count = 1;

   XZ, Xc, Y : T.Real_Array_Access := null;

   --  The scratch is the session's either way, kept for the next batch.
   procedure Release is null;

   --  A batch's scratch at least Length long: kept, or made anew.
   procedure Grow
     (Room : in out T.Real_Array_Access; Length : Element_Count) is
   begin
      if Room = null or else Room.all'Length < Length then
         T.Free (Room);
         T.Allocate (Length, Room);
      end if;
   end Grow;

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
   Whole := False;

   --  The mixer whole on the device, where it runs there: the memory
   --  and the state seated in the device's room and read and written
   --  there, one submission a mixer. Refused, they come home first and
   --  the host takes the mixer.
   if Mamba2_Fits (Item, Current) then
      declare
         Seated : Boolean;
         Ran    : Boolean := False;
      begin
         Send_States (Item'Unchecked_Access, Seated);
         if Seated then
            Model_Runner.Backend.Device.Mamba2_Layer
              (Mamba2_Block_Of (Item, Current, Layer_Index, False),
               Rows.all (Rows.all'First
                         .. Rows.all'First + Count * Width - 1),
               Count,
               Rows.all (Rows.all'First
                         .. Rows.all'First + Count * Width - 1),
               Ran, Item.Stopping);
         end if;

         if Ran then
            Whole := True;
            return;
         end if;
      end;
   end if;

   --  The host's copy of the memory and the state, where a mixer before
   --  this one left them on the device.
   Fetch_States (Item'Unchecked_Access);
   Item.Ring_Written := True;

   if Own then
      XZ := Item.Mamba_XZ;
      Xc := Item.Mamba_X;
      Y  := Item.Mamba_Y;
   else
      Grow (Item.Mamba_Batch_XZ, Count * In_Out);
      Grow (Item.Mamba_Batch_X, Count * DXBC);
      Grow (Item.Mamba_Batch_Y, Count * Inner);
      XZ := Item.Mamba_Batch_XZ;
      Xc := Item.Mamba_Batch_X;
      Y  := Item.Mamba_Batch_Y;
      if XZ = null or else Xc = null or else Y = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
   end if;

   --  The one projection in: z | x | B | C | dt a position.
   Project (Current.Ssm_In, Rows, XZ);
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   --  The convolution over the block past the gate, the team's, then
   --  the unit over all of it, so B and C pass through it as x does.
   declare
      Share : aliased Mamba_Conv_Share :=
        (Count  => Count, Inner => DXBC, Stride => In_Out, Shift => Inner,
         Taps   => Taps, Base => Conv_Base,
         Memory => Item.Conv_State, Conv => Current.Conv,
         Bias   => Current.Conv_Bias, XZ => XZ, Xc => Xc,
         Unit   => True);
   begin
      Workers_CPU.Dispatch_Shares
        (Item.Team, DXBC, Share'Unchecked_Access, Status,
         Cost => DXBC * Taps * Count);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
   end;

   --  Each head's step a position, through the softplus, and the decay
   --  it makes of the head's scalar transition; then the scan, the
   --  team's, a share of the channels each.
   declare
      Steps, Decays : T.Real_Array_Access;
   begin
      T.Allocate (Count * Heads, Steps);
      T.Allocate (Count * Heads, Decays);
      if Steps = null or else Decays = null then
         T.Free (Steps);
         T.Free (Decays);
         Release;
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      for P in 0 .. Count - 1 loop
         for Hd in 0 .. Heads - 1 loop
            declare
               Raw  : constant N.Wide_Real :=
                 N.Wide_Real (XZ (P * In_Out + Inner + DXBC + Hd)
                              + Current.DT_Bias.all (Hd));
               Soft : constant N.Wide_Real :=
                 (if Raw > 20.0 then Raw else N.Log (1.0 + N.Exp (Raw)));
            begin
               Steps (P * Heads + Hd) := Real (Soft);
               Decays (P * Heads + Hd) :=
                 Real (N.Exp (Soft * N.Wide_Real (Current.Ssm_A.all (Hd))));
            end;
         end loop;
      end loop;

      declare
         Share : aliased Mamba2_Scan_Share :=
           (Count  => Count, Inner => Inner, State => State,
            Group  => Group, Per_G => Heads / Group, Heads => Heads,
            Wide   => Wide, DXBC => DXBC, Base => State_Base,
            H      => Item.Delta_State, D => Current.Ssm_D,
            Steps  => Steps, Decays => Decays, Xc => Xc, Y => Y);
      begin
         Workers_CPU.Dispatch_Shares
           (Item.Team, Inner, Share'Unchecked_Access, Status,
            Cost => Inner * State * Count * 2);
      end;

      T.Free (Steps);
      T.Free (Decays);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
   end;

   --  The gate and the grouped normalization, the team's, a share of
   --  the positions each.
   declare
      Share : aliased Mamba2_Gate_Share :=
        (Inner   => Inner, In_Out => In_Out, Group => Group,
         Epsilon => Settings.Epsilon, Gain => Current.State_Norm,
         XZ      => XZ, Y => Y);
   begin
      Workers_CPU.Dispatch_Shares
        (Item.Team, Count, Share'Unchecked_Access, Status,
         Cost => Count * Inner * 4);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
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
            Rows.all (Rows.all'First .. Rows.all'First + Count * Width - 1)
              := Out_Rows.all (0 .. Count * Width - 1);
         end if;
         T.Free (Out_Rows);
      end;
   end if;

   Release;
end Mamba2_Batch;
