separate (Model_Runner.Llama)
procedure Apply_Adapters
  (Item : Session; Weight : T.View; Input : Real_Array; Into : in out Real_Array;
   Status : out E.Error_Info)
is
   pragma Suppress (Validity_Check);
   use type Model_Runner.GGUF.Tensor_Type;
   Started : Boolean := False;
begin
   Status := E.Success;
   if C.Is_Cancelled (Item.Stopping) then
      Status := E.Make (E.Generation_Cancelled);
      return;
   end if;
   for Pair of Item.Owner.Runtime_Pairs.all loop
      if Pair.Target.Base = Weight.Base and then Pair.Target.Offset = Weight.Offset
        and then Pair.Target.Rows = Weight.Rows and then Pair.Target.Columns = Weight.Columns
        and then Pair.Target.Format = Weight.Format and then Pair.Factor /= 0.0
      then
         if Item.Adapter_Rank = null or else Item.Adapter_Output = null
           or else Item.Adapter_Rank'Length < Pair.Rank or else Item.Adapter_Output'Length < Weight.Rows
           or else Input'Length /= Weight.Columns or else Into'Length /= Weight.Rows
         then
            Status := E.Make (E.Internal_Invariant_Violated);
            return;
         end if;
         if not Started then
            for Value of Input loop
               if not N.Is_Finite (Value) then
                  Status := E.Make (E.Tensor_Non_Finite_Value);
                  return;
               end if;
            end loop;
            Item.Adapter_Output.all (0 .. Weight.Rows - 1) := Into;
            Started := True;
         end if;
         if C.Is_Cancelled (Item.Stopping) then
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;
         for Rank_Row in 0 .. Pair.Rank - 1 loop
            declare
               Sum : Wide_Real := 0.0;
               At_Row : constant Element_Count := Rank_Row * Weight.Columns;
            begin
               for Column in 0 .. Weight.Columns - 1 loop
                  Sum := Sum + Wide_Real (Pair.Down (At_Row + Column)) * Wide_Real (Input (Input'First + Column));
               end loop;
               if not N.Is_Finite (Sum) or else abs Sum > Wide_Real (Real'Last) then
                  Status := E.Make (E.Tensor_Non_Finite_Value);
                  return;
               end if;
               Item.Adapter_Rank (Rank_Row) := Real (Sum);
            end;
         end loop;
         for Row in 0 .. Weight.Rows - 1 loop
            if Row mod 64 = 0 and then C.Is_Cancelled (Item.Stopping) then
               Status := E.Make (E.Generation_Cancelled);
               return;
            end if;
            declare
               Sum : Wide_Real := 0.0;
               At_Row : constant Element_Count := Row * Pair.Rank;
            begin
               for Column in 0 .. Pair.Rank - 1 loop
                  Sum := Sum + Wide_Real (Pair.Up (At_Row + Column)) * Wide_Real (Item.Adapter_Rank (Column));
               end loop;
               Sum := Wide_Real (Item.Adapter_Output (Row)) + Pair.Factor * Sum;
               if not N.Is_Finite (Sum) or else abs Sum > Wide_Real (Real'Last) then
                  Status := E.Make (E.Tensor_Non_Finite_Value);
                  return;
               end if;
               Item.Adapter_Output (Row) := Real (Sum);
            end;
         end loop;
      end if;
   end loop;
   if Started then
      Into := Item.Adapter_Output.all (0 .. Weight.Rows - 1);
   end if;
end Apply_Adapters;
