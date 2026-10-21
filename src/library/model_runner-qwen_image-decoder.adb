with System.Storage_Elements;

with Model_Runner.Backend.Device;
with Model_Runner.GGUF;
with Model_Runner.Kernels;
with Model_Runner.Platform.Device.Products;
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
         if E.Is_Error (Status) then
            return;
         end if;
         Vector (Name & ".bias", Outputs, Result.Bias);

         --  Laid out again, tap after tap, and padded to the multiples of
         --  32, where it is a 3x3 or its rows fall short of one.
         declare
            Taps      : constant Element_Count := Element_Count (Size * Size);
            Ins       : constant Element_Count := Element_Count (Inputs);
            Rows_To   : constant Element_Count := (Element_Count (Outputs) + 31) / 32 * 32;
            --  A 1x1 reads the pixels as they lie, so its columns stay.
            Across    : constant Element_Count := (if Size = 1 then Columns else (Columns + 31) / 32 * 32);
            Element   : constant B.Byte_Count := T.Row_Bytes (Result.Kernel) / B.Byte_Count (Columns);
            Row_From  : constant B.Byte_Count := T.Row_Bytes (Result.Kernel);
            Row_To    : constant B.Byte_Count := B.Byte_Count (Across) * Element;
            Start     : constant B.Byte_Count :=
              S.Info (Item.Table, Index).Data_Offset - S.Data_Start (Item.Table);
            From      : B.Byte_Array (0 .. Row_From * B.Byte_Count (Outputs) - 1)
              with Import, Address => System.Storage_Elements.To_Address
                (System.Storage_Elements.To_Integer (Item.Base) + System.Storage_Elements.Integer_Address (Start));
         begin
            if (Size = 1 and then Rows_To = Element_Count (Outputs))
              or else Row_From /= B.Byte_Count (Columns) * Element
            then
               return;
            end if;
            B.Allocate (B.Byte_Count (Rows_To) * Row_To, Result.Owned);
            if Result.Owned = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
            for O in 0 .. B.Byte_Count (Outputs) - 1 loop
               for Channel in 0 .. B.Byte_Count (Ins) - 1 loop
                  for Tap in 0 .. B.Byte_Count (Taps) - 1 loop
                     declare
                        Here  : constant B.Byte_Count := O * Row_From + (Channel * B.Byte_Count (Taps) + Tap) * Element;
                        There : constant B.Byte_Count :=
                          Result.Owned'First + O * Row_To + (Tap * B.Byte_Count (Ins) + Channel) * Element;
                     begin
                        Result.Owned (There .. There + Element - 1) := From (Here .. Here + Element - 1);
                     end;
                  end loop;
               end loop;
            end loop;
            T.Make (Result.Kernel.Format, Rows_To, Across, Result.Owned, 0, Result.Kernel, Status);

            --  A 3x3's taps apart, for the device.
            if Size = 3 and then E.Is_Ok (Status) then
               declare
                  Ins_To    : constant Element_Count := (Ins + 31) / 32 * 32;
                  Tap_Bytes : constant B.Byte_Count := B.Byte_Count (Rows_To * Ins_To) * Element;
               begin
                  B.Allocate (Tap_Bytes * B.Byte_Count (Taps), Result.Tap_Owned);
                  if Result.Tap_Owned = null then
                     Status := E.Make (E.Memory_Allocation_Failed);
                     return;
                  end if;
                  for O in 0 .. B.Byte_Count (Outputs) - 1 loop
                     for Channel in 0 .. B.Byte_Count (Ins) - 1 loop
                        for Tap in 0 .. B.Byte_Count (Taps) - 1 loop
                           declare
                              Here  : constant B.Byte_Count :=
                                O * Row_From + (Channel * B.Byte_Count (Taps) + Tap) * Element;
                              There : constant B.Byte_Count :=
                                Result.Tap_Owned'First + Tap * Tap_Bytes
                                + (O * B.Byte_Count (Ins_To) + Channel) * Element;
                           begin
                              Result.Tap_Owned (There .. There + Element - 1) := From (Here .. Here + Element - 1);
                           end;
                        end loop;
                     end loop;
                  end loop;
                  for Tap in Result.Taps'Range loop
                     exit when E.Is_Error (Status);
                     T.Make (Result.Kernel.Format, Rows_To, Ins_To, Result.Tap_Owned, B.Byte_Count (Tap) * Tap_Bytes,
                             Result.Taps (Tap), Status);
                  end loop;
               end;
            end if;
         end;
      end Convolve;

      --  C's Fit, out of the gain of the norm before it.
      procedure Fit (Gain : T.Real_Array_Access; C : in out Convolution) is
      begin
         if E.Is_Error (Status) or else Gain = null or else C.Tap_Owned = null then
            return;
         end if;
         declare
            Ins    : constant Element_Count := Element_Count (C.Inputs);
            Ins_To : constant Element_Count := C.Taps (0).Columns;
            Root   : constant Real := Real (N.Sqrt (Wide (Ins) / Wide (Ins_To)));
         begin
            T.Allocate (Ins_To, C.Fit);
            if C.Fit = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
            for I in 0 .. Ins_To - 1 loop
               C.Fit (I) := (if I < Ins then Gain (Gain'First + I) * Root else 0.0);
            end loop;
         end;
      end Fit;

      procedure Residual_Of (Name : String; Inputs, Outputs : Positive; Result : out Residual) is
      begin
         Vector (Name & ".norm1.gamma", Inputs, Result.Norm_1);
         Convolve (Name & ".conv1", Inputs, Outputs, 3, Result.Conv_1);
         Fit (Result.Norm_1, Result.Conv_1);
         Vector (Name & ".norm2.gamma", Outputs, Result.Norm_2);
         Convolve (Name & ".conv2", Outputs, Outputs, 3, Result.Conv_2);
         Fit (Result.Norm_2, Result.Conv_2);
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
      Fit (Item.Norm_Out, Item.Conv_Out);
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
         B.Free (C.Owned);
         B.Free (C.Tap_Owned);
         T.Free (C.Fit);
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
      --  The device remembers a matrix by where its bytes lie, and these
      --  are about to go.
      Model_Runner.Backend.Device.Forget_Matrices;
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

   --  Each row of scores, Positions of Across, turned into the attention's
   --  weights in place: scaled, less the row's most, exponentiated and
   --  divided by their sum, the padding past Positions left nought.
   type Softmax_Work is new Model_Runner.Shares.Work with record
      Scores    : T.Real_Array_Access;
      Positions, Across : Element_Count := 0;
      Scale     : Real := 1.0;
   end record;

   overriding procedure Run (Item : in out Softmax_Work; First : Element_Count; Last : Element_Count) is
   begin
      for Row in First .. Last loop
         declare
            Base  : constant Element_Count := Row * Item.Across;
            Most  : Real := Real'First;
            Total : Real := 0.0;
         begin
            for Key in 0 .. Item.Positions - 1 loop
               Item.Scores (Base + Key) := Item.Scores (Base + Key) * Item.Scale;
               Most := Real'Max (Most, Item.Scores (Base + Key));
            end loop;
            for Key in 0 .. Item.Positions - 1 loop
               Item.Scores (Base + Key) := Real (N.Exp (Wide (Item.Scores (Base + Key) - Most)));
               Total := Total + Item.Scores (Base + Key);
            end loop;
            for Key in 0 .. Item.Positions - 1 loop
               Item.Scores (Base + Key) := Item.Scores (Base + Key) / Total;
            end loop;
            for Key in Item.Positions .. Item.Across - 1 loop
               Item.Scores (Base + Key) := 0.0;
            end loop;
         end;
      end loop;
   end Run;

   --  A decode's work between its products, a share at a time: a band's
   --  pixels' 3x3 neighbourhoods gathered, a tap's channels together and
   --  zero past the edges; or pixels' channels normalized by their root
   --  mean square and a gain, SiLU after where asked; or a product's
   --  answers put in their pixels, a bias added and the padding dropped;
   --  or Source's pixels added to Target's; or Source doubled into
   --  Target, nearest; or a level's input added to its doubled pixels as
   --  the shortcut, as Decode says.
   --  Or, for the device's 3x3, a band's rows laid out padded: a pixel of
   --  zeros either side of each row and a row of them above and below, each
   --  pixel's channels padded to Across with zeros.
   type Pixel_Kind is (Gather_Rows, Norm_Pixels, Put_Answers, Add_Pixels, Double_Pixels, Shortcut_Pixels, Pad_Rows);

   type Pixel_Work is new Model_Runner.Shares.Work with record
      Kind            : Pixel_Kind := Gather_Rows;
      Source, Target  : T.Real_Array_Access;
      Gain            : T.Real_Array_Access;
      Silu            : Boolean := True;
      --  The band's first row (its first pixel, putting), the picture's
      --  height and width, the channels read or put, and how far apart two
      --  pixels' neighbourhoods or answers lie.
      Row, Height, Width, Channels, Across : Element_Count := 0;
      --  The shortcut's: the level's input channels, the doubled pixels'
      --  channel count each input channel's value repeats over, and which
      --  of the 2x2 frames' subpixels a single frame keeps.
      Inputs, Factor, Repeats, Frame : Element_Count := 0;
      --  Putting answers laid out a padded row at a time: how many pixels
      --  a row of them holds; nought for answers a pixel after another.
      Padded : Element_Count := 0;
   end record;

   overriding procedure Run (Item : in out Pixel_Work; First : Element_Count; Last : Element_Count) is
      Ins : constant Element_Count := Item.Channels;

      --  A pixel's channels from Source at From into Target at Into, by
      --  their root mean square and the gain, SiLU after where asked -- in
      --  binary32 through the kernels' own exponential, as a language
      --  model's gate takes it: in binary64 through the library's it was
      --  most of a 1024 picture's 2.9 s of norms.
      procedure Norm_Into (From, Into : Element_Count) is
         Square : Wide := 0.0;
      begin
         for C in 0 .. Ins - 1 loop
            Square := Square + Wide (Item.Source (From + C)) ** 2;
         end loop;
         declare
            Inverse : constant Real := Real (1.0 / N.Sqrt (Square / Wide (Ins) + 1.0E-12));
         begin
            for C in 0 .. Ins - 1 loop
               Item.Target (Into + C) := Item.Source (From + C) * Inverse * Item.Gain (C);
            end loop;
         end;
         if Item.Silu then
            Model_Runner.Kernels.SiLU (Item.Target (Into .. Into + Ins - 1));
         end if;
      end Norm_Into;
   begin
      case Item.Kind is
         when Gather_Rows =>
            --  First .. Last count the band's pixels; what lies past the
            --  nine taps in a neighbourhood stays the zero it was given.
            for Pixel in First .. Last loop
               declare
                  At_Patch : constant Element_Count := Pixel * Item.Across;
                  Y        : constant Element_Count := Item.Row + Pixel / Item.Width;
                  X        : constant Element_Count := Pixel rem Item.Width;
               begin
                  for DY in Element_Count range 0 .. 2 loop
                     for DX in Element_Count range 0 .. 2 loop
                        declare
                           Into : constant Element_Count := At_Patch + (DY * 3 + DX) * Ins;
                        begin
                           --  The tap's pixel, one up or left of Y + DY, X + DX.
                           if Y + DY < 1 or else Y + DY > Item.Height or else X + DX < 1 or else X + DX > Item.Width
                           then
                              Item.Target (Into .. Into + Ins - 1) := [others => 0.0];
                           else
                              declare
                                 From : constant Element_Count := ((Y + DY - 1) * Item.Width + X + DX - 1) * Ins;
                              begin
                                 Item.Target (Into .. Into + Ins - 1) := Item.Source (From .. From + Ins - 1);
                              end;
                           end if;
                        end;
                     end loop;
                  end loop;
               end;
            end loop;
         when Pad_Rows =>
            --  First .. Last count the padded band's pixels, Width + 2 a
            --  row, the first row the one above the band's first.
            for Pixel in First .. Last loop
               declare
                  Y    : constant Element_Count := Item.Row + Pixel / (Item.Width + 2);
                  X    : constant Element_Count := Pixel rem (Item.Width + 2);
                  Into : constant Element_Count := Pixel * Item.Across;
               begin
                  if Y < 1 or else Y > Item.Height or else X < 1 or else X > Item.Width then
                     Item.Target (Into .. Into + Item.Across - 1) := [others => 0.0];
                  else
                     declare
                        From : constant Element_Count := ((Y - 1) * Item.Width + X - 1) * Ins;
                     begin
                        if Item.Gain /= null then
                           Norm_Into (From, Into);
                        else
                           Item.Target (Into .. Into + Ins - 1) := Item.Source (From .. From + Ins - 1);
                        end if;
                        Item.Target (Into + Ins .. Into + Item.Across - 1) := [others => 0.0];
                     end;
                  end if;
               end;
            end loop;
         when Add_Pixels =>
            for I in First * Ins .. (Last + 1) * Ins - 1 loop
               Item.Target (I) := Item.Target (I) + Item.Source (I);
            end loop;
         when Double_Pixels =>
            --  First .. Last count the doubled pixels; Width is the narrow
            --  picture's.
            for Pixel in First .. Last loop
               declare
                  Into : constant Element_Count := Pixel * Ins;
                  From : constant Element_Count :=
                    ((Pixel / (2 * Item.Width) / 2) * Item.Width + Pixel rem (2 * Item.Width) / 2) * Ins;
               begin
                  Item.Target (Into .. Into + Ins - 1) := Item.Source (From .. From + Ins - 1);
               end;
            end loop;
         when Shortcut_Pixels =>
            for Pixel in First .. Last loop
               declare
                  Row  : constant Element_Count := Pixel / (2 * Item.Width);
                  Col  : constant Element_Count := Pixel rem (2 * Item.Width);
                  Sub  : constant Element_Count := Item.Frame * 4 + (Row rem 2) * 2 + (Col rem 2);
                  From : constant Element_Count := ((Row / 2) * Item.Width + Col / 2) * Item.Inputs;
                  Into : constant Element_Count := Pixel * Ins;
               begin
                  for C in 0 .. Ins - 1 loop
                     Item.Target (Into + C) :=
                       Item.Target (Into + C) + Item.Source (From + (C * Item.Factor + Sub) / Item.Repeats);
                  end loop;
               end;
            end loop;
         when Put_Answers =>
            for Pixel in First .. Last loop
               declare
                  From : constant Element_Count :=
                    (if Item.Padded > 0 then (Pixel / Item.Width) * Item.Padded + Pixel rem Item.Width else Pixel)
                    * Item.Across;
                  Into : constant Element_Count := (Item.Row + Pixel) * Ins;
                  Answer : N.Real_Array renames Item.Source (From .. From + Ins - 1);
                  Put_In : N.Real_Array renames Item.Target (Into .. Into + Ins - 1);
                  Bias   : N.Real_Array renames Item.Gain (Item.Gain'First .. Item.Gain'First + Ins - 1);
               begin
                  for C in 0 .. Ins - 1 loop
                     Put_In (Into + C) := Answer (From + C) + Bias (Item.Gain'First + C);
                  end loop;
               end;
            end loop;
         when Norm_Pixels =>
            for Pixel in First .. Last loop
               Norm_Into (Pixel * Ins, Pixel * Ins);
            end loop;
      end case;
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
      X, Y, Z, V : T.Real_Array_Access;

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

      package Device renames Model_Runner.Backend.Device;
      On_Device : constant Boolean := Device.Is_Ready;

      --  How many pixels one device product takes, and the room they are
      --  copied through. A 3x3's band of rows is cut to it, so a product
      --  takes its gathered patches as they lie. A 512 picture decoded in
      --  7.5 to 7.9 s at 1,024 and 7.9 to 8.5 at 4,096, whose patches lie
      --  past the caches.
      Device_Rows : constant Element_Count := 1_024;
      Chunk_In, Chunk_Out : T.Real_Array_Access;

      --  How many pixels a 3x3's band holds on the device, its padding
      --  included: the band goes over once, not nine times.
      Tap_Rows : constant Element_Count := 4_096;
      Tap_Answers : constant Element_Count := 4_194_304;

      --  Target := Weight times each of Count vectors: on the device where
      --  one is open, as they lie where they are one chunk and a chunk at a
      --  time otherwise; across the pool where none is.
      procedure Product
        (Weight : T.View; Vectors : T.Real_Array_Access; Count : Element_Count; Target : T.Real_Array_Access) is
      begin
         if E.Is_Error (Status) then
            return;
         elsif not On_Device then
            CPU.Dispatch_Batch (Pool, Weight, Vectors, Count, Target, Status);
            return;
         elsif Count <= Device_Rows then
            Device.Dispatch_Batch (Weight, Vectors, Count, Target, Status);
            return;
         end if;
         declare
            From : Element_Count := 0;
            Ins  : constant Element_Count := Weight.Columns;
            Outs : constant Element_Count := Weight.Rows;
         begin
            while From < Count and then E.Is_Ok (Status) loop
               declare
                  Take : constant Element_Count := Element_Count'Min (Device_Rows, Count - From);
               begin
                  if Chunk_In = null or else Chunk_In'Length < Take * Ins then
                     T.Free (Chunk_In);
                     T.Allocate (Device_Rows * Ins, Chunk_In);
                  end if;
                  if Chunk_Out = null or else Chunk_Out'Length < Take * Outs then
                     T.Free (Chunk_Out);
                     T.Allocate (Device_Rows * Outs, Chunk_Out);
                  end if;
                  Chunk_In (0 .. Take * Ins - 1) := Vectors (From * Ins .. (From + Take) * Ins - 1);
                  Device.Dispatch_Batch (Weight, Chunk_In, Take, Chunk_Out, Status);
                  if E.Is_Ok (Status) then
                     Target (From * Outs .. (From + Take) * Outs - 1) := Chunk_Out (0 .. Take * Outs - 1);
                  end if;
                  From := From + Take;
               end;
            end loop;
         end;
      end Product;

      --  Target := C, a 3x3, applied to Source's pixels on the device, a
      --  band of rows at a time -- each pixel normed by Gain first, SiLU
      --  after, where Gain is given: the band laid out padded -- a pixel of
      --  zeros either side, a row above and below -- and sent over once;
      --  each tap a product reading it shifted, Width + 2 pixels to a row
      --  down and one to a column across, and the nine summed on the
      --  device as they are made; the answers in the padding columns
      --  dropped as they are put.
      procedure Apply_Taps
        (C : Convolution; Source : T.Real_Array_Access; Target : T.Real_Array_Access;
         Gain : T.Real_Array_Access := null) is
         package P renames Model_Runner.Platform.Device.Products;
         Ins     : constant Element_Count := Element_Count (C.Inputs);
         Outs    : constant Element_Count := Element_Count (C.Outputs);
         Ins_To  : constant Element_Count := C.Taps (0).Columns;
         Fitted  : constant Element_Count := C.Taps (0).Rows;
         Wide    : constant Element_Count := Width + 2;
         Band    : constant Element_Count :=
           Element_Count'Max (1, Element_Count'Min (Height, Element_Count'Max (Tap_Rows, Tap_Answers / Fitted) / Wide));
         Row     : Element_Count := 0;
         --  Whether the norm is the device's, ahead of the taps.
         On_Device_Norm : constant Boolean := Gain /= null and then C.Fit /= null;
      begin
         --  The band is laid out straight into the device's own memory and
         --  the answers put from where the device left them: neither goes
         --  through a copy on one core.
         while Row < Height and then E.Is_Ok (Status) loop
            declare
               Rows_Here : constant Element_Count := Element_Count'Min (Band, Height - Row);
               Count     : constant Element_Count := Rows_Here * Wide - 2;
               Values    : constant Element_Count := (Rows_Here + 2) * Wide * Ins_To;
               Room_At   : System.Address;
               Ok        : Boolean;
               Steps     : P.Sequence;
               Added     : Boolean := True;
               Sum       : Natural := 0;
            begin
               Device.Activation_Room (Values, Room_At, Ok);
               if not Ok then
                  Status := E.Make (E.Backend_Capability_Missing);
                  return;
               end if;
               declare
                  Padded : aliased N.Real_Array (0 .. Values - 1) with Import, Address => Room_At;
                  Lay    : aliased Pixel_Work :=
                    (Kind => Pad_Rows, Source => Source, Target => Padded'Unrestricted_Access,
                     Gain => (if On_Device_Norm then null else Gain), Silu => True, Row => Row, Height => Height,
                     Width => Width, Channels => Ins, Across => Ins_To, others => 0);
               begin
                  CPU.Dispatch_Shares (Pool, (Rows_Here + 2) * Wide, Lay'Unchecked_Access, Status,
                                       Cost => (Rows_Here + 2) * Wide * Ins_To);
                  --  The band normed and its SiLU taken on the device, where
                  --  the gain is fitted for it, and left there for the taps:
                  --  a pixel of zeros stays zeros.
                  if On_Device_Norm and then E.Is_Ok (Status) then
                     declare
                        First : P.Sequence;
                     begin
                        P.Open_Sequence (First);
                        P.Add_Norm (First, C.Fit.all'Address, B.Byte_Count (Ins_To) * 4, 0, Natural (Ins_To),
                                    1.0E-12, Added, Key => C.Fit.all'Address, Kept => False);
                        if Added then
                           P.Add_Combination (First, 4, Added, Kept => False);
                        end if;
                        if Added then
                           Device.Run_Steps (First, Padded, Positive ((Rows_Here + 2) * Wide), System.Null_Address,
                                             Status, Carry_In => True, Carry_Out => True);
                        else
                           Status := E.Make (E.Backend_Capability_Missing);
                        end if;
                     end;
                  end if;
                  P.Open_Sequence (Steps);
                  for Tap in C.Taps'Range loop
                     exit when not Added;
                     Device.Add_View_Product_At
                       (Steps, C.Taps (Tap),
                        Natural ((Element_Count (Tap / 3) * Wide + Element_Count (Tap rem 3)) * Ins_To), Added);
                     if Added and then Tap > 0 then
                        P.Add_Join (Steps, Added, From_Step => P.Length (Steps), Residual_Step => Sum,
                                    Kept => Tap = C.Taps'Last);
                     end if;
                     Sum := P.Length (Steps);
                  end loop;
                  if not Added then
                     Status := E.Make (E.Backend_Capability_Missing);
                  elsif E.Is_Ok (Status) then
                     Device.Run_Steps (Steps, Padded, Positive (Count), System.Null_Address, Status, In_Place => True);
                  end if;
               end;
               if E.Is_Ok (Status) and then Device.Kept_Answer = System.Null_Address then
                  Status := E.Make (E.Backend_Capability_Missing);
               end if;
               if E.Is_Ok (Status) then
                  declare
                     Answers : aliased N.Real_Array (0 .. Count * Fitted - 1)
                       with Import, Address => Device.Kept_Answer;
                     Put     : aliased Pixel_Work :=
                       (Kind => Put_Answers, Source => Answers'Unrestricted_Access, Target => Target,
                        Gain => C.Bias, Silu => False, Row => Row * Width, Height => Height, Width => Width,
                        Channels => Outs, Across => Fitted, Padded => Wide, others => 0);
                  begin
                     CPU.Dispatch_Shares (Pool, Rows_Here * Width, Put'Unchecked_Access, Status,
                                          Cost => Rows_Here * Width * Outs);
                  end;
               end if;
               Row := Row + Rows_Here;
            end;
         end loop;
      end Apply_Taps;

      --  Target := C applied to Source's Height by Width pixels: a 1x1 as a
      --  product, a 3x3 as a product over each pixel's neighbourhood,
      --  gathered a band of rows at a time, zero past the edges; the bias
      --  added and the padding's channels dropped as the answers are put.
      procedure Apply (C : Convolution; Source : T.Real_Array_Access; Target : in out T.Real_Array_Access) is
         Pixels : constant Element_Count := Height * Width;
         Outs   : constant Element_Count := Element_Count (C.Outputs);
         Ins    : constant Element_Count := Element_Count (C.Inputs);
         --  The kernel's rows and columns, padded.
         Fitted : constant Element_Count := C.Kernel.Rows;
         Across : constant Element_Count := C.Kernel.Columns;
         Answers : T.Real_Array_Access;

         --  Target's pixels First .. First + Count - 1 := Answers' first
         --  Count, their bias added.
         procedure Put (First, Count : Element_Count) is
            Job : aliased Pixel_Work :=
              (Kind => Put_Answers, Source => Answers, Target => Target, Gain => C.Bias, Silu => False,
               Row => First, Height => Height, Width => Width, Channels => Outs, Across => Fitted, others => 0);
         begin
            if E.Is_Ok (Status) then
               CPU.Dispatch_Shares (Pool, Count, Job'Unchecked_Access, Status, Cost => Count * Outs);
            end if;
         end Put;
      begin
         Room (Target, Pixels * Outs);
         if E.Is_Error (Status) then
            return;
         end if;
         if C.Size = 1 then
            if Fitted = Outs then
               Answers := Target;
               Product (C.Kernel, Source, Pixels, Target);
               Put (0, Pixels);
               return;
            end if;
            T.Allocate (Pixels * Fitted, Answers);
            if Answers = null then
               Status := E.Make (E.Memory_Allocation_Failed);
               return;
            end if;
            Product (C.Kernel, Source, Pixels, Answers);
            Put (0, Pixels);
            T.Free (Answers);
            return;
         end if;
         if On_Device and then C.Tap_Owned /= null then
            Apply_Taps (C, Source, Target);
            return;
         end if;
         declare
            --  A band of rows: what one device product takes, or on the
            --  processor patches of about 64 MB.
            Band  : constant Element_Count :=
              Element_Count'Max
                (1, Element_Count'Min
                   (Height, (if On_Device then Device_Rows / Width else 16_777_216 / (Across * Width))));
            Patches : T.Real_Array_Access;
         begin
            T.Allocate (Band * Width * Across, Patches);
            T.Allocate (Band * Width * Fitted, Answers);
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
                     Job       : aliased Pixel_Work :=
                       (Kind => Gather_Rows, Source => Source, Target => Patches, Gain => null, Silu => False,
                        Row => Row, Height => Height, Width => Width, Channels => Ins, Across => Across, others => 0);
                  begin
                              CPU.Dispatch_Shares (Pool, Rows_Here * Width, Job'Unchecked_Access, Status,
                                          Cost => Rows_Here * Width * Across);
                     Product (C.Kernel, Patches, Rows_Here * Width, Answers);
                     Put (Row * Width, Rows_Here * Width);
                     Row := Row + Rows_Here;
                  end;
               end loop;
            end;
            T.Free (Patches);
            T.Free (Answers);
         end;
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
         declare
            Job : aliased Pixel_Work :=
              (Kind => Norm_Pixels, Source => Source, Target => Target, Gain => Gain, Silu => Silu, Row => 0,
               Height => Height, Width => Width, Channels => Channels, others => 0);
         begin
            CPU.Dispatch_Shares (Pool, Height * Width, Job'Unchecked_Access, Status, Cost => Height * Width * Channels);
         end;
      end Norm;

      --  Target's pixels plus Source's, Channels each, across the pool.
      procedure Add (Target, Source : T.Real_Array_Access; Channels : Element_Count) is
         Job : aliased Pixel_Work :=
           (Kind => Add_Pixels, Source => Source, Target => Target, Gain => null, Silu => False, Row => 0,
            Height => Height, Width => Width, Channels => Channels, others => 0);
      begin
         if E.Is_Ok (Status) then
            CPU.Dispatch_Shares (Pool, Height * Width, Job'Unchecked_Access, Status, Cost => Height * Width * Channels);
         end if;
      end Add;

      --  Answer := the mid block's attention over Joint's Positions rows of
      --  queries, keys and values, C each, as two products on the device:
      --  the scores, every query against the keys laid out as a matrix of
      --  halves, and the answer, the weights against the values laid out
      --  transposed -- each matrix's rows padded with zeros to the 32 the
      --  device's tile takes, the padding's scores dropped. The softmax
      --  between them across the pool; both matrices given back after.
      procedure Attend_On_Device (Joint, Answer : T.Real_Array_Access; Positions, C : Element_Count) is
         Across  : constant Element_Count := (Positions + 31) / 32 * 32;
         Keys_Of, Values_Of : B.Byte_Array_Access;
         Keys, Values : T.View;
         Queries, Scores : T.Real_Array_Access;
      begin
         B.Allocate (B.Byte_Count (Across * C * 2), Keys_Of);
         B.Allocate (B.Byte_Count (C * Across * 2), Values_Of);
         T.Allocate (Positions * C, Queries);
         T.Allocate (Positions * Across, Scores);
         if Keys_Of = null or else Values_Of = null or else Queries = null or else Scores = null then
            Status := E.Make (E.Memory_Allocation_Failed);
         else
            declare
               Key_Halves   : N.Half_Array (0 .. Across * C - 1) with Import, Address => Keys_Of.all'Address;
               Value_Halves : N.Half_Array (0 .. C * Across - 1) with Import, Address => Values_Of.all'Address;
               Row          : N.Real_Array (0 .. Across - 1);
               Halves       : N.Half_Array (0 .. Across - 1);
               Zeros        : N.Half_Array (0 .. C - 1);
            begin
               Model_Runner.Kernels.To_Halves ([for I in 0 .. C - 1 => 0.0], Zeros);
               for P in 0 .. Positions - 1 loop
                  Queries (P * C .. P * C + C - 1) := Joint (P * 3 * C .. P * 3 * C + C - 1);
                  Model_Runner.Kernels.To_Halves
                    (Joint (P * 3 * C + C .. P * 3 * C + 2 * C - 1), Key_Halves (P * C .. P * C + C - 1));
               end loop;
               for P in Positions .. Across - 1 loop
                  Key_Halves (P * C .. P * C + C - 1) := Zeros;
               end loop;
               for Channel in 0 .. C - 1 loop
                  Row := [others => 0.0];
                  for P in 0 .. Positions - 1 loop
                     Row (P) := Joint (P * 3 * C + 2 * C + Channel);
                  end loop;
                  Model_Runner.Kernels.To_Halves (Row, Halves);
                  Value_Halves (Channel * Across .. Channel * Across + Across - 1) := Halves;
               end loop;
            end;
            T.Make (Model_Runner.GGUF.Type_F16, Across, C, Keys_Of, 0, Keys, Status);
            if E.Is_Ok (Status) then
               T.Make (Model_Runner.GGUF.Type_F16, C, Across, Values_Of, 0, Values, Status);
            end if;
            Product (Keys, Queries, Positions, Scores);
            if E.Is_Ok (Status) then
               declare
                  Job : aliased Softmax_Work :=
                    (Scores => Scores, Positions => Positions, Across => Across,
                     Scale => Real (1.0 / N.Sqrt (Wide (C))));
               begin
                  CPU.Dispatch_Shares (Pool, Positions, Job'Unchecked_Access, Status, Cost => Positions * Across * 4);
               end;
            end if;
            Product (Values, Scores, Positions, Answer);
            Device.Forget (Keys);
            Device.Forget (Values);
         end if;
         B.Free (Keys_Of);
         B.Free (Values_Of);
         T.Free (Queries);
         T.Free (Scores);
      end Attend_On_Device;

      --  Target := C applied to Source's pixels normed by Gain, SiLU
      --  after: on the device the norm made as each band is laid out, which
      --  is the one pass over the pixels rather than two; here into Y
      --  first. Source, Target and Y are three buffers.
      procedure Normed_Apply
        (C : Convolution; Source : T.Real_Array_Access; Channels : Element_Count; Gain : T.Real_Array_Access;
         Target : in out T.Real_Array_Access) is
      begin
         if On_Device and then C.Tap_Owned /= null then
            Room (Target, Height * Width * Element_Count (C.Outputs));
            if E.Is_Ok (Status) then
               Apply_Taps (C, Source, Target, Gain);
            end if;
         else
            Norm (Source, Channels, Gain, Y);
            Apply (C, Y, Target);
         end if;
      end Normed_Apply;

      --  X := the residual block of X: norm, SiLU, 3x3, the same again,
      --  and the input (through a 1x1 where the width changes) added.
      procedure Block (R : Residual) is
         Ins  : constant Element_Count := Element_Count (R.Conv_1.Inputs);
         Outs : constant Element_Count := Element_Count (R.Conv_1.Outputs);
         Kept : T.Real_Array_Access;
      begin
         Normed_Apply (R.Conv_1, X, Ins, R.Norm_1, Z);
         Normed_Apply (R.Conv_2, Z, Outs, R.Norm_2, V);
         if E.Is_Error (Status) then
            return;
         end if;
         if R.Shortcut.Outputs > 0 then
            Apply (R.Shortcut, X, Kept);
            Add (V, Kept, Outs);
            T.Free (Kept);
         else
            Add (V, X, Outs);
         end if;
         Swap (X, V);
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
            if E.Is_Ok (Status) and then On_Device then
               Attend_On_Device (Z, Y, Height * Width, C);
            elsif E.Is_Ok (Status) then
               Job := (Joint => Z, Answer => Y, Positions => Height * Width, Width => C);
                  CPU.Dispatch_Shares (Pool, Height * Width, Job'Unchecked_Access, Status,
                                    Cost => Height * Width * Height * Width * C);
            end if;
            declare
               Out_Rows : T.Real_Array_Access;
            begin
               Apply (Item.Attention_Out, Y, Out_Rows);
               Add (X, Out_Rows, C);
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
               declare
                  Job : aliased Pixel_Work :=
                    (Kind => Double_Pixels, Source => X, Target => Y, Gain => null, Silu => False, Row => 0,
                     Height => Height, Width => Width, Channels => Outs, others => 0);
               begin
                  if E.Is_Ok (Status) then
                     CPU.Dispatch_Shares (Pool, 4 * Height * Width, Job'Unchecked_Access, Status,
                                          Cost => 4 * Height * Width * Outs);
                  end if;
               end;
               declare
                  Factor : constant Element_Count := Element_Count (Level_Of.Temporal) * 4;
                  --  The shortcut: the level's input, its channels repeated
                  --  and laid out into the 2x2 pixels -- and, with a temporal
                  --  factor of two, into the second of two frames, which is
                  --  the one a single frame keeps.
                  Job    : aliased Pixel_Work :=
                    (Kind => Shortcut_Pixels, Source => Input, Target => X, Gain => null, Silu => False, Row => 0,
                     Height => 2 * Height, Width => Width, Channels => Outs, Across => 0, Inputs => Ins,
                     Factor => Factor, Repeats => Outs * Factor / Ins,
                     Frame => Element_Count (Level_Of.Temporal) - 1, Padded => 0);
               begin
                  Height := 2 * Height;
                  Width := 2 * Width;
                  Apply (Level_Of.Up, Y, X);
                  Job.Target := X;
                  if E.Is_Ok (Status) then
                     CPU.Dispatch_Shares (Pool, Height * Width, Job'Unchecked_Access, Status,
                                          Cost => Height * Width * Outs);
                  end if;
               end;
            end if;
            T.Free (Input);
         end;
      end loop;

      --  The head: norm, SiLU, conv_out; the planes out.
      if E.Is_Ok (Status) then
         Normed_Apply (Item.Conv_Out, X, Element_Count (Widths (5)), Item.Norm_Out, Z);
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
      T.Free (V);
      T.Free (Chunk_In);
      T.Free (Chunk_Out);
   end Decode;

end Model_Runner.Qwen_Image.Decoder;
