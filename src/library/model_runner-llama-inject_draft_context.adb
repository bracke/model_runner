separate (Model_Runner.Llama)
procedure Inject_Draft_Context
  (Item : in out Session; Source : Model'Class;
   Tokens : Model_Runner.Tokenizer.Token_Array;
   Features : T.Real_Array_Access;
   Cancel : Model_Runner.Cancellation.Token_Reference := null;
   Status : out E.Error_Info)
is
   H : constant Element_Count := Element_Count (Source.Settings.Embedding);
   D : constant Element_Count := Element_Count (Source.Settings.Head_Size);
   KV : constant Element_Count := Element_Count (Source.Settings.KV_Heads) * D;
   Count : constant Element_Count := Element_Count (Tokens'Length);
   Start : constant Natural := Item.Committed;
   Was : constant C.Token_Reference := Item.Stopping;

   procedure Mix (Gains, Norm : T.Real_Array_Access) is
      Acc : Real;
   begin
      for Token in 0 .. Count - 1 loop
         for Channel in 0 .. H - 1 loop
            Acc := 0.0;
            for Tap in Element_Count range 0 .. 3 loop
               Acc := Draft_FMA (Gains (Gains'First + Tap),
                 Features (Features'First + Token * 4 * H + Tap * H + Channel), Acc);
            end loop;
            Item.Draft_Work (Token * H + Channel) := Acc;
         end loop;
         K.RMS_Norm_In_Place
           (Item.Draft_Work.all (Token * H .. (Token + 1) * H - 1), Norm.all, Source.Settings.Epsilon);
      end loop;
   end Mix;

   procedure Run is
   begin
      for Layer in 0 .. 2 loop
         if C.Is_Cancelled (Cancel) then Status := E.Make (E.Generation_Cancelled); return; end if;
         declare
            Context : DSpark_Layer renames Source.DSpark_Views.Contexts (Layer);
            K_At : constant Element_Count := Keys_At (Item, Layer) + Element_Count (Start) * KV;
            V_At : constant Element_Count := Values_At (Item, Layer) + Element_Count (Start) * KV;
            Mixed : constant T.Real_Array_Access := Item.Draft_Work.all (0 .. Count * H - 1)'Unrestricted_Access;
            Keys : constant T.Real_Array_Access := Item.Keys.all (K_At .. K_At + Count * KV - 1)'Unrestricted_Access;
            Values : constant T.Real_Array_Access :=
              Item.Values.all (V_At .. V_At + Count * KV - 1)'Unrestricted_Access;
         begin
            Mix (Context.Mix, Context.Norm);
            Product_Group (Item, [Context.Key, Context.Value], Mixed, [Keys, Values], Status, Count => Count);
            if E.Is_Error (Status) then return; end if;
            for Token in 0 .. Count - 1 loop
               for Head in 0 .. Element_Count (Source.Settings.KV_Heads) - 1 loop
                  declare
                     At_Head : constant Element_Count := K_At + Token * KV + Head * D;
                  begin
                     K.RMS_Norm_In_Place
                       (Item.Keys.all (At_Head .. At_Head + D - 1), Context.Key_Norm.all, Source.Settings.Epsilon);
                  end;
               end loop;
               declare
                  At_Key : constant Element_Count := K_At + Token * KV;
               begin
                  Draft_Rotate
                    (Item.Keys.all (At_Key .. At_Key + KV - 1), Element_Count (Source.Settings.KV_Heads),
                     D, Start + Natural (Token), Source.Settings.Rope_Base);
               end;
            end loop;
            if Item.Seen /= null then
               Note_State (Item.Seen.all, "kcur_injected", Layer, Layer, 1, Start, Keys.all);
               Note_State (Item.Seen.all, "vcur_injected", Layer, Layer, 1, Start, Values.all);
            end if;
            for Value of Keys.all loop
               if not N.Is_Finite (Value) then Status := E.Make (E.Tensor_Non_Finite_Value); return; end if;
            end loop;
            for Value of Values.all loop
               if not N.Is_Finite (Value) then Status := E.Make (E.Tensor_Non_Finite_Value); return; end if;
            end loop;
         end;
      end loop;
      Mix (Source.DSpark_Views.Context_Mix, Source.DSpark_Views.Context_Norm);
      if C.Is_Cancelled (Cancel) then Status := E.Make (E.Generation_Cancelled); return; end if;
      for Value of Item.Draft_Work.all (0 .. Count * H - 1) loop
         if not N.Is_Finite (Value) then Status := E.Make (E.Tensor_Non_Finite_Value); return; end if;
      end loop;
      if Item.Seen /= null then
         Note_State (Item.Seen.all, "context", 0, 0, 1, Start, Item.Draft_Work.all (0 .. Count * H - 1));
      end if;
      Item.Draft_Context.all (Element_Count (Start) * H .. (Element_Count (Start) + Count) * H - 1) :=
        Item.Draft_Work.all (0 .. Count * H - 1);
      for Token in 0 .. Natural (Count) - 1 loop
         Item.History (Start + Token) := Tokens (Tokens'First + Token);
      end loop;
      Item.Committed := Start + Natural (Count);
   end Run;
begin
   Status := E.Success;
   if not Source.Ready or else Source.Settings.Kind /= DFlash or else Item.Owner = null
     or else Item.Owner.all'Address /= Source'Address or else Item.Current in Closed | Failed
     or else Item.Draft_Work = null or else Item.Held /= Exact
   then
      Status := E.Make (E.Lifecycle_Invalid_State); return;
   end if;
   if Count = 0 or else Count > 512 or else Features = null
     or else Features'Length < Count * 4 * H
   then Status := E.Make (E.Tensor_Shape_Mismatch); return; end if;
   if Natural (Count) > Item.Context - Item.Committed then
      Status := E.Make (E.Generation_Context_Exhausted); return;
   end if;
   for Token of Tokens loop
      if not Model_Runner.Tokenizer.Is_Valid (Source.Words, Token) then
         Status := E.Make (E.Tokenizer_Invalid_Token_Id); return;
      end if;
   end loop;
   for Value of Features.all (Features'First .. Features'First + Count * 4 * H - 1) loop
      if not N.Is_Finite (Value) then Status := E.Make (E.Tensor_Non_Finite_Value); return; end if;
   end loop;
   Item.Stopping := Cancel;
   Run;
   Item.Stopping := Was;
exception
   when others =>
      Item.Stopping := Was;
      Item.Committed := Start;
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "llama.inject_draft_context");
end Inject_Draft_Context;
