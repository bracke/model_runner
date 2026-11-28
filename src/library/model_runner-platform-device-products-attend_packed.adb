separate (Model_Runner.Platform.Device.Products)
procedure Attend_Packed
  (Item       : in out Engine;
   K_Bits     : Positive;
   V_Bits     : Positive;
   Query      : Model_Runner.Numerics.Real_Array;
   Heads      : Natural;
   Head_Size  : Natural;
   Value_Size : Natural;
   Group_Size : Natural;
   First      : Natural;
   Last       : Natural;
   K_Bytes    : Interfaces.Unsigned_64;
   V_Bytes    : Interfaces.Unsigned_64;
   KV_Width   : Natural;
   V_Width    : Natural;
   KS_At      : Natural;
   VS_At      : Natural;
   K_Blocks   : Natural;
   V_Blocks   : Natural;
   Scale      : Model_Runner.Numerics.Real;
   Cap        : Model_Runner.Numerics.Real;
   Target     : out Model_Runner.Numerics.Real_Array;
   Ok         : out Boolean;
   Positions  : Natural := 1;
   Window     : Natural := 0;
   Causal     : Boolean := True;
   Max_Bias   : Model_Runner.Numerics.Real := 0.0;
   K_Codec    : Cache_Codec := Inferred_From_Bits_Cache;
   V_Codec    : Cache_Codec := Inferred_From_Bits_Cache;
   Relative_At : Natural := 0)
is
   Ignored : constant Boolean := Set_Asking (Item);

   Held_K_Codec : constant Cache_Codec :=
     (if K_Codec /= Inferred_From_Bits_Cache then K_Codec
      elsif K_Bits = E4M3_Cache_Code then OCP_E4M3_Cache
      else Scaled_Integer_Cache);
   Held_V_Codec : constant Cache_Codec :=
     (if V_Codec /= Inferred_From_Bits_Cache then V_Codec
      elsif V_Bits = E4M3_Cache_Code then OCP_E4M3_Cache
      else Scaled_Integer_Cache);

   Slots : constant Natural := Natural'Max (Positions, 1);

   Kept_Bytes  : constant Interfaces.Unsigned_64 := Item.Cache_Bytes;
   Query_Bytes : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64 (Query'Length) * 4;
   Blend_Bytes : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64 (Slots) *
     Interfaces.Unsigned_64 (Heads) *
     Interfaces.Unsigned_64 (Value_Size) * 4;

   Good      : Boolean;
   Cancelled : Boolean;
begin
   Ok := False;

   if not Is_Ready (Item)
     or else not Packed_Fits
                   (Item,
                    (K_Codec => Held_K_Codec,
                     V_Codec => Held_V_Codec,
                     K_Bits => K_Bits, V_Bits => V_Bits,
                     K_Bytes => K_Bytes, V_Bytes => V_Bytes,
                     KS_At => KS_At, VS_At => VS_At,
                     K_Blocks => K_Blocks, V_Blocks => V_Blocks),
                    Head_Size, Value_Size, KV_Width, V_Width)
     or else Heads = 0
     or else Group_Size = 0
     or else Last < First
     or else Item.Cache_Buffer = Null_Handle
     or else Query'Length
               < Model_Runner.Numerics.Element_Count (Slots)
                 * Model_Runner.Numerics.Element_Count (Heads)
                 * Model_Runner.Numerics.Element_Count (Head_Size)
     or else Target'Length
               < Model_Runner.Numerics.Element_Count (Slots)
                 * Model_Runner.Numerics.Element_Count (Heads)
                 * Model_Runner.Numerics.Element_Count (Value_Size)
   then
      return;
   end if;

   if not Relative_Fits (Item, Held_K_Codec, Held_V_Codec, Relative_At, Heads, Positions, First) then
      return;
   end if;

   --  What is in flight done with the shared buffers before they are
   --  grown or the query written into them, as One_Product has it: a
   --  sequence handed over without a wait may still read the activation
   --  this overwrites.
   Settle (Item, Good);
   if not Good then
      return;
   end if;

   if Item.Vector_Bytes < Query_Bytes then
      Unmap_Standing (Item, Item.Vector_Memory, Item.Vector_At);
      Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
      Item.Vector_Bytes := 0;
      Take (Item, Query_Bytes, Item.Vector_Buffer, Item.Vector_Memory,
            Good);
      if not Good then
         Give_Back_Buffer (Item, Item.Vector_Buffer, Item.Vector_Memory);
         return;
      end if;
      Item.Vector_Bytes := Query_Bytes;
   end if;

   if Item.Result_Bytes < Blend_Bytes then
      Unmap_Standing (Item, Item.Result_Memory, Item.Result_At);
      Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
      Item.Result_Bytes := 0;
      Take (Item, Blend_Bytes, Item.Result_Buffer, Item.Result_Memory,
            Good, Read => True);
      if not Good then
         Give_Back_Buffer (Item, Item.Result_Buffer, Item.Result_Memory);
         return;
      end if;
      Item.Result_Bytes := Blend_Bytes;
   end if;

   Standing (Item, Item.Vector_Memory, Item.Vector_At, Item.Vector_Bytes,
             Good);
   if Good then
      declare
         Room : Model_Runner.Numerics.Real_Array (Query'Range)
           with Import, Address => Item.Vector_At;
      begin
         Room := Query;
      end;
   end if;
   if not Good then
      return;
   end if;

   declare
      Update : constant Update_Sets_Call :=
        To_Update_Sets (Point ("vkUpdateDescriptorSets"));

      Told  : aliased Buffer_Info_Array;
      Notes : aliased Write_Array;
   begin
      if Update = null then
         return;
      end if;

      Told (1) := (Item.Cache_Buffer, 0, Kept_Bytes);
      Told (2) := (Item.Vector_Buffer, 0, Query_Bytes);
      Told (3) := (Item.Result_Buffer, 0, Blend_Bytes);
      Told (4) := Half_Descriptor (Item);
      Told (5) := Told (3);

      Told (6) := Copy_Descriptor (Item);

      for Binding in Told'Range loop
         Notes (Binding).Target := Item.Descriptor;
         Notes (Binding).Binding := C.unsigned (Binding - 1);
         Notes (Binding).Buffers := Told (Binding)'Address;
      end loop;

      Update (Item.Logical, 6, Notes'Address, 0, Null_Handle);
   end;

   declare
      Reset_Buffer : constant Reset_Buffer_Call :=
        To_Reset_Buffer (Point ("vkResetCommandBuffer"));
      Start : constant Begin_Call :=
        To_Begin (Point ("vkBeginCommandBuffer"));
      Stop  : constant End_Call := To_End (Point ("vkEndCommandBuffer"));
      Bind_Pipeline : constant Bind_Pipeline_Call :=
        To_Bind_Pipeline (Point ("vkCmdBindPipeline"));
      Bind_Sets : constant Bind_Sets_Call :=
        To_Bind_Sets (Point ("vkCmdBindDescriptorSets"));
      Push : constant Push_Call := To_Push (Point ("vkCmdPushConstants"));
      Dispatch : constant Dispatch_Call :=
        To_Dispatch (Point ("vkCmdDispatch"));

      Sets  : aliased Address := Item.Descriptor;
      Began : aliased Command_Begin_Info;

      Queries : constant Positive := Packed_Queries (Slots);
      Bundle  : constant Positive :=
        Packed_Bundle (Item, Group_Size, Queries, Last - First + 1);

      Shape : aliased Packed_Constants :=
        (Heads      => C.unsigned (Heads),
         Head_Size  => C.unsigned (Head_Size),
         Value_Size => C.unsigned (Value_Size),
         Group_Size => C.unsigned (Group_Size),
         First      => C.unsigned (First),
         Last       => C.unsigned (Last),
         K_Bytes    => C.unsigned (K_Bytes),
         V_Bytes    => C.unsigned (V_Bytes),
         KV_Width   => C.unsigned (KV_Width),
         V_Width    => C.unsigned (V_Width),
         KS_At      => C.unsigned (KS_At),
         VS_At      => C.unsigned (VS_At),
         K_Blocks   => C.unsigned (K_Blocks),
         V_Blocks   => C.unsigned (V_Blocks),
         K_Bits     => C.unsigned (K_Bits),
         V_Bits     => C.unsigned (V_Bits),
         Scale      => C.C_float (Scale),
         Cap        => C.C_float (Cap),
         Max_Bias   => C.C_float (Max_Bias),
         Positions  => C.unsigned (Slots),
         Window     => C.unsigned (Window),
         Causal     => (if Causal then 1 else 0),
         Bundle     => C.unsigned (Bundle),
         Queries    => C.unsigned (Queries),
         Table_At   => 0,
         Sinks_At   => 0,

         --  The single call reads one session's cache whole, never a
         --  round and never in pages.
         Pages_At       => 0,
         Page_Shift     => 0,
         First_Position => 0,
         K_Codec => C.unsigned (Cache_Codec'Pos (Held_K_Codec)),
         V_Codec => C.unsigned (Cache_Codec'Pos (Held_V_Codec)), Relative_At => C.unsigned (Relative_At));
   begin
      if Reset_Buffer = null or else Start = null or else Stop = null
        or else Bind_Pipeline = null or else Bind_Sets = null
        or else Push = null or else Dispatch = null
      then
         return;
      end if;

      declare
         Settled : Boolean;
      begin
         Settle (Item, Settled);
         if not Settled then
            return;
         end if;
      end;

      if Reset_Buffer (Item.Buffer, 0) /= 0
        or else Opened (Item.Buffer, Start, Began'Address) /= 0
      then
         return;
      end if;

      --  A workgroup its rows of heads and positions, and one slice:
      --  the single call has no merge after it, and a sequence is
      --  where a token's long cache is cut.
      Bind_Pipeline (Item.Buffer, Bind_Point_Compute,
                     Packed_Pipeline (Item));
      Bind_Sets (Item.Buffer, Bind_Point_Compute, Item.Layout, 0, 1,
                 Sets'Address, 0, Null_Handle);
      Push (Item.Buffer, Item.Layout, Stage_Compute, 0,
            Packed_Bytes, Shape'Address);
      Dispatch (Item.Buffer,
                C.unsigned ((Heads + Bundle - 1) / Bundle),
                C.unsigned ((Slots + Queries - 1) / Queries), 1);

      if Stop (Item.Buffer) /= 0 then
         return;
      end if;
   end;

   Submit_And_Wait (Item, Good, Cancelled, null);
   if not Good then
      return;
   end if;

   declare
      Good_Map : Boolean;
   begin
      Standing (Item, Item.Result_Memory, Item.Result_At,
                Item.Result_Bytes, Good_Map);
      if not Good_Map then
         return;
      end if;

      declare
         Slice : Model_Runner.Numerics.Real_Array
           (Target'First
            .. Target'First
               + Model_Runner.Numerics.Element_Count (Slots)
                 * Model_Runner.Numerics.Element_Count (Heads)
                 * Model_Runner.Numerics.Element_Count (Value_Size) - 1)
           with Import, Address => Item.Result_At;
      begin
         Target (Slice'Range) := Slice;
      end;
   end;

   Ok := True;
end Attend_Packed;
