with System.Storage_Elements;

with Model_Runner.GGUF;
with Model_Runner.Shares;

package body Model_Runner.Qwen_Image.Decoder is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package S renames Model_Runner.Safetensors;
   package CPU renames Model_Runner.Backend.CPU;

   subtype Element_Count is N.Element_Count;
   subtype Real is N.Real;
   subtype Wide is N.Wide_Real;

   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type Element_Count;
   use type Real;
   use type Wide;
   use type System.Address;
   use type System.Storage_Elements.Integer_Address;
   use type T.Real_Array_Access;
   use type Model_Runner.GGUF.U64;

   --  The latent's statistics, from the model's configuration: what the
   --  sampler's latent is multiplied by and moved by before decoding.
   Means : constant array (0 .. Latent_Channels - 1) of Real :=
     [0.5126, 0.7721, -0.0631, 1.3506, -0.7855, -2.1025, -0.3458, 1.3722,
      1.8873, -1.7177, -0.6510, 0.2732, 0.7562, -0.6163, -1.0277, 3.8363,
      2.0210, 0.0472, 0.9320, 2.0087, 2.4954, -0.1391, -1.4249, 1.8464,
      -0.5236, 1.2826, 3.7046, -1.3035, 2.7286, -1.4518, -1.9036, -1.9955,
      -0.0342, -1.0265, -0.7636, 3.0555, 0.0746, -3.0751, -0.1076, 1.7376,
      -1.0914, -1.9435, -0.2784, -1.3680, 0.4809, -0.4433, 0.3764, 0.5729,
      -2.0595, 1.0960, -1.3260, -2.0211, -5.0179, 0.5275, 4.0162, 1.8505,
      0.3026, 1.9373, 1.4937, 0.2632, 0.5547, -1.7121, -0.1562, 0.0304];
   Deviations : constant array (0 .. Latent_Channels - 1) of Real :=
     [3.2001, 3.2936, 3.4321, 3.0091, 3.1061, 4.0379, 4.0705, 3.7910,
      3.0785, 3.6500, 3.9308, 3.0904, 2.8778, 3.7675, 3.7320, 5.0756,
      3.2864, 4.0397, 3.1317, 4.0443, 2.9249, 3.9454, 3.0988, 4.2489,
      3.4896, 3.8513, 3.9323, 3.4719, 3.7498, 4.2830, 3.5694, 4.2467,
      3.9037, 3.2947, 5.0770, 3.5075, 3.2700, 3.4767, 2.8063, 5.1125,
      3.5327, 4.7833, 3.1286, 4.1819, 3.8527, 3.8312, 3.5605, 4.3875,
      3.9624, 4.0168, 3.5643, 4.0550, 5.5614, 4.2963, 4.4080, 3.4959,
      3.8747, 3.7608, 3.5735, 3.1490, 3.7662, 3.6746, 3.4563, 3.8161];

   --  Each level's width as a multiple of the last's: the mid block's
   --  first, then each level's out.
   Multiples : constant array (0 .. 5) of Positive := [8, 8, 8, 4, 2, 1];
   Temporals : constant array (1 .. 5) of Positive := [2, 2, 2, 1, 1];

   function Image (Value : Natural) return String is
      Text : constant String := Value'Image;
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   ----------
   -- Open --
   ----------

   procedure Open (Item : in out Picture_Decoder; Path : String; Status : out E.Error_Info) is

      --  A tensor of the elements given, or refused naming it.
      function Find (Name : String; Elements : Element_Count) return Natural is
         Index : constant Natural := S.Find (Item.Table, Name);
      begin
         if E.Is_Error (Status) then
            return 0;
         elsif Index = 0 then
            Status := E.Make (E.Arch_Missing_Tensor);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            return 0;
         elsif Element_Count (S.Info (Item.Table, Index).Elements) /= Elements then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", Name, E.Param_Identifier);
            E.Add_Integer (Status, "rows", 1);
            E.Add_Integer (Status, "columns", Long_Long_Integer (S.Info (Item.Table, Index).Elements));
            E.Add_Integer (Status, "expected_rows", 1);
            E.Add_Integer (Status, "expected_columns", Long_Long_Integer (Elements));
            return 0;
         end if;
         return Index;
      end Find;

      procedure View_Of (Index : Positive; Rows, Columns : Element_Count; Result : out T.View) is
         Info : constant S.Tensor_Info := S.Info (Item.Table, Index);
      begin
         T.Make
           (Format => Info.Element, Rows => Rows, Columns => Columns, Base => Item.Base, Span => Item.Span,
            Offset => Info.Data_Offset - S.Data_Start (Item.Table), Result => Result, Status => Status);
      end View_Of;

      procedure Vector (Name : String; Length : Positive; Result : out T.Real_Array_Access) is
         Index : constant Natural := Find (Name, Element_Count (Length));
         View  : T.View;
      begin
         Result := null;
         if Index = 0 then
            return;
         end if;
         View_Of (Index, 1, Element_Count (Length), View);
         if E.Is_Ok (Status) then
            T.Allocate (Element_Count (Length), Result);
            T.Dequantize_Row (View, 0, Result.all, Status);
         end if;
      end Vector;

      procedure Convolve (Name : String; Inputs, Outputs, Size : Positive; Result : out Convolution) is
         Columns : constant Element_Count := Element_Count (Inputs * Size * Size);
         Index   : constant Natural := Find (Name & ".weight", Element_Count (Outputs) * Columns);
      begin
         Result := (Inputs => Inputs, Outputs => Outputs, Size => Size, others => <>);
         if Index = 0 then
            return;
         end if;
         View_Of (Index, Element_Count (Outputs), Columns, Result.Kernel);
         if E.Is_Ok (Status) then
            Vector (Name & ".bias", Outputs, Result.Bias);
         end if;
      end Convolve;

      procedure Residual_Of (Name : String; Inputs, Outputs : Positive; Result : out Residual) is
      begin
         Vector (Name & ".norm1.gamma", Inputs, Result.Norm_1);
         Convolve (Name & ".conv1", Inputs, Outputs, 3, Result.Conv_1);
         Vector (Name & ".norm2.gamma", Outputs, Result.Norm_2);
         Convolve (Name & ".conv2", Outputs, Outputs, 3, Result.Conv_2);
         if Inputs /= Outputs then
            Convolve (Name & ".conv_shortcut", Inputs, Outputs, 1, Result.Shortcut);
         end if;
      end Residual_Of;
      Widths : Width_Array renames Item.Widths;
   begin
      Close (Item);
      Model_Runner.Byte_Sources.Files.Open (Item.File, Path, Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;
      S.Read (Item.Table, Item.File, Status);
      if E.Is_Error (Status) then
         Close (Item);
         return;
      end if;

      --  The tensors' bytes: the file's own pages where it is mapped.
      declare
         Start  : constant B.Byte_Count := S.Data_Start (Item.Table);
         Length : constant B.Byte_Count := Item.File.Size - Start;
      begin
         if Item.File.Is_Mapped and then Item.File.Base /= System.Null_Address then
            Item.Base := System.Storage_Elements.To_Address
              (System.Storage_Elements.To_Integer (Item.File.Base) + System.Storage_Elements.Integer_Address (Start));
         else
            B.Allocate (Length, Item.Arena);
            if Item.Arena = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               Close (Item);
               return;
            end if;
            Item.File.Read (Start, Item.Arena.all, Status);
            Item.Base := Item.Arena.all'Address;
         end if;
         Item.Span := Length;
      end;

      --  The widths, off the last norm's: the published file's is 144.
      declare
         Last : constant Natural := S.Find (Item.Table, "decoder.norm_out.gamma");
      begin
         if Last = 0 then
            Status := E.Make (E.Arch_Missing_Tensor);
            E.Add_Text (Status, "tensor", "decoder.norm_out.gamma", E.Param_Identifier);
            Close (Item);
            return;
         elsif S.Info (Item.Table, Last).Elements = 0 or else S.Info (Item.Table, Last).Elements > 65_536 then
            Status := E.Make (E.Arch_Invalid_Tensor_Shape);
            E.Add_Text (Status, "tensor", "decoder.norm_out.gamma", E.Param_Identifier);
            E.Add_Integer (Status, "rows", 1);
            E.Add_Integer (Status, "columns", Long_Long_Integer (S.Info (Item.Table, Last).Elements));
            E.Add_Integer (Status, "expected_rows", 1);
            E.Add_Integer (Status, "expected_columns", 144);
            Close (Item);
            return;
         end if;
         for Index in Widths'Range loop
            Widths (Index) := Multiples (Index) * Positive (S.Info (Item.Table, Last).Elements);
         end loop;
      end;

      Convolve ("post_quant_conv", Latent_Channels, Latent_Channels, 1, Item.Post_Quant);
      Convolve ("decoder.conv_in", Latent_Channels, Widths (0), 3, Item.Conv_In);
      Residual_Of ("decoder.mid_block.resnets.0", Widths (0), Widths (0), Item.Mid_1);
      Vector ("decoder.mid_block.attentions.0.norm.gamma", Widths (0), Item.Attention_Norm);
      Convolve ("decoder.mid_block.attentions.0.to_qkv", Widths (0), 3 * Widths (0), 1, Item.Joint);
      Convolve ("decoder.mid_block.attentions.0.proj", Widths (0), Widths (0), 1, Item.Attention_Out);
      Residual_Of ("decoder.mid_block.resnets.1", Widths (0), Widths (0), Item.Mid_2);
      for L in Item.Levels'Range loop
         declare
            Lead : constant String := "decoder.up_blocks." & Image (L - 1) & ".";
         begin
            Item.Levels (L).Temporal := Temporals (L);
            for R in Residual_Array'Range loop
               Residual_Of (Lead & "resnets." & Image (R - 1), (if R = 1 then Widths (L - 1) else Widths (L)),
                            Widths (L), Item.Levels (L).Blocks (R));
            end loop;
            if L < Item.Levels'Last then
               Convolve (Lead & "upsampler.resample.1", Widths (L), Widths (L), 3, Item.Levels (L).Up);
            end if;
         end;
      end loop;
      Vector ("decoder.norm_out.gamma", Widths (5), Item.Norm_Out);
      Convolve ("decoder.conv_out", Widths (5), Picture_Channels, 3, Item.Conv_Out);
      if E.Is_Error (Status) then
         declare
            Kept : constant E.Error_Info := Status;
         begin
            Close (Item);
            Status := Kept;
         end;
         return;
      end if;
      Item.Ready := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Picture_Decoder) is
      procedure Let_Go (C : in out Convolution) is
      begin
         T.Free (C.Bias);
         C := (others => <>);
      end Let_Go;

      procedure Let_Go (R : in out Residual) is
      begin
         T.Free (R.Norm_1);
         T.Free (R.Norm_2);
         Let_Go (R.Conv_1);
         Let_Go (R.Conv_2);
         Let_Go (R.Shortcut);
      end Let_Go;
   begin
      Let_Go (Item.Post_Quant);
      Let_Go (Item.Conv_In);
      Let_Go (Item.Mid_1);
      Let_Go (Item.Mid_2);
      T.Free (Item.Attention_Norm);
      Let_Go (Item.Joint);
      Let_Go (Item.Attention_Out);
      for L of Item.Levels loop
         for R of L.Blocks loop
            Let_Go (R);
         end loop;
         Let_Go (L.Up);
      end loop;
      T.Free (Item.Norm_Out);
      Let_Go (Item.Conv_Out);
      B.Free (Item.Arena);
      Item.Base := System.Null_Address;
      Item.Span := 0;
      Item.Ready := False;
      Model_Runner.Byte_Sources.Files.Close (Item.File);
   end Close;

   function Is_Ready (Item : Picture_Decoder) return Boolean
   is (Item.Ready);

   function To_Pixels (Picture : N.Real_Array; Pixels : Element_Count) return B.Byte_Array is
      Result : B.Byte_Array (0 .. B.Byte_Count (Pixels) * Picture_Channels - 1);
   begin
      for Pixel in 0 .. Pixels - 1 loop
         for Channel in Element_Count range 0 .. Picture_Channels - 1 loop
            declare
               V : constant Real :=
                 Real'Min (1.0, Real'Max (0.0, (Picture (Picture'First + Channel * Pixels + Pixel) + 1.0) * 0.5));
            begin
               Result (B.Byte_Count (Pixel * Picture_Channels + Channel)) := B.Byte (Real'Truncation (V * 255.0));
            end;
         end loop;
      end loop;
      return Result;
   end To_Pixels;

   ------------
   -- Decode --
   ------------

   --  The mid block's attention, a share of query positions at a time:
   --  one head as wide as the channels, every position seeing every one.
   type Attention_Work is new Model_Runner.Shares.Work with record
      Joint, Answer : T.Real_Array_Access;
      Positions, Width : Element_Count := 0;
   end record;

   overriding procedure Run (Item : in out Attention_Work; First : Element_Count; Last : Element_Count) is
      Scale  : constant Real := Real (1.0 / N.Sqrt (Wide (Item.Width)));
      Scores : N.Real_Array (0 .. Item.Positions - 1);
      Sums   : N.Real_Array (0 .. Item.Width - 1);
      Stride : constant Element_Count := 3 * Item.Width;
   begin
      for Query in First .. Last loop
         declare
            Most  : Real := Real'First;
            Total : Real := 0.0;
         begin
            for Key in 0 .. Item.Positions - 1 loop
               declare
                  Dot : Real := 0.0;
               begin
                  for I in 0 .. Item.Width - 1 loop
                     Dot := Dot + Item.Joint (Query * Stride + I) * Item.Joint (Key * Stride + Item.Width + I);
                  end loop;
                  Scores (Key) := Dot * Scale;
                  Most := Real'Max (Most, Scores (Key));
               end;
            end loop;
            Sums := [others => 0.0];
            for Key in 0 .. Item.Positions - 1 loop
               declare
                  P : constant Real := Real (N.Exp (Wide (Scores (Key) - Most)));
               begin
                  Total := Total + P;
                  for I in 0 .. Item.Width - 1 loop
                     Sums (I) := Sums (I) + P * Item.Joint (Key * Stride + 2 * Item.Width + I);
                  end loop;
               end;
            end loop;
            for I in 0 .. Item.Width - 1 loop
               Item.Answer (Query * Item.Width + I) := Sums (I) / Total;
            end loop;
         end;
      end loop;
   end Run;

   procedure Decode
     (Item    : Picture_Decoder;
      Latent  : N.Real_Array;
      Rows    : Positive;
      Columns : Positive;
      Pool    : CPU.Pool_Reference;
      Picture : out N.Real_Array;
      Status  : out E.Error_Info)
   is
      Widths : Width_Array renames Item.Widths;
      --  Activations a pixel at a time, a pixel's channels together.
      Height : Element_Count := Element_Count (Rows);
      Width  : Element_Count := Element_Count (Columns);
      X, Y, Z : T.Real_Array_Access;

      procedure Swap (A, B_Side : in out T.Real_Array_Access) is
         Held : constant T.Real_Array_Access := A;
      begin
         A := B_Side;
         B_Side := Held;
      end Swap;

      --  A buffer of at least Length, reused where it is already so long.
      procedure Room (Buffer : in out T.Real_Array_Access; Length : Element_Count) is
      begin
         if Buffer = null or else Buffer'Length < Length then
            T.Free (Buffer);
            T.Allocate (Length, Buffer);
            if Buffer = null and then E.Is_Ok (Status) then
               Status := E.Make (E.Memory_Allocation_Failed);
            end if;
         end if;
      end Room;

      --  Target := C applied to Source's Height by Width pixels: a 1x1 as a
      --  product, a 3x3 as a product over each pixel's neighbourhood,
      --  gathered a band of rows at a time, zero past the edges.
      procedure Apply (C : Convolution; Source : T.Real_Array_Access; Target : in out T.Real_Array_Access) is
         Pixels : constant Element_Count := Height * Width;
         Outs   : constant Element_Count := Element_Count (C.Outputs);
         Ins    : constant Element_Count := Element_Count (C.Inputs);
      begin
         Room (Target, Pixels * Outs);
         if E.Is_Error (Status) then
            return;
         end if;
         if C.Size = 1 then
            CPU.Dispatch_Batch (Pool, C.Kernel, Source, Pixels, Target, Status);
         else
            declare
               Patch : constant Element_Count := Ins * 9;
               --  A band of rows whose patches are about 64 MB.
               Band  : constant Element_Count :=
                 Element_Count'Max (1, Element_Count'Min (Height, 16_777_216 / (Patch * Width)));
               Patches, Answers : T.Real_Array_Access;
            begin
               T.Allocate (Band * Width * Patch, Patches);
               T.Allocate (Band * Width * Outs, Answers);
               if Patches = null or else Answers = null then
                  T.Free (Patches);
                  T.Free (Answers);
                  Status := E.Make (E.Memory_Allocation_Failed);
                  return;
               end if;
               declare
                  Row : Element_Count := 0;
               begin
                  while Row < Height and then E.Is_Ok (Status) loop
                     declare
                        Rows_Here : constant Element_Count := Element_Count'Min (Band, Height - Row);
                     begin
                        for R in 0 .. Rows_Here - 1 loop
                           for Col in 0 .. Width - 1 loop
                              declare
                                 At_Patch : constant Element_Count := (R * Width + Col) * Patch;
                              begin
                                 for Channel in 0 .. Ins - 1 loop
                                    for DY in Element_Count range 0 .. 2 loop
                                       for DX in Element_Count range 0 .. 2 loop
                                          declare
                                             SY : constant Element_Count := Row + R + DY;
                                             SX : constant Element_Count := Col + DX;
                                          begin
                                             Patches (At_Patch + Channel * 9 + DY * 3 + DX) :=
                                               (if SY < 1 or else SY > Height or else SX < 1 or else SX > Width
                                                then 0.0
                                                else Source (((SY - 1) * Width + (SX - 1)) * Ins + Channel));
                                          end;
                                       end loop;
                                    end loop;
                                 end loop;
                              end;
                           end loop;
                        end loop;
                        CPU.Dispatch_Batch (Pool, C.Kernel, Patches, Rows_Here * Width, Answers, Status);
                        Target (Row * Width * Outs .. (Row + Rows_Here) * Width * Outs - 1) :=
                          Answers (0 .. Rows_Here * Width * Outs - 1);
                        Row := Row + Rows_Here;
                     end;
                  end loop;
               end;
               T.Free (Patches);
               T.Free (Answers);
            end;
         end if;
         for Pixel in 0 .. Pixels - 1 loop
            for O in 0 .. Outs - 1 loop
               Target (Pixel * Outs + O) := Target (Pixel * Outs + O) + C.Bias (O);
            end loop;
         end loop;
      end Apply;

      --  Each pixel's channels by their root mean square and Gain, then
      --  SiLU where asked: Target := that of Source.
      procedure Norm (Source : T.Real_Array_Access; Channels : Element_Count; Gain : T.Real_Array_Access;
                      Target : in out T.Real_Array_Access; Silu : Boolean := True) is
      begin
         Room (Target, Height * Width * Channels);
         if E.Is_Error (Status) then
            return;
         end if;
         for Pixel in 0 .. Height * Width - 1 loop
            declare
               Square : Wide := 0.0;
               Base   : constant Element_Count := Pixel * Channels;
            begin
               for C in 0 .. Channels - 1 loop
                  Square := Square + Wide (Source (Base + C)) ** 2;
               end loop;
               declare
                  Inverse : constant Real := Real (1.0 / N.Sqrt (Square / Wide (Channels) + 1.0E-12));
               begin
                  for C in 0 .. Channels - 1 loop
                     declare
                        V : constant Real := Source (Base + C) * Inverse * Gain (C);
                     begin
                        Target (Base + C) :=
                          (if Silu then Real (Wide (V) / (1.0 + N.Exp (-Wide (V)))) else V);
                     end;
                  end loop;
               end;
            end;
         end loop;
      end Norm;

      --  X := the residual block of X: norm, SiLU, 3x3, the same again,
      --  and the input (through a 1x1 where the width changes) added.
      procedure Block (R : Residual) is
         Ins  : constant Element_Count := Element_Count (R.Conv_1.Inputs);
         Outs : constant Element_Count := Element_Count (R.Conv_1.Outputs);
         Kept : T.Real_Array_Access;
      begin
         Norm (X, Ins, R.Norm_1, Y);
         Apply (R.Conv_1, Y, Z);
         Norm (Z, Outs, R.Norm_2, Y);
         Apply (R.Conv_2, Y, Z);
         if E.Is_Error (Status) then
            return;
         end if;
         if R.Shortcut.Outputs > 0 then
            Apply (R.Shortcut, X, Kept);
            if E.Is_Ok (Status) then
               for I in 0 .. Height * Width * Outs - 1 loop
                  Z (I) := Z (I) + Kept (I);
               end loop;
            end if;
            T.Free (Kept);
         else
            for I in 0 .. Height * Width * Outs - 1 loop
               Z (I) := Z (I) + X (I);
            end loop;
         end if;
         Swap (X, Z);
      end Block;
   begin
      Picture := [others => 0.0];
      Status := E.Success;
      if not Item.Ready or else Latent'Length /= Element_Count (Latent_Channels) * Height * Width
        or else Picture'Length /= Element_Count (Picture_Channels) * Height * Width * Upscale * Upscale
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;

      --  The latent unnormalized, a pixel at a time.
      Room (X, Height * Width * Latent_Channels);
      if E.Is_Error (Status) then
         return;
      end if;
      for Channel in 0 .. Element_Count (Latent_Channels) - 1 loop
         for Pixel in 0 .. Height * Width - 1 loop
            X (Pixel * Latent_Channels + Channel) :=
              Latent (Latent'First + Channel * Height * Width + Pixel) * Deviations (Natural (Channel))
              + Means (Natural (Channel));
         end loop;
      end loop;
      Apply (Item.Post_Quant, X, Y);
      Apply (Item.Conv_In, Y, X);

      --  The mid block.
      Block (Item.Mid_1);
      if E.Is_Ok (Status) then
         declare
            C   : constant Element_Count := Element_Count (Widths (0));
            Job : aliased Attention_Work;
         begin
            Norm (X, C, Item.Attention_Norm, Y, Silu => False);
            Apply (Item.Joint, Y, Z);
            Room (Y, Height * Width * C);
            if E.Is_Ok (Status) then
               Job := (Joint => Z, Answer => Y, Positions => Height * Width, Width => C);
               CPU.Dispatch_Shares (Pool, Height * Width, Job'Unchecked_Access, Status,
                                    Cost => Height * Width * Height * Width * C);
            end if;
            declare
               Out_Rows : T.Real_Array_Access;
            begin
               Apply (Item.Attention_Out, Y, Out_Rows);
               if E.Is_Ok (Status) then
                  for I in 0 .. Height * Width * C - 1 loop
                     X (I) := X (I) + Out_Rows (I);
                  end loop;
               end if;
               T.Free (Out_Rows);
            end;
         end;
      end if;
      if E.Is_Ok (Status) then
         Block (Item.Mid_2);
      end if;

      --  The levels.
      for L in Item.Levels'Range loop
         exit when E.Is_Error (Status);
         declare
            Level_Of : Level renames Item.Levels (L);
            Ins      : constant Element_Count := Element_Count (Widths (L - 1));
            Outs     : constant Element_Count := Element_Count (Widths (L));
            Input    : T.Real_Array_Access;
         begin
            if Level_Of.Up.Outputs > 0 then
               Room (Input, Height * Width * Ins);
               if E.Is_Ok (Status) then
                  Input (0 .. Height * Width * Ins - 1) := X (0 .. Height * Width * Ins - 1);
               end if;
            end if;
            for R of Level_Of.Blocks loop
               exit when E.Is_Error (Status);
               Block (R);
            end loop;
            if Level_Of.Up.Outputs > 0 and then E.Is_Ok (Status) then
               --  Doubled, nearest; then its 3x3.
               Room (Y, 4 * Height * Width * Outs);
               if E.Is_Ok (Status) then
                  for Row in 0 .. 2 * Height - 1 loop
                     for Col in 0 .. 2 * Width - 1 loop
                        Y ((Row * 2 * Width + Col) * Outs .. (Row * 2 * Width + Col) * Outs + Outs - 1) :=
                          X (((Row / 2) * Width + Col / 2) * Outs .. ((Row / 2) * Width + Col / 2) * Outs + Outs - 1);
                     end loop;
                  end loop;
               end if;
               declare
                  Narrow_Width  : constant Element_Count := Width;
                  Factor        : constant Element_Count := Element_Count (Level_Of.Temporal) * 4;
                  Repeats       : constant Element_Count := Outs * Factor / Ins;
               begin
                  Height := 2 * Height;
                  Width := 2 * Width;
                  Apply (Level_Of.Up, Y, X);
                  --  The shortcut: the level's input, its channels repeated
                  --  and laid out into the 2x2 pixels -- and, with a temporal
                  --  factor of two, into the second of two frames, which is
                  --  the one a single frame keeps.
                  if E.Is_Ok (Status) then
                     for Row in 0 .. Height - 1 loop
                        for Col in 0 .. Width - 1 loop
                           declare
                              Sub : constant Element_Count :=
                                (Element_Count (Level_Of.Temporal) - 1) * 4 + (Row rem 2) * 2 + (Col rem 2);
                              From : constant Element_Count := ((Row / 2) * Narrow_Width + Col / 2) * Ins;
                              Into : constant Element_Count := (Row * Width + Col) * Outs;
                           begin
                              for C in 0 .. Outs - 1 loop
                                 X (Into + C) := X (Into + C) + Input (From + (C * Factor + Sub) / Repeats);
                              end loop;
                           end;
                        end loop;
                     end loop;
                  end if;
               end;
            end if;
            T.Free (Input);
         end;
      end loop;

      --  The head: norm, SiLU, conv_out; the planes out.
      if E.Is_Ok (Status) then
         Norm (X, Element_Count (Widths (5)), Item.Norm_Out, Y);
         Apply (Item.Conv_Out, Y, Z);
      end if;
      if E.Is_Ok (Status) then
         for Pixel in 0 .. Height * Width - 1 loop
            for C in 0 .. Element_Count (Picture_Channels) - 1 loop
               Picture (Picture'First + C * Height * Width + Pixel) := Z (Pixel * Picture_Channels + C);
            end loop;
         end loop;
      end if;
      T.Free (X);
      T.Free (Y);
      T.Free (Z);
   end Decode;

end Model_Runner.Qwen_Image.Decoder;
