with Model_Runner.GGUF;
with Model_Runner.Quantization;

package body Model_Runner.Backend.Reference is

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;

   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type N.Wide_Real;

   --------------
   -- Describe --
   --------------

   function Describe return Capabilities is
      Result : Capabilities;
   begin
      Result.Kind := Backend_Reference;

      --  Whatever the decoder decodes, since a row is decoded before it is
      --  multiplied and this backend adds nothing of its own to that.
      for Format in Model_Runner.GGUF.Tensor_Type loop
         Result.Formats (Format) :=
           Model_Runner.Quantization.Is_Decodable (Format);
      end loop;

      Result.Alignment := 4;
      Result.Supports_Matrix_Vector := True;
      Result.Supports_Batched := False;
      Result.Supports_Parallel := False;
      Result.Max_Workers := 1;
      return Result;
   end Describe;

   -------------
   -- Product --
   -------------

   procedure Product
     (Weight : T.View;
      Vector : T.Real_Array_Access;
      Target : T.Real_Array_Access;
      Status : out E.Error_Info) is
   begin
      Status := E.Success;

      if Vector = null or else Target = null then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      if Vector.all'Length < Weight.Columns
        or else Target.all'Length < Weight.Rows
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         E.Add_Integer
           (Status, "rows", Long_Long_Integer (Weight.Rows));
         E.Add_Integer
           (Status, "columns", Long_Long_Integer (Weight.Columns));
         return;
      end if;

      --  A row at a time, decoded whole and summed in the wide format. The
      --  buffer is one row rather than one span because there is no loop
      --  here worth shaping for a compiler.
      declare
         Row : T.Real_Array (0 .. Weight.Columns - 1) := [others => 0.0];
      begin
         for Index in 0 .. Weight.Rows - 1 loop
            T.Dequantize_Row (Weight, Index, Row, Status);
            exit when E.Is_Error (Status);

            declare
               Sum : N.Wide_Real := 0.0;
            begin
               for Column in 0 .. Weight.Columns - 1 loop
                  Sum := Sum
                    + N.Wide_Real (Row (Column))
                      * N.Wide_Real (Vector.all (Vector.all'First + Column));
               end loop;
               Target.all (Target.all'First + Index) := N.Real (Sum);
            end;
         end loop;
      end;
   end Product;

   -------------------
   -- Product_Batch --
   -------------------

   procedure Product_Batch
     (Weight  : T.View;
      Vectors : T.Real_Array_Access;
      Count   : Element_Count;
      Target  : T.Real_Array_Access;
      Status  : out E.Error_Info) is
   begin
      Status := E.Success;

      if Vectors = null or else Target = null or else Count = 0 then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      --  One whole product per vector, reading the weights again each time.
      --  That is the saving this backend declines to make, and the reason it
      --  reports that it does not batch.
      for Which in 0 .. Count - 1 loop
         declare
            From : constant Element_Count := Which * Weight.Columns;
            Into : constant Element_Count := Which * Weight.Rows;
            Row  : T.Real_Array (0 .. Weight.Columns - 1) := [others => 0.0];
         begin
            if Vectors.all'Length < From + Weight.Columns
              or else Target.all'Length < Into + Weight.Rows
            then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               return;
            end if;

            for Index in 0 .. Weight.Rows - 1 loop
               T.Dequantize_Row (Weight, Index, Row, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               declare
                  Sum : N.Wide_Real := 0.0;
               begin
                  for Column in 0 .. Weight.Columns - 1 loop
                     Sum := Sum
                       + N.Wide_Real (Row (Column))
                         * N.Wide_Real
                             (Vectors.all
                                (Vectors.all'First + From + Column));
                  end loop;
                  Target.all (Target.all'First + Into + Index) :=
                    N.Real (Sum);
               end;
            end loop;
         end;
      end loop;
   end Product_Batch;

end Model_Runner.Backend.Reference;
