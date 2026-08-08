with Ada.Real_Time;
with Interfaces;
with Ada.Text_IO;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Kernels;
with Model_Runner.Numerics;
with Model_Runner.Quantization;
with Model_Runner.Tensors;

with Fixtures;

package body Benchmarks is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Quantization;
   package T renames Model_Runner.Tensors;

   use type Interfaces.Unsigned_64;

   use type B.Byte_Array_Access;
   use type B.Byte_Count;
   use type N.Element_Count;
   use type N.Real;

   --  Fed by the reference copy so that the copy cannot be optimised away,
   --  and read once at the end where the value can never be what is tested.
   Guard : Interfaces.Unsigned_64 := 0;

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
      Elapsed  : Duration;
      Relative : Long_Float := 0.0)
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

      --  Where a reference was measured in this same run, this is the figure
      --  worth keeping. It survives a different machine, a busy one and a
      --  throttled one, and an absolute rate survives none of those. Quoted
      --  as a cost so that it rises when the code gets slower.
      if Relative > 0.0 and then Rate > 0.0 then
         IO.Put
           ("   " & Long_Float'Image (Relative / Rate) & " x a copied byte");
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
      --
      --  These rates are comparable within one sitting and not across two.
      --  Repeated on an idle machine, the same binary reports each kernel to
      --  within about half a percent; hours apart, on a laptop that has
      --  changed thermal and clock state, the same binary has reported 785
      --  and 598 Me/s for the same kernel. So a change is worth believing
      --  only when the two versions were run against each other in one
      --  sitting, alternating -- old, new, old -- and it survived.
      --
      --  Two attempts to make a single run mean something on its own were
      --  measured and dropped. Dividing by a memory copy timed in the same
      --  round, which is what makes the parse figure below comparable, was
      --  worse than the plain rate for nine of the twelve kernels: a copy is
      --  bound by memory and these are bound by arithmetic, so the two do
      --  not move together and the division adds the copy's noise instead of
      --  removing the kernel's. Dividing by the f32 dot product, which is
      --  bound by the same thing, was worse still. Timing five short rounds
      --  and keeping the best was worse than one long one, because each
      --  round then measures a fifth as much work and the best of five short
      --  rounds is an optimistic one rather than an undisturbed one.
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

      --  The vector kernels each token passes through, which the measures
      --  above do not touch: normalization before every attention and feed
      --  forward block, softmax over the attention scores and again over the
      --  vocabulary, and the activation between the feed forward matrices.
      --  A row product is the larger cost, but these run just as often and
      --  nothing here was measuring them.
      procedure Measure_Vector (Name : String; Which : Character) is
         Length : constant N.Element_Count := 4096;
         Values : N.Real_Array (0 .. Length - 1);
         Weight : constant N.Real_Array (0 .. Length - 1) := [others => 1.0];
         Target : N.Real_Array (0 .. Length - 1) := [others => 0.0];
         Started : Ada.Real_Time.Time;
         Done    : N.Element_Count := 0;
         Guard   : N.Real := 0.0;
         Ok      : Boolean;
      begin
         for Index in Values'Range loop
            Values (Index) := N.Real (Index mod 23) * 0.125 - 1.0;
         end loop;

         Started := Ada.Real_Time.Clock;
         loop
            case Which is
               when 'S' =>
                  Target := Values;
                  Model_Runner.Kernels.Softmax (Target, Ok);
                  Guard := Guard + Target (0);
               when 'N' =>
                  Model_Runner.Kernels.RMS_Norm
                    (Values, Weight, 1.0E-5, Target);
                  Guard := Guard + Target (0);
               when 'L' =>
                  Target := Values;
                  Model_Runner.Kernels.SiLU (Target);
                  Guard := Guard + Target (0);
               when others =>
                  Guard := Guard
                    + Model_Runner.Kernels.Dot (Values, Weight);
            end case;

            Done := Done + Length;
            exit when Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started) >= Seconds;
         end loop;

         Report
           (Name, Long_Long_Integer (Done),
            Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));

         if Guard = N.Real'Last then
            IO.Put_Line ("");
         end if;
      end Measure_Vector;

      --  Decode blocks with no arithmetic on top, to separate the cost of
      --  producing the values from the cost of using them.
      --  How many times a measurement is repeated before its best is kept.
      --
      --  A single timing on a shared machine carries a spread wider than the
      --  regressions worth catching: the same binary measured a twelfth apart
      --  run to run while this was being written. The best of several is the
      --  round that was interrupted least, which is the one that says most
      --  about the code.
      Rounds : constant := 5;

      Round_Seconds : constant Duration := Seconds / Rounds;

      --  A reference measured in this same run, under the same conditions.
      --
      --  An absolute rate says nothing on its own. It moves with the machine,
      --  its load and its clock, so a number recorded on one host cannot be
      --  compared with one produced on another -- and that comparison is
      --  exactly what catching a regression needs. Parsing is mostly copying
      --  bytes and looking at them, so a plain memory copy moves with the
      --  same things and divides them back out.
      Reference_Span : constant B.Byte_Count := 4 * 1024 * 1024;

      --  One round of the reference, run beside the round it is compared
      --  with rather than once before all of them.
      --
      --  That is what makes the ratio worth quoting. A disturbance that
      --  slows the machine for half a second slows both halves of the same
      --  round, and dividing one by the other takes most of it back out. A
      --  reference measured once, earlier, cancels nothing: it just moves
      --  the error into the answer.
      function Copy_Round
        (From : B.Byte_Array_Access;
         Into : B.Byte_Array_Access;
         Span : Duration) return Long_Float
      is
         Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         Copies  : Long_Long_Integer := 0;
         Elapsed : Duration := 0.0;
      begin
         loop
            Into.all := From.all;

            --  Read back, so that nothing here can be discarded as work
            --  whose result is never wanted.
            Guard := Guard + Interfaces.Unsigned_64 (Into.all (Into.all'First));
            Copies := Copies + 1;
            Elapsed := Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started);
            exit when Elapsed >= Span;
         end loop;

         if Elapsed <= 0.0 then
            return 0.0;
         end if;

         return Long_Float (Copies * Long_Long_Integer (Reference_Span))
           / Long_Float (Elapsed);
      end Copy_Round;

      --  Time parsing a metadata-heavy container.
      --
      --  Loading a model is not a kernel, but it is the first thing a run
      --  spends time on, and until this was here a change to the reader could
      --  cost a fifth of it without anything noticing. A vocabulary is what
      --  makes a real file's metadata large: a hundred thousand token strings
      --  and their scores, which is the shape of a small real model.
      procedure Measure_Parse is
         Tokens  : constant := 100_000;
         Builder : Fixtures.Builder;
         Image   : B.Byte_Array_Access;
         Passes       : Long_Long_Integer := 0;
         Started      : Ada.Real_Time.Time;
         Elapsed      : Duration := 0.0;
         Best_Cost    : Long_Float := 0.0;
         Copy_Rate    : Long_Float := 0.0;
         Kept_Copy    : Long_Float := 0.0;
         Kept_Passes  : Long_Long_Integer := 0;
         Kept_Elapsed : Duration := 0.0;
         From         : B.Byte_Array_Access;
         Into         : B.Byte_Array_Access;
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.tokens", G.Value_String, Tokens);
         for Index in 1 .. Tokens loop
            Fixtures.String_Element
              (Builder, "token" & Integer'Image (Index) & "xyzzy");
         end loop;
         Fixtures.End_Array (Builder);

         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.scores", G.Value_Float32, Tokens);
         for Index in 1 .. Tokens loop
            Fixtures.Float_Element (Builder, N.Real (Index));
         end loop;
         Fixtures.End_Array (Builder);
         Fixtures.Build (Builder, Image);

         if Image = null then
            return;
         end if;

         B.Allocate (Reference_Span, From);
         B.Allocate (Reference_Span, Into);

         if From = null or else Into = null then
            B.Free (From);
            B.Free (Into);
            B.Free (Image);
            return;
         end if;

         Fill (From.all);

         for Round in 1 .. Rounds loop
            --  The reference first, then the parse, in the same round.
            Copy_Rate := Copy_Round (From, Into, Round_Seconds / 2);

            Passes := 0;
            Started := Ada.Real_Time.Clock;

            loop
               declare
                  Held   : aliased constant B.Byte_Array := Image.all;
                  Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
                    (Held'Access);
                  Item   : Model_Runner.GGUF.Containers.Container;
                  Status : E.Error_Info;
               begin
                  Model_Runner.GGUF.Containers.Reader.Parse
                    (Item, Source, Model_Runner.Limits.Default_Model_Limits,
                     null, null, Status);
                  exit when E.Is_Error (Status);
                  Model_Runner.GGUF.Containers.Close (Item);
               end;

               Passes := Passes + 1;
               Elapsed := Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started);
               exit when Elapsed >= Round_Seconds / 2;
            end loop;

            --  The round with the lowest cost against its own reference,
            --  not the average of the rounds: a slow round measured the
            --  machine rather than the reader, and this is what says so.
            if Elapsed > 0.0 and then Copy_Rate > 0.0 and then Passes > 0 then
               declare
                  Rate : constant Long_Float :=
                    Long_Float (Passes * Long_Long_Integer (Image.all'Length))
                    / Long_Float (Elapsed);
                  Cost : constant Long_Float := Copy_Rate / Rate;
               begin
                  if Best_Cost = 0.0 or else Cost < Best_Cost then
                     Best_Cost := Cost;
                     Kept_Passes := Passes;
                     Kept_Elapsed := Elapsed;
                     Kept_Copy := Copy_Rate;
                  end if;
               end;
            end if;
         end loop;

         --  Reported per byte of container, which is what a reader's cost
         --  scales with and what makes it comparable across fixtures.
         Report
           ("metadata parse, per byte",
            Kept_Passes * Long_Long_Integer (Image.all'Length), Kept_Elapsed,
            Kept_Copy);
         B.Free (From);
         B.Free (Into);
         B.Free (Image);
      end Measure_Parse;

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
      Measure ("q5_k Row_Dot", G.Type_Q5_K, True);
      Measure ("q6_k Row_Dot", G.Type_Q6_K, True);
      Measure ("f16  Row_Dot", G.Type_F16, True);
      Measure ("f32  Row_Dot", G.Type_F32, True);
      IO.New_Line;

      IO.Put_Line ("row dequantization");
      Measure ("q8_0 Dequantize_Row", G.Type_Q8_0, False);
      Measure ("f16  Dequantize_Row", G.Type_F16, False);
      Measure ("q4_k Dequantize_Row", G.Type_Q4_K, False);
      Measure ("f32  Dequantize_Row", G.Type_F32, False);
      IO.New_Line;

      IO.Put_Line ("vector kernels");
      Measure_Vector ("softmax", 'S');
      Measure_Vector ("rms norm", 'N');
      Measure_Vector ("silu", 'L');
      Measure_Vector ("dot", 'D');
      IO.New_Line;

      IO.Put_Line ("metadata parsing");
      Measure_Parse;
      IO.New_Line;

      IO.Put_Line ("block decode alone");
      Measure_Decode ("q8_0 Decode_Block", G.Type_Q8_0);
      Measure_Decode ("q4_k Decode_Block", G.Type_Q4_K);
      Measure_Decode ("q5_k Decode_Block", G.Type_Q5_K);
      Measure_Decode ("q6_k Decode_Block", G.Type_Q6_K);
      Measure_Decode ("f32  Decode_Block", G.Type_F32);
   end Run;

end Benchmarks;
