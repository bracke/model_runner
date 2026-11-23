separate (Model_Runner.Llama)
procedure Apply_Adapters_Batch
  (Item : Session; Weight : T.View; Input : Real_Array; Count : Element_Count;
   Into : in out Real_Array; Status : out E.Error_Info)
is
   pragma Suppress (Validity_Check);
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Backend.Backend_Kind;
   use type System.Bit_Order;
   Done : Element_Count := 0;
   Checked : Boolean := False;

   --  The existing wide tensor product computes A*x for a bounded tile. Its four-lane
   --  reduction retains binary64 accumulation, including finite cancellation of large products.
   type Down_Work is new Workers_CPU.Task_Item with record
      Matrix : T.View;
      Inputs : System.Address := System.Null_Address;
      Count : Element_Count := 0;
      Output : T.Real_Array_Access := null;
      Stop : C.Token_Reference := null;
      Invalid : Boolean := False with Atomic;
      Cancelled : Boolean := False with Atomic;
   end record;
   overriding procedure Run (Work : in out Down_Work; From, To : Element_Count);

   overriding procedure Run (Work : in out Down_Work; From, To : Element_Count) is
      Vectors : Real_Array (0 .. Work.Count * Work.Matrix.Columns - 1)
        with Import, Address => Work.Inputs;
      First : Element_Count := From;
   begin
      while First <= To loop
         if C.Is_Cancelled (Work.Stop) then
            Work.Cancelled := True;
            return;
         end if;
         declare
            Last : constant Element_Count := Element_Count'Min (To, First + 7);
         begin
            T.Mat_Mul_Range (Work.Matrix, Vectors, Work.Count, Work.Output.all, First, Last);
            for Position in 0 .. Work.Count - 1 loop
               for Row in First .. Last loop
                  if not N.Is_Finite (Work.Output (Position * Work.Matrix.Rows + Row)) then
                     Work.Invalid := True;
                     return;
                  end if;
               end loop;
            end loop;
            First := Last + 1;
         end;
      end loop;
   exception
      when Constraint_Error =>
         --  A finite binary64 dot that cannot be represented by the admitted F32 rank buffer.
         Work.Invalid := True;
   end Run;

   type Up_Work is new Workers_CPU.Task_Item with record
      Matrix : T.Real_Array_Access := null;
      Ranked, Output : T.Real_Array_Access := null;
      Rows, Rank, Count : Element_Count := 0;
      Factor : Wide_Real := 0.0;
      Stop : C.Token_Reference := null;
      Invalid : Boolean := False with Atomic;
      Cancelled : Boolean := False with Atomic;
   end record;
   overriding procedure Run (Work : in out Up_Work; From, To : Element_Count);

   overriding procedure Run (Work : in out Up_Work; From, To : Element_Count) is
      --  The caller proves matrix, rank and output extents before dispatch. Workers own disjoint
      --  rows; four positions keep independent wide sums, with no reduction across positions.
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      procedure Store (Position, Row : Element_Count; Sum : Wide_Real) is
         Index : constant Element_Count := Position * Work.Rows + Row;
         Value : constant Wide_Real := Wide_Real (Work.Output (Index)) + Work.Factor * Sum;
      begin
         if not N.Is_Finite (Value) or else abs Value > Wide_Real (Real'Last) then
            Work.Invalid := True;
         else
            Work.Output (Index) := Real (Value);
         end if;
      end Store;
   begin
      for Row in From .. To loop
         if Row mod 64 = 0 and then C.Is_Cancelled (Work.Stop) then
            Work.Cancelled := True;
            return;
         end if;
         declare
            At_Row : constant Element_Count := Row * Work.Rank;
            Position : Element_Count := 0;
         begin
            while Work.Count - Position >= 4 loop
               declare
                  S0, S1, S2, S3 : Wide_Real := 0.0;
                  At_Rank : constant Element_Count := Position * Work.Rank;
               begin
                  for Column in 0 .. Work.Rank - 1 loop
                     declare
                        Value : constant Wide_Real := Wide_Real (Work.Matrix (At_Row + Column));
                     begin
                        S0 := S0 + Value * Wide_Real (Work.Ranked (At_Rank + Column));
                        S1 := S1 + Value * Wide_Real (Work.Ranked (At_Rank + Work.Rank + Column));
                        S2 := S2 + Value * Wide_Real (Work.Ranked (At_Rank + 2 * Work.Rank + Column));
                        S3 := S3 + Value * Wide_Real (Work.Ranked (At_Rank + 3 * Work.Rank + Column));
                     end;
                  end loop;
                  Store (Position, Row, S0);
                  Store (Position + 1, Row, S1);
                  Store (Position + 2, Row, S2);
                  Store (Position + 3, Row, S3);
                  Position := Position + 4;
               end;
            end loop;
            while Position < Work.Count loop
               declare
                  Sum : Wide_Real := 0.0;
               begin
                  for Column in 0 .. Work.Rank - 1 loop
                     Sum := Sum + Wide_Real (Work.Matrix (At_Row + Column))
                       * Wide_Real (Work.Ranked (Position * Work.Rank + Column));
                  end loop;
                  Store (Position, Row, Sum);
                  Position := Position + 1;
               end;
            end loop;
         end;
      end loop;
   end Run;

   function Matches (Pair : Runtime_Pair) return Boolean is
     (Pair.Target.Base = Weight.Base and then Pair.Target.Offset = Weight.Offset
      and then Pair.Target.Rows = Weight.Rows and then Pair.Target.Columns = Weight.Columns
      and then Pair.Target.Format = Weight.Format and then Pair.Factor /= 0.0);
begin
   Status := E.Success;
   if Weight.Columns = 0 or else Weight.Rows = 0 or else Count = 0
     or else Count > Input'Length / Weight.Columns or else Count > Into'Length / Weight.Rows
   then
      Status := E.Make (E.Tensor_Shape_Mismatch);
      return;
   end if;
   --  Tensor F32 views describe little-endian bytes; owned Real arrays are native storage.
   if Item.Owner.Able.Kind /= Model_Runner.Backend.Backend_CPU or else Count = 1
     or else System.Default_Bit_Order /= System.Low_Order_First
   then
      for Position in 0 .. Count - 1 loop
         Apply_Adapters
           (Item, Weight,
            Input (Input'First + Position * Weight.Columns .. Input'First + ((Position + 1) * Weight.Columns - 1)),
            Into (Into'First + Position * Weight.Rows .. Into'First + ((Position + 1) * Weight.Rows - 1)), Status);
         exit when E.Is_Error (Status);
      end loop;
      return;
   end if;
   while Done < Count loop
      if C.Is_Cancelled (Item.Stopping) then
         Status := E.Make (E.Generation_Cancelled);
         return;
      end if;
      declare
         Here : constant Element_Count := Element_Count'Min (Runtime_Tile, Count - Done);
         Started : Boolean := False;
      begin
         for Pair of Item.Owner.Runtime_Pairs.all loop
            if Matches (Pair) then
               if Item.Adapter_Rank = null or else Item.Adapter_Output = null
                 or else Item.Adapter_Rank'Length < Here * Pair.Rank
                 or else Item.Adapter_Output'Length < Here * Weight.Rows
                 or else Pair.Down = null or else Pair.Up = null
                 or else Pair.Down'Length /= Pair.Rank * Weight.Columns
                 or else Pair.Up'Length /= Pair.Rank * Weight.Rows
               then
                  Status := E.Make (E.Internal_Invariant_Violated);
                  return;
               end if;
               if not Checked then
                  for Index in Input'First .. Input'First + (Count * Weight.Columns - 1) loop
                     if not N.Is_Finite (Input (Index)) then
                        Status := E.Make (E.Tensor_Non_Finite_Value);
                        return;
                     end if;
                  end loop;
                  Checked := True;
               end if;
               if not Started then
                  Item.Adapter_Output.all (0 .. Here * Weight.Rows - 1) :=
                    Into (Into'First + Done * Weight.Rows .. Into'First + ((Done + Here) * Weight.Rows - 1));
                  Started := True;
               end if;
               declare
                  Down : aliased Down_Work;
                  Up : aliased Up_Work;
               begin
                  T.Make (Model_Runner.GGUF.Type_F32, Pair.Rank, Weight.Columns,
                          Pair.Down (Pair.Down'First)'Address, B.Byte_Count (Pair.Down'Length) * 4, 0,
                          Down.Matrix, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  Down.Inputs := Input (Input'First + Done * Weight.Columns)'Address;
                  Down.Count := Here;
                  Down.Output := Item.Adapter_Rank;
                  Down.Stop := Item.Stopping;
                  Workers_CPU.Dispatch_Shares
                    (Item.Team, Pair.Rank, Down'Unchecked_Access, Status,
                     Cost => Here * Pair.Rank * Weight.Columns);
                  if Down.Cancelled or else C.Is_Cancelled (Item.Stopping) then
                     Status := E.Make (E.Generation_Cancelled);
                  elsif Down.Invalid then
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                  end if;
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  Up.Matrix := Pair.Up;
                  Up.Ranked := Item.Adapter_Rank;
                  Up.Output := Item.Adapter_Output;
                  Up.Rows := Weight.Rows;
                  Up.Rank := Pair.Rank;
                  Up.Count := Here;
                  Up.Factor := Pair.Factor;
                  Up.Stop := Item.Stopping;
                  Workers_CPU.Dispatch_Shares
                    (Item.Team, Weight.Rows, Up'Unchecked_Access, Status,
                     Cost => Here * Pair.Rank * Weight.Rows);
                  if Up.Cancelled or else C.Is_Cancelled (Item.Stopping) then
                     Status := E.Make (E.Generation_Cancelled);
                  elsif Up.Invalid then
                     Status := E.Make (E.Tensor_Non_Finite_Value);
                  end if;
                  if E.Is_Error (Status) then
                     return;
                  end if;
               end;
            end if;
         end loop;
         if C.Is_Cancelled (Item.Stopping) then
            Status := E.Make (E.Generation_Cancelled);
            return;
         end if;
         if Started then
            Into (Into'First + Done * Weight.Rows .. Into'First + ((Done + Here) * Weight.Rows - 1)) :=
              Item.Adapter_Output.all (0 .. Here * Weight.Rows - 1);
         end if;
         Done := Done + Here;
      end;
   end loop;
end Apply_Adapters_Batch;
