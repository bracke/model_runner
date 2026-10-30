separate (Model_Runner.Llama)
procedure Shortconv_Batch
  (Item        : in out Session;
   Source      : Model'Class;
   Current     : Layer;
   Layer_Index : Natural;
   Position    : Natural;
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
   Back  : constant Element_Count := Taps - 1;

   --  Where this layer's memory lies in a slot of the ring, how far apart
   --  the slots are, and the slot the batch's first position reads.
   Memory_At  : constant Element_Count := Conv_At (Settings, Layer_Index);
   Every_Conv : constant Element_Count := Conv_Room (Settings);
   Read_At    : constant Element_Count :=
     State_Slot (Item, Position) * Every_Conv + Memory_At;

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
   --  The share leaves the batch's last memory where it read the first,
   --  which is the ring's slot for another position: what it read is kept
   --  first and put back, and the memories the ring holds written below.
   declare
      Read : constant Real_Array :=
        Item.Conv_State.all (Read_At .. Read_At + Back * Width - 1);

      Share : aliased Mamba_Conv_Share :=
        (Count  => Count, Inner => Width, Stride => Width, Shift => 0,
         Taps   => Taps, Base => Read_At,
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

      Item.Conv_State.all (Read_At .. Read_At + Back * Width - 1) := Read;

      --  The memory each position leaves -- its last Back inputs, the
      --  oldest first, from the batch or from what the batch read -- in
      --  the slot the position after it reads: the last position's, and
      --  as many before it as the ring keeps.
      for P in 0 .. Count - 1 loop
         if P = Count - 1
           or else (Item.Kept_States > 0
                    and then P + Element_Count (Item.Kept_States) + 1 >= Count)
         then
            declare
               Into : constant Element_Count :=
                 State_Slot (Item, Position + Natural (P) + 1) * Every_Conv
                 + Memory_At;
            begin
               for J in 0 .. Back - 1 loop
                  declare
                     From : constant Long_Long_Integer :=
                       Long_Long_Integer (P) - Long_Long_Integer (Back)
                       + 1 + Long_Long_Integer (J);
                  begin
                     if From >= 0 then
                        Item.Conv_State.all
                          (Into + J * Width .. Into + (J + 1) * Width - 1) :=
                          BX.all (Element_Count (From) * Width
                                  .. (Element_Count (From) + 1) * Width - 1);
                     else
                        Item.Conv_State.all
                          (Into + J * Width .. Into + (J + 1) * Width - 1) :=
                          Read (Read'First
                                + Element_Count (Long_Long_Integer (Back) + From)
                                  * Width
                                .. Read'First
                                   + (Element_Count (Long_Long_Integer (Back) + From)
                                      + 1) * Width - 1);
                     end if;
                  end;
               end loop;
            end;
         end if;
      end loop;
   end;
   Item.Kept_Newest :=
     Natural'Max (Item.Kept_Newest, Position + Natural (Count));

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
