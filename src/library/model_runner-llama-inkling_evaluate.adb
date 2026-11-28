with Model_Runner.Llama.Execution_Schedules;
with System.Machine_Code;

separate (Model_Runner.Llama)
procedure Inkling_Evaluate
  (Item : in out Session; Source : Model'Class; Row : T.Real_Array_Access;
   Cancel : Model_Runner.Cancellation.Token_Reference; Status : out E.Error_Info;
   Batch_Count : Element_Count := 1; Embeddings : T.Real_Array_Access := null;
   States : T.Real_Array_Access := null; Every : T.Real_Array_Access := null;
   Normalized : Boolean := True; Transaction : Boolean := True)
is
   package S renames Model_Runner.Llama.Execution_Schedules;
   Settings : Configuration renames Source.Settings;
   Wide_Values : constant Boolean := Workers_CPU.Wide_Vectors;
   Reference_Arithmetic : constant Boolean := (for some Role of Item.Arithmetic => Role);
   H : constant Element_Count := Element_Count (Settings.Embedding);
   D : constant Element_Count := Element_Count (Settings.Head_Size);
   Q : constant Element_Count := Element_Count (Settings.Heads);
   KV : constant Element_Count := Element_Count (Settings.KV_Heads);
   R : constant Element_Count := Element_Count (Settings.Inkling.Relative_Width);
   C_Taps : constant Element_Count := Element_Count (Settings.Inkling.Convolution_Length);
   Rank : constant Element_Count := Element_Count (Settings.Inkling.Gate_Rank);
   Channels : constant Element_Count := 2 * KV * D + 2 * H;
   Wide : constant Element_Count := Batch_Count * H;
   Vocab : constant Element_Count := Element_Count (Settings.Vocabulary);
   subtype Hidden is Real_Array (0 .. H - 1);
   Acts_Base : constant Element_Count := 0;
   Normals_Base : constant Element_Count := Acts_Base + Batch_Count * (H);
   Blocks_Base : constant Element_Count := Normals_Base + Batch_Count * (H);
   Bank_Base : constant Element_Count := Blocks_Base + Batch_Count * (4 * H);
   Prelude_Base : constant Element_Count := Bank_Base + Batch_Count * (H);
   Bank_Out_Base : constant Element_Count := Prelude_Base + Batch_Count * (H);
   Residual_Base : constant Element_Count := Bank_Out_Base + Batch_Count * (H);
   Inputs_Base : constant Element_Count := Residual_Base + Batch_Count * (H);
   Messages_Base : constant Element_Count := Inputs_Base + Batch_Count * (3 * H);
   In_Q_Base : constant Element_Count := Messages_Base + Batch_Count * (4 * H);
   In_K_Base : constant Element_Count := In_Q_Base + Batch_Count * (H);
   In_V_Base : constant Element_Count := In_K_Base + Batch_Count * (H);
   Queries_Base : constant Element_Count := In_V_Base + Batch_Count * (H);
   Keys_Base : constant Element_Count := Queries_Base + Batch_Count * (Q * D);
   Values_Base : constant Element_Count := Keys_Base + Batch_Count * (KV * D);
   Relatives_Base : constant Element_Count := Values_Base + Batch_Count * (KV * D);
   Gate_Rows_Base : constant Element_Count := Relatives_Base + Batch_Count * (Q * R);
   Sink_Rows_Base : constant Element_Count := Gate_Rows_Base + Batch_Count * (Q * D);
   Dynamic_K_Base : constant Element_Count := Sink_Rows_Base + Batch_Count * (Q);
   Dynamic_V_Base : constant Element_Count := Dynamic_K_Base + Batch_Count * (KV * C_Taps);
   Attention_Rows_Base : constant Element_Count := Dynamic_V_Base + Batch_Count * (KV * C_Taps);
   Mixtures_Base : constant Element_Count := Attention_Rows_Base + Batch_Count * (Q * D);
   Mix_States_Base : constant Element_Count := Mixtures_Base + Batch_Count * (H);
   Mix_Scores_Base : constant Element_Count := Mix_States_Base + Batch_Count * (5 * H);
   Joined_Base : constant Element_Count := Mix_Scores_Base + Batch_Count * (20);
   Down_Base : constant Element_Count := Joined_Base + Batch_Count * (2 * H);
   Gain_Base : constant Element_Count := Down_Base + Batch_Count * (Rank);
   Forget_Base : constant Element_Count := Gain_Base + Batch_Count * (H);
   Projection_Group_Base : constant Element_Count := Forget_Base + Batch_Count * H;
   Relative_Table_Base : constant Element_Count := Projection_Group_Base + 7 * H;
   Room : constant Element_Count := Relative_Table_Base;
   Arena : T.Real_Array_Access := null;
   Head_Rows : T.Real_Array_Access := null;
   Previous_Normal : Hidden with Import,
     Address => Item.Inkling_Workspace.all (Inkling_Work_Room (Settings) - H)'Address;
   Order : S.Schedule;
   Step : S.Execution_Step;
   Used_Blocks : Natural := 0;
   Observing_Token : Element_Count := 0;
   Backed_Up : Boolean := False;
   Reserved : constant Natural := Item.Committed;
   Sequential_Device : constant Boolean := Batch_Count > 1
     and then Item.Held = Transformed_Fourth
     and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
     and then (not Reference_Arithmetic or else Batch_Count > 128);
   Output_Ready : Boolean := False;
   Output_Finished : Boolean := False;
   Attention_Ready : Boolean := False;
   Attention_Convolved : Boolean := False;
   Attention_Joined : Boolean := False;
   Aborted : exception;
   Mark : Ada.Real_Time.Time := (if Item.Budgeting then Ada.Real_Time.Clock else Ada.Real_Time.Time_First);

   procedure Release is
   begin
      null; --  Scratch is session-owned and reused after this call.
   end Release;

   --  Selective feature capture does not change observer/backend eligibility.
   procedure Capture (Logical : Natural; Values : Real_Array) is
      Number : Element_Count;
   begin
      if Item.Feature_Request = null then return; end if;
      Number := Element_Count (Item.Feature_Request.all'Length);
      for Index in Item.Feature_Request.all'Range loop
         if Item.Feature_Request (Index) = Logical then
            for Token in 0 .. Batch_Count - 1 loop
               declare
                  Into : constant Element_Count := Item.Feature_Rows.all'First
                    + ((Element_Count (Item.Committed - Item.Feature_Start) + Token) * Number
                      + Element_Count (Index - Item.Feature_Request.all'First)) * H;
               begin
                  Item.Feature_Rows.all (Into .. Into + H - 1) :=
                    Values (Values'First + Token * H .. Values'First + (Token + 1) * H - 1);
               end;
            end loop;
            return;
         end if;
      end loop;
   end Capture;

   procedure Observe_One (Which : String; Values : Real_Array) is
   begin
      if Item.Seen /= null then
         Note_State (Item.Seen.all, Which, Step.Physical_Layer, Step.Logical_Layer,
                     Step.Visit, Item.Committed + Natural (Observing_Token), Values);
      end if;
   end Observe_One;

   procedure Observe (Which : String; Values : Real_Array) is
      Width : constant Element_Count := Values'Length / Batch_Count;
   begin
      if Item.Seen /= null then
         for Token in 0 .. Batch_Count - 1 loop
            Observing_Token := Token;
            Observe_One (Which, Values (Values'First + Token * Width .. Values'First + (Token + 1) * Width - 1));
         end loop;
      end if;
   end Observe;

   procedure Check is
   begin
      if E.Is_Error (Status) then
         raise Aborted;
      end if;
      if C.Is_Cancelled (Cancel) then
         Status := E.Make (E.Generation_Cancelled);
         raise Aborted;
      end if;
   end Check;

   procedure Finite (Values : Real_Array) is
   begin
      if not K.All_Finite (Values) then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         raise Aborted;
      end if;
   end Finite;

   function Cached (Weight : T.View) return T.Real_Array_Access is
      Slot : Natural := 0;
      Found : Boolean := False;
      Buffer : T.Real_Array_Access := null;
      Rows : Element_Count := Weight.Rows;
   begin
      for Role in Inkling_Weight_Role loop
         declare
            Held : T.View renames Source.Layers (Step.Physical_Layer).Inkling_Weights (Role);
         begin
            if Held.Base = Weight.Base and then Held.Offset = Weight.Offset and then T.Is_Present (Held) then
               Slot := Step.Physical_Layer * (Inkling_Weight_Role'Pos (Inkling_Weight_Role'Last) + 1)
                 + Inkling_Weight_Role'Pos (Role);
               if Role = Inkling_Relative_Bias then
                  Rows := Element_Count'Min (Rows, Element_Count (Item.Context));
               end if;
               Found := True;
               exit;
            end if;
         end;
      end loop;
      if not Found then
         Status := E.Make (E.Internal_Invariant_Violated);
         raise Aborted;
      end if;
      if Item.Inkling_Decoded (Slot) = null then
         T.Allocate (Rows * Weight.Columns, Buffer);
         if Buffer = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            raise Aborted;
         end if;
         begin
            for Index in 0 .. Rows - 1 loop
               T.Dequantize_Row (Weight, Index,
                 Buffer.all (Index * Weight.Columns .. (Index + 1) * Weight.Columns - 1), Status);
               Check;
            end loop;
         exception
            when others => T.Free (Buffer); raise;
         end;
         Item.Inkling_Decoded (Slot) := Buffer;
      end if;
      return Item.Inkling_Decoded (Slot);
   end Cached;

   function With_Scales (Weight : T.View; Many : Element_Count) return T.View is
      Result : T.View := Weight;
      Count : constant Element_Count := T.Scale_Count (Weight);
      Slot : Natural;
      Buffer : T.Real_Array_Access := null;
      Limit : constant Interfaces.Unsigned_64 := 128 * 1024 * 1024;
   begin
      if Count = 0 or else Many > 16 or else Item.Inkling_Scale_Data = null
        or else (for some Role of Item.Arithmetic => Role)
        or else (not Item.Host_Feed and then Model_Runner.Backend."="
                   (Source.Able.Kind, Model_Runner.Backend.Backend_Device))
      then return Result; end if;
      for Role in Inkling_Weight_Role loop
         declare
            Held : T.View renames Source.Layers (Step.Physical_Layer).Inkling_Weights (Role);
         begin
            if Held.Base = Weight.Base and then Held.Offset = Weight.Offset
              and then Held.Rows = Weight.Rows and then Held.Columns = Weight.Columns
            then
               Slot := Step.Physical_Layer * (Inkling_Weight_Role'Pos (Inkling_Weight_Role'Last) + 1)
                 + Inkling_Weight_Role'Pos (Role);
               if Item.Inkling_Scale_Data (Slot) = null
                 and then Interfaces.Unsigned_64 (Count) * 4 <= Limit - Item.Inkling_Scale_Bytes
               then
                  T.Allocate (Count, Buffer);
                  if Buffer /= null then
                     T.Decode_Scales (Weight, Buffer.all, Status);
                     if E.Is_Error (Status) then T.Free (Buffer); Check; end if;
                     Item.Inkling_Scale_Data (Slot) := Buffer;
                     Item.Inkling_Scale_Bytes := Item.Inkling_Scale_Bytes + Interfaces.Unsigned_64 (Count) * 4;
                  end if;
               end if;
               Result.Scales := Item.Inkling_Scale_Data (Slot);
               exit;
            end if;
         end;
      end loop;
      return Result;
   end With_Scales;

   procedure Mat
     (Physical_Weight : T.View; Input : Real_Array; Output : out Real_Array;
      Many : Element_Count := Batch_Count; Into : Phase := Projecting) is
      Weight : constant T.View := With_Scales (Physical_Weight, Many);
   begin
      if Many = 1 then
         Product (Item, Weight, Input'Unrestricted_Access, Output'Unrestricted_Access, Status);
      elsif (for some Role of Item.Arithmetic => Role)
        and then not Item.Arithmetic (Weight.Role)
      then
         --  Unqualified device integer batching retains its prior row path.
         --  The CPU batch packer quantizes each row independently.
         --  Keep its scalar product arithmetic, as the expert path does.
         --  The qualified F32 profile below uses actual batched products.
         declare
            Width : constant Element_Count := Output'Length / Many;
         begin
            for Token in 0 .. Many - 1 loop
               Product
                 (Item, Weight,
                  Input (Input'First + Token * Weight.Columns
                         .. Input'First + (Token + 1) * Weight.Columns - 1)'Unrestricted_Access,
                  Output (Output'First + Token * Width
                          .. Output'First + (Token + 1) * Width - 1)'Unrestricted_Access, Status);
               Check;
            end loop;
         end;
      else
         Product_Batch (Item, Weight, Input'Unrestricted_Access, Many, Output'Unrestricted_Access, Status);
      end if;
      Check;
      Finite (Output);
      Charge (Item, Into, Mark);
   end Mat;

   procedure Shared_Mats
     (Weights : T.View_Group; Input : in out Real_Array; Targets : T.Target_Group;
      Gain : T.Real_Array_Access := null; Scratch : T.Real_Array_Access := null)
   is
      package QI renames Model_Runner.Quantization.Integers;
      type Flags is array (Natural range 0 .. 3) of Boolean;
      Tried, Packed : Flags := [others => False];
      Views : T.View_Group (Weights'Range);
      type Offsets is array (Weights'Range) of Element_Count;
      Starts, Stops : Offsets := [others => 0];
      type Slots is array (Weights'Range) of Natural;
      Classes : Slots;
      Factors : Real_Array (1 .. (if Gain = null then 0 else Batch_Count));
      Total, Cost : Element_Count := 0;
      Materialized : Boolean := False;
      procedure Produce (First : Element_Count; Into : out Real_Array) is
         Token : constant Element_Count := First / H;
         At_Gain : constant Element_Count := First mod H;
         Whole : constant Element_Count := (if Wide_Values then Into'Length / 8 * 8 else 0);
         LF : constant Character := ASCII.LF;
      begin
         --  The packer assigns complete rows, so this worker produces the
         --  row's factor before any of its blocks consumes it.
         if At_Gain = 0 then
            Factors (Token + 1) := K.RMS_Scale (Input (Input'First + Token * H
                                                    .. Input'First + (Token + 1) * H - 1), Settings.Epsilon);
         end if;
         if Whole > 0 then
            System.Machine_Code.Asm
              ("vbroadcastss %4, %%ymm2" & LF & "xorq %%rcx, %%rcx" & LF & "1:" & LF
               & "vmulps (%0, %%rcx, 4), %%ymm2, %%ymm0" & LF
               & "vmulps (%1, %%rcx, 4), %%ymm0, %%ymm0" & LF
               & "vmovups %%ymm0, (%2, %%rcx, 4)" & LF
               & "vmovups %%ymm0, (%3, %%rcx, 4)" & LF
               & "addq $8, %%rcx" & LF & "cmpq %5, %%rcx" & LF & "jb 1b" & LF & "vzeroupper",
               Inputs => [System.Address'Asm_Input ("r", Input (Input'First + First)'Address),
                          System.Address'Asm_Input ("r", Gain (Gain.all'First + At_Gain)'Address),
                          System.Address'Asm_Input ("r", Into (Into'First)'Address),
                          System.Address'Asm_Input ("r", Scratch (Scratch.all'First + First)'Address),
                          Real'Asm_Input ("m", Factors (Token + 1)),
                          Element_Count'Asm_Input ("r", Whole)],
               Clobber => "ymm0,ymm2,rcx,cc,memory", Volatile => True);
         end if;
         for I in Whole .. Element_Count (Into'Length) - 1 loop
            Into (Into'First + I) := Input (Input'First + First + I) * Factors (Token + 1)
              * Gain (Gain.all'First + At_Gain + I);
            Scratch (Scratch.all'First + First + I) := Into (Into'First + I);
         end loop;
         if First + Into'Length = Input'Length then Materialized := True; end if;
      end Produce;
      type Product_Share is limited new Workers_CPU.Task_Item with record
         Valid : aliased Boolean := True with Atomic;
      end record;
      overriding procedure Run (Work : in out Product_Share; From, To : Element_Count);
      overriding procedure Run (Work : in out Product_Share; From, To : Element_Count) is
         Done : Boolean;
      begin
         for I in Views'Range loop
            if Stops (I) > Starts (I) and then From < Stops (I) and then To >= Starts (I) then
               Workers_CPU.Multiply_Packed_Whole
                 (Views (I), Item.Expert_Packed (Classes (I)),
                  Targets (Targets'First + I - Views'First).all, Done,
                  First_Row => Element_Count'Max (From, Starts (I)) - Starts (I),
                  Last_Row => Element_Count'Min (To, Stops (I) - 1) - Starts (I));
               if not Done then Work.Valid := False; end if;
            end if;
         end loop;
      end Run;
      Work : aliased Product_Share;
   begin
      for I in Views'Range loop
         Views (I) := With_Scales (Weights (I), Batch_Count);
         declare
            Weight : T.View renames Views (I);
            Slot : constant Natural := (if QI.Supers_Vectors (Weight.Format) then 2 else 0)
              + (if Weight.Format in Model_Runner.GGUF.Type_Q8_0 | Model_Runner.GGUF.Type_Q5_0
                | Model_Runner.GGUF.Type_IQ4_NL | Model_Runner.GGUF.Type_Q2_0 then 1 else 0);
         begin
            Classes (I) := Slot; Starts (I) := Total; Stops (I) := Total;
            if Item.Arithmetic (Weight.Role) and then Weight.Reference_Activations
              and then QI.Packs_Vectors (Weight.Format, Batch_Count, Weight.Interleaved, True)
            then
               if not Tried (Slot) then
                  Tried (Slot) := True;
                  Workers_CPU.Pack
                    (Item.Expert_Packed (Slot), Input'Unrestricted_Access, Batch_Count, H, Slot >= 2, Packed (Slot),
                     Roles => [others => True], Reference_Arithmetic => True, Half_Scales => Slot mod 2 = 1,
                     Transform => (if Gain = null then null else Produce'Unrestricted_Access), Team => Item.Team);
               end if;
               if Packed (Slot) then
                  Total := Total + Weight.Rows; Stops (I) := Total;
                  Cost := Cost + Weight.Rows * Weight.Columns * Batch_Count;
               end if;
            end if;
         end;
      end loop;
      if Total > 0 then
         Workers_CPU.Dispatch_Shares (Item.Team, Total, Work'Unchecked_Access, Status, Cost => Cost);
         Check;
         if not Work.Valid then Status := E.Make (E.Tensor_Shape_Mismatch); raise Aborted; end if;
      end if;
      if Gain /= null then
         if not Materialized then
            Scratch.all := Input;
            for Token in 0 .. Batch_Count - 1 loop
               K.RMS_Norm_In_Place (Scratch.all (Scratch.all'First + Token * H
                 .. Scratch.all'First + (Token + 1) * H - 1), Gain.all, Settings.Epsilon);
            end loop;
         end if;
         Input := Scratch.all;
      end if;
      for I in Views'Range loop
         if Stops (I) = Starts (I) then Mat (Views (I), Input, Targets (Targets'First + I - Views'First).all);
         else Finite (Targets (Targets'First + I - Views'First).all); end if;
      end loop;
      Charge (Item, Projecting, Mark);
   end Shared_Mats;

   procedure Finish_Row (Values : in out Real_Array) is
      use type Workers_CPU.Pool_Reference;
      type Output_Share is limited new Workers_CPU.Task_Item with null record;
      overriding procedure Run (Share : in out Output_Share; From, To : Element_Count);
      overriding procedure Run (Share : in out Output_Share; From, To : Element_Count) is
         pragma Unreferenced (Share);
      begin
         Finish_Logits (Source, Values (Values'First + From .. Values'First + To),
                        Reference_Arithmetic, Add_Bias => False);
      end Run;
      Work : aliased Output_Share;
   begin
      if Reference_Arithmetic and then Item.Team /= null and then Values'Length > 0 then
         if Source.Output_Bias /= null and then Source.Output_Bias.all'Length = Values'Length then
            K.Add (Values, Source.Output_Bias.all);
         end if;
         Workers_CPU.Dispatch_Shares
           (Item.Team, Values'Length, Work'Unchecked_Access, Status, Cost => Values'Length * 32);
         Check;
      else
         Finish_Logits (Source, Values, Reference_Arithmetic);
      end if;
   end Finish_Row;

   procedure Fused_Output (Input : Real_Array; Into : in out Real_Array; Many : Element_Count; Done : out Boolean) is
      Packed : Workers_CPU.Packed_Rows renames Item.Expert_Packed (0);
      Ready : Boolean;
      --  Finish a bounded row tile while its logits remain near the core.
      Tile_Rows : constant Element_Count := 128;
      protected Best_Of is
         procedure Consider (Row : Element_Count; Value : Real; Id : Token_Id);
         procedure Publish;
      private
         Best : Real_Array (0 .. Many - 1) := [others => Real'First];
         Which : Model_Runner.Tokenizer.Token_Array (1 .. Positive (Many)) :=
           [others => Model_Runner.Tokenizer.No_Token];
      end Best_Of;
      protected body Best_Of is
         procedure Consider (Row : Element_Count; Value : Real; Id : Token_Id) is
            At_Row : constant Positive := Positive (Row + 1);
         begin
            if Id /= Model_Runner.Tokenizer.No_Token
              and then (Which (At_Row) = Model_Runner.Tokenizer.No_Token or else Value > Best (Row)
                or else (Value = Best (Row) and then Id < Which (At_Row)))
            then Best (Row) := Value; Which (At_Row) := Id; end if;
         end Consider;
         procedure Publish is
         begin
            Item.Inkling_Greedy_Result := Which (Which'Last);
            if Item.Inkling_Greedy_Rows /= null and then Item.Inkling_Greedy_Rows.all'Length = Natural (Many) then
               for I in Which'Range loop
                  Item.Inkling_Greedy_Rows (Item.Inkling_Greedy_Rows.all'First + I - 1) := Which (I);
               end loop;
            end if;
         end Publish;
      end Best_Of;
      type Output_Work is limited new Workers_CPU.Task_Item with record
         Valid : Boolean := True with Atomic;
      end record;
      overriding procedure Run (Work : in out Output_Work; From, To : Element_Count);
      overriding procedure Run (Work : in out Output_Work; From, To : Element_Count) is
         Ok : Boolean;
         Best : Real_Array (0 .. Many - 1) := [others => Real'First];
         Winners : Model_Runner.Tokenizer.Token_Array (1 .. Positive (Many)) :=
           [others => Model_Runner.Tokenizer.No_Token];
         At_Row : Element_Count := From;
         Room : Real_Array (0 .. (if Item.Compact_Verify then Many * Tile_Rows else 1) - 1);
         procedure Finish_Tile (Values : in out Real_Array; Token, Last_Row : Element_Count) is
            Choice : Token_Id renames Winners (Positive (Token + 1));
         begin
            if Source.Output_Bias /= null then
               K.Add (Values, Source.Output_Bias.all
                 (Source.Output_Bias.all'First + At_Row .. Source.Output_Bias.all'First + Last_Row));
            end if;
            Finish_Logits (Source, Values, True, Add_Bias => False);
            if Item.Inkling_Greedy_Head then
               for I in At_Row .. Last_Row loop
                  if Token_Id (I) /= Item.Inkling_Greedy_Forbid
                    and then (Choice = Model_Runner.Tokenizer.No_Token
                      or else Values (Values'First + I - At_Row) > Best (Token))
                  then Best (Token) := Values (Values'First + I - At_Row); Choice := Token_Id (I); end if;
               end loop;
            end if;
         end Finish_Tile;
      begin
         while At_Row <= To loop
            declare
               Last_Row : constant Element_Count := At_Row + Element_Count'Min (Tile_Rows - 1, To - At_Row);
               Rows : constant Element_Count := Last_Row - At_Row + 1;
               Weight : T.View := Source.Output;
            begin
               if Item.Compact_Verify then
                  Weight.Rows := Rows; Weight.Offset := Weight.Offset + B.Byte_Count (At_Row) * T.Row_Bytes (Weight);
                  Weight.Length := B.Byte_Count (Rows) * T.Row_Bytes (Weight); Weight.Scales := null;
                  Workers_CPU.Multiply_Packed_Whole (Weight, Packed, Room, Ok);
               else
                  Workers_CPU.Multiply_Packed_Whole
                    (Weight, Packed, Into, Ok, First_Row => At_Row, Last_Row => Last_Row);
               end if;
               if not Ok then Work.Valid := False; return; end if;
               for Token in 0 .. Many - 1 loop
                  if Item.Compact_Verify then
                     Finish_Tile (Room (Token * Rows .. (Token + 1) * Rows - 1), Token, Last_Row);
                     if Token = Many - 1 then
                        Into (Into'First + At_Row .. Into'First + Last_Row) :=
                          Room (Token * Rows .. (Token + 1) * Rows - 1);
                     end if;
                  else
                     Finish_Tile (Into (Into'First + Token * Vocab + At_Row
                       .. Into'First + Token * Vocab + Last_Row), Token, Last_Row);
                  end if;
               end loop;
               exit when Last_Row = To;
               At_Row := Last_Row + 1;
            end;
         end loop;
         if Item.Inkling_Greedy_Head then
            for Token in 0 .. Many - 1 loop
               Best_Of.Consider (Token, Best (Token), Winners (Positive (Token + 1)));
            end loop;
         end if;
      end Run;
      Work : aliased Output_Work;
   begin
      Done := False;
      if not Reference_Arithmetic or else not Item.Arithmetic (Source.Output.Role)
        or else not Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_CPU)
        or else Item.Seen /= null or else Source.Runtime_Pairs /= null or else Source.Output.Interleaved
        or else not Source.Output.Reference_Activations
        or else not Model_Runner.Quantization.Integers.Packs_Vectors
          (Source.Output.Format, Many, Source.Output.Interleaved, Reference_Arithmetic => True)
      then return; end if;
      Workers_CPU.Pack
        (Packed, Input'Unrestricted_Access, Many, H,
         Model_Runner.Quantization.Integers.Supers_Vectors (Source.Output.Format), Ready,
         Roles => [others => True], Reference_Arithmetic => True,
         Half_Scales => Source.Output.Format in Model_Runner.GGUF.Type_Q8_0 | Model_Runner.GGUF.Type_Q5_0
                | Model_Runner.GGUF.Type_IQ4_NL | Model_Runner.GGUF.Type_Q2_0);
      if not Ready then return; end if;
      Workers_CPU.Dispatch_Shares (Item.Team, Vocab, Work'Unchecked_Access, Status,
        Cost => Vocab * H * Many,
        Team_Size => (if Many = 1 and then Vocab >= 32_768 then 7 else Workers_CPU.Max_Workers + 1));
      Check;
      if not Work.Valid then Status := E.Make (E.Tensor_Shape_Mismatch); raise Aborted; end if;
      if Item.Inkling_Greedy_Head then Best_Of.Publish; end if;
      Done := True;
      Charge (Item, Reading_Out, Mark);
   end Fused_Output;

   procedure Norm (Value : in out Real_Array; Weight : T.View) is
      Width : constant Element_Count := Value'Length / Batch_Count;
      Valid : aliased Boolean := True;
      Learned : constant T.Real_Array_Access := Cached (Weight);
   begin
      Check;
      for Token in 0 .. Batch_Count - 1 loop
         K.RMS_Norm_In_Place
           (Value (Value'First + Token * Width .. Value'First + (Token + 1) * Width - 1),
            Learned.all, Settings.Epsilon, Finite => Valid'Access);
         if not Valid then
            Status := E.Make (E.Tensor_Non_Finite_Value);
            raise Aborted;
         end if;
      end loop;
      Charge (Item, Normalizing, Mark);
   end Norm;

   procedure Plain_Norm (Value : Real_Array; Into : out Real_Array; Epsilon : Real := 1.0E-6) is
   begin
      K.RMS_Norm (Value, Epsilon, Into);
      Finite (Into);
      Charge (Item, Normalizing, Mark);
   end Plain_Norm;

begin
   Status := E.Success;
   if not Item.Compact_Verify then Item.Verify_Count := 0; end if;
   if Item.Inkling_Arena = null or else Item.Inkling_Arena.all'Length < Room then
      T.Free (Item.Inkling_Arena);
      T.Allocate (Room, Item.Inkling_Arena);
   end if;
   Arena := Item.Inkling_Arena;
   if Arena = null then
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;
   if Item.Inkling_Check_Rows = null then
      T.Allocate (2 * H + Vocab, Item.Inkling_Check_Rows);
   end if;
   if Item.Inkling_Check_Rows = null then
      Status := E.Make (E.Memory_Allocation_Failed);
      return;
   end if;
   if Item.Inkling_Conv_Backup = null then
      T.Allocate (Item.Conv_State.all'Length, Item.Inkling_Conv_Backup);
   end if;
   if Item.Inkling_Conv_Backup = null then Status := E.Make (E.Memory_Allocation_Failed); return; end if;
   if Transaction then
      Item.Inkling_Check_Valid := False;
      Item.Inkling_Check_At := Item.Committed;
      Item.Inkling_Check_Rows.all (0 .. H - 1) := Item.Inkling_Workspace.all (0 .. H - 1);
      Item.Inkling_Check_Rows.all (H .. 2 * H - 1) := Item.Normalized.all;
      Item.Inkling_Check_Rows.all (2 * H .. 2 * H + Vocab - 1) := Item.Logit_Row.all;
      Item.Inkling_Check_Valid := Item.Inkling_Last_Row_Valid;
      Item.Inkling_Conv_Backup.all := Item.Conv_State.all;
      Previous_Normal := Item.Normalized.all;
      Backed_Up := True;
   end if;
   if Sequential_Device then
      --  Device batch reductions can straddle a Q4T rounding boundary.
      --  Use the decode arithmetic for each row, inside one transaction.
      --  Inner calls share the arena and retain this outer rollback copy.
      for Token in 0 .. Batch_Count - 1 loop
         Item.Committed := Reserved + Natural (Token);
         Inkling_Evaluate
           (Item, Source, Row, Cancel, Status, Batch_Count => 1,
            Embeddings => Embeddings.all
              (Embeddings'First + Token * H .. Embeddings'First + (Token + 1) * H - 1)'Unrestricted_Access,
            States => (if States = null then null else States.all
              (States'First + Token * H .. States'First + (Token + 1) * H - 1)'Unrestricted_Access),
            Every => (if Every = null then null else Every.all
              (Every'First + Token * Vocab .. Every'First + (Token + 1) * Vocab - 1)'Unrestricted_Access),
            Normalized => Normalized, Transaction => False);
         Check;
      end loop;
      Item.Committed := Reserved;
   else
   declare
      Acts : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Acts_Base)'Address;
      Normals : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Normals_Base)'Address;
      Blocks : aliased Real_Array (0 .. Batch_Count * (4 * H) - 1)
        with Import, Address => Arena.all (Blocks_Base)'Address;
      Bank : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Bank_Base)'Address;
      Prelude : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Prelude_Base)'Address;
      Bank_Out : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Bank_Out_Base)'Address;
      Residual : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Residual_Base)'Address;
      Inputs : aliased Real_Array (0 .. Batch_Count * (3 * H) - 1)
        with Import, Address => Arena.all (Inputs_Base)'Address;
      Messages : aliased Real_Array (0 .. Batch_Count * (4 * H) - 1)
        with Import, Address => Arena.all (Messages_Base)'Address;
      In_Q : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (In_Q_Base)'Address;
      In_K : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (In_K_Base)'Address;
      In_V : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (In_V_Base)'Address;
      Queries : aliased Real_Array (0 .. Batch_Count * (Q * D) - 1)
        with Import, Address => Arena.all (Queries_Base)'Address;
      Keys : aliased Real_Array (0 .. Batch_Count * (KV * D) - 1)
        with Import, Address => Arena.all (Keys_Base)'Address;
      Values : aliased Real_Array (0 .. Batch_Count * (KV * D) - 1)
        with Import, Address => Arena.all (Values_Base)'Address;
      Relatives : aliased Real_Array (0 .. Batch_Count * (Q * R) - 1)
        with Import, Address => Arena.all (Relatives_Base)'Address;
      Gate_Rows : aliased Real_Array (0 .. Batch_Count * (Q * D) - 1)
        with Import, Address => Arena.all (Gate_Rows_Base)'Address;
      Sink_Rows : aliased Real_Array (0 .. Batch_Count * (Q) - 1)
        with Import, Address => Arena.all (Sink_Rows_Base)'Address;
      Dynamic_K : aliased Real_Array (0 .. Batch_Count * (KV * C_Taps) - 1)
        with Import, Address => Arena.all (Dynamic_K_Base)'Address;
      Dynamic_V : aliased Real_Array (0 .. Batch_Count * (KV * C_Taps) - 1)
        with Import, Address => Arena.all (Dynamic_V_Base)'Address;
      Attention_Rows : aliased Real_Array (0 .. Batch_Count * (Q * D) - 1)
        with Import, Address => Arena.all (Attention_Rows_Base)'Address;
      Mixtures : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Mixtures_Base)'Address;
      Mix_States : aliased Real_Array (0 .. Batch_Count * (5 * H) - 1)
        with Import, Address => Arena.all (Mix_States_Base)'Address;
      Mix_Scores : aliased Real_Array (0 .. Batch_Count * (20) - 1)
        with Import, Address => Arena.all (Mix_Scores_Base)'Address;
      Joined : aliased Real_Array (0 .. Batch_Count * (2 * H) - 1)
        with Import, Address => Arena.all (Joined_Base)'Address;
      Down : aliased Real_Array (0 .. Batch_Count * (Rank) - 1)
        with Import, Address => Arena.all (Down_Base)'Address;
      Gain : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Gain_Base)'Address;
      Forget : aliased Real_Array (0 .. Batch_Count * (H) - 1)
        with Import, Address => Arena.all (Forget_Base)'Address;
      Relative_Table : T.Real_Array_Access;
      Projection_Group : aliased Real_Array (0 .. 7 * H - 1)
        with Import, Address => Arena.all (Projection_Group_Base)'Address;

      --  Earlier blocks are normalized when saved, not on every reuse.
      --  Candidates retain the reference's reverse-block/current order.
      procedure Mix_Channels (From : Real_Array; Share : Real; Into : in out Real_Array) is
         Whole : constant Element_Count := (if Wide_Values then H / 8 * 8 else 0);
         LF : constant Character := ASCII.LF;
      begin
         if Whole > 0 then
            if Reference_Arithmetic then
            System.Machine_Code.Asm
              ("vbroadcastss %2, %%ymm2" & LF
               & "xorq %%rcx, %%rcx" & LF & "1:" & LF
               & "vmovups (%1, %%rcx, 4), %%ymm0" & LF
               & "vfmadd231ps (%0, %%rcx, 4), %%ymm2, %%ymm0" & LF
               & "vmovups %%ymm0, (%1, %%rcx, 4)" & LF
               & "addq $8, %%rcx" & LF & "cmpq %3, %%rcx" & LF
               & "jb 1b" & LF & "vzeroupper",
               Inputs => [System.Address'Asm_Input ("r", From (From'First)'Address),
                          System.Address'Asm_Input ("r", Into (Into'First)'Address),
                          Real'Asm_Input ("m", Share),
                          Element_Count'Asm_Input ("r", Whole)],
               Clobber => "ymm0, ymm2, rcx, cc, memory", Volatile => True);
            else
            System.Machine_Code.Asm
              ("vbroadcastss %2, %%ymm2" & LF
               & "xorq %%rcx, %%rcx" & LF & "1:" & LF
               & "vmulps (%0, %%rcx, 4), %%ymm2, %%ymm0" & LF
               & "vaddps (%1, %%rcx, 4), %%ymm0, %%ymm0" & LF
               & "vmovups %%ymm0, (%1, %%rcx, 4)" & LF
               & "addq $8, %%rcx" & LF & "cmpq %3, %%rcx" & LF
               & "jb 1b" & LF & "vzeroupper",
               Inputs => [System.Address'Asm_Input ("r", From (From'First)'Address),
                          System.Address'Asm_Input ("r", Into (Into'First)'Address),
                          Real'Asm_Input ("m", Share),
                          Element_Count'Asm_Input ("r", Whole)],
               Clobber => "ymm0, ymm2, rcx, cc, memory", Volatile => True);
            end if;
         end if;
         for Channel in Whole .. H - 1 loop
            Into (Into'First + Channel) := Into (Into'First + Channel) + Share * From (From'First + Channel);
         end loop;
      end Mix_Channels;

      --  Products cover all tokens and candidates; each softmax and sum
      --  retains the scalar arithmetic and accumulation order.
      procedure Mix
        (Earlier : Real_Array; Used : Natural; Current : Real_Array;
         Weight : T.View; Into : out Real_Array;
         Current_Normalized : Boolean := False)
      is
         Candidates : constant Element_Count := Element_Count (Used + 1);
         Scores : Real_Array (0 .. Candidates - 1);
         Usable : Boolean;
         Scale : constant Real := 1.0 / Real (N.Sqrt (N.Wide_Real (H)));
      begin
         for Token in 0 .. Batch_Count - 1 loop
            declare
               From : constant Element_Count := Token * H;
               At_State : constant Element_Count := Element_Count (Used) * Wide + From;
            begin
               if Current_Normalized then
                  Mix_States (At_State .. At_State + H - 1) :=
                    Current (Current'First + From .. Current'First + From + H - 1);
               else
                  Plain_Norm (Current (Current'First + From .. Current'First + From + H - 1),
                              Mix_States (At_State .. At_State + H - 1));
               end if;
            end;
         end loop;
         if Used > 0 then
            Mat (Weight, Earlier (Earlier'First .. Earlier'First + Element_Count (Used) * Wide - 1),
                 Mix_Scores (0 .. Element_Count (Used) * Batch_Count * Weight.Rows - 1),
                 Element_Count (Used) * Batch_Count);
         end if;
         Mat (Weight, Mix_States (Element_Count (Used) * Wide .. Candidates * Wide - 1),
              Mix_Scores (Element_Count (Used) * Batch_Count * Weight.Rows
                          .. Candidates * Batch_Count * Weight.Rows - 1), Batch_Count);
         Into := [others => 0.0];
         for Token in 0 .. Batch_Count - 1 loop
            for Query in 0 .. Weight.Rows - 1 loop
               for Index in 0 .. Candidates - 1 loop
                  Scores (Index) := Mix_Scores (((if Index < Candidates - 1 then Candidates - Index - 2 else Index)
                     * Batch_Count + Token) * Weight.Rows + Query) * Scale;
               end loop;
               if Reference_Arithmetic then Reference_Depth_Softmax (Scores, Usable);
               else K.Softmax (Scores, Usable); end if;
               if not Usable then
                  Status := E.Make (E.Tensor_Non_Finite_Value);
                  raise Aborted;
               end if;
               for Index in 0 .. Candidates - 1 loop
                  declare
                     Target : constant Element_Count := Into'First + (Token * Weight.Rows + Query) * H;
                     Source_Row : constant Element_Count :=
                       (if Index < Candidates - 1 then Earlier'First + (Candidates - Index - 2) * Wide + Token * H
                        else Index * Wide + Token * H);
                  begin
                     if Index < Candidates - 1 then
                        Mix_Channels (Earlier (Source_Row .. Source_Row + H - 1),
                                      Scores (Index), Into (Target .. Target + H - 1));
                     else
                        Mix_Channels (Mix_States (Source_Row .. Source_Row + H - 1),
                                      Scores (Index), Into (Target .. Target + H - 1));
                     end if;
                  end;
               end loop;
            end loop;
         end loop;
         Charge (Item, Joining, Mark);
      end Mix;

      procedure Control
        (Value : in out Real_Array; Which : Natural; Weights : Inkling_Weight_Views)
      is
         Role : constant Inkling_Weight_Role := Inkling_Weight_Role'Val
           (Inkling_Weight_Role'Pos (Inkling_Q_Down) + Which * 3);

         type Gate_Share is limited new Workers_CPU.Task_Item with null record;
         overriding procedure Run
           (Share : in out Gate_Share; From, To : Element_Count);

         overriding procedure Run
           (Share : in out Gate_Share; From, To : Element_Count)
         is
            pragma Unreferenced (Share);
         begin
            --  Each channel owns its gains and output. Only the readonly
            --  message bank is shared; preserve the original scalar math.
            for Token in From / H .. To / H loop
               declare
                  Base : constant Element_Count := Token * H;
                  First : constant Element_Count := Element_Count'Max (From, Base) - Base;
                  Last : constant Element_Count := Element_Count'Min (To, Base + H - 1) - Base;
               begin
                  for Channel in First .. Last loop
                     declare
                        Index : constant Element_Count := Base + Channel;
                     begin
                        Gain (Index) := (if Reference_Arithmetic then Reference_Tanh (Gain (Index))
                                         else Real (N.Tanh (N.Wide_Real (Gain (Index)))));
                        Forget (Index) := (if Reference_Arithmetic then Reference_Tanh (Forget (Index))
                                           else Real (N.Tanh (N.Wide_Real (Forget (Index)))));
                        Value (Index) := (Value (Index) - Forget (Index) * Value (Index))
                          + Gain (Index) * Messages ((Token * 4 + Element_Count (Which)) * H + Channel);
                     end;
                  end loop;
               end;
            end loop;
         end Run;

         Share : aliased Gate_Share;
         Chained : Boolean := False;
      begin
         for Token in 0 .. Batch_Count - 1 loop
            Plain_Norm (Value (Token * H .. (Token + 1) * H - 1),
                        Joined (Token * 2 * H .. Token * 2 * H + H - 1));
            Plain_Norm (Messages ((Token * 4 + Element_Count (Which)) * H
                                  .. (Token * 4 + Element_Count (Which) + 1) * H - 1),
                        Joined (Token * 2 * H + H .. (Token + 1) * 2 * H - 1));
         end loop;
         if not Item.Host_Feed
           and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
           and then (for all Role of Item.Arithmetic => not Role)
         then
            for Token in 0 .. Batch_Count - 1 loop
               Gain (Token * H .. (Token + 1) * H - 1) :=
                 Messages ((Token * 4 + Element_Count (Which)) * H
                           .. (Token * 4 + Element_Count (Which) + 1) * H - 1);
            end loop;
            Model_Runner.Backend.Device.Control_And_Blend
              (Weights (Role), Weights (Inkling_Weight_Role'Succ (Role)),
               Weights (Inkling_Weight_Role'Val (Inkling_Weight_Role'Pos (Role) + 2)),
               Joined'Unrestricted_Access, Value'Unrestricted_Access, Gain'Unrestricted_Access,
               Down'Unrestricted_Access, Gain'Unrestricted_Access, Forget'Unrestricted_Access,
               Positive (Batch_Count), Chained, Status, Cancel);
            Check;
            if Chained then
               Finite (Down); Finite (Gain); Finite (Forget); Finite (Value);
               if Item.Seen /= null then
                  Tell (Item, Weights (Role), Joined, Batch_Count);
                  Tell (Item, Weights (Inkling_Weight_Role'Succ (Role)), Down, Batch_Count);
                  Tell (Item, Weights (Inkling_Weight_Role'Val
                    (Inkling_Weight_Role'Pos (Role) + 2)), Down, Batch_Count);
                  Check;
               end if;
               Charge (Item, Projecting, Mark);
               return;
            end if;
         end if;
         if Item.Seen = null and then not Item.Host_Feed
           and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
           and then (for all Role of Item.Arithmetic => not Role)
         then
            declare
               Steps : Model_Runner.Backend.Device.Product_Sequence;
               Added : Boolean;
               Targets : constant Model_Runner.Backend.Device.Result_Addresses :=
                 [Gain (0)'Address, Forget (0)'Address];
            begin
               Model_Runner.Backend.Device.Open_Steps (Steps);
               Model_Runner.Backend.Device.Add_View_Product_At (Steps, Weights (Role), 0, Added);
               if Added then
                  Model_Runner.Backend.Device.Add_View_Product
                    (Steps, Weights (Inkling_Weight_Role'Succ (Role)), 1, Added, Kept => True);
               end if;
               if Added then
                  Model_Runner.Backend.Device.Add_View_Product
                    (Steps, Weights (Inkling_Weight_Role'Val (Inkling_Weight_Role'Pos (Role) + 2)),
                     1, Added, Kept => True);
               end if;
               if Added then
                  Model_Runner.Backend.Device.Run_Steps
                    (Steps, Joined, Positive (Batch_Count), System.Null_Address, Status,
                     Targets => Targets, Cancel => Cancel);
                  Check;
                  Finite (Gain);
                  Finite (Forget);
                  Charge (Item, Projecting, Mark);
                  Chained := True;
               end if;
            end;
         end if;
         if not Chained then
            Mat (Weights (Role), Joined, Down);
         if Batch_Count = 1 then
            declare
               Views : constant T.View_Group :=
                 [Weights (Inkling_Weight_Role'Succ (Role)),
                  Weights (Inkling_Weight_Role'Val (Inkling_Weight_Role'Pos (Role) + 2))];
               Targets : constant T.Target_Group :=
                 [Gain'Unrestricted_Access, Forget'Unrestricted_Access];
            begin
               --  Both projections read Down; one existing backend group
               --  replaces two CPU pool jobs or device submissions.
               Product_Group (Item, Views, Down'Unrestricted_Access, Targets, Status);
               Check;
               Finite (Gain);
               Finite (Forget);
               Charge (Item, Projecting, Mark);
            end;
         elsif not Item.Host_Feed
           and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
           and then (for all Role of Item.Arithmetic => not Role)
         then
            declare
               Views : constant T.View_Group :=
                 [Weights (Inkling_Weight_Role'Succ (Role)),
                  Weights (Inkling_Weight_Role'Val (Inkling_Weight_Role'Pos (Role) + 2))];
               Targets : constant T.Target_Group := [Gain'Unrestricted_Access, Forget'Unrestricted_Access];
            begin
               if Item.Seen /= null then
                  for Weight of Views loop
                     Tell (Item, Weight, Down, Batch_Count);
                  end loop;
               end if;
               Model_Runner.Backend.Device.Dispatch_Batch_Group
                 (Views, Down'Unrestricted_Access, Batch_Count, Targets, Status, Cancel);
               Check;
               Finite (Gain);
               Finite (Forget);
               Charge (Item, Projecting, Mark);
            end;
         elsif (Item.Host_Feed
                or else Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_CPU))
           and then (for all Role of Item.Arithmetic => not Role)
         then
            declare
               Views : constant T.View_Group :=
                 [Weights (Inkling_Weight_Role'Succ (Role)),
                  Weights (Inkling_Weight_Role'Val (Inkling_Weight_Role'Pos (Role) + 2))];
               Targets : constant T.Target_Group := [Gain'Unrestricted_Access, Forget'Unrestricted_Access];
            begin
               if Item.Seen /= null then
                  for Weight of Views loop
                     Tell (Item, Weight, Down, Batch_Count);
                  end loop;
               end if;
               Workers_CPU.Dispatch_Group
                 (Item.Team, Views, Down'Unrestricted_Access, Targets, Status,
                  Roles => Item.Arithmetic, Count => Batch_Count);
               Check;
               Finite (Gain);
               Finite (Forget);
               Charge (Item, Projecting, Mark);
            end;
         else
            Mat (Weights (Inkling_Weight_Role'Succ (Role)), Down, Gain);
            Mat (Weights (Inkling_Weight_Role'Val (Inkling_Weight_Role'Pos (Role) + 2)), Down, Forget);
         end if;
         end if;
         Workers_CPU.Dispatch_Shares
           (Item.Team, Wide, Share'Unchecked_Access, Status, Cost => 32 * Wide);
         Check;
      end Control;

   --  Four independent three-tap channels. Keep both stages of every
   --  binary32 multiply/add and the original per-channel tap order.
   function Platform_Fused_Product (Left, Right, Added : Real) return Real
     with Import, Convention => C, External_Name => "fmaf";

   function Fused_Product (Left, Right, Added : Real) return Real with Inline_Always;
   function Fused_Product (Left, Right, Added : Real) return Real is
      Result : Real := Added;
   begin
      if Wide_Values then
         System.Machine_Code.Asm
           ("vfmadd231ss %1, %2, %0",
            Outputs => [Real'Asm_Output ("+x", Result)],
            Inputs => [Real'Asm_Input ("x", Left), Real'Asm_Input ("x", Right)]);
         return Result;
      end if;
      return Platform_Fused_Product (Left, Right, Added);
   end Fused_Product;

   procedure Convolve_Four
     (Value, Taps, State, Dynamic, Scale : System.Address; With_Dynamic : Boolean)
   with Inline_Always;

   procedure Convolve_Four
     (Value, Taps, State, Dynamic, Scale : System.Address; With_Dynamic : Boolean)
   is
      LF : constant Character := ASCII.LF;
   begin
      System.Machine_Code.Asm
        (
           "movq %0, %%r8" & LF
         & "movq %1, %%r9" & LF
         & "movq %2, %%r10" & LF
         & "movq %3, %%r11" & LF
         & "movq %4, %%r12" & LF
         & "vmovups (%%r8), %%xmm7" & LF
         & "vxorps %%xmm0, %%xmm0, %%xmm0" & LF
         & "vmovss 0(%%r9), %%xmm1" & LF
         & "vinsertps $16, 12(%%r9), %%xmm1, %%xmm1" & LF
         & "vinsertps $32, 24(%%r9), %%xmm1, %%xmm1" & LF
         & "vinsertps $48, 36(%%r9), %%xmm1, %%xmm1" & LF
         & "vmovss 0(%%r10), %%xmm2" & LF
         & "vinsertps $16, 8(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $32, 16(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $48, 24(%%r10), %%xmm2, %%xmm2" & LF
         & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
         & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
         & "vmovss 4(%%r9), %%xmm1" & LF
         & "vinsertps $16, 16(%%r9), %%xmm1, %%xmm1" & LF
         & "vinsertps $32, 28(%%r9), %%xmm1, %%xmm1" & LF
         & "vinsertps $48, 40(%%r9), %%xmm1, %%xmm1" & LF
         & "vmovss 4(%%r10), %%xmm2" & LF
         & "vinsertps $16, 12(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $32, 20(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $48, 28(%%r10), %%xmm2, %%xmm2" & LF
         & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
         & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
         & "vmovss 8(%%r9), %%xmm1" & LF
         & "vinsertps $16, 20(%%r9), %%xmm1, %%xmm1" & LF
         & "vinsertps $32, 32(%%r9), %%xmm1, %%xmm1" & LF
         & "vinsertps $48, 44(%%r9), %%xmm1, %%xmm1" & LF
         & "vmovaps %%xmm7, %%xmm2" & LF
         & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
         & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
         & "testq %5, %5" & LF
         & "jz 1f" & LF
         & "vbroadcastss 0(%%r11), %%xmm1" & LF
         & "vmovaps %%xmm7, %%xmm2" & LF
         & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
         & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
         & "vbroadcastss 4(%%r11), %%xmm1" & LF
         & "vmovss 4(%%r10), %%xmm2" & LF
         & "vinsertps $16, 12(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $32, 20(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $48, 28(%%r10), %%xmm2, %%xmm2" & LF
         & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
         & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
         & "vbroadcastss 8(%%r11), %%xmm1" & LF
         & "vmovss 0(%%r10), %%xmm2" & LF
         & "vinsertps $16, 8(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $32, 16(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $48, 24(%%r10), %%xmm2, %%xmm2" & LF
         & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
         & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
         & "1:" & LF
         & "vmovss 4(%%r10), %%xmm2" & LF
         & "vinsertps $16, 12(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $32, 20(%%r10), %%xmm2, %%xmm2" & LF
         & "vinsertps $48, 28(%%r10), %%xmm2, %%xmm2" & LF
         & "vextractps $0, %%xmm2, 0(%%r10)" & LF
         & "vextractps $0, %%xmm7, 4(%%r10)" & LF
         & "vextractps $1, %%xmm2, 8(%%r10)" & LF
         & "vextractps $1, %%xmm7, 12(%%r10)" & LF
         & "vextractps $2, %%xmm2, 16(%%r10)" & LF
         & "vextractps $2, %%xmm7, 20(%%r10)" & LF
         & "vextractps $3, %%xmm2, 24(%%r10)" & LF
         & "vextractps $3, %%xmm7, 28(%%r10)" & LF
         & "vaddps %%xmm0, %%xmm7, %%xmm0" & LF
         & "vbroadcastss (%%r12), %%xmm1" & LF
         & "vmulps %%xmm1, %%xmm0, %%xmm0" & LF
         & "vmovups %%xmm0, (%%r8)" & LF
         & "vzeroupper",
         Inputs =>
           [System.Address'Asm_Input ("r", Value), System.Address'Asm_Input ("r", Taps),
            System.Address'Asm_Input ("r", State), System.Address'Asm_Input ("r", Dynamic),
            System.Address'Asm_Input ("r", Scale),
            Interfaces.Unsigned_64'Asm_Input ("r", Boolean'Pos (With_Dynamic))],
         Clobber => "r8, r9, r10, r11, r12, xmm0, xmm1, xmm2, xmm7, cc, memory",
         Volatile => True);
   end Convolve_Four;

   procedure Convolve_Rows
     (Value : in out Real_Array; Weight : T.View; Offset : Element_Count;
      Dynamic : Real_Array; Is_Dynamic : Boolean := False; Joined : access Real_Array := null)
   is
      Width : constant Element_Count := Value'Length / Batch_Count;
      Learned : constant T.Real_Array_Access := Cached (Weight);
      Scale : constant Real := 1.0 / Real (N.Sqrt
        (N.Wide_Real ((if Is_Dynamic then 2 else 1) * C_Taps + 1)));
      Produced_Finite : Boolean := True with Atomic;
      State_Base : constant Element_Count := Element_Count (Step.State_Layer) * Channels * (C_Taps - 1);
      --  State belongs to channels. A worker owns each channel for all
      --  tokens, preserving its causal history and exact tap/FMA order.
      --  Workers only publish False to the atomic finite flag; errors and
      --  cancellation are resolved by the caller after every share settles.
      procedure Compute (From, To : Element_Count) is
      begin
      for Channel in From .. To loop

         declare
            At_State : constant Element_Count := State_Base + (Offset + Channel) * (C_Taps - 1);
         begin
            for Token in 0 .. Batch_Count - 1 loop
               if C.Is_Cancelled (Cancel) then return; end if;
               declare
                  At_Value : constant Element_Count := Value'First + Token * Width + Channel;
                  Raw : constant Real := Value (At_Value);
                  Total : Real := 0.0;
               begin
                  for Tap in 0 .. C_Taps - 1 loop
                     if Reference_Arithmetic then
                        Total := Fused_Product
                          (Learned (Channel * C_Taps + Tap),
                           (if Tap = C_Taps - 1 then Raw else Item.Conv_State (At_State + Tap)), Total);
                     else
                        Total := Total + Learned (Channel * C_Taps + Tap)
                          * (if Tap = C_Taps - 1 then Raw else Item.Conv_State (At_State + Tap));
                     end if;
                  end loop;
                  if Is_Dynamic then
                     for Lag in 0 .. C_Taps - 1 loop
                        Total := Total
                          + Dynamic (Dynamic'First + Token * KV * C_Taps + Channel / D * C_Taps + Lag)
                            * (if Lag = 0 then Raw else Item.Conv_State (At_State + C_Taps - 1 - Lag));
                     end loop;
                  end if;
                  for Tap in 1 .. C_Taps - 2 loop
                     Item.Conv_State (At_State + Tap - 1) := Item.Conv_State (At_State + Tap);
                  end loop;
                  Item.Conv_State (At_State + C_Taps - 2) := Raw;
                  Value (At_Value) := (Raw + Total) * Scale;
                  if not N.Is_Finite (Value (At_Value)) then Produced_Finite := False; end if;
                  if Joined /= null then
                     declare
                        At_Join : constant Element_Count := Joined.all'First + Token * Width + Channel;
                     begin
                        Joined (At_Join) := Joined (At_Join) + Value (At_Value);
                        if not N.Is_Finite (Joined (At_Join)) then Produced_Finite := False; end if;
                     end;
                  end if;
               end;
            end loop;
         end;
      end loop;
      end Compute;
      type Convolution_Share is limited new Workers_CPU.Task_Item with null record;
      overriding procedure Run (Share : in out Convolution_Share; From, To : Element_Count);
      overriding procedure Run (Share : in out Convolution_Share; From, To : Element_Count) is
         pragma Unreferenced (Share);
      begin
         Compute (From, To);
      end Run;
      Share : aliased Convolution_Share;
   begin
      if Wide_Values and then not Reference_Arithmetic and then Joined = null
        and then C_Taps = 3 and then Width mod 4 = 0
        and then (not Is_Dynamic or else D mod 4 = 0)
      then
         for Group in 0 .. Width / 4 - 1 loop
            for Token in 0 .. Batch_Count - 1 loop
               Check;
               declare
                  Channel : constant Element_Count := Group * 4;
                  Dynamic_At : constant Element_Count := Dynamic'First
                    + (if Is_Dynamic then (Token * KV + Channel / D) * C_Taps else 0);
               begin
                  Convolve_Four
                    (Value (Value'First + Token * Width + Channel)'Address,
                     Learned (Channel * C_Taps)'Address,
                     Item.Conv_State (State_Base + (Offset + Channel) * (C_Taps - 1))'Address,
                     Dynamic (Dynamic_At)'Address, Scale'Address, Is_Dynamic);
               end;
            end loop;
         end loop;
         Finite (Value);
         Charge (Item, Joining, Mark);
         return;
      end if;
      --  Unusual tap counts or head widths retain the scalar operation.
      Check;
      if Reference_Arithmetic and then Batch_Count >= 8 then
         Workers_CPU.Dispatch_Shares
           (Item.Team, Width, Share'Unchecked_Access, Status,
            Cost => Width * Batch_Count * C_Taps * 8);
      else
         Compute (0, Width - 1);
      end if;
      Check;
      if not Produced_Finite then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         raise Aborted;
      end if;
      Charge (Item, Joining, Mark);
   end Convolve_Rows;

   procedure Clip_Rows (Value : in out Real_Array; Width : Element_Count; Weight : T.View; Limit : Real) is
      Row_Width : constant Element_Count := Value'Length / Batch_Count;
      Learned : Real_Array (0 .. Width - 1);
      Cached_Weight : T.Real_Array_Access := null;
      Has_Learned : constant Boolean := T.Is_Present (Weight);
   begin
      if Has_Learned then
         Cached_Weight := Cached (Weight);
      end if;
      for Head in 0 .. Row_Width / Width - 1 loop
         if Has_Learned then
            Learned := Cached_Weight.all (Head * Width .. (Head + 1) * Width - 1);
         else
            Learned := [others => 1.0];
         end if;
         for Token in 0 .. Batch_Count - 1 loop
            if Has_Learned then
               Check;
            end if;
            declare
               At_Head : constant Element_Count := Value'First + Token * Row_Width + Head * Width;
               Sum : Wide_Real := 0.0;
               Factor : Real;
            begin
               for Channel in Learned'Range loop
                  Value (At_Head + Channel) := Value (At_Head + Channel) * Learned (Channel);
                  Sum := Sum + Wide_Real (Value (At_Head + Channel) ** 2);
               end loop;
               Factor := Real'Min (1.0, Limit / (Real (N.Sqrt (Wide_Real (Real (Sum)))) + 1.0E-6));
               for Channel in Learned'Range loop
                  Value (At_Head + Channel) := Value (At_Head + Channel) * Factor;
                  if not N.Is_Finite (Value (At_Head + Channel)) then
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                     raise Aborted;
                  end if;
               end loop;
            end;
         end loop;
      end loop;
      Charge (Item, Normalizing, Mark);
   end Clip_Rows;

   procedure Attend (Local : Boolean) is
      --  Q4T has its own independently checked packed-cache arithmetic.
      --  Reuse its fused score/value kernels for either activation profile;
      --  the uncompressed reference cache retains the exact CPU fold order.
      Reference_Folds : constant Boolean := Reference_Arithmetic
        and then Item.Held /= Transformed_Fourth;
      State : constant Natural := Step.State_Layer;
      Last_Position : constant Element_Count := Element_Count (Item.Committed) + Batch_Count - 1;
      Extent : constant Element_Count :=
        Element_Count (if Local then Settings.Window else Settings.Inkling.Relative_Extent);
      Span : constant Element_Count :=
        (if Local then Element_Count'Min (Last_Position + 1, Element_Count (Settings.Window))
         else Last_Position + 1);
      Scale : constant Real := 1.0 / Real (N.Sqrt (N.Wide_Real (D)));

      --  When a KV group fits each member of the active team, keep its
      --  query heads together. Twenty-four heads on nine tasks otherwise
      --  leave three tasks with two heads and six with three.
      Team_Size : constant Element_Count :=
        (if Workers_CPU."=" (Item.Team, null) then 1
         else Element_Count (Workers_CPU.Worker_Total (Item.Team.all)) + 1);
      Grouped : constant Boolean :=
        Team_Size in KV .. KV + 1 and then Q mod KV = 0;
      Heads_Per_Work : constant Element_Count := (if Grouped then Q / KV else 1);

      function On_Device return Boolean is
         Laid : constant Packed_Block := Packed_Layout (Item);
         Table_Room : constant Element_Count := Element_Count (Settings.Layers) * R
           * Element_Count (Natural'Max (Settings.Window, Settings.Inkling.Relative_Extent));
         Meta : Real_Array (0 .. 3 + Batch_Count * Q * (R + 1));
         Done : Boolean;
         Key_At : constant Element_Count := Keys_At (Item, State);
         Value_At : constant Element_Count := Values_At (Item, State);
         Origin : constant Element_Count := (if Item.Origin = null then 0 else Item.Origin (State));
         From : Element_Count;
         Many : Element_Count;
         Table_At, Meta_At : Element_Count;
         K_Base, V_Base, KS_Base, VS_Base : Element_Count;
         States : constant Natural := Item.Cells.all'Length;
         Table_Slot : constant Natural := States + Step.Physical_Layer;
         procedure Append_Attention
           (Steps : in out Model_Runner.Backend.Device.Product_Sequence; Query_At : Natural; Added : out Boolean) is
            package P renames Model_Runner.Backend.Device;
         begin
            P.Add_Packed_Attention
              (Steps, Natural (Q), Natural (D), Natural (D), Settings.Group_Size,
               (if Local and then Item.Committed + 1 > Settings.Window
                then Item.Committed + 1 - Settings.Window else 0), Item.Committed,
               Natural (KV * D), Natural (KV * D), Scale, 0.0, Added,
               Window => (if Local then Settings.Window else 0), At_Vector => Query_At,
               Relative_At => Natural (Meta_At),
               Packed => (K_Codec => P.Transformed_Four_Bit_Cache, V_Codec => P.Scaled_Integer_Cache,
                 K_Bits => 4, V_Bits => 4, K_Bytes => Interfaces.Unsigned_64 (K_Base),
                 V_Bytes => Interfaces.Unsigned_64 (V_Base), KS_At => Natural (KS_Base), VS_At => Natural (VS_Base),
                 K_Blocks => Natural (KV * D / 32), V_Blocks => Natural (KV * D / 32)));
         end Append_Attention;
         procedure Put
           (Key : Boolean; Start, Count : Element_Count; Ok : out Boolean) is
            Head_Base : constant Element_Count := (if Key then Key_At else Value_At);
            First : constant Element_Count := Head_Base + Start * KV * D;
            Length : constant Element_Count := Count * KV * D;
            At_Byte : constant B.Byte_Count := Byte_Of (Fourth, First, D);
            At_Scale : constant Element_Count := Scale_Of (Fourth, First, D);
            Scales : constant T.Real_Array_Access := (if Key then Item.Key_Scales else Item.Value_Scales);
            Bytes : constant B.Byte_Array_Access := (if Key then Item.Byte_Keys else Item.Byte_Values);
         begin
            Model_Runner.Backend.Device.Put_Cache_Bytes
              (Interfaces.Unsigned_64 (Item.Cache_Base + (if Key then 0 else Laid.Values_At)) * 4
               + Interfaces.Unsigned_64 (At_Byte - Bytes.all'First),
               Bytes.all (At_Byte .. At_Byte + B.Byte_Count (Length / 2) - 1), Ok);
            if Ok then
               Model_Runner.Backend.Device.Put_Cache
                 (Item.Cache_Base + (if Key then Laid.Key_Scales_At else Laid.Value_Scales_At) + At_Scale,
                  Scales.all (Scales.all'First + At_Scale .. Scales.all'First + At_Scale + Length / 32 - 1), Ok);
            end if;
         end Put;
      begin
         if Batch_Count > 128 or else Item.Host_Feed or else Item.Held /= Transformed_Fourth
           or else Item.Held_Values /= Fourth or else D mod 32 /= 0
           or else not Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
           or else not Model_Runner.Backend.Device.Attends_Packed_Heads (Natural (D), Natural (D))
         then return False; end if;
         if Item.Inkling_Device_Marks = null then
            Item.Inkling_Device_Marks := new Cell_Counts'(0 .. States + Settings.Layers - 1 => Element_Count'Last);
            --  Reference product batches are bounded to128 positions. Reserve
            --  their metadata once so a later larger batch cannot overrun a
            --  block already owned by this session.
            Item.Inkling_Device_Extra := Table_Room + 4 + 128 * Q * (R + 1);
         end if;
         Take_Block (Item'Unchecked_Access, Done);
         if not Done then return False; end if;
         if Item.Inkling_Device_Base /= Item.Cache_Base then
            Item.Inkling_Device_Marks.all := [others => Element_Count'Last];
            Item.Inkling_Device_Base := Item.Cache_Base;
         end if;
         Table_At := Item.Cache_Base + Laid.Span + Element_Count (Step.Physical_Layer) * R
           * Element_Count (Natural'Max (Settings.Window, Settings.Inkling.Relative_Extent));
         Meta_At := Item.Cache_Base + Laid.Span + Table_Room;
         if Item.Inkling_Device_Marks (Table_Slot) = Element_Count'Last then
            Finite (Relative_Table.all);
            Model_Runner.Backend.Device.Put_Cache (Table_At, Relative_Table.all, Done);
            if not Done then return False; end if;
            Item.Inkling_Device_Marks (Table_Slot) := 0;
         end if;
         if Item.Inkling_Device_Marks (State) /= Origin then
            From := 0; Many := Item.Cells (State);
         else From := Element_Count (Item.Committed) - Origin; Many := Batch_Count;
         end if;
         Put (True, From, Many, Done); if not Done then return False; end if;
         Put (False, From, Many, Done); if not Done then return False; end if;
         Item.Inkling_Device_Marks (State) := Origin;
         Meta (0) := N.From_Bits (Interfaces.Unsigned_32 (R));
         Meta (1) := N.From_Bits (Interfaces.Unsigned_32 (Extent));
         Meta (2) := N.From_Bits (Interfaces.Unsigned_32 (Origin));
         Meta (3) := N.From_Bits (Interfaces.Unsigned_32 (Table_At));
         Meta (4 .. 3 + Batch_Count * Q * R) := Relatives;
         Meta (4 + Batch_Count * Q * R .. Meta'Last) := Sink_Rows;
         Model_Runner.Backend.Device.Put_Cache (Meta_At, Meta, Done); if not Done then return False; end if;
         K_Base := Item.Cache_Base * 4 + Element_Count (Byte_Of (Fourth, Key_At, D) - Item.Byte_Keys.all'First);
         V_Base := (Item.Cache_Base + Laid.Values_At) * 4
           + Element_Count (Byte_Of (Fourth, Value_At, D) - Item.Byte_Values.all'First);
         KS_Base := Item.Cache_Base + Laid.Key_Scales_At + Scale_Of (Fourth, Key_At, D);
         VS_Base := Item.Cache_Base + Laid.Value_Scales_At + Scale_Of (Fourth, Value_At, D);
         if Reference_Arithmetic and then Item.Seen = null and then Source.Runtime_Pairs = null
           and then C_Taps in 3 .. 4
         then
            declare
               W : Inkling_Weight_Views renames Source.Layers (Step.Physical_Layer).Inkling_Weights;
               At_History : constant Element_Count := Element_Count (Step.State_Layer) * Channels * (C_Taps - 1)
                 + 2 * KV * D * (C_Taps - 1);
               History : aliased Real_Array (0 .. H * (C_Taps - 1) - 1)
                 with Import, Address => Item.Conv_State (At_History)'Address;
               Taps : constant T.Real_Array_Access := Cached (W (Inkling_Attention_Conv));
            begin
               if Item.Arithmetic (W (Inkling_Attention_Gate).Role)
                 and then Item.Arithmetic (W (Inkling_Attention_Out).Role)
               then
                  Model_Runner.Backend.Device.Gate_And_Project
                    (W (Inkling_Attention_Gate), W (Inkling_Attention_Out), In_Q'Unrestricted_Access,
                     Queries'Unrestricted_Access, Gate_Rows'Unrestricted_Access, Acts'Unrestricted_Access,
                     null, Done, Status, Cancel, Positive (Batch_Count), Taps.all, History'Unrestricted_Access,
                     Mixtures'Unrestricted_Access, Reference_Arithmetic => True,
                     Residual => (if Step.Physical_Layer mod Settings.Inkling.Block_Size /= 0
                                  then Residual'Unrestricted_Access else null),
                     Attention => Append_Attention'Unrestricted_Access);
                  Check;
                  if Done then
                     Attention_Ready := True; Attention_Convolved := True;
                     Attention_Joined := Step.Physical_Layer mod Settings.Inkling.Block_Size /= 0;
                     Finite (Acts); Finite (Mixtures);
                     Item.Inkling_Device_Runs := Item.Inkling_Device_Runs + 1;
                     return True;
                  end if;
               end if;
            end;
         end if;
         Model_Runner.Backend.Device.Attend_Packed
           (4, 4, Queries, Natural (Q), Natural (D), Natural (D), Settings.Group_Size,
            (if Local and then Item.Committed + 1 > Settings.Window
             then Item.Committed + 1 - Settings.Window else 0), Item.Committed,
            Interfaces.Unsigned_64 (K_Base), Interfaces.Unsigned_64 (V_Base), Natural (KV * D), Natural (KV * D),
            Natural (KS_Base), Natural (VS_Base), Natural (KV * D / 32), Natural (KV * D / 32),
            Scale, 0.0, Attention_Rows, Done, Positions => Natural (Batch_Count),
            Window => (if Local then Settings.Window else 0),
            K_Codec => Model_Runner.Backend.Device.Transformed_Four_Bit_Cache,
            V_Codec => Model_Runner.Backend.Device.Scaled_Integer_Cache, Relative_At => Natural (Meta_At));
         if Done then Item.Inkling_Device_Runs := Item.Inkling_Device_Runs + 1; end if;
         return Done;
      end On_Device;

      procedure Read_Key (Origin : Element_Count; Target : out Real_Array) is
      begin
         case Item.Held is
            when Exact => Target := Item.Keys.all (Origin .. Origin + D - 1);
            when Halved => K.From_Halves (Item.Half_Keys.all (Origin .. Origin + D - 1), Target);
            when Transformed_Fourth =>
               --  Head boundaries align with full 32-coordinate groups.
               --  Decode stored coordinates, without inverse rotation.
               Unpack_Row (Item.Byte_Keys.all, Origin, D, Item.Key_Scales.all,
                           Fourth, Target, Widen => Wide_Values);
            when others => raise Program_Error with "unsupported Inkling key cache";
         end case;
      end Read_Key;

      procedure Read_Value (Origin : Element_Count; Target : out Real_Array) is
      begin
         case Item.Held_Values is
            when Exact => Target := Item.Values.all (Origin .. Origin + D - 1);
            when Halved => K.From_Halves (Item.Half_Values.all (Origin .. Origin + D - 1), Target);
            when Fourth =>
               Unpack_Row (Item.Byte_Values.all, Origin, D, Item.Value_Scales.all,
                           Fourth, Target, Widen => Wide_Values);
            when others => raise Program_Error with "unsupported Inkling value cache";
         end case;
      end Read_Value;

      procedure Score_Four
        (Query, Key_0, Key_1, Key_2, Key_3 : System.Address;
         Scores : out Real_Array)
      with Inline_Always;

      procedure Score_Four
        (Query, Key_0, Key_1, Key_2, Key_3 : System.Address;
         Scores : out Real_Array)
      is
         LF : constant Character := ASCII.LF;
      begin
         --  Each lane is one position, accumulated in channel order.
         --  No horizontal reduction or fused multiply/add is permitted.
         System.Machine_Code.Asm
           ("vxorps %%xmm0, %%xmm0, %%xmm0" & LF
            & "xorq %%rax, %%rax" & LF
            & "1:" & LF
            & "vmovss (%1, %%rax), %%xmm1" & LF
            & "vinsertps $16, (%2, %%rax), %%xmm1, %%xmm1" & LF
            & "vinsertps $32, (%3, %%rax), %%xmm1, %%xmm1" & LF
            & "vinsertps $48, (%4, %%rax), %%xmm1, %%xmm1" & LF
            & "vbroadcastss (%0, %%rax), %%xmm2" & LF
            & "vmulps %%xmm1, %%xmm2, %%xmm1" & LF
            & "vaddps %%xmm1, %%xmm0, %%xmm0" & LF
            & "addq $4, %%rax" & LF
            & "cmpq %6, %%rax" & LF
            & "jne 1b" & LF
            & "vmovups %%xmm0, (%5)" & LF
            & "vzeroupper",
            Inputs =>
              [System.Address'Asm_Input ("r", Query),
               System.Address'Asm_Input ("r", Key_0),
               System.Address'Asm_Input ("r", Key_1),
               System.Address'Asm_Input ("r", Key_2),
               System.Address'Asm_Input ("r", Key_3),
               System.Address'Asm_Input ("r", Scores (Scores'First)'Address),
               Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (D) * 4)],
            Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
              & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, rax, cc, memory",
            Volatile => True);
      end Score_Four;

      procedure Add_Value
        (Value : Real_Array; Probability : Real; Accumulated : in out N.Wide_Real_Array)
      with Inline_Always;

      procedure Add_Value
        (Value : Real_Array; Probability : Real; Accumulated : in out N.Wide_Real_Array)
      is
         Whole : constant Element_Count := (if Wide_Values then D - D mod 4 else 0);
         Factor : constant N.Wide_Real := N.Wide_Real (Probability);
         LF : constant Character := ASCII.LF;
      begin
         --  Channels are independent. Keep each channel's chronological
         --  binary64 sum and separate multiply/add instructions unchanged.
         if Whole > 0 then
            System.Machine_Code.Asm
              ("movq %0, %%r8" & LF
               & "movq %1, %%r9" & LF
               & "movq %2, %%r10" & LF
               & "vbroadcastsd %3, %%ymm0" & LF
               & "1:" & LF
               & "vcvtps2pd (%%r8), %%ymm1" & LF
               & "vmulpd %%ymm1, %%ymm0, %%ymm1" & LF
               & "vmovupd (%%r9), %%ymm2" & LF
               & "vaddpd %%ymm1, %%ymm2, %%ymm1" & LF
               & "vmovupd %%ymm1, (%%r9)" & LF
               & "addq $16, %%r8" & LF
               & "addq $32, %%r9" & LF
               & "decq %%r10" & LF
               & "jnz 1b" & LF
               & "vzeroupper",
               Inputs =>
                 [System.Address'Asm_Input ("r", Value (Value'First)'Address),
                  System.Address'Asm_Input ("r", Accumulated (Accumulated'First)'Address),
                  Interfaces.Unsigned_64'Asm_Input ("r", Interfaces.Unsigned_64 (Whole / 4)),
                  N.Wide_Real'Asm_Input ("m", Factor)],
               Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7, "
                 & "ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15, r8, r9, r10, cc, memory",
               Volatile => True);
         end if;
         for Channel in Whole .. D - 1 loop
            Accumulated (Accumulated'First + Channel) := Accumulated (Accumulated'First + Channel)
              + Factor * N.Wide_Real (Value (Value'First + Channel));
         end loop;
      end Add_Value;

      procedure Score_Heads
        (Query, K0, K1, K2, K3 : System.Address; Dots : out Real_Array) is
         LF : constant Character := ASCII.LF;
      begin
         System.Machine_Code.Asm
           (
              "vxorps %%xmm0, %%xmm0, %%xmm0" & LF
               & "vxorps %%xmm3, %%xmm3, %%xmm3" & LF
               & "vxorps %%xmm4, %%xmm4, %%xmm4" & LF
               & "movq %0, %%r8" & LF
               & "movq %5, %%r9" & LF
               & "movq %6, %%r10" & LF
               & "xorq %%rax, %%rax" & LF
               & "1:" & LF
               & "vmovss (%1, %%rax), %%xmm1" & LF
               & "vinsertps $16, (%2, %%rax), %%xmm1, %%xmm1" & LF
               & "vinsertps $32, (%3, %%rax), %%xmm1, %%xmm1" & LF
               & "vinsertps $48, (%4, %%rax), %%xmm1, %%xmm1" & LF
               & "vbroadcastss (%%r8, %%rax), %%xmm2" & LF
               & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
               & "vaddps %%xmm2, %%xmm0, %%xmm0" & LF
               & "addq %%r10, %%r8" & LF
               & "vbroadcastss (%%r8, %%rax), %%xmm2" & LF
               & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
               & "vaddps %%xmm2, %%xmm3, %%xmm3" & LF
               & "addq %%r10, %%r8" & LF
               & "vbroadcastss (%%r8, %%rax), %%xmm2" & LF
               & "vmulps %%xmm1, %%xmm2, %%xmm2" & LF
               & "vaddps %%xmm2, %%xmm4, %%xmm4" & LF
               & "subq %%r10, %%r8" & LF
               & "subq %%r10, %%r8" & LF
               & "addq $4, %%rax" & LF
               & "cmpq %%r10, %%rax" & LF
               & "jne 1b" & LF
               & "vmovups %%xmm0, 0(%%r9)" & LF
               & "vmovups %%xmm3, 16(%%r9)" & LF
               & "vmovups %%xmm4, 32(%%r9)" & LF
               & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("r", Query), System.Address'Asm_Input ("r", K0),
                       System.Address'Asm_Input ("r", K1), System.Address'Asm_Input ("r", K2),
                       System.Address'Asm_Input ("r", K3), System.Address'Asm_Input ("r", Dots (Dots'First)'Address),
                       Element_Count'Asm_Input ("r", D * 4)],
            Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, rax, r8, r9, r10, cc, memory", Volatile => True);
      end Score_Heads;

      type Key_Addresses is array (0 .. 7) of System.Address;
      --  Read packed key coordinates in registers. Each SIMD lane remains
      --  one position; binary32 products and sums retain channel order.
      procedure Score_Packed
        (Query : System.Address; Addresses : Key_Addresses; Scales : Real_Array;
         Dots : out Real_Array; Paired : Boolean)
      is
         LF : constant Character := ASCII.LF;
         Query_At : constant System.Address := Query;
         Keys_At : constant System.Address := Addresses (0)'Address;
         Scales_At : constant System.Address := Scales (0)'Address;
         Dots_At : constant System.Address := Dots (Dots'First)'Address;
         Head_Bytes : constant Element_Count := D * 4;
         Pair_Bytes : constant Element_Count := (if Paired then Q * D * 4 else 0);
      begin
         System.Machine_Code.Asm
           (
              "vxorps %%ymm0, %%ymm0, %%ymm0" & LF
               & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
               & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
               & "vxorps %%ymm6, %%ymm6, %%ymm6" & LF
               & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
               & "vxorps %%ymm8, %%ymm8, %%ymm8" & LF
               & "movq %0, %%r8" & LF
               & "movq %1, %%r11" & LF
               & "movq %2, %%r9" & LF
               & "movq %4, %%r10" & LF
               & "movq %5, %%r15" & LF
               & "addq %%r8, %%r15" & LF
               & "movq 0(%%r11), %%rdi" & LF
               & "movq 8(%%r11), %%rsi" & LF
               & "movq 16(%%r11), %%rdx" & LF
               & "movq 24(%%r11), %%rcx" & LF
               & "movq 32(%%r11), %%r12" & LF
               & "movq 40(%%r11), %%r13" & LF
               & "movq 48(%%r11), %%r14" & LF
               & "movq 56(%%r11), %%r11" & LF
               & "movl $15, %%eax" & LF
               & "vmovd %%eax, %%xmm10" & LF
               & "vpbroadcastd %%xmm10, %%ymm10" & LF
               & "movl $0x41000000, %%eax" & LF
               & "vmovd %%eax, %%xmm11" & LF
               & "vbroadcastss %%xmm11, %%ymm11" & LF
               & "xorq %%rax, %%rax" & LF
               & "xorq %%rbx, %%rbx" & LF
               & "1:" & LF
               & "testq $127, %%rbx" & LF
               & "jnz 2f" & LF
               & "vmovups (%%r9), %%ymm9" & LF
               & "addq $32, %%r9" & LF
               & "2:" & LF
               & "vpinsrb $0, (%%rdi, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $1, (%%rsi, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $2, (%%rdx, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $3, (%%rcx, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $4, (%%r12, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $5, (%%r13, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $6, (%%r14, %%rax), %%xmm12, %%xmm12" & LF
               & "vpinsrb $7, (%%r11, %%rax), %%xmm12, %%xmm12" & LF
               & "vpmovzxbd %%xmm12, %%ymm12" & LF
               & "vmovdqa %%ymm12, %%ymm1" & LF
               & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
               & "vcvtdq2ps %%ymm1, %%ymm1" & LF
               & "vsubps %%ymm11, %%ymm1, %%ymm1" & LF
               & "vmulps %%ymm9, %%ymm1, %%ymm1" & LF
               & "vbroadcastss (%%r8, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm0, %%ymm0" & LF
               & "addq %%r10, %%r8" & LF
               & "vbroadcastss (%%r8, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm3, %%ymm3" & LF
               & "addq %%r10, %%r8" & LF
               & "vbroadcastss (%%r8, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm4, %%ymm4" & LF
               & "subq %%r10, %%r8" & LF
               & "subq %%r10, %%r8" & LF
               & "cmpq $0, %5" & LF
               & "je 3f" & LF
               & "vbroadcastss (%%r15, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm6, %%ymm6" & LF
               & "addq %%r10, %%r15" & LF
               & "vbroadcastss (%%r15, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm7, %%ymm7" & LF
               & "addq %%r10, %%r15" & LF
               & "vbroadcastss (%%r15, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm8, %%ymm8" & LF
               & "subq %%r10, %%r15" & LF
               & "subq %%r10, %%r15" & LF
               & "3:" & LF
               & "addq $4, %%rbx" & LF
               & "vpsrld $4, %%ymm12, %%ymm1" & LF
               & "vpand %%ymm10, %%ymm1, %%ymm1" & LF
               & "vcvtdq2ps %%ymm1, %%ymm1" & LF
               & "vsubps %%ymm11, %%ymm1, %%ymm1" & LF
               & "vmulps %%ymm9, %%ymm1, %%ymm1" & LF
               & "vbroadcastss (%%r8, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm0, %%ymm0" & LF
               & "addq %%r10, %%r8" & LF
               & "vbroadcastss (%%r8, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm3, %%ymm3" & LF
               & "addq %%r10, %%r8" & LF
               & "vbroadcastss (%%r8, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm4, %%ymm4" & LF
               & "subq %%r10, %%r8" & LF
               & "subq %%r10, %%r8" & LF
               & "cmpq $0, %5" & LF
               & "je 4f" & LF
               & "vbroadcastss (%%r15, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm6, %%ymm6" & LF
               & "addq %%r10, %%r15" & LF
               & "vbroadcastss (%%r15, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm7, %%ymm7" & LF
               & "addq %%r10, %%r15" & LF
               & "vbroadcastss (%%r15, %%rbx), %%ymm2" & LF
               & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
               & "vaddps %%ymm2, %%ymm8, %%ymm8" & LF
               & "subq %%r10, %%r15" & LF
               & "subq %%r10, %%r15" & LF
               & "4:" & LF
               & "addq $4, %%rbx" & LF
               & "incq %%rax" & LF
               & "cmpq %%r10, %%rbx" & LF
               & "jne 1b" & LF
               & "movq %3, %%r9" & LF
               & "vmovups %%ymm0, 0(%%r9)" & LF
               & "vmovups %%ymm3, 32(%%r9)" & LF
               & "vmovups %%ymm4, 64(%%r9)" & LF
               & "cmpq $0, %5" & LF
               & "je 5f" & LF
               & "vmovups %%ymm6, 96(%%r9)" & LF
               & "vmovups %%ymm7, 128(%%r9)" & LF
               & "vmovups %%ymm8, 160(%%r9)" & LF
               & "5:" & LF
               & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Query_At),
                       System.Address'Asm_Input ("m", Keys_At),
                       System.Address'Asm_Input ("m", Scales_At),
                       System.Address'Asm_Input ("m", Dots_At),
                       Element_Count'Asm_Input ("m", Head_Bytes),
                       Element_Count'Asm_Input ("m", Pair_Bytes)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm6,ymm7,ymm8,ymm9,ymm10,ymm11,ymm12,"
              & "rax,rbx,r8,r9,r10,rdi,rsi,rdx,rcx,r12,r13,r14,r11,r15,cc,memory",
            Volatile => True);
      end Score_Packed;

      procedure Score_Packed_Four
        (Query : System.Address; Addresses : Key_Addresses; Scales : Real_Array; Dots : out Real_Array)
      is
         LF : constant Character := ASCII.LF;
         Query_At : constant System.Address := Query;
         Keys_At : constant System.Address := Addresses (0)'Address;
         Scales_At : constant System.Address := Scales (Scales'First)'Address;
         Dots_At : constant System.Address := Dots (Dots'First)'Address;
         Head_Bytes : constant Element_Count := D * 4;
         Query_Bytes : constant Element_Count := Q * D * 4;
      begin
         System.Machine_Code.Asm
           ("vxorps %%ymm0, %%ymm0, %%ymm0" & LF
            & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
            & "vxorps %%ymm2, %%ymm2, %%ymm2" & LF
            & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
            & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
            & "vxorps %%ymm5, %%ymm5, %%ymm5" & LF
            & "vxorps %%ymm6, %%ymm6, %%ymm6" & LF
            & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
            & "vxorps %%ymm8, %%ymm8, %%ymm8" & LF
            & "vxorps %%ymm9, %%ymm9, %%ymm9" & LF
            & "vxorps %%ymm10, %%ymm10, %%ymm10" & LF
            & "vxorps %%ymm11, %%ymm11, %%ymm11" & LF
            & "movq %0, %%r8" & LF
            & "movq %1, %%r11" & LF
            & "movq %2, %%r9" & LF
            & "movq %4, %%r10" & LF
            & "movq %5, %%r15" & LF
            & "movq 0(%%r11), %%rdi" & LF
            & "movq 8(%%r11), %%rsi" & LF
            & "movq 16(%%r11), %%rdx" & LF
            & "movq 24(%%r11), %%rcx" & LF
            & "movq 32(%%r11), %%r12" & LF
            & "movq 40(%%r11), %%r13" & LF
            & "movq 48(%%r11), %%r14" & LF
            & "movq 56(%%r11), %%r11" & LF
            & "xorq %%rax, %%rax" & LF
            & "xorq %%rbx, %%rbx" & LF
            & "1:" & LF
            & "vpinsrb $0, (%%rdi,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $1, (%%rsi,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $2, (%%rdx,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $3, (%%rcx,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $4, (%%r12,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $5, (%%r13,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $6, (%%r14,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $7, (%%r11,%%rax), %%xmm12, %%xmm12" & LF
            & "vpmovzxbd %%xmm12, %%ymm12" & LF
            & "vmovdqa %%ymm12, %%ymm13" & LF
            & "vpand 6f(%%rip), %%ymm13, %%ymm13" & LF
            & "vcvtdq2ps %%ymm13, %%ymm13" & LF
            & "vsubps 7f(%%rip), %%ymm13, %%ymm13" & LF
            & "vmulps (%%r9), %%ymm13, %%ymm13" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm0, %%ymm0" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm1, %%ymm1" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm2, %%ymm2" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm3, %%ymm3" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm4, %%ymm4" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm5, %%ymm5" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm6, %%ymm6" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm7, %%ymm7" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm8, %%ymm8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm9, %%ymm9" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm10, %%ymm10" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm11, %%ymm11" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "addq $4, %%rbx" & LF
            & "vpsrld $4, %%ymm12, %%ymm13" & LF
            & "vpand 6f(%%rip), %%ymm13, %%ymm13" & LF
            & "vcvtdq2ps %%ymm13, %%ymm13" & LF
            & "vsubps 7f(%%rip), %%ymm13, %%ymm13" & LF
            & "vmulps (%%r9), %%ymm13, %%ymm13" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm0, %%ymm0" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm1, %%ymm1" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm2, %%ymm2" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm3, %%ymm3" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm4, %%ymm4" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm5, %%ymm5" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm6, %%ymm6" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm7, %%ymm7" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm8, %%ymm8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm9, %%ymm9" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm10, %%ymm10" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm11, %%ymm11" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "addq $4, %%rbx" & LF
            & "incq %%rax" & LF
            & "testq $127, %%rbx" & LF
            & "jnz 2f" & LF
            & "addq $32, %%r9" & LF
            & "2:" & LF
            & "cmpq %%r10, %%rbx" & LF
            & "jne 1b" & LF
            & "movq %3, %%r9" & LF
            & "vmovups %%ymm0, 0(%%r9)" & LF
            & "vmovups %%ymm1, 32(%%r9)" & LF
            & "vmovups %%ymm2, 64(%%r9)" & LF
            & "vmovups %%ymm3, 96(%%r9)" & LF
            & "vmovups %%ymm4, 128(%%r9)" & LF
            & "vmovups %%ymm5, 160(%%r9)" & LF
            & "vmovups %%ymm6, 192(%%r9)" & LF
            & "vmovups %%ymm7, 224(%%r9)" & LF
            & "vmovups %%ymm8, 256(%%r9)" & LF
            & "vmovups %%ymm9, 288(%%r9)" & LF
            & "vmovups %%ymm10, 320(%%r9)" & LF
            & "vmovups %%ymm11, 352(%%r9)" & LF
            & "jmp 8f" & LF
            & ".p2align 5" & LF
            & "6: .long 15,15,15,15,15,15,15,15" & LF
            & "7: .long 0x41000000,0x41000000,0x41000000,0x41000000,0x41000000,0x41000000,0x41000000,0x41000000" & LF
            & "8:" & LF
            & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Query_At), System.Address'Asm_Input ("m", Keys_At),
              System.Address'Asm_Input ("m", Scales_At), System.Address'Asm_Input ("m", Dots_At),
              Element_Count'Asm_Input ("m", Head_Bytes), Element_Count'Asm_Input ("m", Query_Bytes)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,"
                       & "ymm15,rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,cc,memory", Volatile => True);
      end Score_Packed_Four;

      procedure Score_Packed_Eight
        (Query : System.Address; Addresses : Key_Addresses; Scales : Real_Array; Dots : out Real_Array);
      pragma Machine_Attribute
        (Score_Packed_Eight, "target", "avx512f,avx512bw,avx512vl,avx512vnni,avx2,fma,f16c");
      pragma No_Inline (Score_Packed_Eight);
      procedure Score_Packed_Eight
        (Query : System.Address; Addresses : Key_Addresses; Scales : Real_Array; Dots : out Real_Array)
      is
         LF : constant Character := ASCII.LF;
         Query_At : constant System.Address := Query;
         Keys_At : constant System.Address := Addresses (0)'Address;
         Scales_At : constant System.Address := Scales (Scales'First)'Address;
         Dots_At : constant System.Address := Dots (Dots'First)'Address;
         Head_Bytes : constant Element_Count := D * 4;
         Query_Bytes : constant Element_Count := Q * D * 4;
      begin
         System.Machine_Code.Asm
           ("vxorps %%ymm0, %%ymm0, %%ymm0" & LF
            & "vxorps %%ymm1, %%ymm1, %%ymm1" & LF
            & "vxorps %%ymm2, %%ymm2, %%ymm2" & LF
            & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
            & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
            & "vxorps %%ymm5, %%ymm5, %%ymm5" & LF
            & "vxorps %%ymm6, %%ymm6, %%ymm6" & LF
            & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
            & "vxorps %%ymm8, %%ymm8, %%ymm8" & LF
            & "vxorps %%ymm9, %%ymm9, %%ymm9" & LF
            & "vxorps %%ymm10, %%ymm10, %%ymm10" & LF
            & "vxorps %%ymm11, %%ymm11, %%ymm11" & LF
            & "vxorps %%ymm16, %%ymm16, %%ymm16" & LF
            & "vxorps %%ymm17, %%ymm17, %%ymm17" & LF
            & "vxorps %%ymm18, %%ymm18, %%ymm18" & LF
            & "vxorps %%ymm19, %%ymm19, %%ymm19" & LF
            & "vxorps %%ymm20, %%ymm20, %%ymm20" & LF
            & "vxorps %%ymm21, %%ymm21, %%ymm21" & LF
            & "vxorps %%ymm22, %%ymm22, %%ymm22" & LF
            & "vxorps %%ymm23, %%ymm23, %%ymm23" & LF
            & "vxorps %%ymm24, %%ymm24, %%ymm24" & LF
            & "vxorps %%ymm25, %%ymm25, %%ymm25" & LF
            & "vxorps %%ymm26, %%ymm26, %%ymm26" & LF
            & "vxorps %%ymm27, %%ymm27, %%ymm27" & LF
            & "movq %0, %%r8" & LF
            & "movq %1, %%r11" & LF
            & "movq %2, %%r9" & LF
            & "movq %4, %%r10" & LF
            & "movq %5, %%r15" & LF
            & "movq 0(%%r11), %%rdi" & LF
            & "movq 8(%%r11), %%rsi" & LF
            & "movq 16(%%r11), %%rdx" & LF
            & "movq 24(%%r11), %%rcx" & LF
            & "movq 32(%%r11), %%r12" & LF
            & "movq 40(%%r11), %%r13" & LF
            & "movq 48(%%r11), %%r14" & LF
            & "movq 56(%%r11), %%r11" & LF
            & "xorq %%rax, %%rax" & LF
            & "xorq %%rbx, %%rbx" & LF
            & "1:" & LF
            & "vpinsrb $0, (%%rdi,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $1, (%%rsi,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $2, (%%rdx,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $3, (%%rcx,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $4, (%%r12,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $5, (%%r13,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $6, (%%r14,%%rax), %%xmm12, %%xmm12" & LF
            & "vpinsrb $7, (%%r11,%%rax), %%xmm12, %%xmm12" & LF
            & "vpmovzxbd %%xmm12, %%ymm12" & LF
            & "vmovdqa %%ymm12, %%ymm13" & LF
            & "vpand 6f(%%rip), %%ymm13, %%ymm13" & LF
            & "vcvtdq2ps %%ymm13, %%ymm13" & LF
            & "vsubps 7f(%%rip), %%ymm13, %%ymm13" & LF
            & "vmulps (%%r9), %%ymm13, %%ymm13" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm0, %%ymm0" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm1, %%ymm1" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm2, %%ymm2" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm3, %%ymm3" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm4, %%ymm4" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm5, %%ymm5" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm6, %%ymm6" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm7, %%ymm7" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm8, %%ymm8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm9, %%ymm9" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm10, %%ymm10" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm11, %%ymm11" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm16, %%ymm16" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm17, %%ymm17" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm18, %%ymm18" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm19, %%ymm19" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm20, %%ymm20" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm21, %%ymm21" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm22, %%ymm22" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm23, %%ymm23" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm24, %%ymm24" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm25, %%ymm25" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm26, %%ymm26" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm27, %%ymm27" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "addq $4, %%rbx" & LF
            & "vpsrld $4, %%ymm12, %%ymm13" & LF
            & "vpand 6f(%%rip), %%ymm13, %%ymm13" & LF
            & "vcvtdq2ps %%ymm13, %%ymm13" & LF
            & "vsubps 7f(%%rip), %%ymm13, %%ymm13" & LF
            & "vmulps (%%r9), %%ymm13, %%ymm13" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm0, %%ymm0" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm1, %%ymm1" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm2, %%ymm2" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm3, %%ymm3" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm4, %%ymm4" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm5, %%ymm5" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm6, %%ymm6" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm7, %%ymm7" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm8, %%ymm8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm9, %%ymm9" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm10, %%ymm10" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm11, %%ymm11" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm16, %%ymm16" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm17, %%ymm17" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm18, %%ymm18" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm19, %%ymm19" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm20, %%ymm20" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm21, %%ymm21" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm22, %%ymm22" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm23, %%ymm23" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm24, %%ymm24" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq %%r15, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm25, %%ymm25" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm26, %%ymm26" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8,%%rbx), %%ymm14" & LF
            & "vmulps %%ymm13, %%ymm14, %%ymm14" & LF
            & "vaddps %%ymm14, %%ymm27, %%ymm27" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "subq %%r15, %%r8" & LF
            & "addq $4, %%rbx" & LF
            & "incq %%rax" & LF
            & "testq $127, %%rbx" & LF
            & "jnz 2f" & LF
            & "addq $32, %%r9" & LF
            & "2:" & LF
            & "cmpq %%r10, %%rbx" & LF
            & "jne 1b" & LF
            & "movq %3, %%r9" & LF
            & "vmovups %%ymm0, 0(%%r9)" & LF
            & "vmovups %%ymm1, 32(%%r9)" & LF
            & "vmovups %%ymm2, 64(%%r9)" & LF
            & "vmovups %%ymm3, 96(%%r9)" & LF
            & "vmovups %%ymm4, 128(%%r9)" & LF
            & "vmovups %%ymm5, 160(%%r9)" & LF
            & "vmovups %%ymm6, 192(%%r9)" & LF
            & "vmovups %%ymm7, 224(%%r9)" & LF
            & "vmovups %%ymm8, 256(%%r9)" & LF
            & "vmovups %%ymm9, 288(%%r9)" & LF
            & "vmovups %%ymm10, 320(%%r9)" & LF
            & "vmovups %%ymm11, 352(%%r9)" & LF
            & "vmovups %%ymm16, 384(%%r9)" & LF
            & "vmovups %%ymm17, 416(%%r9)" & LF
            & "vmovups %%ymm18, 448(%%r9)" & LF
            & "vmovups %%ymm19, 480(%%r9)" & LF
            & "vmovups %%ymm20, 512(%%r9)" & LF
            & "vmovups %%ymm21, 544(%%r9)" & LF
            & "vmovups %%ymm22, 576(%%r9)" & LF
            & "vmovups %%ymm23, 608(%%r9)" & LF
            & "vmovups %%ymm24, 640(%%r9)" & LF
            & "vmovups %%ymm25, 672(%%r9)" & LF
            & "vmovups %%ymm26, 704(%%r9)" & LF
            & "vmovups %%ymm27, 736(%%r9)" & LF
            & "jmp 8f" & LF
            & ".p2align 5" & LF
            & "6: .long 15,15,15,15,15,15,15,15" & LF
            & "7: .long 0x41000000,0x41000000,0x41000000,0x41000000,0x41000000,0x41000000,0x41000000,0x41000000" & LF
            & "8:" & LF
            & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Query_At), System.Address'Asm_Input ("m", Keys_At),
              System.Address'Asm_Input ("m", Scales_At), System.Address'Asm_Input ("m", Dots_At),
              Element_Count'Asm_Input ("m", Head_Bytes), Element_Count'Asm_Input ("m", Query_Bytes)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,ymm9,ymm10,ymm11,ymm12,ymm13,ymm14,"
                       & "ymm15,ymm16,ymm17,ymm18,ymm19,ymm20,ymm21,ymm22,ymm23,ymm24,ymm25,ymm26,ymm27,"
                       & "rax,rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15,cc,memory", Volatile => True);
      end Score_Packed_Eight;


      procedure Score_Heads_Eight
        (Query : System.Address; Keys : Key_Addresses; Dots : out Real_Array) is
         LF : constant Character := ASCII.LF;
         Query_At : constant System.Address := Query;
         Keys_At : constant System.Address := Keys (0)'Address;
         Dots_At : constant System.Address := Dots (Dots'First)'Address;
         Head_Bytes : constant Element_Count := D * 4;
      begin
         System.Machine_Code.Asm
           ("vxorps %%ymm0, %%ymm0, %%ymm0" & LF
            & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
            & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
            & "movq %0, %%r8" & LF
            & "movq %1, %%r11" & LF
            & "movq %2, %%r9" & LF
            & "movq %3, %%r10" & LF
            & "movq 0(%%r11), %%rdi" & LF
            & "movq 8(%%r11), %%rsi" & LF
            & "movq 16(%%r11), %%rdx" & LF
            & "movq 24(%%r11), %%rcx" & LF
            & "movq 32(%%r11), %%r12" & LF
            & "movq 40(%%r11), %%r13" & LF
            & "movq 48(%%r11), %%r14" & LF
            & "movq 56(%%r11), %%r11" & LF
            & "xorq %%rax, %%rax" & LF
            & "1:" & LF
            & "vmovss (%%rdi, %%rax), %%xmm1" & LF
            & "vinsertps $16, (%%rsi, %%rax), %%xmm1, %%xmm1" & LF
            & "vinsertps $32, (%%rdx, %%rax), %%xmm1, %%xmm1" & LF
            & "vinsertps $48, (%%rcx, %%rax), %%xmm1, %%xmm1" & LF
            & "vmovss (%%r12, %%rax), %%xmm5" & LF
            & "vinsertps $16, (%%r13, %%rax), %%xmm5, %%xmm5" & LF
            & "vinsertps $32, (%%r14, %%rax), %%xmm5, %%xmm5" & LF
            & "vinsertps $48, (%%r11, %%rax), %%xmm5, %%xmm5" & LF
            & "vinsertf128 $1, %%xmm5, %%ymm1, %%ymm1" & LF
            & "vbroadcastss (%%r8, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm0, %%ymm0" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm3, %%ymm3" & LF
            & "addq %%r10, %%r8" & LF
            & "vbroadcastss (%%r8, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm4, %%ymm4" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "addq $4, %%rax" & LF
            & "cmpq %%r10, %%rax" & LF
            & "jne 1b" & LF
            & "vmovups %%ymm0, 0(%%r9)" & LF
            & "vmovups %%ymm3, 32(%%r9)" & LF
            & "vmovups %%ymm4, 64(%%r9)" & LF
            & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Query_At),
                       System.Address'Asm_Input ("m", Keys_At),
                       System.Address'Asm_Input ("m", Dots_At),
                       Element_Count'Asm_Input ("m", Head_Bytes)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,"
              & "rax,r8,r9,r10,rdi,rsi,rdx,rcx,r12,r13,r14,r11,cc,memory",
            Volatile => True);
      end Score_Heads_Eight;

      procedure Score_Query_Pair
        (Query : System.Address; Keys : Key_Addresses; Dots : out Real_Array) is
         LF : constant Character := ASCII.LF;
         Query_At : constant System.Address := Query;
         Keys_At : constant System.Address := Keys (0)'Address;
         Dots_At : constant System.Address := Dots (Dots'First)'Address;
         Head_Bytes : constant Element_Count := D * 4;
         Query_Bytes : constant Element_Count := Q * D * 4;
      begin
         System.Machine_Code.Asm
           ("vxorps %%ymm0, %%ymm0, %%ymm0" & LF
            & "vxorps %%ymm3, %%ymm3, %%ymm3" & LF
            & "vxorps %%ymm4, %%ymm4, %%ymm4" & LF
            & "vxorps %%ymm6, %%ymm6, %%ymm6" & LF
            & "vxorps %%ymm7, %%ymm7, %%ymm7" & LF
            & "vxorps %%ymm8, %%ymm8, %%ymm8" & LF
            & "movq %0, %%r8" & LF
            & "movq %1, %%r11" & LF
            & "movq %2, %%r9" & LF
            & "movq %3, %%r10" & LF
            & "movq %4, %%r15" & LF
            & "addq %%r8, %%r15" & LF
            & "movq 0(%%r11), %%rdi" & LF
            & "movq 8(%%r11), %%rsi" & LF
            & "movq 16(%%r11), %%rdx" & LF
            & "movq 24(%%r11), %%rcx" & LF
            & "movq 32(%%r11), %%r12" & LF
            & "movq 40(%%r11), %%r13" & LF
            & "movq 48(%%r11), %%r14" & LF
            & "movq 56(%%r11), %%r11" & LF
            & "xorq %%rax, %%rax" & LF
            & "1:" & LF
            & "vmovss (%%rdi, %%rax), %%xmm1" & LF
            & "vinsertps $16, (%%rsi, %%rax), %%xmm1, %%xmm1" & LF
            & "vinsertps $32, (%%rdx, %%rax), %%xmm1, %%xmm1" & LF
            & "vinsertps $48, (%%rcx, %%rax), %%xmm1, %%xmm1" & LF
            & "vmovss (%%r12, %%rax), %%xmm5" & LF
            & "vinsertps $16, (%%r13, %%rax), %%xmm5, %%xmm5" & LF
            & "vinsertps $32, (%%r14, %%rax), %%xmm5, %%xmm5" & LF
            & "vinsertps $48, (%%r11, %%rax), %%xmm5, %%xmm5" & LF
            & "vinsertf128 $1, %%xmm5, %%ymm1, %%ymm1" & LF
            & "vbroadcastss (%%r8, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm0, %%ymm0" & LF
            & "vbroadcastss (%%r15, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm6, %%ymm6" & LF
            & "addq %%r10, %%r8" & LF
            & "addq %%r10, %%r15" & LF
            & "vbroadcastss (%%r8, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm3, %%ymm3" & LF
            & "vbroadcastss (%%r15, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm7, %%ymm7" & LF
            & "addq %%r10, %%r8" & LF
            & "addq %%r10, %%r15" & LF
            & "vbroadcastss (%%r8, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm4, %%ymm4" & LF
            & "vbroadcastss (%%r15, %%rax), %%ymm2" & LF
            & "vmulps %%ymm1, %%ymm2, %%ymm2" & LF
            & "vaddps %%ymm2, %%ymm8, %%ymm8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r8" & LF
            & "subq %%r10, %%r15" & LF
            & "subq %%r10, %%r15" & LF
            & "addq $4, %%rax" & LF
            & "cmpq %%r10, %%rax" & LF
            & "jne 1b" & LF
            & "vmovups %%ymm0, 0(%%r9)" & LF
            & "vmovups %%ymm3, 32(%%r9)" & LF
            & "vmovups %%ymm4, 64(%%r9)" & LF
            & "vmovups %%ymm6, 96(%%r9)" & LF
            & "vmovups %%ymm7, 128(%%r9)" & LF
            & "vmovups %%ymm8, 160(%%r9)" & LF
            & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Query_At),
                       System.Address'Asm_Input ("m", Keys_At),
                       System.Address'Asm_Input ("m", Dots_At),
                       Element_Count'Asm_Input ("m", Head_Bytes),
                       Element_Count'Asm_Input ("m", Query_Bytes)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm7,ymm8,"
              & "rax,r8,r9,r10,rdi,rsi,rdx,rcx,r12,r13,r14,r11,r15,cc,memory",
            Volatile => True);
      end Score_Query_Pair;

      function Reference_Dot (Left, Right : Real_Array) return Real is
         Span : constant B.Byte_Count := B.Byte_Count (Left'Length) * 4;
         Weight : constant T.View :=
           (Format => Model_Runner.GGUF.Type_F32, Rows => 1, Columns => Left'Length,
            Role => T.Role_Attention, Reference_Activations => True, Scales => null,
            Base => Left (Left'First)'Address, Span => Span, Offset => 0,
            Length => Span, Interleaved => False);
         Result : Real_Array (0 .. 0);
         Handled : Boolean;
      begin
         T.Mat_Mul_Range_Float (Weight, Right, 1, Result, 0, 0, Handled);
         if not Handled then return K.Dot (Left, Right); end if;
         return Result (0);
      end Reference_Dot;

      procedure One
        (Head, Token : Element_Count; Precomputed : Boolean := False;
         Make_Values : Boolean := True; Score_Offset : Element_Count := 0;
         Scores_Finished : Boolean := False; Given_Maximum : Real := 0.0;
         Normalization : access Real := null) is
         Position : constant Element_Count := Element_Count (Item.Committed) + Token;
         Query : Real_Array (0 .. Q * D - 1) with Import, Address => Queries (Token * Q * D)'Address;
         Attention : Real_Array (0 .. Q * D - 1) with Import, Address => Attention_Rows (Token * Q * D)'Address;
         Relative : Real_Array (0 .. Q * R - 1) with Import, Address => Relatives (Token * Q * R)'Address;
         Sinks : Real_Array (0 .. Q - 1) with Import, Address => Sink_Rows (Token * Q)'Address;
         First : constant Element_Count :=
           (if Local and then Position >= Element_Count (Settings.Window)
            then Position - Element_Count (Settings.Window) + 1 else 0);
         Scores : Real_Array (0 .. Position - First)
           with Import, Address => Item.Scores (Score_Offset + Head * Item.Score_Room)'Address;
         Key, Value : Real_Array (0 .. D - 1);
         Maximum, Score, Bias, Probability, Inverse : Real;
         Denominator : N.Wide_Real;
         Accumulated : N.Wide_Real_Array (0 .. D - 1);
         Past : Element_Count := First;
         KV_Head : constant Element_Count := Head / Element_Count (Settings.Group_Size);

         procedure Finish_Score (At_Position : Element_Count; Dot : Real) is
         begin
            Bias := 0.0;
            if Position - At_Position < Extent then
               for Channel in 0 .. R - 1 loop
                  Bias := Bias + Relative (Head * R + Channel)
                    * Relative_Table ((Position - At_Position) * R + Channel);
               end loop;
            end if;
            Score := Dot * Scale + (Bias - Sinks (Head));
            Scores (At_Position - First) := Score;
            Maximum := Real'Max (Maximum, Score);
         end Finish_Score;
      begin
         Maximum := Given_Maximum;
         if Precomputed and then Scores_Finished then
            Past := Position + 1;
         elsif Precomputed then
            if Item.Held = Transformed_Fourth then
               while Past <= Position and then Position - Past >= 7 loop
                  declare
                     Done : Boolean;
                  begin
                     K.Relative_Scores_Eight
                       (Scores (Past - First .. Past - First + 7), Relative (Head * R .. (Head + 1) * R - 1),
                        Relative_Table.all, Position - Past, Extent, Scale, Sinks (Head), Done);
                     for Lane in Element_Count range 0 .. 7 loop
                        if Done then Maximum := Real'Max (Maximum, Scores (Past + Lane - First));
                        else Finish_Score (Past + Lane, Scores (Past + Lane - First)); end if;
                     end loop;
                  end;
                  Past := Past + 8;
               end loop;
            end if;
            for Index in Past .. Position loop Finish_Score (Index, Scores (Index - First)); end loop;
            Past := Position + 1;
         elsif Wide_Values and then Item.Held = Exact and then not Reference_Folds then
            while Past <= Position and then Position - Past >= 3 loop
               declare
                  type Offsets is array (Element_Count range 0 .. 3) of Element_Count;
                  At_Key : Offsets;
                  Dots : Real_Array (0 .. 3);
               begin
                  for Member in At_Key'Range loop
                     At_Key (Member) := Keys_At (Item, State)
                       + Cell_Of (Item, State, Past + Member) * KV * D + KV_Head * D;
                  end loop;
                  declare
                     Key_0 : Real_Array renames Item.Keys.all (At_Key (0) .. At_Key (0) + D - 1);
                     Key_1 : Real_Array renames Item.Keys.all (At_Key (1) .. At_Key (1) + D - 1);
                     Key_2 : Real_Array renames Item.Keys.all (At_Key (2) .. At_Key (2) + D - 1);
                     Key_3 : Real_Array renames Item.Keys.all (At_Key (3) .. At_Key (3) + D - 1);
                  begin
                     Score_Four
                       (Query (Head * D)'Address,
                        Key_0 (Key_0'First)'Address, Key_1 (Key_1'First)'Address,
                        Key_2 (Key_2'First)'Address, Key_3 (Key_3'First)'Address, Dots);
                  end;
                  for Member in Dots'Range loop
                     Finish_Score (Past + Member, Dots (Member));
                  end loop;
               end;
               Past := Past + 4;
            end loop;
         end if;
         for Remaining in Past .. Position loop
            declare
               At_Key : constant Element_Count := Keys_At (Item, State)
                 + Cell_Of (Item, State, Remaining) * KV * D + KV_Head * D;
            begin
               Read_Key (At_Key, Key);
               if Reference_Folds then
                  Score := Reference_Dot (Query (Head * D .. (Head + 1) * D - 1), Key);
               else
                  Score := 0.0;
                  for Channel in 0 .. D - 1 loop
                     Score := Score + Query (Head * D + Channel) * Key (Channel);
                  end loop;
               end if;
               Finish_Score (Remaining, Score);
            end;
         end loop;
         if Reference_Folds then
            declare
               Group : Real_Array (0 .. 15) := [others => 0.0];
            begin
               Denominator := 0.0;
               Draft_Exp (Scores, Maximum);
               for Past in First .. Position loop
                  Group ((Past - First) mod 16) := Scores (Past - First);
                  if (Past - First) mod 16 = 15 then
                     Denominator := Denominator + N.Wide_Real (Reference_Sum_Sixteen (Group));
                     Group := [others => 0.0];
                  end if;
               end loop;
               if (Position - First + 1) mod 16 /= 0 then
                  Denominator := Denominator + N.Wide_Real (Reference_Sum_Sixteen (Group));
               end if;
               Denominator := Denominator + N.Wide_Real (Reference_Exp (-Maximum));
            end;
         else
            Denominator := N.Wide_Real (Real (N.Exp (N.Wide_Real (-Maximum))));
            for Past in First .. Position loop
               Probability := Real (N.Exp (N.Wide_Real (Scores (Past - First) - Maximum)));
               Scores (Past - First) := Probability;
               Denominator := Denominator + N.Wide_Real (Probability);
            end loop;
         end if;
         Inverse := Real (1.0 / Denominator);
         if not Make_Values then
            if Normalization /= null then
               Normalization.all := Inverse;
               return;
            end if;
            for Index in Scores'Range loop
               Scores (Index) := Scores (Index) * Inverse;
            end loop;
            return;
         end if;
         if Reference_Folds then
            --  The CPU reference pads KV rows to whole vector tiles. Its
            --  value dot uses four sixteen-lane FMA streams and the same
            --  fold as the query/key product. Keep those lanes by token
            --  while processing all channels of one value together.
            declare
               Lanes : Real_Array (0 .. 64 * D - 1) := [others => 0.0];
               LF : constant Character := ASCII.LF;
            begin
               for Past in First .. Position loop
                  declare
                     At_Value : constant Element_Count := Values_At (Item, State)
                       + Cell_Of (Item, State, Past) * KV * D + KV_Head * D;
                     Lane : constant Element_Count := (Past mod 64) * D;
                     P : constant Real := Scores (Past - First) * Inverse;
                  begin
                     Read_Value (At_Value, Value);
                     if Wide_Values and then D mod 8 = 0 then
                        System.Machine_Code.Asm
                          ("movq %0, %%r8" & LF
                           & "movq %1, %%r9" & LF
                           & "movq %3, %%r10" & LF
                           & "vbroadcastss %2, %%ymm0" & LF
                           & "1:" & LF
                           & "vmovups (%%r8), %%ymm1" & LF
                           & "vfmadd213ps (%%r9), %%ymm0, %%ymm1" & LF
                           & "vmovups %%ymm1, (%%r9)" & LF
                           & "addq $32, %%r8" & LF
                           & "addq $32, %%r9" & LF
                           & "decq %%r10" & LF
                           & "jnz 1b" & LF
                           & "vzeroupper",
                           Inputs => [System.Address'Asm_Input ("r", Value (0)'Address),
                                      System.Address'Asm_Input ("r", Lanes (Lane)'Address),
                                      Real'Asm_Input ("m", P), Element_Count'Asm_Input ("r", D / 8)],
                           Clobber => "r8,r9,r10,ymm0,ymm1,cc,memory", Volatile => True);
                     else
                        for Channel in 0 .. D - 1 loop
                           Lanes (Lane + Channel) :=
                             Fused_Product (Value (Channel), P, Lanes (Lane + Channel));
                        end loop;
                     end if;
                  end;
               end loop;
               for Index in Element_Count range 0 .. 16 * D - 1 loop
                  Lanes (Index) := (Lanes (Index) + Lanes (Index + 32 * D))
                    + (Lanes (Index + 16 * D) + Lanes (Index + 48 * D));
               end loop;
               for Index in Element_Count range 0 .. 8 * D - 1 loop
                  Lanes (Index) := Lanes (Index + 8 * D) + Lanes (Index);
               end loop;
               for Index in Element_Count range 0 .. 4 * D - 1 loop
                  Lanes (Index) := Lanes (Index + 4 * D) + Lanes (Index);
               end loop;
               for Channel in 0 .. D - 1 loop
                  Attention (Head * D + Channel) :=
                    (Lanes (Channel + 2 * D) + Lanes (Channel))
                      + (Lanes (Channel + 3 * D) + Lanes (Channel + D));
               end loop;
            end;
            return;
         end if;
         Accumulated := [others => 0.0];
         for Past in First .. Position loop
            declare
               At_Value : constant Element_Count := Values_At (Item, State)
                 + Cell_Of (Item, State, Past) * KV * D + KV_Head * D;
            begin
               Probability := Scores (Past - First) * Inverse;
               if Item.Held_Values = Exact then
                  declare
                     Cached : Real_Array (0 .. D - 1)
                       with Import, Address => Item.Values.all (At_Value)'Address;
                  begin
                     Add_Value (Cached, Probability, Accumulated);
                  end;
               else
                  Read_Value (At_Value, Value);
                  Add_Value (Value, Probability, Accumulated);
               end if;
            end;
         end loop;
         for Channel in 0 .. D - 1 loop
            Attention (Head * D + Channel) := Real (Accumulated (Channel));
         end loop;
      end One;

      procedure Group_Values (Value : Real_Array; P : N.Wide_Real_Array; Acc : in out N.Wide_Real_Array) is
         Whole : constant Element_Count := D / 4 * 4;
         LF : constant Character := ASCII.LF;
      begin
         if Whole > 0 then
            System.Machine_Code.Asm
              (
              "movq %0, %%r8" & LF
               & "movq %1, %%r9" & LF
               & "movq %2, %%r10" & LF
               & "movq %3, %%r11" & LF
               & "movq %4, %%r12" & LF
               & "movq %5, %%r13" & LF
               & "vbroadcastsd 0(%%r12), %%ymm0" & LF
               & "vbroadcastsd 8(%%r12), %%ymm1" & LF
               & "vbroadcastsd 16(%%r12), %%ymm2" & LF
               & "1:" & LF
               & "vcvtps2pd (%%r8), %%ymm3" & LF
               & "vmulpd %%ymm0, %%ymm3, %%ymm4" & LF
               & "vaddpd (%%r9), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, (%%r9)" & LF
               & "addq $32, %%r9" & LF
               & "vmulpd %%ymm1, %%ymm3, %%ymm4" & LF
               & "vaddpd (%%r10), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, (%%r10)" & LF
               & "addq $32, %%r10" & LF
               & "vmulpd %%ymm2, %%ymm3, %%ymm4" & LF
               & "vaddpd (%%r11), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, (%%r11)" & LF
               & "addq $32, %%r11" & LF
               & "addq $16, %%r8" & LF
               & "decq %%r13" & LF
               & "jnz 1b" & LF
               & "vzeroupper",
               Inputs => [System.Address'Asm_Input ("r", Value (Value'First)'Address),
                          System.Address'Asm_Input ("r", Acc (Acc'First)'Address),
                          System.Address'Asm_Input ("r", Acc (Acc'First + D)'Address),
                          System.Address'Asm_Input ("r", Acc (Acc'First + 2 * D)'Address),
                          System.Address'Asm_Input ("r", P (P'First)'Address),
                          Element_Count'Asm_Input ("r", Whole / 4)],
               Clobber => "ymm0, ymm1, ymm2, ymm3, ymm4, r8, r9, r10, r11, r12, r13, cc, memory",
               Volatile => True);
         end if;
         for Channel in Whole .. D - 1 loop
            for Member in Element_Count range 0 .. 2 loop
               Acc (Acc'First + Member * D + Channel) := Acc (Acc'First + Member * D + Channel)
                 + P (Member) * N.Wide_Real (Value (Value'First + Channel));
            end loop;
         end loop;
      end Group_Values;

      --  Decode eight value coordinates in registers and immediately
      --  accumulate them into three heads, retaining binary64 sums.
      procedure Packed_Group_Values
        (Origin : Element_Count; P : N.Wide_Real_Array;
         Acc : in out N.Wide_Real_Array)
      is
         At_Byte : constant B.Byte_Count := Byte_Of (Fourth, Origin, D);
         At_Scale : constant Element_Count :=
           Item.Value_Scales'First + Scale_Of (Fourth, Origin, D);
         Bytes_At : constant System.Address := Item.Byte_Values (At_Byte)'Address;
         Acc_At : constant System.Address := Acc (Acc'First)'Address;
         Scales_At : constant System.Address := Item.Value_Scales (At_Scale)'Address;
         P_At : constant System.Address := P (P'First)'Address;
         Blocks : constant Element_Count := D / 32;
         Stride : constant Element_Count := D * 8;
         LF : constant Character := ASCII.LF;
      begin
         System.Machine_Code.Asm
           (
              "movq %0, %%r8" & LF
               & "movq %1, %%r9" & LF
               & "movq %2, %%r10" & LF
               & "movq %3, %%r11" & LF
               & "movq %4, %%r12" & LF
               & "movq %5, %%r13" & LF
               & "leaq (%%r9, %%r13), %%r14" & LF
               & "leaq (%%r14, %%r13), %%r15" & LF
               & "vbroadcastsd 0(%%r12), %%ymm8" & LF
               & "vbroadcastsd 8(%%r12), %%ymm9" & LF
               & "vbroadcastsd 16(%%r12), %%ymm10" & LF
               & "movl $0x0F0F0F0F, %%eax" & LF
               & "vmovd %%eax, %%xmm14" & LF
               & "vpbroadcastd %%xmm14, %%xmm14" & LF
               & "movl $0x41000000, %%eax" & LF
               & "vmovd %%eax, %%xmm15" & LF
               & "vbroadcastss %%xmm15, %%ymm15" & LF
               & "1:" & LF
               & "vbroadcastss (%%r10), %%ymm6" & LF
               & "movl $4, %%ecx" & LF
               & "2:" & LF
               & "vmovd (%%r8), %%xmm0" & LF
               & "vpand %%xmm14, %%xmm0, %%xmm1" & LF
               & "vpsrlw $4, %%xmm0, %%xmm2" & LF
               & "vpand %%xmm14, %%xmm2, %%xmm2" & LF
               & "vpunpcklbw %%xmm2, %%xmm1, %%xmm4" & LF
               & "vpmovzxbd %%xmm4, %%ymm0" & LF
               & "vcvtdq2ps %%ymm0, %%ymm0" & LF
               & "vsubps %%ymm15, %%ymm0, %%ymm0" & LF
               & "vmulps %%ymm6, %%ymm0, %%ymm0" & LF
               & "vcvtps2pd %%xmm0, %%ymm3" & LF
               & "vextractf128 $1, %%ymm0, %%xmm0" & LF
               & "vcvtps2pd %%xmm0, %%ymm5" & LF
               & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
               & "vaddpd 0(%%r9), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, 0(%%r9)" & LF
               & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
               & "vaddpd 32(%%r9), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, 32(%%r9)" & LF
               & "addq $64, %%r9" & LF
               & "vmulpd %%ymm9, %%ymm3, %%ymm4" & LF
               & "vaddpd 0(%%r14), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, 0(%%r14)" & LF
               & "vmulpd %%ymm9, %%ymm5, %%ymm4" & LF
               & "vaddpd 32(%%r14), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, 32(%%r14)" & LF
               & "addq $64, %%r14" & LF
               & "vmulpd %%ymm10, %%ymm3, %%ymm4" & LF
               & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, 0(%%r15)" & LF
               & "vmulpd %%ymm10, %%ymm5, %%ymm4" & LF
               & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
               & "vmovupd %%ymm4, 32(%%r15)" & LF
               & "addq $64, %%r15" & LF
               & "addq $4, %%r8" & LF
               & "decl %%ecx" & LF
               & "jnz 2b" & LF
               & "addq $4, %%r10" & LF
               & "decq %%r11" & LF
               & "jnz 1b" & LF
               & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Bytes_At),
                       System.Address'Asm_Input ("m", Acc_At),
                       System.Address'Asm_Input ("m", Scales_At),
                       Element_Count'Asm_Input ("m", Blocks),
                       System.Address'Asm_Input ("m", P_At),
                       Element_Count'Asm_Input ("m", Stride)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm8,ymm9,ymm10,ymm14,ymm15,"
              & "rax,rcx,r8,r9,r10,r11,r12,r13,r14,r15,cc,memory",
            Volatile => True);
      end Packed_Group_Values;

      procedure Packed_Group_Values_Wide
        (Origin : Element_Count; P : N.Wide_Real_Array;
         Acc : in out N.Wide_Real_Array)
      is
         At_Byte : constant B.Byte_Count := Byte_Of (Fourth, Origin, D);
         At_Scale : constant Element_Count :=
           Item.Value_Scales'First + Scale_Of (Fourth, Origin, D);
         Bytes_At : constant System.Address := Item.Byte_Values (At_Byte)'Address;
         Acc_At : constant System.Address := Acc (Acc'First)'Address;
         Scales_At : constant System.Address := Item.Value_Scales (At_Scale)'Address;
         P_At : constant System.Address := P (P'First)'Address;
         Blocks : constant Element_Count := D / 32;
         Stride : constant Element_Count := D * 8;
         LF : constant Character := ASCII.LF;
      begin
         System.Machine_Code.Asm
           (
              "movq %0, %%r8" & LF
               & "movq %1, %%r9" & LF
               & "movq %2, %%r10" & LF
               & "movq %3, %%r11" & LF
               & "movq %4, %%r12" & LF
               & "movq %5, %%r13" & LF
               & "leaq (%%r9, %%r13), %%r14" & LF
               & "leaq (%%r14, %%r13), %%r15" & LF
               & "vbroadcastsd 0(%%r12), %%zmm8" & LF
               & "vbroadcastsd 8(%%r12), %%zmm9" & LF
               & "vbroadcastsd 16(%%r12), %%zmm10" & LF
               & "movl $0x0F0F0F0F, %%eax" & LF
               & "vmovd %%eax, %%xmm14" & LF
               & "vpbroadcastd %%xmm14, %%xmm14" & LF
               & "movl $0x41000000, %%eax" & LF
               & "vmovd %%eax, %%xmm15" & LF
               & "vbroadcastss %%xmm15, %%zmm15" & LF
               & "1:" & LF
               & "vbroadcastss (%%r10), %%zmm6" & LF
               & "movl $2, %%ecx" & LF
               & "2:" & LF
               & "vmovq (%%r8), %%xmm0" & LF
               & "vpand %%xmm14, %%xmm0, %%xmm1" & LF
               & "vpsrlw $4, %%xmm0, %%xmm2" & LF
               & "vpand %%xmm14, %%xmm2, %%xmm2" & LF
               & "vpunpcklbw %%xmm2, %%xmm1, %%xmm4" & LF
               & "vpmovzxbd %%xmm4, %%zmm0" & LF
               & "vcvtdq2ps %%zmm0, %%zmm0" & LF
               & "vsubps %%zmm15, %%zmm0, %%zmm0" & LF
               & "vmulps %%zmm6, %%zmm0, %%zmm0" & LF
               & "vcvtps2pd %%ymm0, %%zmm3" & LF
               & "vextractf64x4 $1, %%zmm0, %%ymm0" & LF
               & "vcvtps2pd %%ymm0, %%zmm5" & LF
               & "vmulpd %%zmm8, %%zmm3, %%zmm4" & LF
               & "vaddpd 0(%%r9), %%zmm4, %%zmm4" & LF
               & "vmovupd %%zmm4, 0(%%r9)" & LF
               & "vmulpd %%zmm8, %%zmm5, %%zmm4" & LF
               & "vaddpd 64(%%r9), %%zmm4, %%zmm4" & LF
               & "vmovupd %%zmm4, 64(%%r9)" & LF
               & "addq $128, %%r9" & LF
               & "vmulpd %%zmm9, %%zmm3, %%zmm4" & LF
               & "vaddpd 0(%%r14), %%zmm4, %%zmm4" & LF
               & "vmovupd %%zmm4, 0(%%r14)" & LF
               & "vmulpd %%zmm9, %%zmm5, %%zmm4" & LF
               & "vaddpd 64(%%r14), %%zmm4, %%zmm4" & LF
               & "vmovupd %%zmm4, 64(%%r14)" & LF
               & "addq $128, %%r14" & LF
               & "vmulpd %%zmm10, %%zmm3, %%zmm4" & LF
               & "vaddpd 0(%%r15), %%zmm4, %%zmm4" & LF
               & "vmovupd %%zmm4, 0(%%r15)" & LF
               & "vmulpd %%zmm10, %%zmm5, %%zmm4" & LF
               & "vaddpd 64(%%r15), %%zmm4, %%zmm4" & LF
               & "vmovupd %%zmm4, 64(%%r15)" & LF
               & "addq $128, %%r15" & LF
               & "addq $8, %%r8" & LF
               & "decl %%ecx" & LF
               & "jnz 2b" & LF
               & "addq $4, %%r10" & LF
               & "decq %%r11" & LF
               & "jnz 1b" & LF
               & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Bytes_At),
                       System.Address'Asm_Input ("m", Acc_At),
                       System.Address'Asm_Input ("m", Scales_At),
                       Element_Count'Asm_Input ("m", Blocks),
                       System.Address'Asm_Input ("m", P_At),
                       Element_Count'Asm_Input ("m", Stride)],
            Clobber => "zmm0,zmm1,zmm2,zmm3,zmm4,zmm5,zmm6,zmm8,zmm9,zmm10,zmm14,zmm15,"
              & "rax,rcx,r8,r9,r10,r11,r12,r13,r14,r15,cc,memory",
            Volatile => True);
      end Packed_Group_Values_Wide;

      procedure Packed_Four_Query_Values
        (Origin : Element_Count; P : N.Wide_Real_Array; Active : Element_Count;
         Acc : in out N.Wide_Real_Array)
      is
         At_Byte : constant B.Byte_Count := Byte_Of (Fourth, Origin, D);
         At_Scale : constant Element_Count := Item.Value_Scales'First + Scale_Of (Fourth, Origin, D);
         Bytes_At : constant System.Address := Item.Byte_Values (At_Byte)'Address;
         Acc_At : constant System.Address := Acc (Acc'First)'Address;
         Scales_At : constant System.Address := Item.Value_Scales (At_Scale)'Address;
         P_At : constant System.Address := P (P'First)'Address;
         Blocks : constant Element_Count := D / 32;
         Stride : constant Element_Count := D * 8;
         LF : constant Character := ASCII.LF;
      begin
         System.Machine_Code.Asm
           ("movq %0, %%r8" & LF
            & "movq %1, %%r9" & LF
            & "movq %2, %%r10" & LF
            & "movq %3, %%r11" & LF
            & "movq %4, %%r12" & LF
            & "movq %5, %%r13" & LF
            & "movq %6, %%r14" & LF
            & "movl $0x0f0f0f0f, %%eax" & LF
            & "vmovd %%eax, %%xmm14" & LF
            & "vpbroadcastd %%xmm14, %%xmm14" & LF
            & "movl $0x41000000, %%eax" & LF
            & "vmovd %%eax, %%xmm15" & LF
            & "vbroadcastss %%xmm15, %%ymm15" & LF
            & "1:" & LF
            & "vbroadcastss (%%r10), %%ymm6" & LF
            & "movl $4, %%ecx" & LF
            & "2:" & LF
            & "vmovd (%%r8), %%xmm0" & LF
            & "vpand %%xmm14, %%xmm0, %%xmm1" & LF
            & "vpsrlw $4, %%xmm0, %%xmm2" & LF
            & "vpand %%xmm14, %%xmm2, %%xmm2" & LF
            & "vpunpcklbw %%xmm2, %%xmm1, %%xmm4" & LF
            & "vpmovzxbd %%xmm4, %%ymm0" & LF
            & "vcvtdq2ps %%ymm0, %%ymm0" & LF
            & "vsubps %%ymm15, %%ymm0, %%ymm0" & LF
            & "vmulps %%ymm6, %%ymm0, %%ymm0" & LF
            & "vcvtps2pd %%xmm0, %%ymm3" & LF
            & "vextractf128 $1, %%ymm0, %%xmm0" & LF
            & "vcvtps2pd %%xmm0, %%ymm5" & LF
            & "testq $1, %%r14" & LF
            & "jz 3f" & LF
            & "movl $0, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 0(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 8(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 16(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "3:" & LF
            & "testq $2, %%r14" & LF
            & "jz 4f" & LF
            & "movl $3, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 24(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 32(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 40(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "4:" & LF
            & "testq $4, %%r14" & LF
            & "jz 5f" & LF
            & "movl $6, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 48(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 56(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 64(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "5:" & LF
            & "testq $8, %%r14" & LF
            & "jz 6f" & LF
            & "movl $9, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 72(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 80(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 88(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "6:" & LF
            & "addq $64, %%r9" & LF
            & "addq $4, %%r8" & LF
            & "decl %%ecx" & LF
            & "jnz 2b" & LF
            & "addq $4, %%r10" & LF
            & "decq %%r11" & LF
            & "jnz 1b" & LF
            & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Bytes_At), System.Address'Asm_Input ("m", Acc_At),
              System.Address'Asm_Input ("m", Scales_At), Element_Count'Asm_Input ("m", Blocks),
              System.Address'Asm_Input ("m", P_At), Element_Count'Asm_Input ("m", Stride),
              Element_Count'Asm_Input ("m", Active)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm8,ymm14,ymm15,rax,rcx,r8,r9,r10,r11,r12,"
                       & "r13,r14,r15,cc,memory", Volatile => True);
      end Packed_Four_Query_Values;

      procedure Packed_Eight_Query_Values
        (Origin : Element_Count; P : N.Wide_Real_Array; Active : Element_Count;
         Acc : in out N.Wide_Real_Array)
      is
         At_Byte : constant B.Byte_Count := Byte_Of (Fourth, Origin, D);
         At_Scale : constant Element_Count := Item.Value_Scales'First + Scale_Of (Fourth, Origin, D);
         Bytes_At : constant System.Address := Item.Byte_Values (At_Byte)'Address;
         Acc_At : constant System.Address := Acc (Acc'First)'Address;
         Scales_At : constant System.Address := Item.Value_Scales (At_Scale)'Address;
         P_At : constant System.Address := P (P'First)'Address;
         Blocks : constant Element_Count := D / 32;
         Stride : constant Element_Count := D * 8;
         LF : constant Character := ASCII.LF;
      begin
         System.Machine_Code.Asm
           ("movq %0, %%r8" & LF
            & "movq %1, %%r9" & LF
            & "movq %2, %%r10" & LF
            & "movq %3, %%r11" & LF
            & "movq %4, %%r12" & LF
            & "movq %5, %%r13" & LF
            & "movq %6, %%r14" & LF
            & "movl $0x0f0f0f0f, %%eax" & LF
            & "vmovd %%eax, %%xmm14" & LF
            & "vpbroadcastd %%xmm14, %%xmm14" & LF
            & "movl $0x41000000, %%eax" & LF
            & "vmovd %%eax, %%xmm15" & LF
            & "vbroadcastss %%xmm15, %%ymm15" & LF
            & "1:" & LF
            & "vbroadcastss (%%r10), %%ymm6" & LF
            & "movl $4, %%ecx" & LF
            & "2:" & LF
            & "vmovd (%%r8), %%xmm0" & LF
            & "vpand %%xmm14, %%xmm0, %%xmm1" & LF
            & "vpsrlw $4, %%xmm0, %%xmm2" & LF
            & "vpand %%xmm14, %%xmm2, %%xmm2" & LF
            & "vpunpcklbw %%xmm2, %%xmm1, %%xmm4" & LF
            & "vpmovzxbd %%xmm4, %%ymm0" & LF
            & "vcvtdq2ps %%ymm0, %%ymm0" & LF
            & "vsubps %%ymm15, %%ymm0, %%ymm0" & LF
            & "vmulps %%ymm6, %%ymm0, %%ymm0" & LF
            & "vcvtps2pd %%xmm0, %%ymm3" & LF
            & "vextractf128 $1, %%ymm0, %%xmm0" & LF
            & "vcvtps2pd %%xmm0, %%ymm5" & LF
            & "testq $1, %%r14" & LF
            & "jz 3f" & LF
            & "movl $0, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 0(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 8(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 16(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "3:" & LF
            & "testq $2, %%r14" & LF
            & "jz 4f" & LF
            & "movl $3, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 24(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 32(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 40(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "4:" & LF
            & "testq $4, %%r14" & LF
            & "jz 5f" & LF
            & "movl $6, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 48(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 56(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 64(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "5:" & LF
            & "testq $8, %%r14" & LF
            & "jz 6f" & LF
            & "movl $9, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 72(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 80(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 88(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "6:" & LF
            & "testq $16, %%r14" & LF
            & "jz 7f" & LF
            & "movl $12, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 96(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 104(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 112(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "7:" & LF
            & "testq $32, %%r14" & LF
            & "jz 8f" & LF
            & "movl $15, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 120(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 128(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 136(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "8:" & LF
            & "testq $64, %%r14" & LF
            & "jz 9f" & LF
            & "movl $18, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 144(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 152(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 160(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "9:" & LF
            & "testq $128, %%r14" & LF
            & "jz 10f" & LF
            & "movl $21, %%eax" & LF
            & "imulq %%r13, %%rax" & LF
            & "leaq (%%r9,%%rax), %%r15" & LF
            & "vbroadcastsd 168(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 176(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "addq %%r13, %%r15" & LF
            & "vbroadcastsd 184(%%r12), %%ymm8" & LF
            & "vmulpd %%ymm8, %%ymm3, %%ymm4" & LF
            & "vaddpd 0(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 0(%%r15)" & LF
            & "vmulpd %%ymm8, %%ymm5, %%ymm4" & LF
            & "vaddpd 32(%%r15), %%ymm4, %%ymm4" & LF
            & "vmovupd %%ymm4, 32(%%r15)" & LF
            & "10:" & LF
            & "addq $64, %%r9" & LF
            & "addq $4, %%r8" & LF
            & "decl %%ecx" & LF
            & "jnz 2b" & LF
            & "addq $4, %%r10" & LF
            & "decq %%r11" & LF
            & "jnz 1b" & LF
            & "vzeroupper",
            Inputs => [System.Address'Asm_Input ("m", Bytes_At), System.Address'Asm_Input ("m", Acc_At),
              System.Address'Asm_Input ("m", Scales_At), Element_Count'Asm_Input ("m", Blocks),
              System.Address'Asm_Input ("m", P_At), Element_Count'Asm_Input ("m", Stride),
              Element_Count'Asm_Input ("m", Active)],
            Clobber => "ymm0,ymm1,ymm2,ymm3,ymm4,ymm5,ymm6,ymm8,ymm14,ymm15,rax,rcx,r8,r9,r10,r11,r12,"
                       & "r13,r14,r15,cc,memory", Volatile => True);
      end Packed_Eight_Query_Values;


      procedure Group_Of_Heads (Work, Token : Element_Count) is
         Position : constant Element_Count := Element_Count (Item.Committed) + Token;
         First : constant Element_Count :=
           (if Local and then Position >= Element_Count (Settings.Window)
            then Position - Element_Count (Settings.Window) + 1 else 0);
         Dots : Real_Array (0 .. 11);
         Key_Tile : Real_Array (0 .. 4 * D - 1);
         Past : Element_Count := First;
         Head : constant Element_Count := Work * 3;
         Fused : constant Boolean := Item.Held = Transformed_Fourth;
         Maxima : Real_Array (0 .. 2) := [others => 0.0];
         Deferred : constant Boolean := Fused and then Item.Held_Values = Fourth;
         Inverses : Real_Array (0 .. 2);
         procedure Store (Member, Position_At : Element_Count; Values : in out Real_Array) is
            Done : Boolean := False;
            Bias : Real;
            Actual_Head : constant Element_Count := Head + Member;
         begin
            if Fused then
               if Values'Length = 8 then
                  K.Relative_Scores_Eight
                    (Values, Relatives (Token * Q * R + Actual_Head * R .. Token * Q * R + (Actual_Head + 1) * R - 1),
                     Relative_Table.all, Position - Position_At, Extent, Scale,
                     Sink_Rows (Token * Q + Actual_Head), Done);
               end if;
               for I in Values'Range loop
                  if not Done then
                     Bias := 0.0;
                     if Position - Position_At - (I - Values'First) < Extent then
                        for C in 0 .. R - 1 loop
                           Bias := Bias + Relatives (Token * Q * R + Actual_Head * R + C)
                             * Relative_Table ((Position - Position_At - (I - Values'First)) * R + C);
                        end loop;
                     end if;
                     Values (I) := Values (I) * Scale + (Bias - Sink_Rows (Token * Q + Actual_Head));
                  end if;
                  Maxima (Member) := Real'Max (Maxima (Member), Values (I));
               end loop;
            end if;
            Item.Scores.all (Actual_Head * Item.Score_Room + Position_At - First
                            .. Actual_Head * Item.Score_Room + Position_At - First + Values'Length - 1) := Values;
         end Store;

      begin
         while Past <= Position and then Position - Past >= 7 loop
            declare
               Addresses : Key_Addresses;
               Expanded : Real_Array (0 .. 8 * D - 1);
               Eight_Dots : Real_Array (0 .. 23);
            begin
               for Member in Addresses'Range loop
                  declare
                     At_Key : constant Element_Count := Keys_At (Item, State)
                       + Cell_Of (Item, State, Past + Element_Count (Member)) * KV * D + Work * D;
                  begin
                     if Item.Held = Exact then
                        Addresses (Member) := Item.Keys (At_Key)'Address;
                     elsif Item.Held /= Transformed_Fourth then
                        Read_Key (At_Key,
                          Expanded (Element_Count (Member) * D .. (Element_Count (Member) + 1) * D - 1));
                        Addresses (Member) := Expanded (Element_Count (Member) * D)'Address;
                     end if;
                  end;
               end loop;
               if Item.Held = Transformed_Fourth then
                  declare
                     Held_Scales : Real_Array (0 .. D / 32 * 8 - 1);
                  begin
                     for Member in Addresses'Range loop
                        declare
                           Origin : constant Element_Count := Keys_At (Item, State)
                             + Cell_Of (Item, State, Past + Element_Count (Member)) * KV * D + Work * D;
                        begin
                           Addresses (Member) := Item.Byte_Keys (Byte_Of (Fourth, Origin, D))'Address;
                           for Group in Element_Count range 0 .. D / 32 - 1 loop
                              Held_Scales (Group * 8 + Element_Count (Member)) :=
                                Item.Key_Scales (Item.Key_Scales'First + Scale_Of (Fourth, Origin, D) + Group);
                           end loop;
                        end;
                     end loop;
                     Score_Packed (Queries (Token * Q * D + Head * D)'Address,
                                   Addresses, Held_Scales, Eight_Dots, Paired => False);
                  end;
               else
                  Score_Heads_Eight (Queries (Token * Q * D + Head * D)'Address, Addresses, Eight_Dots);
               end if;
               for Member in Element_Count range 0 .. 2 loop
                  Store (Member, Past, Eight_Dots (Member * 8 .. Member * 8 + 7));
               end loop;
            end;
            Past := Past + 8;
         end loop;
         while Past <= Position and then Position - Past >= 3 loop
            declare
               type Places is array (0 .. 3) of Element_Count;
               At_Key : Places;
            begin
               for Member in At_Key'Range loop
                  At_Key (Member) := Keys_At (Item, State)
                    + Cell_Of (Item, State, Past + Element_Count (Member)) * KV * D + Work * D;
               end loop;
               if Item.Held = Exact then
               Score_Heads (Queries (Token * Q * D + Head * D)'Address,
                            Item.Keys (At_Key (0))'Address, Item.Keys (At_Key (1))'Address,
                            Item.Keys (At_Key (2))'Address, Item.Keys (At_Key (3))'Address, Dots);
               else
                  for Member in At_Key'Range loop
                     Read_Key (At_Key (Member),
                                    Key_Tile (Element_Count (Member) * D .. (Element_Count (Member) + 1) * D - 1));
                  end loop;
                  Score_Heads (Queries (Token * Q * D + Head * D)'Address,
                               Key_Tile (0)'Address, Key_Tile (D)'Address,
                               Key_Tile (2 * D)'Address, Key_Tile (3 * D)'Address, Dots);
               end if;
               for Member in Element_Count range 0 .. 2 loop
                  Store (Member, Past, Dots (Member * 4 .. Member * 4 + 3));
               end loop;
            end;
            Past := Past + 4;
         end loop;
         for Index in Past .. Position loop
            declare
               At_Key : constant Element_Count := Keys_At (Item, State)
                 + Cell_Of (Item, State, Index) * KV * D + Work * D;
               Sums : Real_Array (0 .. 2) := [others => 0.0];
               Key_Row : Real_Array (0 .. D - 1);
            begin
               Read_Key (At_Key, Key_Row);
               for Channel in 0 .. D - 1 loop
                  declare
                     Key : constant Real := Key_Row (Channel);
                  begin
                     for Member in Sums'Range loop
                        Sums (Member) := Sums (Member) + Key * Queries (Token * Q * D + (Head + Member) * D + Channel);
                     end loop;
                  end;
               end loop;
               for Member in Sums'Range loop
                  Store (Member, Index, Sums (Member .. Member));
               end loop;
            end;
         end loop;
         for Member in Element_Count range 0 .. 2 loop
            One (Head + Member, Token, Precomputed => True, Make_Values => False,
                 Scores_Finished => Fused, Given_Maximum => Maxima (Member),
                 Normalization => (if Deferred then Inverses (Member)'Unrestricted_Access else null));
         end loop;
         declare
            Acc : N.Wide_Real_Array (0 .. 3 * D - 1) := [others => 0.0];
            P : N.Wide_Real_Array (0 .. 2);
            Value : Real_Array (0 .. D - 1);
         begin
            for Index in First .. Position loop
               declare
                  At_Value : constant Element_Count := Values_At (Item, State)
                    + Cell_Of (Item, State, Index) * KV * D + Work * D;
               begin
                  for Member in P'Range loop
                     declare
                        Probability : Real := Item.Scores ((Head + Member) * Item.Score_Room + Index - First);
                     begin
                        if Deferred then Probability := Probability * Inverses (Member); end if;
                        P (Member) := N.Wide_Real (Probability);
                     end;
                  end loop;
                  if Item.Held_Values = Exact then
                     Group_Values (Item.Values.all (At_Value .. At_Value + D - 1), P, Acc);
                  elsif Item.Held_Values = Fourth then
                     if Workers_CPU.Byte_Products then Packed_Group_Values_Wide (At_Value, P, Acc);
                     else Packed_Group_Values (At_Value, P, Acc); end if;
                  else
                     Read_Value (At_Value, Value);
                     Group_Values (Value, P, Acc);
                  end if;
               end;
            end loop;
            for Channel in Acc'Range loop
               Attention_Rows (Token * Q * D + Head * D + Channel) := Real (Acc (Channel));
            end loop;
         end;
      end Group_Of_Heads;

      --  Two queries share each key conversion and value fetch. Score rows
      --  remain disjoint; softmax and value sums keep chronological order.
      procedure Group_Of_Queries (Work, Token : Element_Count; Query_Count : Positive := 2) is
         Head : constant Element_Count := Work * 3;
         type Pair_Places is array (Element_Count range 0 .. Element_Count (Query_Count) - 1) of Element_Count;
         Positions : constant Pair_Places :=
           [for Which in Pair_Places'Range => Element_Count (Item.Committed) + Token + Which];
         Firsts : Pair_Places;
         Past : Element_Count;
         Last : constant Element_Count := Positions (Positions'Last);
         Key_Tile : Real_Array (0 .. 8 * D - 1);
         Pair_Dots : Real_Array (0 .. Element_Count (Query_Count) * 24 - 1);
         Fused : constant Boolean := Item.Held = Transformed_Fourth;
         Maxima : Real_Array (0 .. Element_Count (Query_Count) * 3 - 1) := [others => 0.0];
         Deferred : constant Boolean := Fused and then Item.Held_Values = Fourth;
         Inverses : Real_Array (Maxima'Range);
         procedure Finish (Which, Member, At_Position : Element_Count; Value : in out Real) is
            Bias : Real := 0.0;
            Distance : constant Element_Count := Positions (Which) - At_Position;
            At_Head : constant Element_Count := Head + Member;
         begin
            if not Fused then return; end if;
            if Distance < Extent then
               for C in 0 .. R - 1 loop
                  Bias := Bias + Relatives ((Token + Which) * Q * R + At_Head * R + C)
                    * Relative_Table (Distance * R + C);
               end loop;
            end if;
            Value := Value * Scale + (Bias - Sink_Rows ((Token + Which) * Q + At_Head));
            Maxima (Which * 3 + Member) := Real'Max (Maxima (Which * 3 + Member), Value);
         end Finish;
         procedure Finish_Block (Which, Member, At_Position : Element_Count; Values : in out Real_Array) is
            Done : Boolean := False;
            At_Head : constant Element_Count := Head + Member;
         begin
            if not Fused then return; end if;
            if At_Position >= Firsts (Which) and then At_Position + 7 <= Positions (Which) then
               K.Relative_Scores_Eight
                 (Values, Relatives ((Token + Which) * Q * R + At_Head * R
                                    .. (Token + Which) * Q * R + (At_Head + 1) * R - 1),
                  Relative_Table.all, Positions (Which) - At_Position, Extent, Scale,
                  Sink_Rows ((Token + Which) * Q + At_Head), Done);
            end if;
            for I in Values'Range loop
               if At_Position + I - Values'First >= Firsts (Which)
                 and then At_Position + I - Values'First <= Positions (Which)
               then
                  if Done then
                     Maxima (Which * 3 + Member) := Real'Max (Maxima (Which * 3 + Member), Values (I));
                  else Finish (Which, Member, At_Position + I - Values'First, Values (I)); end if;
               end if;
            end loop;
         end Finish_Block;
         function Score_At (Which, Member, Position : Element_Count) return Element_Count is
           ((Which * Q + Head + Member) * Item.Score_Room + Position - Firsts (Which));
         function Probability_At (Which, Member, Position : Element_Count) return N.Wide_Real is
            Value : Real := Item.Scores (Score_At (Which, Member, Position));
         begin
            if Deferred then Value := Value * Inverses (Which * 3 + Member); end if;
            return N.Wide_Real (Value);
         end Probability_At;
      begin
         for Which in Firsts'Range loop
            Firsts (Which) :=
              (if Local and then Positions (Which) >= Element_Count (Settings.Window)
               then Positions (Which) - Element_Count (Settings.Window) + 1 else 0);
         end loop;
         Past := Firsts (0);
         while Past <= Last and then Last - Past >= 7 loop
            declare
               Addresses : Key_Addresses;
            begin
               for Member in Addresses'Range loop
                  declare
                     At_Key : constant Element_Count := Keys_At (Item, State)
                       + Cell_Of (Item, State, Past + Element_Count (Member)) * KV * D + Work * D;
                  begin
                     if Item.Held = Exact then
                        Addresses (Member) := Item.Keys (At_Key)'Address;
                     elsif Item.Held /= Transformed_Fourth then
                        Read_Key (At_Key,
                          Key_Tile (Element_Count (Member) * D .. (Element_Count (Member) + 1) * D - 1));
                        Addresses (Member) := Key_Tile (Element_Count (Member) * D)'Address;
                     end if;
                  end;
               end loop;
               if Item.Held = Transformed_Fourth then
                  declare
                     Held_Scales : Real_Array (0 .. D / 32 * 8 - 1);
                  begin
                     for Member in Addresses'Range loop
                        declare
                           Origin : constant Element_Count := Keys_At (Item, State)
                             + Cell_Of (Item, State, Past + Element_Count (Member)) * KV * D + Work * D;
                        begin
                           Addresses (Member) := Item.Byte_Keys (Byte_Of (Fourth, Origin, D))'Address;
                           for Group in Element_Count range 0 .. D / 32 - 1 loop
                              Held_Scales (Group * 8 + Element_Count (Member)) :=
                                Item.Key_Scales (Item.Key_Scales'First + Scale_Of (Fourth, Origin, D) + Group);
                           end loop;
                        end;
                     end loop;
                     if Query_Count = 8 then
                        Score_Packed_Eight (Queries (Token * Q * D + Head * D)'Address,
                                            Addresses, Held_Scales, Pair_Dots);
                     elsif Query_Count = 4 then
                        Score_Packed_Four (Queries (Token * Q * D + Head * D)'Address,
                                           Addresses, Held_Scales, Pair_Dots);
                     else
                     Score_Packed (Queries (Token * Q * D + Head * D)'Address,
                                   Addresses, Held_Scales, Pair_Dots, Paired => True);
                     end if;
                  end;
               else
                  Score_Query_Pair (Queries (Token * Q * D + Head * D)'Address, Addresses, Pair_Dots);
               end if;
               for Which in Firsts'Range loop
                  for Member in Element_Count range 0 .. 2 loop
                     Finish_Block (Which, Member, Past, Pair_Dots (Which * 24 + Member * 8
                                   .. Which * 24 + Member * 8 + 7));
                     for Position in Element_Count range 0 .. 7 loop
                        if Past + Position >= Firsts (Which) and then Past + Position <= Positions (Which) then
                           Item.Scores (Score_At (Which, Member, Past + Position)) :=
                             Pair_Dots (Which * 24 + Member * 8 + Position);
                        end if;
                     end loop;
                  end loop;
               end loop;
            end;
            Past := Past + 8;
         end loop;
         for Position in Past .. Last loop
            declare
               At_Key : constant Element_Count := Keys_At (Item, State)
                 + Cell_Of (Item, State, Position) * KV * D + Work * D;
               Key : Real_Array (0 .. D - 1);
               Sums : Real_Array (0 .. Element_Count (Query_Count) * 3 - 1) := [others => 0.0];
            begin
               Read_Key (At_Key, Key);
               for Channel in 0 .. D - 1 loop
                  for Which in Firsts'Range loop
                     for Member in Element_Count range 0 .. 2 loop
                        Sums (Which * 3 + Member) := Sums (Which * 3 + Member)
                          + Key (Channel) * Queries ((Token + Which) * Q * D + (Head + Member) * D + Channel);
                     end loop;
                  end loop;
               end loop;
               for Which in Firsts'Range loop
                  if Position >= Firsts (Which) and then Position <= Positions (Which) then
                     for Member in Element_Count range 0 .. 2 loop
                        Finish (Which, Member, Position, Sums (Which * 3 + Member));
                        Item.Scores (Score_At (Which, Member, Position)) := Sums (Which * 3 + Member);
                     end loop;
                  end if;
               end loop;
            end;
         end loop;
         for Which in Firsts'Range loop
            for Member in Element_Count range 0 .. 2 loop
               One (Head + Member, Token + Which, Precomputed => True, Make_Values => False,
                    Score_Offset => Which * Q * Item.Score_Room,
                    Scores_Finished => Fused, Given_Maximum => Maxima (Which * 3 + Member),
                    Normalization => (if Deferred then Inverses (Which * 3 + Member)'Unrestricted_Access else null));
            end loop;
         end loop;
         declare
            Acc : N.Wide_Real_Array (0 .. Element_Count (Query_Count) * 3 * D - 1) := [others => 0.0];
            P : N.Wide_Real_Array (0 .. 2);
            Value : Real_Array (0 .. D - 1);
         begin
            for Position in Firsts (0) .. Last loop
               declare
                  At_Value : constant Element_Count := Values_At (Item, State)
                    + Cell_Of (Item, State, Position) * KV * D + Work * D;
               begin
                  if Item.Held_Values /= Fourth then Read_Value (At_Value, Value); end if;
                  if Query_Count in 4 | 8 and then Item.Held_Values = Fourth then
                     declare
                        Probabilities : N.Wide_Real_Array (0 .. Element_Count (Query_Count) * 3 - 1) := [others => 0.0];
                        Active : Element_Count := 0;
                     begin
                        for Which in Firsts'Range loop
                           if Position >= Firsts (Which) and then Position <= Positions (Which) then
                              Active := Active + 2 ** Natural (Which);
                              for Member in P'Range loop
                                 Probabilities (Which * 3 + Member) :=
                                   Probability_At (Which, Member, Position);
                              end loop;
                           end if;
                        end loop;
                        if Query_Count = 8 then
                           Packed_Eight_Query_Values (At_Value, Probabilities, Active, Acc);
                        else
                           Packed_Four_Query_Values (At_Value, Probabilities, Active, Acc);
                        end if;
                     end;
                  else
                  for Which in Firsts'Range loop
                     if Position >= Firsts (Which) and then Position <= Positions (Which) then
                        for Member in P'Range loop
                           P (Member) := Probability_At (Which, Member, Position);
                        end loop;
                        if Item.Held_Values = Fourth then
                           Packed_Group_Values (At_Value, P, Acc (Which * 3 * D .. (Which + 1) * 3 * D - 1));
                        else
                           Group_Values (Value, P, Acc (Which * 3 * D .. (Which + 1) * 3 * D - 1));
                        end if;
                     end if;
                  end loop;
                  end if;
               end;
            end loop;
            for Which in Firsts'Range loop
               for Channel in Element_Count range 0 .. 3 * D - 1 loop
                  Attention_Rows ((Token + Which) * Q * D + Head * D + Channel) :=
                    Real (Acc (Which * 3 * D + Channel));
               end loop;
            end loop;
         end;
      end Group_Of_Queries;

      type Head_Share is limited new Workers_CPU.Task_Item with null record;
      overriding procedure Run
        (Share : in out Head_Share; From, To : Element_Count);

      overriding procedure Run
        (Share : in out Head_Share; From, To : Element_Count)
      is
         pragma Unreferenced (Share);
      begin
         for Work in From .. To loop
            if Heads_Per_Work = 3 and then Wide_Values and then not Reference_Folds then
               declare
                  Token : Element_Count := 0;
               begin
                  if Item.Held = Transformed_Fourth and then Item.Held_Values = Fourth then
                     if Workers_CPU.Byte_Products then
                        while Token + 7 < Batch_Count loop
                           if C.Is_Cancelled (Cancel) then return; end if;
                           Group_Of_Queries (Work, Token, 8);
                           Token := Token + 8;
                        end loop;
                     end if;
                     while Token + 3 < Batch_Count loop
                        if C.Is_Cancelled (Cancel) then return; end if;
                        Group_Of_Queries (Work, Token, 4);
                        Token := Token + 4;
                     end loop;
                  end if;
                  while Token + 1 < Batch_Count loop
                     if C.Is_Cancelled (Cancel) then return; end if;
                     Group_Of_Queries (Work, Token);
                     Token := Token + 2;
                  end loop;
                  if Token < Batch_Count then Group_Of_Heads (Work, Token); end if;
               end;
            else
               for Head in Work * Heads_Per_Work .. (Work + 1) * Heads_Per_Work - 1 loop
                  for Token in 0 .. Batch_Count - 1 loop
                     if C.Is_Cancelled (Cancel) then return; end if;
                     One (Head, Token);
                  end loop;
               end loop;
            end if;
         end loop;
      end Run;

      Share : aliased Head_Share;
   begin
      --  Sliding caches reserve a window plus a batch. Publish this visit's
      --  rows once; each query still reads only First .. Position above.
      for Token in 0 .. Batch_Count - 1 loop
         Check;
         declare
            Position : constant Element_Count := Element_Count (Item.Committed) + Token;
            Cell : constant Element_Count := Cell_Of (Item, State, Position);
            Key_At : constant Element_Count := Keys_At (Item, State) + Cell * KV * D;
            Value_At : constant Element_Count := Values_At (Item, State) + Cell * KV * D;
            Key_Row : Real_Array (0 .. KV * D - 1) with Import, Address => Keys (Token * KV * D)'Address;
            Value_Row : Real_Array (0 .. KV * D - 1) with Import, Address => Values (Token * KV * D)'Address;
         begin
            if Item.Held = Exact then
               Item.Keys.all (Key_At .. Key_At + KV * D - 1) := Key_Row;
            elsif Item.Held = Halved then
               K.To_Halves (Key_Row, Item.Half_Keys.all (Key_At .. Key_At + KV * D - 1));
            else
               Pack_Row (Key_Row, Item.Byte_Keys.all, Key_At, KV * D,
                         Item.Key_Scales.all, Item.Held);
            end if;
            if Item.Held_Values = Exact then
               Item.Values.all (Value_At .. Value_At + KV * D - 1) := Value_Row;
            elsif Item.Held_Values = Halved then
               K.To_Halves (Value_Row, Item.Half_Values.all (Value_At .. Value_At + KV * D - 1));
            else
               Pack_Row (Value_Row, Item.Byte_Values.all, Value_At, KV * D,
                         Item.Value_Scales.all, Item.Held_Values);
            end if;
         end;
      end loop;
      if Item.Held = Transformed_Fourth and then D mod Q4T.Group_Size = 0 then
         declare
            Valid : Boolean;
         begin
            Q4T.Rotate_Rows (Queries, D, Batch_Count * Q, Valid);
            if not Valid then Status := E.Make (E.Internal_Invariant_Violated); Check; end if;
         end;
      elsif Item.Held = Transformed_Fourth then
         declare
            Rotated : Real_Array (0 .. D - 1);
            Valid : Boolean;
         begin
            --  One bounded head-sized temporary, independently of batch
            --  size. Relative bias and sink logits stay in their own basis.
            for Head in 0 .. Batch_Count * Q - 1 loop
               Q4T.Rotate_Key (Queries (Head * D .. (Head + 1) * D - 1), Rotated, Valid);
               if not Valid then
                  Status := E.Make (E.Internal_Invariant_Violated);
                  Check;
               end if;
               Queries (Head * D .. (Head + 1) * D - 1) := Rotated;
            end loop;
         end;
      end if;
      Attention_Rows := [others => 0.0];
      if Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
        and then not Item.Host_Feed and then On_Device
      then
         Finite (Attention_Rows); Charge (Item, Attending, Mark); return;
      end if;
      Workers_CPU.Dispatch_Shares
        (Item.Team, Q / Heads_Per_Work, Share'Unchecked_Access, Status,
         Cost => 4 * Q * D * Batch_Count * Span);
      Check;
      Finite (Attention_Rows);
      Charge (Item, Attending, Mark);
   end Attend;
   begin
      --  Every live region is produced before consumption. In particular,
      --  Used_Blocks gates saved rows, and messages exist only after Mix.
      --  Into and attention accumulators retain their own initialization.
      if Embeddings = null then
         Acts := Item.Activation.all;
      else
         Acts := Embeddings.all;
      end if;
      for Token in 0 .. Batch_Count - 1 loop
         K.RMS_Norm (Acts (Token * H .. (Token + 1) * H - 1), Source.Embedding_Norm.all,
                     Settings.Epsilon, Normals (Token * H .. (Token + 1) * H - 1), K.Binary32_Stages);
      end loop;
      Acts := Normals;
      S.Build (Settings.Layers, (Settings.Inkling.First_Layer, Settings.Inkling.End_Layer,
               Settings.Inkling.Iterations), Order, Status);
      Check;
      for Logical in 0 .. S.Length (Order) - 1 loop
         S.Resolve (Order, Logical, Step, Status);
         Check;
         Item.Inkling_Plan_Slot := Step.State_Layer;
         declare
            Physical : constant Natural := Step.Physical_Layer;
            Current : Layer renames Source.Layers (Physical);
            W : Inkling_Weight_Views renames Current.Inkling_Weights;
            Local : constant Boolean := Settings.Window_Layers (Physical);
            Core : constant Boolean := Physical in Settings.Inkling.First_Layer .. Settings.Inkling.End_Layer - 1;
            Shared_CPU : constant Boolean := Item.Seen = null and then Reference_Arithmetic
              and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_CPU);
            Same_Local : constant Boolean := Local and then not (Core and then Step.Visit > 1);
            Fused_Norm : constant Boolean := Shared_CPU and then Same_Local;
            Group_Projections : constant Boolean := Batch_Count = 1 and then not Item.Host_Feed
              and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device);
         begin
            if Physical = Settings.Inkling.First_Layer then
               if Step.Visit = 1 then
                  Prelude := Acts;
               else
                  Bank := Blocks (2 * Wide .. 3 * Wide - 1);
                  --  Both message sources remain fixed during this visit.
                  for Token in 0 .. Batch_Count - 1 loop
                     Plain_Norm
                       (Acts (Token * H .. (Token + 1) * H - 1),
                        Bank_Out (Token * H .. (Token + 1) * H - 1));
                  end loop;
                  Acts := Prelude;
                  Used_Blocks := 1;
               end if;
            end if;
            Capture (Step.Logical_Layer, Acts);
            if Core and then Step.Visit > 1 then
               Mix (Bank, 1, Bank_Out, W (Inkling_Message_Query), Messages,
                    Current_Normalized => True);
               Observe ("loop_messages", Messages);
            end if;
            Residual := Acts;
            if T.Is_Present (W (Inkling_Attention_Depth)) then
               Mix (Blocks, Used_Blocks, Residual, W (Inkling_Attention_Depth),
                    Inputs (0 .. (if Local then Wide else 3 * Wide) - 1));
               for Token in 0 .. Batch_Count - 1 loop
                  declare
                     Base : constant Element_Count := Token * (if Local then H else 3 * H);
                     Dest : constant Element_Count := Token * H;
                  begin
                     In_Q (Dest .. Dest + H - 1) := Inputs (Base .. Base + H - 1);
                     In_K (Dest .. Dest + H - 1) :=
                       Inputs (Base + (if Local then 0 else H) .. Base + (if Local then H else 2 * H) - 1);
                     In_V (Dest .. Dest + H - 1) :=
                       Inputs (Base + (if Local then 0 else 2 * H) .. Base + (if Local then H else 3 * H) - 1);
                  end;
               end loop;
            else
               In_Q := Residual;
               In_K := Residual;
               In_V := Residual;
            end if;
            if Core and then Step.Visit > 1 then
               Control (In_Q, 0, W);
               Control (In_K, 1, W);
               Control (In_V, 2, W);
               Observe ("loop_control_q", In_Q);
               Observe ("loop_control_k", In_K);
               Observe ("loop_control_v", In_V);
            end if;
            if not Fused_Norm then
            Norm (In_Q, W (if Local then Inkling_Attention_Norm else Inkling_Query_Norm));
            if Same_Local then In_K := In_Q; In_V := In_Q;
            else
               Norm (In_K, W (if Local then Inkling_Attention_Norm else Inkling_Key_Norm));
               Norm (In_V, W (if Local then Inkling_Attention_Norm else Inkling_Value_Norm));
            end if;
            end if;
            if Group_Projections then
               declare
                  Views : constant T.View_Group :=
                    (if Local then T.View_Group'[W (Inkling_Query), W (Inkling_Key), W (Inkling_Value),
                                                 W (Inkling_Relative), W (Inkling_Sink)]
                     else T.View_Group'[W (Inkling_Query), W (Inkling_Key), W (Inkling_Value),
                                        W (Inkling_Key_Dynamic), W (Inkling_Value_Dynamic),
                                        W (Inkling_Relative), W (Inkling_Sink)]);
                  Targets : constant T.Target_Group :=
                    (if Local then T.Target_Group'[Queries'Unrestricted_Access, Keys'Unrestricted_Access,
                           Values'Unrestricted_Access, Relatives'Unrestricted_Access, Sink_Rows'Unrestricted_Access]
                     else T.Target_Group'[Queries'Unrestricted_Access, Keys'Unrestricted_Access,
                           Values'Unrestricted_Access, Dynamic_K'Unrestricted_Access, Dynamic_V'Unrestricted_Access,
                           Relatives'Unrestricted_Access, Sink_Rows'Unrestricted_Access]);
               begin
                  Projection_Group (0 .. H - 1) := In_Q;
                  Projection_Group (H .. 2 * H - 1) := In_K;
                  Projection_Group (2 * H .. 3 * H - 1) := In_V;
                  if Local then
                     Projection_Group (3 * H .. 4 * H - 1) := In_Q;
                     Projection_Group (4 * H .. 5 * H - 1) := In_Q;
                  else
                     Projection_Group (3 * H .. 4 * H - 1) := In_K;
                     Projection_Group (4 * H .. 5 * H - 1) := In_V;
                     Projection_Group (5 * H .. 6 * H - 1) := In_Q;
                     Projection_Group (6 * H .. 7 * H - 1) := In_Q;
                  end if;
                  Product_Group (Item, Views, Projection_Group'Unrestricted_Access, Targets, Status, Apart => H);
                  Check;
                  for Target of Targets loop
                     Finite (Target.all);
                  end loop;
                  Charge (Item, Projecting, Mark);
               end;
            elsif Shared_CPU then
               if Same_Local then
                  Shared_Mats
                    ([W (Inkling_Query), W (Inkling_Key), W (Inkling_Value), W (Inkling_Relative), W (Inkling_Sink)],
                     In_Q, [Queries'Unrestricted_Access, Keys'Unrestricted_Access, Values'Unrestricted_Access,
                            Relatives'Unrestricted_Access, Sink_Rows'Unrestricted_Access],
                     Gain => (if Fused_Norm then Cached (W (Inkling_Attention_Norm)) else null),
                     Scratch => (if Fused_Norm then In_K'Unrestricted_Access else null));
               else
                  Shared_Mats
                    ([W (Inkling_Query), W (Inkling_Relative), W (Inkling_Sink)], In_Q,
                     [Queries'Unrestricted_Access, Relatives'Unrestricted_Access, Sink_Rows'Unrestricted_Access]);
                  if Local then
                     Mat (W (Inkling_Key), In_K, Keys); Mat (W (Inkling_Value), In_V, Values);
                  else
                     Shared_Mats ([W (Inkling_Key), W (Inkling_Key_Dynamic)], In_K,
                                  [Keys'Unrestricted_Access, Dynamic_K'Unrestricted_Access]);
                     Shared_Mats ([W (Inkling_Value), W (Inkling_Value_Dynamic)], In_V,
                                  [Values'Unrestricted_Access, Dynamic_V'Unrestricted_Access]);
                  end if;
               end if;
            else
            Mat (W (Inkling_Query), In_Q, Queries);
            Mat (W (Inkling_Key), In_K, Keys);
            Mat (W (Inkling_Value), In_V, Values);
            if not Local then
               Mat (W (Inkling_Key_Dynamic), In_K, Dynamic_K);
               Mat (W (Inkling_Value_Dynamic), In_V, Dynamic_V);
            end if;
            end if;
            Convolve_Rows (Keys, W (Inkling_Key_Conv), 0, Dynamic_K, not Local);
            Convolve_Rows (Values, W (Inkling_Value_Conv), KV * D, Dynamic_V, not Local);
            if not Group_Projections and then not Shared_CPU then
               Mat (W (Inkling_Relative), In_Q, Relatives);
            end if;
            Clip_Rows (Queries, D, W (Inkling_Query_Clip), Settings.Inkling.QK_Clip);
            Clip_Rows (Keys, D, T.Empty_View, Settings.Inkling.QK_Clip);
            for Head in 0 .. Batch_Count * KV - 1 loop
               Plain_Norm (Values (Head * D .. (Head + 1) * D - 1),
                           Values (Head * D .. (Head + 1) * D - 1), Settings.Epsilon);
            end loop;
            Clip_Rows (Relatives, R, W (Inkling_Relative_Clip), Settings.Inkling.Relative_Clip);
            if not Local then
               for Token in 0 .. Batch_Count - 1 loop
                  declare
                     Position : constant Element_Count := Element_Count (Item.Committed) + Token;
                     Tau : constant Real := 1.0 + Settings.Inkling.Log_Scale_Alpha * Real (N.Log
                       (N.Wide_Real (Real'Max (1.0, Real (Position + 1) / Real (Settings.Inkling.Log_Scale_Floor)))));
                  begin
                     for Value of Queries (Token * Q * D .. (Token + 1) * Q * D - 1) loop
                        Value := Value * Tau;
                     end loop;
                     for Value of Relatives (Token * Q * R .. (Token + 1) * Q * R - 1) loop
                        Value := Value * Tau;
                     end loop;
                  end;
               end loop;
            end if;
            if not Group_Projections and then not Shared_CPU then
               Mat (W (Inkling_Sink), In_Q, Sink_Rows);
            end if;
            Observe ("Qcur", Queries);
            Observe ("Kcur", Keys);
            Observe ("Vcur", Values);
            Observe ("Rcur", Relatives);
            --  The distance table is the same for every head and token
            --  in this visit. Decode each reachable row once, outside the
            --  quadratic attention loop and before workers read it.
            Relative_Table := Cached (W (Inkling_Relative_Bias));
            if Item.Held = Transformed_Fourth then Observe ("attn_q4t_sinks", Sink_Rows); end if;
            Attention_Ready := False;
            Attend (Local);
            Observe ("attention_values", Attention_Rows);
            if Item.Held = Transformed_Fourth then Observe ("attn_q4t_output", Attention_Rows); end if;
            if not Attention_Ready then
            Attention_Convolved := False;
            Attention_Joined := False;
            declare
               Done : Boolean := False;
               Conv_Base : constant Element_Count :=
                 Element_Count (Step.State_Layer) * Channels * (C_Taps - 1)
                   + 2 * KV * D * (C_Taps - 1);
               History : aliased Real_Array (0 .. H * (C_Taps - 1) - 1)
                 with Import, Address => Item.Conv_State (Conv_Base)'Address;
               Taps : constant T.Real_Array_Access := Cached (W (Inkling_Attention_Conv));
            begin
               if not Item.Host_Feed
                 and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
                 and then ((for all Role of Item.Arithmetic => not Role)
                   or else (Reference_Arithmetic and then Item.Seen = null
                     and then Source.Runtime_Pairs = null
                     and then Item.Arithmetic (W (Inkling_Attention_Gate).Role)
                     and then Item.Arithmetic (W (Inkling_Attention_Out).Role)))
               then
                  if Item.Seen /= null then
                     Tell (Item, W (Inkling_Attention_Gate), In_Q, Batch_Count);
                  end if;
                  Model_Runner.Backend.Device.Gate_And_Project
                    (W (Inkling_Attention_Gate), W (Inkling_Attention_Out), In_Q'Unrestricted_Access,
                     Attention_Rows'Unrestricted_Access, Gate_Rows'Unrestricted_Access, Acts'Unrestricted_Access,
                     (if Item.Seen = null then null else Attention_Rows'Unrestricted_Access),
                     Done, Status, Cancel, Positive (Batch_Count),
                     Conv_Taps => (if C_Taps in 3 .. 4 then Taps.all else []),
                     Conv_History => (if C_Taps in 3 .. 4 then History'Unrestricted_Access else null),
                     Raw_Output => (if C_Taps in 3 .. 4 then Mixtures'Unrestricted_Access else null),
                     Reference_Arithmetic => Reference_Arithmetic,
                     Residual => (if Reference_Arithmetic and then C_Taps in 3 .. 4
                                  and then Physical mod Settings.Inkling.Block_Size /= 0
                                  then Residual'Unrestricted_Access else null));
                  Check;
                  if Done then
                     Attention_Convolved := C_Taps in 3 .. 4;
                     Attention_Joined := Reference_Arithmetic and then Attention_Convolved
                       and then Physical mod Settings.Inkling.Block_Size /= 0;
                     if Attention_Convolved then Finite (Mixtures); end if;
                     Finite (Gate_Rows);
                     Finite (Acts);
                     if Item.Seen /= null then
                        Tell (Item, W (Inkling_Attention_Out), Attention_Rows, Batch_Count);
                     end if;
                     Charge (Item, Projecting, Mark);
                  end if;
               end if;
               if not Done then
                  Mat (W (Inkling_Attention_Gate), In_Q, Gate_Rows);
                  Observe ("attention_gate_logits", Gate_Rows);
                  if Reference_Arithmetic then
                     for Value of Gate_Rows loop Value := Reference_Sigmoid (Value); end loop;
                  else K.Sigmoid (Gate_Rows); end if;
                  K.Multiply (Attention_Rows, Gate_Rows);
                  Observe ("attention_gated_values", Attention_Rows);
                  Mat (W (Inkling_Attention_Out), Attention_Rows, Acts);
                  Observe ("attention_projected", Acts);
               end if;
            end;
            end if;
            if not Attention_Convolved then
            Convolve_Rows (Acts, W (Inkling_Attention_Conv), 2 * KV * D, Dynamic_K);
            end if;
            Observe ("attn_out", Acts);
            if Physical mod Settings.Inkling.Block_Size = 0 then
               for Token in 0 .. Batch_Count - 1 loop
                  declare
                     At_Block : constant Element_Count := Element_Count (Used_Blocks) * Wide + Token * H;
                  begin
                     Plain_Norm
                       (Residual (Token * H .. (Token + 1) * H - 1),
                        Blocks (At_Block .. At_Block + H - 1));
                  end;
               end loop;
               Used_Blocks := Used_Blocks + 1;
            elsif not Attention_Joined then
               K.Add (Acts, Residual);
            end if;
            Residual := Acts;
            Observe ("ffn_inp", Residual);
            Mix (Blocks, Used_Blocks, Residual, W (Inkling_Feed_Depth), Normals);
            if Core and then Step.Visit > 1 then
               Control (Normals, 3, W);
               Observe ("loop_control_ffn", Normals);
            end if;
            Norm (Normals, W (Inkling_Feed_Norm));
            --  Group by physical expert while preserving the session's
            --  activation rounding and deterministic routing contract.
            if Batch_Count > 1 and then Item.Seen = null
            then
               declare
                  Ok : Boolean;
               begin
                  Mixtures := Normals;
                  Mixture_Batch (Item, Current, Mixtures'Unrestricted_Access, Batch_Count, Ok, Status);
                  Check;
                  if not Ok then
                     Status := E.Make (E.Memory_Allocation_Failed);
                     raise Aborted;
                  end if;
               end;
            else
               for Token in 0 .. Batch_Count - 1 loop
                  Observing_Token := Token;
                  Mixture (Item, Current,
                           Normals (Token * H .. (Token + 1) * H - 1)'Unrestricted_Access,
                           Mixtures (Token * H .. (Token + 1) * H - 1)'Unrestricted_Access, Status,
                           (if Item.Seen = null then null else Observe_One'Unrestricted_Access));
                  Check;
               end loop;
            end if;
            Finite (Mixtures);
            Charge (Item, Feeding, Mark);
            if Shared_CPU then
               Convolve_Rows (Mixtures, W (Inkling_Feed_Conv), 2 * KV * D + H, Dynamic_K,
                              Joined => Acts'Unrestricted_Access);
            else
               Convolve_Rows (Mixtures, W (Inkling_Feed_Conv), 2 * KV * D + H, Dynamic_K);
               Acts := Residual;
               K.Add (Acts, Mixtures);
            end if;
            Observe ("ffn_out", Mixtures);
            Observe ("l_out", Acts);
         end;
      end loop;
      Mix (Blocks, Used_Blocks, Acts, Source.Inkling_Output_Query, Normals);
      if Batch_Count = 1 and then not Item.Host_Feed
        and then Model_Runner.Backend."=" (Source.Able.Kind, Model_Runner.Backend.Backend_Device)
        and then (for all Role of Item.Arithmetic => not Role)
      then
         Residual := Normals;
         Model_Runner.Backend.Device.Normalize_Output
           (Source.Output, Source.Output_Norm.all, Settings.Epsilon,
            Residual'Unrestricted_Access, Normals'Unrestricted_Access, Row,
            Output_Ready, Status, Cancel);
         Check;
         if Output_Ready then
            Finite (Normals); Finite (Row.all);
            if Item.Seen /= null then Tell (Item, Source.Output, Normals, 1); end if;
         end if;
      end if;
      if not Output_Ready then
      for Token in 0 .. Batch_Count - 1 loop
         Residual (Token * H .. (Token + 1) * H - 1) := Normals (Token * H .. (Token + 1) * H - 1);
         K.RMS_Norm (Residual (Token * H .. (Token + 1) * H - 1), Source.Output_Norm.all, Settings.Epsilon,
                     Normals (Token * H .. (Token + 1) * H - 1), K.Binary32_Stages);
      end loop;
      end if;
      Capture (S.Length (Order), Normals);
      Observe ("result_norm", Normals);
      if Item.Compact_Verify then
         if Item.Verify_Normals = null then T.Allocate (8 * H, Item.Verify_Normals); end if;
         if Item.Verify_Normals = null then Status := E.Make (E.Memory_Allocation_Failed); raise Aborted; end if;
         Item.Verify_Normals.all (0 .. Batch_Count * H - 1) := Normals (0 .. Batch_Count * H - 1);
         Fused_Output (Normals, Row.all, Batch_Count, Output_Finished);
         if not Output_Finished then
            for Token in 0 .. Batch_Count - 1 loop
               declare
                  Input : Real_Array renames Normals (Token * H .. (Token + 1) * H - 1);
                  Best : Real := Real'First;
                  Id : Token_Id := Model_Runner.Tokenizer.No_Token;
               begin
                  Product (Item, Source.Output, Input'Unrestricted_Access, Row, Status); Check;
                  Finish_Row (Row.all); Finite (Row.all);
                  for I in Row.all'Range loop
                     if Token_Id (I - Row.all'First) /= Item.Inkling_Greedy_Forbid
                       and then (Id = Model_Runner.Tokenizer.No_Token or else Row (I) > Best)
                     then Best := Row (I); Id := Token_Id (I - Row.all'First); end if;
                  end loop;
                  Item.Inkling_Greedy_Rows (Item.Inkling_Greedy_Rows.all'First + Natural (Token)) := Id;
               end;
            end loop;
         end if;
      elsif Every /= null or else Item.Seen /= null then
         if Item.Inkling_Head_Rows = null or else Item.Inkling_Head_Rows.all'Length < Batch_Count * Vocab then
            T.Free (Item.Inkling_Head_Rows);
            T.Allocate (Batch_Count * Vocab, Item.Inkling_Head_Rows);
         end if;
         Head_Rows := Item.Inkling_Head_Rows;
         if Head_Rows = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            raise Aborted;
         end if;
         if Output_Ready then
            Head_Rows.all (0 .. Vocab - 1) := Row.all;
         else
         Fused_Output (Normals, Head_Rows.all (0 .. Batch_Count * Vocab - 1), Batch_Count, Output_Finished);
         if not Output_Finished then
         Mat (Source.Output, Normals, Head_Rows.all (0 .. Batch_Count * Vocab - 1), Into => Reading_Out);
         end if;
         end if;
         if not Output_Finished then
         for Token in 0 .. Batch_Count - 1 loop
            Finish_Row (Head_Rows.all (Token * Vocab .. (Token + 1) * Vocab - 1));
         end loop;
         end if;
         Observe ("result_output", Head_Rows.all (0 .. Batch_Count * Vocab - 1));
         if Every /= null then
            Every.all (Every.all'First .. Every.all'First + Batch_Count * Vocab - 1) :=
              Head_Rows.all (0 .. Batch_Count * Vocab - 1);
         end if;
         Row.all := Head_Rows.all ((Batch_Count - 1) * Vocab .. Batch_Count * Vocab - 1);
      elsif Item.Inkling_Head_Selection /= null then
         declare
            Packed : Workers_CPU.Packed_Rows renames Item.Expert_Packed (0);
            Ready : Boolean := False;
            Done : Boolean;
         begin
         if Item.Arithmetic (Source.Output.Role) then
            Workers_CPU.Pack
              (Packed, Normals (Wide - H .. Wide - 1)'Unrestricted_Access, 1, H,
               Model_Runner.Quantization.Integers.Supers_Vectors (Source.Output.Format), Ready,
               Roles => [others => True], Reference_Arithmetic => True,
               Half_Scales => Source.Output.Format in Model_Runner.GGUF.Type_Q8_0 | Model_Runner.GGUF.Type_Q5_0
                | Model_Runner.GGUF.Type_IQ4_NL | Model_Runner.GGUF.Type_Q2_0);
         end if;
         Row.all := [others => Real'First];
         for Which of Item.Inkling_Head_Selection.all loop
            declare
               Weight : T.View := Source.Output;
               Stride : constant B.Byte_Count := T.Row_Bytes (Weight);
               Value : Real_Array (0 .. 0);
            begin
               Weight.Rows := 1;
               Weight.Offset := Weight.Offset + B.Byte_Count (Which) * Stride;
               Weight.Length := Stride; Weight.Scales := null;
               Done := False;
               if Ready then Workers_CPU.Multiply_Packed_Whole (Weight, Packed, Value, Done); end if;
               if not Done then Mat (Weight, Normals (Wide - H .. Wide - 1), Value, 1, Reading_Out); end if;
               if Source.Output_Bias /= null then
                  Value (0) := Value (0) + Source.Output_Bias (Element_Count (Which));
               end if;
               Finish_Logits (Source, Value, Reference_Arithmetic, Add_Bias => False);
               Row (Row'First + Element_Count (Which)) := Value (0);
            end;
         end loop;
         end;
      else
         if not Output_Ready then
         Fused_Output (Normals ((Batch_Count - 1) * H .. Wide - 1), Row.all, 1, Output_Finished);
         if not Output_Finished then
         Mat (Source.Output, Normals ((Batch_Count - 1) * H .. Wide - 1), Row.all, 1, Reading_Out);
         end if;
         end if;
         if not Output_Finished then Finish_Row (Row.all); end if;
      end if;
      Finite (Row.all);
      if States /= null then
         States.all (States.all'First .. States.all'First + Wide - 1) :=
           (if Normalized then Normals else Acts);
      end if;
      Item.Activation.all := Acts (Wide - H .. Wide - 1);
      Item.Inkling_Workspace.all (0 .. H - 1) := Item.Activation.all;
      Item.Inkling_Partial_Row := Item.Inkling_Head_Selection /= null;
      Item.Inkling_Last_Row_Valid := not Item.Inkling_Partial_Row;
      if Item.Inkling_Last_Row_Valid and then Row /= Item.Logit_Row then
         Item.Logit_Row.all := Row.all;
      end if;
      Item.Normalized.all := Normals (Wide - H .. Wide - 1);
      Charge (Item, Reading_Out, Mark);
   end;
   end if;
   --  Publish a checkpoint only after the complete evaluation succeeds.
   --  Failed/cancelled calls retain their rollback copy without admission.
   if Transaction and then Item.Inkling_Check_Valid and then Item.Inkling_Check_At > 0 then
      declare
         Index : constant Natural :=
           (if Item.Inkling_Prefix_Held and then Item.Inkling_Rewind_Next = 0
            then 1 else Item.Inkling_Rewind_Next);
         Spare_Conv : constant T.Real_Array_Access := Item.Inkling_Rewind_Convs (Index);
         Spare_Rows : constant T.Real_Array_Access := Item.Inkling_Rewinds (Index);
      begin
         Item.Inkling_Rewind_Convs (Index) := Item.Inkling_Conv_Backup;
         Item.Inkling_Rewinds (Index) := Item.Inkling_Check_Rows;
         Item.Inkling_Conv_Backup := Spare_Conv;
         Item.Inkling_Check_Rows := Spare_Rows;
         Item.Inkling_Check_Valid := False;
            Item.Inkling_Rewind_At (Index) := Item.Inkling_Check_At;
            Item.Inkling_Rewind_Next :=
              (if Item.Inkling_Prefix_Held and then Index = 3
               then 1 else (Index + 1) mod 4);
      end;
   end if;
   Release;
exception
   when Aborted =>
      if Backed_Up then
         Item.Conv_State.all := Item.Inkling_Conv_Backup.all;
         Item.Normalized.all := Previous_Normal;
         if Sequential_Device then
            Item.Committed := Reserved;
            Item.Activation.all := Item.Inkling_Check_Rows.all (0 .. H - 1);
            Item.Inkling_Workspace.all (0 .. H - 1) := Item.Activation.all;
            Item.Logit_Row.all := Item.Inkling_Check_Rows.all (2 * H .. 2 * H + Vocab - 1);
            Item.Inkling_Last_Row_Valid := Item.Inkling_Check_Valid;
         end if;
      end if;
      if not Sequential_Device then
         E.Add_Integer (Status, "physical_layer", Long_Long_Integer (Step.Physical_Layer));
         E.Add_Integer (Status, "logical_layer", Long_Long_Integer (Step.Logical_Layer));
      end if;
      Release;
   when Occurrence : others =>
      if Backed_Up then
         Item.Conv_State.all := Item.Inkling_Conv_Backup.all;
         Item.Normalized.all := Previous_Normal;
         if Sequential_Device then
            Item.Committed := Reserved;
            Item.Activation.all := Item.Inkling_Check_Rows.all (0 .. H - 1);
            Item.Inkling_Workspace.all (0 .. H - 1) := Item.Activation.all;
            Item.Logit_Row.all := Item.Inkling_Check_Rows.all (2 * H .. 2 * H + Vocab - 1);
            Item.Inkling_Last_Row_Valid := Item.Inkling_Check_Valid;
         end if;
      end if;
      Release;
      Item.Current := Failed;
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "llama.inkling.evaluate");
      E.Add_Text (Status, "exception", Ada.Exceptions.Exception_Name (Occurrence)
                  & ": " & Ada.Exceptions.Exception_Message (Occurrence));
end Inkling_Evaluate;
