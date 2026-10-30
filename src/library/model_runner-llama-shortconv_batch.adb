separate (Model_Runner.Llama)
procedure Shortconv_Batch
  (Item        : in out Session;
   Source      : Model'Class;
   Current     : Layer;
   Layer_Index : Natural;
   Rows        : T.Real_Array_Access;
   Count       : Element_Count;
   Status      : out E.Error_Info)
is
   pragma Suppress (Index_Check);
   pragma Suppress (Range_Check);
   pragma Suppress (Overflow_Check);

   Settings : Configuration renames Source.Settings;
   Width : constant Element_Count := Element_Count (Settings.Embedding);
   Taps  : constant Element_Count := Element_Count (Settings.Conv_Kernel);

   --  B, C and x a position, end to end; B times x; the convolution's
   --  answer; that times C.
   BCX, BX, Conv, Y : T.Real_Array_Access := null;

   procedure Release is
   begin
      T.Free (BCX); T.Free (BX); T.Free (Conv); T.Free (Y);
   end Release;
begin
   Status := E.Success;

   --  The host's copy of the memory, where anything left it elsewhere.
   Fetch_States (Item'Unchecked_Access);
   Item.Ring_Written := True;

   T.Allocate (Count * 3 * Width, BCX);
   T.Allocate (Count * Width, BX);
   T.Allocate (Count * Width, Conv);
   T.Allocate (Count * Width, Y);
   if BCX = null or else BX = null or else Conv = null or else Y = null then
      Release;
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;

   if Count = 1 then
      Product (Item, Current.Mix, Rows, BCX, Status);
   else
      Product_Batch (Item, Current.Mix, Rows, Count, BCX, Status);
   end if;
   if E.Is_Error (Status) then
      Release;
      return;
   end if;

   for P in 0 .. Count - 1 loop
      declare
         Row : constant Element_Count := P * 3 * Width;
      begin
         for C in 0 .. Width - 1 loop
            BX (P * Width + C) := BCX (Row + C) * BCX (Row + 2 * Width + C);
         end loop;
      end;
   end loop;

   --  The convolution, the team's a share of the channels each, through
   --  Mamba's share: the same taps a channel, the memory the same rows.
   declare
      Share : aliased Mamba_Conv_Share :=
        (Count  => Count, Inner => Width, Stride => Width, Shift => 0,
         Taps   => Taps, Base => Conv_At (Settings, Layer_Index),
         Memory => Item.Conv_State, Conv => Current.Conv,
         Bias   => Current.Conv_Bias, XZ => BX, Xc => Conv,
         Unit   => False);
   begin
      Workers_CPU.Dispatch_Shares
        (Item.Team, Width, Share'Unchecked_Access, Status,
         Cost => Width * Taps * Count * 2);
      if E.Is_Error (Status) then
         Release;
         return;
      end if;
   end;

   for P in 0 .. Count - 1 loop
      declare
         Row : constant Element_Count := P * 3 * Width;
      begin
         for C in 0 .. Width - 1 loop
            Y (P * Width + C) := BCX (Row + Width + C) * Conv (P * Width + C);
         end loop;
      end;
   end loop;

   if Count = 1 then
      Product (Item, Current.Linear_Out, Y, Rows, Status);
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
         Product_Batch (Item, Current.Linear_Out, Y, Count, Out_Rows, Status);
         if E.Is_Ok (Status) then
            Rows.all (Rows.all'First .. Rows.all'First + Count * Width - 1) :=
              Out_Rows.all (0 .. Count * Width - 1);
         end if;
         T.Free (Out_Rows);
      end;
   end if;

   Release;
end Shortconv_Batch;
