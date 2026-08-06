with Ada.Real_Time;
with Ada.Text_IO;

with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.Numerics;
with Model_Runner.Quantization;
with Model_Runner.Tensors;

package body Benchmarks is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Quantization;
   package T renames Model_Runner.Tensors;

   use type B.Byte_Array_Access;
   use type B.Byte_Count;
   use type N.Element_Count;
   use type N.Real;

   Rows    : constant N.Element_Count := 512;
   Columns : constant N.Element_Count := 2048;

   --  Fill a buffer with values that are not all the same, so that a decoder
   --  cannot be accidentally fast on uniform data.
   procedure Fill (Data : in out B.Byte_Array) is
      Value : B.Byte := 0;
   begin
      for Index in Data'Range loop
         Value := B.Byte ((Integer (Value) * 7 + 13) mod 251);
         Data (Index) := Value;
      end loop;
   end Fill;

   --  Force every half-precision scale in a span of blocks to a modest normal
   --  exponent.
   --
   --  Random bytes read as half precision are frequently denormal, infinite
   --  or not-a-number. Arithmetic on denormals is slow on this hardware, so
   --  leaving them in measures a case no real model contains and reports the
   --  kernels as slower than they are.
   procedure Tame_Scales
     (Data   : in out B.Byte_Array;
      Format : G.Tensor_Type;
      Blocks : B.Byte_Count)
   is
      Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
   begin
      case Format is
         when G.Type_F16 =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
            end loop;

         when G.Type_F32 =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 3) := 16#3E#;
            end loop;

         when G.Type_Q4_0 | G.Type_Q8_0 =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
            end loop;

         when G.Type_Q4_K | G.Type_Q5_K =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
               Data (Data'First + Block * Width + 3) := 16#30#;
            end loop;

         when G.Type_Q6_K =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 209) := 16#30#;
            end loop;

         when others =>
            null;
      end case;
   end Tame_Scales;

   --  Report one measurement.
   procedure Report
     (Name     : String;
      Elements : Long_Long_Integer;
      Elapsed  : Duration)
   is
      package IO renames Ada.Text_IO;

      Seconds : constant Long_Float := Long_Float (Elapsed);
      Rate    : constant Long_Float :=
        (if Seconds > 0.0 then Long_Float (Elements) / Seconds else 0.0);
      Label   : String (1 .. 34) := [others => ' '];
      Room    : constant Natural := Natural'Min (Name'Length, Label'Length);
   begin
      Label (1 .. Room) := Name (Name'First .. Name'First + Room - 1);
      IO.Put ("  " & Label);

      --  Elements per second, and the nanoseconds each one cost.
      IO.Put (Long_Float'Image (Rate / 1.0E6) & " Me/s");
      if Rate > 0.0 then
         IO.Put ("   " & Long_Float'Image (1.0E9 / Rate) & " ns/element");
      end if;
      IO.New_Line;
   end Report;

   ---------
   -- Run --
   ---------

   procedure Run (Seconds : Duration := 0.5) is
      package IO renames Ada.Text_IO;
      use type Ada.Real_Time.Time;

      --  Time a kernel until at least Seconds have passed, then report the
      --  cost per element over everything actually done.
      procedure Measure
        (Name        : String;
         Format      : G.Tensor_Type;
         Use_Row_Dot : Boolean)
      is
         Bytes_Per_Row : constant B.Byte_Count :=
           B.Byte_Count (Columns)
           / B.Byte_Count (G.Block_Elements (Format))
           * B.Byte_Count (G.Block_Bytes (Format));

         Data   : B.Byte_Array_Access;
         Item   : T.View;
         Status : E.Error_Info;

         Vector : N.Real_Array (0 .. Columns - 1);
         Target : N.Real_Array (0 .. Rows - 1) := [others => 0.0];
         Scratch : N.Real_Array (0 .. Columns - 1) := [others => 0.0];

         Started  : Ada.Real_Time.Time;
         Done     : N.Element_Count := 0;
         Guard    : N.Real := 0.0;
      begin
         B.Allocate (Bytes_Per_Row * B.Byte_Count (Rows), Data);
         if Data = null then
            IO.Put_Line ("  " & Name & ": allocation failed");
            return;
         end if;

         Fill (Data.all);
         Tame_Scales
           (Data.all, Format,
            B.Byte_Count (Rows) * B.Byte_Count (Columns)
            / B.Byte_Count (G.Block_Elements (Format)));

         T.Make (Format, Rows, Columns, Data, 0, Item, Status);
         if E.Is_Error (Status) then
            IO.Put_Line ("  " & Name & ": view rejected");
            B.Free (Data);
            return;
         end if;

         for Index in Vector'Range loop
            Vector (Index) := N.Real (Index mod 17) * 0.125 - 1.0;
         end loop;

         Started := Ada.Real_Time.Clock;
         loop
            if Use_Row_Dot then
               for Row in 0 .. Rows - 1 loop
                  Target (Row) := T.Row_Dot (Item, Row, Vector);
               end loop;
               Guard := Guard + Target (0);
            else
               for Row in 0 .. Rows - 1 loop
                  T.Dequantize_Row (Item, Row, Scratch, Status);
               end loop;
               Guard := Guard + Scratch (0);
            end if;

            Done := Done + Rows * Columns;
            exit when Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started) >= Seconds;
         end loop;

         Report
           (Name, Long_Long_Integer (Done),
            Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));

         --  Keep the result live so the loop cannot be optimized away.
         if Guard = N.Real'Last then
            IO.Put_Line ("");
         end if;

         B.Free (Data);
      end Measure;

      --  Decode blocks with no arithmetic on top, to separate the cost of
      --  producing the values from the cost of using them.
      procedure Measure_Decode (Name : String; Format : G.Tensor_Type) is
         Per_Block : constant N.Element_Count :=
           N.Element_Count (G.Block_Elements (Format));
         Width     : constant B.Byte_Count :=
           B.Byte_Count (G.Block_Bytes (Format));
         Count     : constant B.Byte_Count := 4096;

         Data    : B.Byte_Array_Access;
         Block   : Q.Block_Buffer;
         Ok      : Boolean;
         Started : Ada.Real_Time.Time;
         Done    : N.Element_Count := 0;
         Guard   : N.Real := 0.0;
      begin
         B.Allocate (Width * Count, Data);
         if Data = null then
            return;
         end if;
         Fill (Data.all);
         Tame_Scales (Data.all, Format, Count);

         Started := Ada.Real_Time.Clock;
         loop
            for Index in 0 .. Count - 1 loop
               Q.Decode_Block (Format, Data.all, Index * Width, Block, Ok);
               Guard := Guard + Block (0);
            end loop;

            Done := Done + N.Element_Count (Count) * Per_Block;
            exit when Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started) >= Seconds;
         end loop;

         Report
           (Name, Long_Long_Integer (Done),
            Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));

         if Guard = N.Real'Last then
            IO.Put_Line ("");
         end if;
         B.Free (Data);
      end Measure_Decode;

   begin
      IO.Put_Line ("kernel benchmarks, single task, "
                   & N.Element_Count'Image (Rows) & " x"
                   & N.Element_Count'Image (Columns) & " per pass");
      IO.New_Line;

      IO.Put_Line ("row dot product");
      Measure ("q8_0 Row_Dot", G.Type_Q8_0, True);
      Measure ("q4_0 Row_Dot", G.Type_Q4_0, True);
      Measure ("q4_k Row_Dot", G.Type_Q4_K, True);
      Measure ("f32  Row_Dot", G.Type_F32, True);
      IO.New_Line;

      IO.Put_Line ("row dequantization");
      Measure ("q8_0 Dequantize_Row", G.Type_Q8_0, False);
      Measure ("f32  Dequantize_Row", G.Type_F32, False);
      IO.New_Line;

      IO.Put_Line ("block decode alone");
      Measure_Decode ("q8_0 Decode_Block", G.Type_Q8_0);
      Measure_Decode ("q4_k Decode_Block", G.Type_Q4_K);
      Measure_Decode ("f32  Decode_Block", G.Type_F32);
   end Run;

end Benchmarks;
