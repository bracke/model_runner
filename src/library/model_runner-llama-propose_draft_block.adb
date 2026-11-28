separate (Model_Runner.Llama)
procedure Propose_Draft_Block
  (Item : in out Session; Source : Model'Class;
   Anchor : Model_Runner.Tokenizer.Token_Id;
   Tokens : out Model_Runner.Tokenizer.Token_Array;
   Every : T.Real_Array_Access := null;
   Cancel : Model_Runner.Cancellation.Token_Reference := null;
   Status : out E.Error_Info)
is
   H : constant Element_Count := Element_Count (Source.Settings.Embedding);
   D : constant Element_Count := Element_Count (Source.Settings.Head_Size);
   Q : constant Element_Count := Element_Count (Source.Settings.Heads) * D;
   KV : constant Element_Count := Element_Count (Source.Settings.KV_Heads) * D;
   F : constant Element_Count := Element_Count (Source.Settings.Feed_Forward);
   V : constant Element_Count := Element_Count (Source.Settings.Vocabulary);
   R : constant Element_Count := Element_Count (Source.Settings.DSpark.Markov_Rank);
   Count : constant Element_Count := Element_Count (Tokens'Length + 1);
   Start : constant Natural := Item.Committed;
   Was : constant C.Token_Reference := Item.Stopping;

   procedure Run is
      --  Each slice descriptor lives for the whole block. Returning an
      --  unrestricted access to a function-local slice would leave its
      --  fat pointer referring to bounds whose lifetime already ended.
      X_Offset : constant Element_Count := 512 * H;
      X_Storage : Real_Array renames
        Item.Draft_Work.all (X_Offset .. X_Offset + 8 * H - 1);
      X : constant T.Real_Array_Access := X_Storage'Unrestricted_Access;
      Norm_Offset : constant Element_Count := X_Offset + 8 * H;
      Norm_Storage : Real_Array renames
        Item.Draft_Work.all (Norm_Offset .. Norm_Offset + 8 * H - 1);
      Norm : constant T.Real_Array_Access := Norm_Storage'Unrestricted_Access;
      Queries_Offset : constant Element_Count := Norm_Offset + 8 * H;
      Queries_Storage : Real_Array renames
        Item.Draft_Work.all (Queries_Offset .. Queries_Offset + 8 * Q - 1);
      Queries : constant T.Real_Array_Access := Queries_Storage'Unrestricted_Access;
      Keys_Offset : constant Element_Count := Queries_Offset + 8 * Q;
      Keys_Storage : Real_Array renames
        Item.Draft_Work.all (Keys_Offset .. Keys_Offset + 8 * KV - 1);
      Keys : constant T.Real_Array_Access := Keys_Storage'Unrestricted_Access;
      Values_Offset : constant Element_Count := Keys_Offset + 8 * KV;
      Values_Storage : Real_Array renames
        Item.Draft_Work.all (Values_Offset .. Values_Offset + 8 * KV - 1);
      Values : constant T.Real_Array_Access := Values_Storage'Unrestricted_Access;
      Attention_Offset : constant Element_Count := Values_Offset + 8 * KV;
      Attention_Storage : Real_Array renames
        Item.Draft_Work.all (Attention_Offset .. Attention_Offset + 8 * Q - 1);
      Attention : constant T.Real_Array_Access := Attention_Storage'Unrestricted_Access;
      Gates_Offset : constant Element_Count := Attention_Offset + 8 * Q;
      Gates_Storage : Real_Array renames
        Item.Draft_Work.all (Gates_Offset .. Gates_Offset + 8 * F - 1);
      Gates : constant T.Real_Array_Access := Gates_Storage'Unrestricted_Access;
      Ups_Offset : constant Element_Count := Gates_Offset + 8 * F;
      Ups_Storage : Real_Array renames
        Item.Draft_Work.all (Ups_Offset .. Ups_Offset + 8 * F - 1);
      Ups : constant T.Real_Array_Access := Ups_Storage'Unrestricted_Access;
      Down_Offset : constant Element_Count := Ups_Offset + 8 * F;
      Down_Storage : Real_Array renames
        Item.Draft_Work.all (Down_Offset .. Down_Offset + 8 * H - 1);
      Down : constant T.Real_Array_Access := Down_Storage'Unrestricted_Access;
      Raw_Offset : constant Element_Count := Down_Offset + 8 * H;
      Raw_Storage : Real_Array renames
        Item.Draft_Work.all (Raw_Offset .. Raw_Offset + 8 * V - 1);
      Raw : constant T.Real_Array_Access := Raw_Storage'Unrestricted_Access;
      Bias_Offset : constant Element_Count := Raw_Offset + 8 * V;
      Bias_Storage : Real_Array renames
        Item.Draft_Work.all (Bias_Offset .. Bias_Offset + V - 1);
      Bias : constant T.Real_Array_Access := Bias_Storage'Unrestricted_Access;
      Joint_Input_Offset : constant Element_Count := Bias_Offset + V;
      Joint_Input_Storage : Real_Array renames
        Item.Draft_Work.all (Joint_Input_Offset .. Joint_Input_Offset + 2 * H + 2 * R - 1);
      Joint_Input : constant T.Real_Array_Access := Joint_Input_Storage'Unrestricted_Access;
      Joint_Offset : constant Element_Count := Joint_Input_Offset + 2 * H + 2 * R;
      Joint_Storage : Real_Array renames
        Item.Draft_Work.all (Joint_Offset .. Joint_Offset + 3 * R - 1);
      Joint : constant T.Real_Array_Access := Joint_Storage'Unrestricted_Access;
      State_Offset : constant Element_Count := Joint_Offset + 3 * R;
      State_Storage : Real_Array renames
        Item.Draft_Work.all (State_Offset .. State_Offset + R - 1);
      State : constant T.Real_Array_Access := State_Storage'Unrestricted_Access;
      Markov_Offset : constant Element_Count := State_Offset + R;
      Markov_Storage : Real_Array renames
        Item.Draft_Work.all (Markov_Offset .. Markov_Offset + R - 1);
      Markov : constant T.Real_Array_Access := Markov_Storage'Unrestricted_Access;
      Previous_Offset : constant Element_Count := Markov_Offset + R;
      Previous_Storage : Real_Array renames
        Item.Draft_Work.all (Previous_Offset .. Previous_Offset + R - 1);
      Previous : constant T.Real_Array_Access := Previous_Storage'Unrestricted_Access;
      Scores_Offset : constant Element_Count := Previous_Offset + R;
      Head_Scratch : constant Element_Count := Element_Count (Item.Context) + 8 + 64 * D;
      Head_Group : constant Element_Count := Element_Count'Min (4, Element_Count (Source.Settings.Group_Size));
      Attention_Scratch : constant Element_Count := Head_Group * Head_Scratch;
      Rotation_Offset : constant Element_Count := Scores_Offset + 8 * Attention_Scratch;
      Last : Token_Id := Anchor;
      Scale : constant Real := Real (1.0 / N.Sqrt (Wide_Real (D)));

      procedure Norm_Rows (Input : T.Real_Array_Access; Weight : T.Real_Array_Access;
                           Width : Element_Count; Into : T.Real_Array_Access) is
      begin
         for Token in 0 .. Count - 1 loop
            K.RMS_Norm
              (Input.all (Input'First + Token * Width .. Input'First + (Token + 1) * Width - 1),
               Weight.all, Source.Settings.Epsilon,
               Into.all (Into'First + Token * Width .. Into'First + (Token + 1) * Width - 1),
               Arithmetic => K.Binary32_Stages);
         end loop;
      end Norm_Rows;

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

      procedure Brain_Round (Values : in out Real_Array) is
         use type Interfaces.Unsigned_32;
      begin
         for Value of Values loop
            declare
               Bits : constant Interfaces.Unsigned_32 := N.Bits (Value);
               Rounded : constant Interfaces.Unsigned_32 :=
                 (Bits + 16#7FFF# + (Interfaces.Shift_Right (Bits, 16) and 1)) and 16#FFFF_0000#;
            begin
               Value := N.From_Bits (Rounded);
            end;
         end loop;
      end Brain_Round;

      procedure Correct (Slot : Element_Count) is
         Weight : T.View renames Source.DSpark_Views.Markov_W2;
         --  Keep watcher inputs and adapter application on their ordinary path.
         Fused : constant Boolean := Item.Seen = null and then Source.Runtime_Pairs = null;
         Tile_Rows : constant Element_Count := 512;
         Local_Output : constant Boolean := Fused and then Every = null;
         protected Best_Of is
            procedure Consider (Value : Real; Id : Token_Id);
            function Choice return Token_Id;
         private
            Value : Real := Real'First;
            Id : Token_Id := Model_Runner.Tokenizer.No_Token;
         end Best_Of;
         protected body Best_Of is
            procedure Consider (Value : Real; Id : Token_Id) is
            begin
               if Id /= Model_Runner.Tokenizer.No_Token
                 and then (Best_Of.Id = Model_Runner.Tokenizer.No_Token or else Value > Best_Of.Value
                   or else (Value = Best_Of.Value and then Id < Best_Of.Id))
               then Best_Of.Value := Value; Best_Of.Id := Id; end if;
            end Consider;
            function Choice return Token_Id is (Id);
         end Best_Of;
         type Output_Share is limited new Workers_CPU.Task_Item with record
            Valid : Boolean := True with Atomic;
         end record;
         overriding procedure Run (Work : in out Output_Share; From, To : Element_Count);
         overriding procedure Run (Work : in out Output_Share; From, To : Element_Count) is
            First : Element_Count := From;
            Best : Real := Real'First;
            Id : Token_Id := Model_Runner.Tokenizer.No_Token;
            Handled : Boolean;
            Local_Values : Real_Array (0 .. Tile_Rows - 1);
            Slice : T.View;
         begin
            while First <= To loop
               if C.Is_Cancelled (Cancel) then return; end if;
               declare
                  Stop : constant Element_Count := First + Element_Count'Min (Tile_Rows - 1, To - First);
               begin
                  if Local_Output then
                     Slice := Weight; Slice.Rows := Stop - First + 1; Slice.Scales := null;
                     Slice.Offset := Weight.Offset + B.Byte_Count (First) * T.Row_Bytes (Weight);
                     Slice.Length := B.Byte_Count (Slice.Rows) * T.Row_Bytes (Weight);
                     Handled := False;
                     if Item.Arithmetic (Weight.Role) then
                        T.Mat_Mul_Range_Float
                          (Slice, Markov.all, 1, Local_Values, 0, Slice.Rows - 1, Handled);
                     end if;
                     if not Handled then
                        T.Mat_Mul_Range (Slice, Markov.all, 1, Local_Values, 0, Slice.Rows - 1);
                     end if;
                  elsif Fused then
                     --  Exactly the floating/fallback choice made by CPU.Take_Share.
                     Handled := False;
                     if Item.Arithmetic (Weight.Role) then
                        T.Mat_Mul_Range_Float (Weight, Markov.all, 1, Bias.all, First, Stop, Handled);
                     end if;
                     if not Handled then
                        T.Mat_Mul_Range (Weight, Markov.all, 1, Bias.all, First, Stop);
                     end if;
                  end if;
                  for Row in First .. Stop loop
                     declare
                        Value : Real := (if Local_Output then Local_Values (Row - First) else Bias (Bias'First + Row))
                          + Source.DSpark_Views.Markov_Bias (Source.DSpark_Views.Markov_Bias'First + Row)
                          + Raw (Raw'First + Slot * V + Row);
                     begin
                        Value := Reference_Tanh (Value * (1.0 / Source.Settings.Logit_Cap))
                          * Source.Settings.Logit_Cap;
                        if not Local_Output then Bias (Bias'First + Row) := Value; end if;
                        if not N.Is_Finite (Value) then Work.Valid := False; return; end if;
                        if Id = Model_Runner.Tokenizer.No_Token or else Value > Best then
                           Best := Value; Id := Token_Id (Row);
                        end if;
                     end;
                  end loop;
                  exit when Stop = To;
                  First := Stop + 1;
               end;
            end loop;
            Best_Of.Consider (Best, Id);
         end Run;
         Work : aliased Output_Share;
      begin
         if not Fused then
            Product (Item, Weight, Markov, Bias, Status);
            if E.Is_Error (Status) then return; end if;
         end if;
         Workers_CPU.Dispatch_Shares
           (Item.Team, V, Work'Unchecked_Access, Status, Cost => V * (R + 32),
            Team_Size => Workers_CPU.Max_Workers + 1);
         if E.Is_Error (Status) then return; end if;
         if C.Is_Cancelled (Cancel) then Status := E.Make (E.Generation_Cancelled); return; end if;
         if not Work.Valid then Status := E.Make (E.Tensor_Non_Finite_Value); return; end if;
         Last := Best_Of.Choice;
      end Correct;

      procedure Attend (Layer : Natural) is
         First : constant Natural :=
           (if Slides (Source.Settings, Layer) and then Start >= Source.Settings.Window
            then Start - Source.Settings.Window + 1 else 0);
         Prefix : constant Element_Count := Element_Count (Start - First);
         K_Base : constant Element_Count := Keys_At (Item, Layer);
         V_Base : constant Element_Count := Values_At (Item, Layer);
         procedure One_Group (Token, KV_Head, Scratch : Element_Count; Error : out E.Error_Info) is
            Grouped : constant Boolean := Workers_CPU.Byte_Products and then D mod 64 = 0 and then Head_Group > 1;
            Score_Base : constant Element_Count := Scores_Offset + Scratch * Attention_Scratch;
            function Scores_At (Member : Element_Count) return Element_Count is
              (Score_Base + Member * Head_Scratch);
            function Lanes_At (Member : Element_Count) return Element_Count is
              (Scores_At (Member) + Element_Count (Item.Context) + 8);
            Dots, Gains : Real_Array (0 .. 3);
            Ok : Boolean;
         begin
            Error := E.Success;
               declare
                  First_Head : Element_Count := KV_Head * Element_Count (Source.Settings.Group_Size);
                  Remaining : Element_Count := Element_Count (Source.Settings.Group_Size);
               begin
                  while Remaining > 0 loop
                     if C.Is_Cancelled (Cancel) then Error := E.Make (E.Generation_Cancelled); return; end if;
                     declare
                        Taken : constant Element_Count := (if Grouped then Element_Count'Min (4, Remaining) else 1);
                        Q_At : constant Element_Count := Queries'First + Token * Q + First_Head * D;
                        procedure Score_Key (Key : Real_Array; Position : Element_Count) is
                        begin
                           if Grouped then
                              Draft_Dots (Queries.all (Q_At .. Q_At + Taken * D - 1), Key, D, Taken, Dots);
                           else
                              Dots (0) := Reference_Dot (Queries.all (Q_At .. Q_At + D - 1), Key);
                           end if;
                           for Member in 0 .. Taken - 1 loop
                              Item.Draft_Work (Scores_At (Member) + Position) := Scale * Dots (Member);
                           end loop;
                        end Score_Key;
                        procedure Add_Row (Value : Real_Array; Position, Lane : Element_Count) is
                        begin
                           for Member in 0 .. Taken - 1 loop
                              Gains (Member) := Item.Draft_Work (Scores_At (Member) + Position);
                           end loop;
                           if Workers_CPU.Wide_Vectors and then D mod 8 = 0 then
                              Draft_Values (Value, Gains,
                                Item.Draft_Work.all (Lanes_At (0) + Lane
                                  .. Lanes_At (Taken - 1) + Lane + D - 1), Head_Scratch, Taken);
                           else
                              for Member in 0 .. Taken - 1 loop
                                 for Channel in 0 .. D - 1 loop
                                    declare
                                       At_Value : constant Element_Count := Lanes_At (Member) + Lane + Channel;
                                    begin
                                       Item.Draft_Work (At_Value) := Draft_FMA
                                         (Value (Value'First + Channel), Gains (Member), Item.Draft_Work (At_Value));
                                    end;
                                 end loop;
                              end loop;
                           end if;
                        end Add_Row;
                     begin
                        for Position in First .. Start - 1 loop
                           declare
                              At_Key : constant Element_Count := K_Base + Element_Count (Position) * KV + KV_Head * D;
                           begin
                              Score_Key (Item.Keys.all (At_Key .. At_Key + D - 1), Element_Count (Position - First));
                           end;
                        end loop;
                        for Slot in 0 .. Count - 1 loop
                           declare
                              At_Key : constant Element_Count := Keys'First + Slot * KV + KV_Head * D;
                           begin
                              Score_Key (Keys.all (At_Key .. At_Key + D - 1), Prefix + Slot);
                           end;
                        end loop;
                        for Member in 0 .. Taken - 1 loop
                           declare
                              S : Real_Array renames Item.Draft_Work.all
                                (Scores_At (Member) .. Scores_At (Member) + Prefix + Count - 1);
                           begin
                              declare
                                 Maximum : Real := Real'First;
                                 Total : Wide_Real := 0.0;
                                 Group : Real_Array (0 .. 15) := [others => 0.0];
                              begin
                                 for Value of S loop Maximum := Real'Max (Maximum, Value); end loop;
                                 Draft_Exp (S, Maximum);
                                 for I in 0 .. S'Length - 1 loop
                                    Group (Element_Count (I mod 16)) := S (S'First + Element_Count (I));
                                    if I mod 16 = 15 then
                                       Total := Total + Wide_Real (Reference_Sum_Sixteen (Group));
                                       Group := [others => 0.0];
                                    end if;
                                 end loop;
                                 if S'Length mod 16 /= 0 then
                                    Total := Total + Wide_Real (Reference_Sum_Sixteen (Group));
                                 end if;
                                 Ok := N.Is_Finite (Total) and then Total > 0.0;
                                 if not Ok then Error := E.Make (E.Tensor_Non_Finite_Value); return; end if;
                                 declare
                                    Inverse : constant Real := Real (1.0 / Total);
                                 begin
                                    for Value of S loop Value := Value * Inverse; end loop;
                                 end;
                              end;

                           end;
                           Item.Draft_Work.all (Lanes_At (Member) .. Lanes_At (Member) + 64 * D - 1) := [others => 0.0];
                        end loop;
                        for Position in First .. Start - 1 loop
                           declare
                              At_Value : constant Element_Count := V_Base + Element_Count (Position) * KV + KV_Head * D;
                           begin
                              Add_Row (Item.Values.all (At_Value .. At_Value + D - 1),
                                       Element_Count (Position - First), (Element_Count (Position) mod 64) * D);
                           end;
                        end loop;
                        for Slot in 0 .. Count - 1 loop
                           declare
                              At_Value : constant Element_Count := Values'First + Slot * KV + KV_Head * D;
                           begin
                              Add_Row (Values.all (At_Value .. At_Value + D - 1), Prefix + Slot,
                                       ((Element_Count (Start) + Slot) mod 64) * D);
                           end;
                        end loop;
                        for Member in 0 .. Taken - 1 loop
                           declare
                              Lanes : Real_Array renames Item.Draft_Work.all
                                (Lanes_At (Member) .. Lanes_At (Member) + 64 * D - 1);
                              Out_At : constant Element_Count :=
                                Attention'First + Token * Q + (First_Head + Member) * D;
                           begin
                              for I in 0 .. 16 * D - 1 loop
                                 Lanes (Lanes'First + I) :=
                                   (Lanes (Lanes'First + I) + Lanes (Lanes'First + I + 32 * D))
                                   + (Lanes (Lanes'First + I + 16 * D) + Lanes (Lanes'First + I + 48 * D));
                              end loop;
                              for I in 0 .. 8 * D - 1 loop
                                 Lanes (Lanes'First + I) := Lanes (Lanes'First + I + 8 * D) + Lanes (Lanes'First + I);
                              end loop;
                              for I in 0 .. 4 * D - 1 loop
                                 Lanes (Lanes'First + I) := Lanes (Lanes'First + I + 4 * D) + Lanes (Lanes'First + I);
                              end loop;
                              for Channel in 0 .. D - 1 loop
                                 Attention (Out_At + Channel) :=
                                   (Lanes (Lanes'First + Channel + 2 * D) + Lanes (Lanes'First + Channel))
                                   + (Lanes (Lanes'First + Channel + 3 * D) + Lanes (Lanes'First + Channel + D));
                              end loop;

                           end;
                        end loop;
                        First_Head := First_Head + Taken; Remaining := Remaining - Taken;
                     end;
                  end loop;
               end;
         end One_Group;

         --  Jobs own disjoint query-head outputs. Each worker reuses one
         --  bounded score/fold slot, including when it handles several KV groups.
         type Token_Share is limited new Workers_CPU.Task_Item with record
            Scratch_Next : aliased Take_Counter := 0;
         end record;
         overriding procedure Run (Share : in out Token_Share; From, To : Element_Count);
         Groups : constant Element_Count := Element_Count (Source.Settings.KV_Heads);
         Errors : array (0 .. Count * Groups - 1) of E.Error_Info := [others => E.Success];
         overriding procedure Run (Share : in out Token_Share; From, To : Element_Count) is
            Scratch : constant Element_Count := Element_Count (Takes.Atomic_Fetch_And_Add (Share.Scratch_Next, 1));
         begin
            pragma Assert (Scratch < 8);
            for Job in From .. To loop
               One_Group (Job / Groups, Job mod Groups, Scratch, Errors (Job));
            end loop;
         end Run;
         Share : aliased Token_Share;
      begin
         Workers_CPU.Dispatch_Shares
           (Item.Team, Count * Groups, Share'Unchecked_Access, Status,
            Cost => 4 * Count * Element_Count (Source.Settings.Heads) * D * (Prefix + Count), Team_Size => 8);
         if E.Is_Error (Status) then return; end if;
         for Job in Errors'Range loop
            if E.Is_Error (Errors (Job)) then Status := Errors (Job); return; end if;
         end loop;
      end Attend;
   begin
      State.all := [others => 0.0];
      T.Dequantize_Row (Source.Embeddings, Element_Count (Anchor), X.all (X'First .. X'First + H - 1), Status);
      if E.Is_Error (Status) then return; end if;
      K.RMS_Norm_In_Place (X.all (X'First .. X'First + H - 1), Source.Embedding_Norm.all, Source.Settings.Epsilon);
      for Slot in 1 .. Count - 1 loop
         T.Dequantize_Row
           (Source.DSpark_Views.Mask, Slot - 1,
            X.all (X'First + Slot * H .. X'First + (Slot + 1) * H - 1), Status);
         if E.Is_Error (Status) then return; end if;
      end loop;
      for Token in 0 .. Count - 1 loop
         Draft_Rotation (D, Start + Natural (Token), Source.Settings.Rope_Base,
                         Item.Draft_Work.all (Rotation_Offset + Token * D .. Rotation_Offset + (Token + 1) * D - 1));
      end loop;
      for Index in 0 .. 2 loop
         if C.Is_Cancelled (Cancel) then Status := E.Make (E.Generation_Cancelled); return; end if;
         declare
            Layer : Model_Runner.Llama.Layer renames Source.Layers (Index);
         begin
            Norm_Rows (X, Layer.Attention_Norm, H, Norm);
            Product_Group
              (Item, [Layer.Query, Layer.Key, Layer.Value], Norm, [Queries, Keys, Values], Status, Count => Count);
            if E.Is_Error (Status) then return; end if;
            for Token in 0 .. Count - 1 loop
               for Head in 0 .. Element_Count (Source.Settings.Heads) - 1 loop
                  declare
                     At_Head : constant Element_Count := Queries'First + Token * Q + Head * D;
                  begin
                     K.RMS_Norm_In_Place
                       (Queries.all (At_Head .. At_Head + D - 1), Layer.Query_Head_Norm.all, Source.Settings.Epsilon);
                  end;
               end loop;
               for Head in 0 .. Element_Count (Source.Settings.KV_Heads) - 1 loop
                  declare
                     At_Head : constant Element_Count := Keys'First + Token * KV + Head * D;
                  begin
                     K.RMS_Norm_In_Place
                       (Keys.all (At_Head .. At_Head + D - 1), Layer.Key_Head_Norm.all, Source.Settings.Epsilon);
                  end;
               end loop;
               Draft_Apply_Rotation
                 (Queries.all (Queries'First + Token * Q .. Queries'First + (Token + 1) * Q - 1),
                  Element_Count (Source.Settings.Heads), D,
                  Item.Draft_Work.all (Rotation_Offset + Token * D .. Rotation_Offset + (Token + 1) * D - 1));
               Draft_Apply_Rotation
                 (Keys.all (Keys'First + Token * KV .. Keys'First + (Token + 1) * KV - 1),
                  Element_Count (Source.Settings.KV_Heads), D,
                  Item.Draft_Work.all (Rotation_Offset + Token * D .. Rotation_Offset + (Token + 1) * D - 1));
            end loop;
            Attend (Index);
            if E.Is_Error (Status) then return; end if;
            Draft_Product_Add (Item, Layer.Attention_Out, Attention, Count, X, Down, Status);
            if E.Is_Error (Status) then return; end if;
            Norm_Rows (X, Layer.Feed_Norm, H, Norm);
            Product_Group (Item, [Layer.Gate, Layer.Up], Norm, [Gates, Ups], Status, Count => Count);
            if E.Is_Error (Status) then return; end if;
            Draft_Activate (Gates.all (Gates'First .. Gates'First + Count * F - 1),
                            Ups.all (Ups'First .. Ups'First + Count * F - 1));
            Draft_Product_Add (Item, Layer.Down, Gates, Count, X, Down, Status);
            if E.Is_Error (Status) then return; end if;
         end;
      end loop;
      Norm_Rows (X, Source.Output_Norm, H, Norm);
      if Item.Seen /= null then
         Note_State (Item.Seen.all, "hidden", 0, 0, 1, Start, Norm.all (Norm'First .. Norm'First + Count * H - 1));
      end if;
      Draft_Project_Proposals (Item, Source.Output, Norm, Count, Raw, Status);
      if E.Is_Error (Status) then return; end if;
      if Item.Seen /= null then
         Note_State (Item.Seen.all, "raw", 0, 0, 1, Start, Raw.all (Raw'First .. Raw'First + Count * V - 1));
      end if;
      for Slot in 1 .. Count - 1 loop
         if C.Is_Cancelled (Cancel) then Status := E.Make (E.Generation_Cancelled); return; end if;
         T.Dequantize_Row (Source.DSpark_Views.Markov_W1, Element_Count (Last), Previous.all, Status);
         if E.Is_Error (Status) then return; end if;
         Joint_Input.all (Joint_Input'First .. Joint_Input'First + R - 1) := State.all;
         Joint_Input.all (Joint_Input'First + R .. Joint_Input'First + 2 * R - 1) := Previous.all;
         Joint_Input.all (Joint_Input'First + 2 * R .. Joint_Input'First + 2 * R + H - 1) :=
           Norm.all (Norm'First + Slot * H .. Norm'First + (Slot + 1) * H - 1);
         Joint_Input.all (Joint_Input'First + 2 * R + H .. Joint_Input'Last) :=
           Item.Draft_Context.all (Element_Count (Start - 1) * H .. Element_Count (Start) * H - 1);
         Brain_Round (Joint_Input.all);
         Product (Item, Source.DSpark_Views.Joint, Joint_Input, Joint, Status);
         if E.Is_Error (Status) then return; end if;
         for Channel in 0 .. 3 * R - 1 loop
            Joint (Joint'First + Channel) := Joint (Joint'First + Channel)
              + Source.DSpark_Views.Joint_Bias (Source.DSpark_Views.Joint_Bias'First + Channel);
         end loop;
         for Channel in 0 .. R - 1 loop
            Joint (Joint'First + Channel) := Reference_Sigmoid (Joint (Joint'First + Channel));
         end loop;
         for Channel in 0 .. R - 1 loop
            declare
               Candidate : constant Real := Reference_Tanh (Joint (Joint'First + R + Channel));
            begin
               State (State'First + Channel) := Candidate + Joint (Joint'First + Channel)
                 * (State (State'First + Channel) - Candidate);
               Markov (Markov'First + Channel) :=
                 Reference_Tanh (Joint (Joint'First + 2 * R + Channel));
            end;
         end loop;
         Brain_Round (Markov.all);
         Correct (Slot);
         if E.Is_Error (Status) then return; end if;
         Tokens (Tokens'First + Natural (Slot) - 1) := Last;
         if Every /= null then
            Every.all (Every'First + (Slot - 1) * V .. Every'First + Slot * V - 1) := Bias.all;
         end if;
      end loop;
   end Run;
begin
   Tokens := [others => Model_Runner.Tokenizer.No_Token];
   Status := E.Success;
   if not Source.Ready or else Source.Settings.Kind /= DFlash or else Item.Owner = null
     or else Item.Owner.all'Address /= Source'Address or else Item.Current in Closed | Failed
     or else Item.Draft_Work = null or else Item.Held /= Exact or else Start = 0
   then Status := E.Make (E.Lifecycle_Invalid_State); return; end if;
   if Tokens'Length not in 1 .. 7
     or else (Every /= null and then Every'Length < (Count - 1) * V)
   then Status := E.Make (E.Tensor_Shape_Mismatch); return; end if;
   if not Model_Runner.Tokenizer.Is_Valid (Source.Words, Anchor) then
      Status := E.Make (E.Tokenizer_Invalid_Token_Id); return;
   end if;
   if Natural (Count) > Item.Context - Start then
      Status := E.Make (E.Generation_Context_Exhausted); return;
   end if;
   Item.Stopping := Cancel;
   Run;
   Item.Stopping := Was;
   if E.Is_Error (Status) then Tokens := [others => Model_Runner.Tokenizer.No_Token]; end if;
exception
   when others =>
      Item.Stopping := Was;
      Tokens := [others => Model_Runner.Tokenizer.No_Token];
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "llama.propose_draft_block");
end Propose_Draft_Block;
