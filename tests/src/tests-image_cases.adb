with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Hash;
with Ada.Unchecked_Conversion;
with Interfaces;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Philox;
with Model_Runner.PNG_Writer;
with Model_Runner.Images;
with Model_Runner.Qwen_Image;
with Model_Runner.Qwen_Image.Prompts;
with Model_Runner.Qwen_Image.Decoder;
with Model_Runner.Tensors;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Tokenizer;

with Fixtures;
with Tiny_Model;

package body Tests.Image_Cases is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Qwen_Image;

   use type E.Error_Code;
   use type N.Element_Count;
   use type N.Real;

   --  The denoiser written small: two heads of the model's 128 -- what its
   --  rotation's three axes add up to -- a feed-forward of ninety-six, eight
   --  latent channels, a text of thirty-two.
   Width   : constant := 256;
   Head    : constant := 128;
   Feed    : constant := 96;
   Latent  : constant := 8;
   Latent_Channels : constant := Latent;
   Context : constant := 32;

   Path : constant String := "obj/qwen-image-denoiser.gguf";

   type Index_List is array (Positive range <>) of Natural;

   --  Every tensor the last denoiser written holds, by its unprefixed
   --  name, for the reference computation to read.
   package Weight_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => N.Real_Array, Hash => Ada.Strings.Hash, Equivalent_Keys => "=",
      "=" => N."=");
   Written : Weight_Maps.Map;

   --  Write a denoiser of the blocks numbered, every tensor under Prefix,
   --  less the one named Omit, the one named Narrow a column short, and
   --  saying it is Said where that is not empty.
   procedure Write_Denoiser
     (Prefix  : String := "model.diffusion_model.";
      Blocks  : Index_List := [0, 1];
      Omit    : String := "";
      Narrow  : String := "";
      Said    : String := "";
      Eight   : Boolean := False)
   is
      Builder : Fixtures.Builder;
      File    : B.Byte_Array_Access;
      Seed    : Natural := 1;
      use Ada.Streams.Stream_IO;
      Handle  : File_Type;

      procedure Tensor (Name : String; Columns : Natural; Rows : Natural := 1) is
         Wide   : constant Natural := (if Name = Narrow then Columns - 1 else Columns);
         Values : N.Real_Array (0 .. N.Element_Count (Wide * Rows) - 1);
      begin
         if Name = Omit then
            return;
         end if;
         for Index in Values'Range loop
            Seed := (Seed * 1_103 + 12_345) mod 65_521;
            Values (Index) := N.Real (Seed mod 201 - 100) / 1_000.0;
         end loop;
         --  A matrix written in eight bits, where its rows divide into the
         --  format's blocks; and kept as the file holds it, decoded again.
         if Eight and then Rows > 1 and then Wide mod 32 = 0 then
            declare
               Bytes : B.Byte_Array_Access := new B.Byte_Array'(Fixtures.Encode_Q8_0 (Values));
               View  : Model_Runner.Tensors.View;
               Done  : E.Error_Info;
            begin
               Model_Runner.Tensors.Make
                 (G.Type_Q8_0, N.Element_Count (Rows), N.Element_Count (Wide), Bytes, 0, View, Done);
               for Row in 0 .. N.Element_Count (Rows) - 1 loop
                  Model_Runner.Tensors.Dequantize_Row
                    (View, Row, Values (Row * N.Element_Count (Wide) .. (Row + 1) * N.Element_Count (Wide) - 1),
                     Done);
               end loop;
               Fixtures.Add_Tensor
                 (Builder, Prefix & Name, [G.U64 (Wide), G.U64 (Rows)], G.Type_Q8_0, Bytes.all);
               B.Free (Bytes);
            end;
         else
            Fixtures.Add_Tensor
              (Builder, Prefix & Name,
               (if Rows = 1 then [G.U64 (Wide)] else [G.U64 (Wide), G.U64 (Rows)]),
               G.Type_F32, Fixtures.Encode_F32 (Values));
         end if;
         Written.Include (Name, Values);
      end Tensor;
   begin
      Written.Clear;
      Fixtures.Reset (Builder);
      if Said /= "" then
         Fixtures.Add_String (Builder, "general.architecture", Said);
      end if;
      Tensor ("img_in.weight", Latent, Width);
      Tensor ("txt_in.text_norm.weight", Context);
      Tensor ("txt_in.in_layer.weight", Context, Width);
      Tensor ("txt_in.out_layer.weight", Width, Width);
      Tensor ("time_text_embed.timestep_embedder.linear_1.weight", Q.Time_Width, Width);
      Tensor ("time_text_embed.timestep_embedder.linear_2.weight", Width, Width);
      Tensor ("modulation.1.weight", Width, 4 * Width);
      Tensor ("norm_out.linear.weight", Width, Width);
      Tensor ("proj_out.weight", Width, Latent);
      for Number of Blocks loop
         declare
            Lead : constant String :=
              "transformer_blocks." & Ada.Strings.Fixed.Trim (Number'Image, Ada.Strings.Left) & ".";
         begin
            Tensor (Lead & "attn.to_q.weight", Width, Width);
            Tensor (Lead & "attn.to_k.weight", Width, Width);
            Tensor (Lead & "attn.to_v.weight", Width, Width);
            Tensor (Lead & "attn.to_out.0.weight", Width, Width);
            Tensor (Lead & "attn.norm_q.weight", Head);
            Tensor (Lead & "attn.norm_k.weight", Head);
            Tensor (Lead & "img_mlp.gate_up.weight", Width, 2 * Feed);
            Tensor (Lead & "img_mlp.out.weight", Feed, Width);
         end;
      end loop;
      Fixtures.Build (Builder, File);
      Create (Handle, Out_File, Path);
      declare
         Block : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (File.all'Length))
           with Import, Address => File.all'Address;
      begin
         Write (Handle, Block);
      end;
      Close (Handle);
      B.Free (File);
   end Write_Denoiser;

   --  The file states nothing, and what it is is read off its shapes:
   --  under ComfyUI's prefix or none.
   procedure The_Denoiser_Is_Read_Off_Its_Shapes (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Model  : Q.Denoiser;
      Status : E.Error_Info;
   begin
      for Prefixed in Boolean loop
         Write_Denoiser (Prefix => (if Prefixed then "model.diffusion_model." else ""), Blocks => [0, 1, 2]);
         Q.Open (Model, Path, Status);
         Assert (E.Is_Ok (Status), "a denoiser did not open: " & E.Error_Code'Image (Status.Code));
         declare
            Shape : constant Q.Configuration := Q.Config (Model);
         begin
            Assert (Q.Is_Ready (Model) and then Shape.Blocks = 3 and then Shape.Width = Width
                    and then Shape.Head_Size = Head and then Shape.Heads = Width / Head
                    and then Shape.Feed = Feed and then Shape.In_Channels = Latent
                    and then Shape.Out_Channels = Latent and then Shape.Context = Context,
                    "the configuration was not what the shapes say:" & Shape.Blocks'Image & Shape.Width'Image
                    & Shape.Heads'Image & Shape.Head_Size'Image & Shape.Feed'Image & Shape.In_Channels'Image
                    & Shape.Out_Channels'Image & Shape.Context'Image);
         end;
         Q.Close (Model);
         Assert (not Q.Is_Ready (Model), "a closed denoiser still said it was ready");
      end loop;
   end The_Denoiser_Is_Read_Off_Its_Shapes;

   --  Shapes that are not this model's are refused, naming what is wrong,
   --  and leave nothing open.
   procedure Other_Shapes_Are_Refused (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);

      procedure Expect (Code : E.Error_Code; What : String) is
         Model  : Q.Denoiser;
         Status : E.Error_Info;
      begin
         Q.Open (Model, Path, Status);
         Assert (Status.Code = Code, What & ": " & E.Error_Code'Image (Status.Code));
         Assert (not Q.Is_Ready (Model), What & ": the denoiser was left open");
      end Expect;
   begin
      Write_Denoiser (Said => "llama");
      Expect (E.Arch_Unsupported, "a file that says it is a text model");
      Write_Denoiser (Omit => "modulation.1.weight");
      Expect (E.Arch_Unsupported, "a file with no modulation");
      Write_Denoiser (Omit => "txt_in.out_layer.weight");
      Expect (E.Arch_Missing_Tensor, "a file missing the text's second linear");
      Write_Denoiser (Omit => "transformer_blocks.1.attn.norm_k.weight");
      Expect (E.Arch_Missing_Tensor, "a block missing its key norm");
      Write_Denoiser (Narrow => "modulation.1.weight");
      Expect (E.Arch_Invalid_Tensor_Shape, "a modulation a column short");
      Write_Denoiser (Narrow => "transformer_blocks.0.img_mlp.gate_up.weight");
      Expect (E.Arch_Invalid_Tensor_Shape, "a fused gate and up a column short");
      Write_Denoiser (Blocks => [0, 2]);
      Expect (E.Arch_Layer_Numbering_Gap, "a block missing below another");
      Write_Denoiser (Blocks => []);
      Expect (E.Arch_Missing_Tensor, "no blocks at all");
      Write_Denoiser (Narrow => "transformer_blocks.0.attn.norm_q.weight");
      Expect (E.Arch_Invalid_Dimensions, "a head of another width than the rotation turns");
   end Other_Shapes_Are_Refused;

   --  The template is the reference's, character for character: a
   --  system turn the model was trained with, the prompt, the assistant's
   --  turn opened.
   procedure The_Prompt_Template_Is_The_References (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      LF : constant Character := ASCII.LF;
   begin
      Assert (Model_Runner.Qwen_Image.Prompts.Template ("a red apple")
              = "<|im_start|>system" & LF & "Comprehend and analyze the provided prompt.<|im_end|>" & LF
                & "<|im_start|>user" & LF & "a red apple<|im_end|>" & LF & "<|im_start|>assistant" & LF,
              "the template is not the reference's");
   end The_Prompt_Template_Is_The_References;

   --  A prompt's rows are each token's state as the last layer left it,
   --  the system turn's dropped: normalized, each is the same position's
   --  state through the final norm -- one gain for every row -- and they
   --  are not those states themselves.
   procedure Prompt_Rows_Are_The_States_Before_The_Norm (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package L renames Model_Runner.Llama;
      package Tk renames Model_Runner.Tensors;
      use type Tk.Real_Array_Access;
      function Sqrt (X : Long_Float) return Long_Float is (Long_Float (N.Sqrt (N.Wide_Real (X))));
      Tokens  : constant Model_Runner.Tokenizer.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];
      Dropped : constant := 3;
      Image   : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Qwen3_VL);
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : Model_Runner.GGUF.Containers.Container;
         Ready  : L.Model;
         Status : E.Error_Info;
         Rows, Normal : Tk.Real_Array_Access;
         Live   : L.Session;
         Width  : N.Element_Count;
         Logits : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
         Gain   : N.Real_Array (0 .. 255) := [others => 0.0];
         Differs : Boolean := False;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Parsed, Source, Status => Status);
         L.Prepare (Ready, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the encoder was not prepared: " & E.Error_Code'Image (Status.Code));
         Width := N.Element_Count (L.Config (Ready).Embedding);

         Model_Runner.Qwen_Image.Prompts.Rows_Of (Ready, Tokens, Dropped, Rows, Status);
         Assert (E.Is_Ok (Status) and then Rows /= null and then Rows'Length = (Tokens'Length - Dropped) * Width,
                 "the prompt's rows were not one a kept token: " & E.Error_Code'Image (Status.Code));

         L.Open (Live, Ready, Context => Tokens'Length, Status => Status);
         Tk.Allocate (Tokens'Length * Width, Normal);
         L.Evaluate_Batch (Live, Ready, Tokens, Logits, States => Normal, Status => Status);
         Assert (E.Is_Ok (Status), "the normalized states were not made");
         L.Close (Live);

         for Kept in 0 .. Tokens'Length - Dropped - 1 loop
            declare
               Row   : constant N.Element_Count := N.Element_Count (Kept) * Width;
               Other : constant N.Element_Count := N.Element_Count (Kept + Dropped) * Width;
               Sum   : Long_Float := 0.0;
            begin
               for I in 0 .. Width - 1 loop
                  Sum := Sum + Long_Float (Rows (Row + I)) ** 2;
               end loop;
               declare
                  Scale : constant Long_Float :=
                    1.0 / Long_Float'Max (Sqrt (Sum / Long_Float (Width) + 1.0E-6), 1.0E-30);
               begin
                  for I in 0 .. Width - 1 loop
                     declare
                        Ratio : constant Long_Float :=
                          Long_Float (Normal (Other + I)) / (Long_Float (Rows (Row + I)) * Scale);
                     begin
                        if Kept = 0 then
                           Gain (I) := N.Real (Ratio);
                        else
                           Assert (abs (Ratio - Long_Float (Gain (I))) < 1.0E-3 * (1.0 + abs Ratio),
                                   "a row normalized is not its position's state through the final norm");
                        end if;
                        Differs := Differs or else abs (Rows (Row + I) - Normal (Other + I)) > 1.0E-3;
                     end;
                  end loop;
               end;
            end;
         end loop;
         Assert (Differs, "the rows were the normalized states, not the states before the norm");
         Tk.Free (Rows);
         Tk.Free (Normal);
         L.Close (Ready, Status);
         Model_Runner.GGUF.Containers.Close (Parsed);
      end;
      B.Free (Image);
   end Prompt_Rows_Are_The_States_Before_The_Norm;

   --  The denoiser computed plainly in binary64, from the weights written,
   --  as the reference implementation's description has it
   --  (stable-diffusion.cpp's qwen_image_2_1.hpp): nothing of the engine's.
   procedure Reference_Velocity
     (Latent : N.Real_Array; Rows, Columns : Positive; Time : Long_Float; Text : N.Real_Array;
      Text_Rows : Natural; Blocks : Natural; Answer : out N.Wide_Real_Array)
   is
      use Ada.Numerics.Long_Elementary_Functions;
      type Matrix is array (Natural range <>, Natural range <>) of Long_Float;
      Image : constant Natural := Rows * Columns;
      Total : constant Natural := Text_Rows + Image;
      Heads : constant Natural := Width / Head;

      function Weight (Name : String; Index : Natural) return Long_Float
      is (Long_Float (Written.Constant_Reference (Name) (N.Element_Count (Index))));

      --  Out := Name's matrix (Out_Width rows of In_Width) times each row of In.
      function Linear (Name : String; Source : Matrix; Out_Width : Natural) return Matrix is
         In_Width : constant Natural := Source'Length (2);
         Result   : Matrix (Source'Range (1), 0 .. Out_Width - 1) := [others => [others => 0.0]];
      begin
         for R in Source'Range (1) loop
            for O in 0 .. Out_Width - 1 loop
               for I in 0 .. In_Width - 1 loop
                  Result (R, O) := Result (R, O) + Weight (Name, O * In_Width + I) * Source (R, I);
               end loop;
            end loop;
         end loop;
         return Result;
      end Linear;

      function Silu (Z : Long_Float) return Long_Float is (Z / (1.0 + Exp (-Z)));

      function Layer_Norm (Source : Matrix; R : Natural) return Matrix is
         Result : Matrix (0 .. 0, Source'Range (2));
         Mean, Var : Long_Float := 0.0;
      begin
         for I in Source'Range (2) loop
            Mean := Mean + Source (R, I);
         end loop;
         Mean := Mean / Long_Float (Source'Length (2));
         for I in Source'Range (2) loop
            Var := Var + (Source (R, I) - Mean) ** 2;
         end loop;
         Var := Var / Long_Float (Source'Length (2));
         for I in Source'Range (2) loop
            Result (0, I) := (Source (R, I) - Mean) / Sqrt (Var + 1.0E-6);
         end loop;
         return Result;
      end Layer_Norm;

      --  The time embedded, for a time: [cos, sin] of t times each
      --  frequency, two linears with SiLU between, then SiLU again.
      function Embedded (T_Value : Long_Float) return Matrix is
         S : Matrix (0 .. 0, 0 .. Q.Time_Width - 1);
         Half : constant Natural := Q.Time_Width / 2;
      begin
         for J in 0 .. Half - 1 loop
            S (0, J) := Cos (T_Value * Exp (-Log (10_000.0) * Long_Float (J) / Long_Float (Half)));
            S (0, Half + J) := Sin (T_Value * Exp (-Log (10_000.0) * Long_Float (J) / Long_Float (Half)));
         end loop;
         declare
            H1 : Matrix := Linear ("time_text_embed.timestep_embedder.linear_1.weight", S, Width);
         begin
            for I in H1'Range (2) loop
               H1 (0, I) := Silu (H1 (0, I));
            end loop;
            declare
               H2 : Matrix := Linear ("time_text_embed.timestep_embedder.linear_2.weight", H1, Width);
            begin
               for I in H2'Range (2) loop
                  H2 (0, I) := Silu (H2 (0, I));
               end loop;
               return H2;
            end;
         end;
      end Embedded;

      Step_Time : constant Matrix := Embedded (Time);
      Zero_Time : constant Matrix := Embedded (0.0);
      Step_Mod  : constant Matrix := Linear ("modulation.1.weight", Step_Time, 4 * Width);
      Zero_Mod  : constant Matrix := Linear ("modulation.1.weight", Zero_Time, 4 * Width);

      --  Row R's modulation part Part (0 attention scale, 1 its gate, 2 the
      --  feed-forward's scale, 3 its gate), element I: the prompt's rows
      --  read time nought's.
      function Modulation (R, Part, I : Natural) return Long_Float
      is (if R < Text_Rows then Zero_Mod (0, Part * Width + I) else Step_Mod (0, Part * Width + I));

      X : Matrix (0 .. Total - 1, 0 .. Width - 1);

      --  Position of a row on the three axes.
      function Place (R, Axis : Natural) return Long_Float is
      begin
         if R < Text_Rows then
            return Long_Float (R);
         end if;
         declare
            Pixel : constant Natural := R - Text_Rows;
         begin
            case Axis is
               when 0 => return Long_Float (Text_Rows);
               when 1 => return Long_Float (Pixel / Columns) - Long_Float (Rows - Rows / 2);
               when others => return Long_Float (Pixel mod Columns) - Long_Float (Columns - Columns / 2);
            end case;
         end;
      end Place;

      --  Head normalization and rotation of one projection, in place.
      procedure Normalize_And_Rotate (P : in out Matrix; Gain : String) is
         Axis_Width : constant array (0 .. 2) of Natural := [16, 56, 56];
      begin
         for R in P'Range (1) loop
            for Hd in 0 .. Heads - 1 loop
               declare
                  Sum : Long_Float := 0.0;
               begin
                  for I in 0 .. Head - 1 loop
                     Sum := Sum + P (R, Hd * Head + I) ** 2;
                  end loop;
                  for I in 0 .. Head - 1 loop
                     P (R, Hd * Head + I) := P (R, Hd * Head + I) / Sqrt (Sum / Long_Float (Head) + 1.0E-6)
                       * Weight (Gain, I);
                  end loop;
                  declare
                     Pair : Natural := 0;
                  begin
                     for Axis in 0 .. 2 loop
                        for J in 0 .. Axis_Width (Axis) / 2 - 1 loop
                           exit when 2 * Pair + 1 >= Head;
                           declare
                              Angle : constant Long_Float := Place (R, Axis)
                                * 10_000.0 ** (-Long_Float (2 * J) / Long_Float (Axis_Width (Axis)));
                              A0 : constant Long_Float := P (R, Hd * Head + 2 * Pair);
                              A1 : constant Long_Float := P (R, Hd * Head + 2 * Pair + 1);
                           begin
                              P (R, Hd * Head + 2 * Pair) := Cos (Angle) * A0 - Sin (Angle) * A1;
                              P (R, Hd * Head + 2 * Pair + 1) := Sin (Angle) * A0 + Cos (Angle) * A1;
                              Pair := Pair + 1;
                           end;
                        end loop;
                     end loop;
                  end;
               end;
            end loop;
         end loop;
      end Normalize_And_Rotate;
   begin
      --  The prompt: zero-centred root-mean-square norm, linear, tanh GELU,
      --  linear.
      declare
         Normed : Matrix (0 .. Text_Rows - 1, 0 .. Context - 1);
      begin
         for R in 0 .. Text_Rows - 1 loop
            declare
               Sum : Long_Float := 0.0;
            begin
               for I in 0 .. Context - 1 loop
                  Sum := Sum + Long_Float (Text (Text'First + N.Element_Count (R * Context + I))) ** 2;
               end loop;
               for I in 0 .. Context - 1 loop
                  Normed (R, I) := Long_Float (Text (Text'First + N.Element_Count (R * Context + I)))
                    / Sqrt (Sum / Long_Float (Context) + 1.0E-6) * (1.0 + Weight ("txt_in.text_norm.weight", I));
               end loop;
            end;
         end loop;
         declare
            First : Matrix := Linear ("txt_in.in_layer.weight", Normed, Width);
         begin
            for R in First'Range (1) loop
               for I in First'Range (2) loop
                  First (R, I) := 0.5 * First (R, I) * (1.0 + Tanh (Sqrt (2.0 / Ada.Numerics.Pi)
                                  * (First (R, I) + 0.044715 * First (R, I) ** 3)));
               end loop;
            end loop;
            declare
               Second : constant Matrix := Linear ("txt_in.out_layer.weight", First, Width);
            begin
               for R in Second'Range (1) loop
                  for I in Second'Range (2) loop
                     X (R, I) := Second (R, I);
                  end loop;
               end loop;
            end;
         end;
      end;
      --  The image: each latent pixel's channels through img_in.
      declare
         Pixels : Matrix (0 .. Image - 1, 0 .. Latent_Channels - 1);
      begin
         for P in 0 .. Image - 1 loop
            for C in 0 .. Latent_Channels - 1 loop
               Pixels (P, C) := Long_Float (Latent (Latent'First + N.Element_Count (C * Image + P)));
            end loop;
         end loop;
         declare
            Rows_In : constant Matrix := Linear ("img_in.weight", Pixels, Width);
         begin
            for P in 0 .. Image - 1 loop
               for I in 0 .. Width - 1 loop
                  X (Text_Rows + P, I) := Rows_In (P, I);
               end loop;
            end loop;
         end;
      end;

      for B_Index in 0 .. Blocks - 1 loop
         declare
            Lead : constant String := "transformer_blocks." & Ada.Strings.Fixed.Trim (B_Index'Image, Ada.Strings.Left)
              & ".";
            Hm : Matrix (X'Range (1), X'Range (2));
         begin
            for R in X'Range (1) loop
               declare
                  L : constant Matrix := Layer_Norm (X, R);
               begin
                  for I in X'Range (2) loop
                     Hm (R, I) := L (0, I) * (1.0 + Modulation (R, 0, I));
                  end loop;
               end;
            end loop;
            declare
               Qm : Matrix := Linear (Lead & "attn.to_q.weight", Hm, Width);
               Km : Matrix := Linear (Lead & "attn.to_k.weight", Hm, Width);
               Vm : constant Matrix := Linear (Lead & "attn.to_v.weight", Hm, Width);
               Am : Matrix (X'Range (1), X'Range (2)) := [others => [others => 0.0]];
            begin
               Normalize_And_Rotate (Qm, Lead & "attn.norm_q.weight");
               Normalize_And_Rotate (Km, Lead & "attn.norm_k.weight");
               --  A prompt token sees the prompt up to itself; an image
               --  token sees everything.
               for R in X'Range (1) loop
                  for Hd in 0 .. Heads - 1 loop
                     declare
                        Last  : constant Natural := (if R < Text_Rows then R else Total - 1);
                        Score : array (0 .. Last) of Long_Float;
                        Most, Sum : Long_Float := 0.0;
                     begin
                        for Key in 0 .. Last loop
                           Score (Key) := 0.0;
                           for I in 0 .. Head - 1 loop
                              Score (Key) := Score (Key) + Qm (R, Hd * Head + I) * Km (Key, Hd * Head + I);
                           end loop;
                           Score (Key) := Score (Key) / Sqrt (Long_Float (Head));
                           Most := (if Key = 0 then Score (Key) else Long_Float'Max (Most, Score (Key)));
                        end loop;
                        for Key in 0 .. Last loop
                           Score (Key) := Exp (Score (Key) - Most);
                           Sum := Sum + Score (Key);
                        end loop;
                        for Key in 0 .. Last loop
                           for I in 0 .. Head - 1 loop
                              Am (R, Hd * Head + I) :=
                                Am (R, Hd * Head + I) + Score (Key) / Sum * Vm (Key, Hd * Head + I);
                           end loop;
                        end loop;
                     end;
                  end loop;
               end loop;
               declare
                  Out_M : constant Matrix := Linear (Lead & "attn.to_out.0.weight", Am, Width);
               begin
                  for R in X'Range (1) loop
                     for I in X'Range (2) loop
                        X (R, I) := X (R, I) + Tanh (Modulation (R, 1, I)) * Out_M (R, I);
                     end loop;
                  end loop;
               end;
            end;
            for R in X'Range (1) loop
               declare
                  L : constant Matrix := Layer_Norm (X, R);
               begin
                  for I in X'Range (2) loop
                     Hm (R, I) := L (0, I) * (1.0 + Modulation (R, 2, I));
                  end loop;
               end;
            end loop;
            declare
               Gu : constant Matrix := Linear (Lead & "img_mlp.gate_up.weight", Hm, 2 * Feed);
               Act : Matrix (X'Range (1), 0 .. Feed - 1);
            begin
               for R in X'Range (1) loop
                  for I in 0 .. Feed - 1 loop
                     Act (R, I) := Silu (Gu (R, I)) * Gu (R, Feed + I);
                  end loop;
               end loop;
               declare
                  Down : constant Matrix := Linear (Lead & "img_mlp.out.weight", Act, Width);
               begin
                  for R in X'Range (1) loop
                     for I in X'Range (2) loop
                        X (R, I) := X (R, I) + Tanh (Modulation (R, 3, I)) * Down (R, I);
                     end loop;
                  end loop;
               end;
            end;
         end;
      end loop;

      declare
         Scale : constant Matrix := Linear ("norm_out.linear.weight", Step_Time, Width);
         Final : Matrix (0 .. Image - 1, 0 .. Width - 1);
      begin
         for P in 0 .. Image - 1 loop
            declare
               L : constant Matrix := Layer_Norm (X, Text_Rows + P);
            begin
               for I in 0 .. Width - 1 loop
                  Final (P, I) := L (0, I) * (1.0 + Scale (0, I));
               end loop;
            end;
         end loop;
         declare
            Out_Rows : constant Matrix := Linear ("proj_out.weight", Final, Latent_Channels);
         begin
            for P in 0 .. Image - 1 loop
               for C in 0 .. Latent_Channels - 1 loop
                  Answer (Answer'First + N.Element_Count (C * Image + P)) := N.Wide_Real (Out_Rows (P, C));
               end loop;
            end loop;
         end;
      end;
   end Reference_Velocity;

   --  One evaluation of the denoiser, in binary32, is the plain binary64
   --  computation of the same network: the time twice, the prompt's rows,
   --  the latent's, every block's modulated attention -- causal among the
   --  prompt, all of it for the image -- and gated feed-forward, the last
   --  norm and the way out.
   procedure A_Step_Is_The_Plain_Computation (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Grid_Rows    : constant := 3;
      Grid_Columns : constant := 4;
      Text_Rows    : constant := 5;
      Model  : Q.Denoiser;
      Status : E.Error_Info;
      Latent : N.Real_Array (0 .. Latent_Channels * Grid_Rows * Grid_Columns - 1);
      Text   : N.Real_Array (0 .. Text_Rows * Context - 1);
      Answer : N.Real_Array (Latent'Range);
      Wanted : N.Wide_Real_Array (Latent'Range);
      Seed   : Natural := 77;
      Worst, Largest : Long_Float := 0.0;
   begin
      for Value of Latent loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 100.0;
      end loop;
      for Value of Text loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 50.0;
      end loop;
      --  In binary32 throughout; in eight bits, the products reading the
      --  matrices a panel of rows at a time, in binary32 and with their
      --  activations rounded to eight bits too.
      for Run in 1 .. 3 loop
         Write_Denoiser (Blocks => [0, 1], Eight => Run > 1);
         Q.Open (Model, Path, Status);
         Assert (E.Is_Ok (Status), "the denoiser did not open");
         if Run = 3 then
            Model_Runner.Backend.CPU.Use_Integer_Activations (Model_Runner.Backend.CPU.Every_Role);
         end if;
         Q.Velocity (Model, Latent, Grid_Rows, Grid_Columns, 500.0, Text, Text_Rows, null, Answer, Status);
         Model_Runner.Backend.CPU.Use_Integer_Activations (Model_Runner.Backend.CPU.No_Role);
         Assert (E.Is_Ok (Status), "the step failed: " & E.Error_Code'Image (Status.Code));
         Reference_Velocity (Latent, Grid_Rows, Grid_Columns, 500.0, Text, Text_Rows, 2, Wanted);
         Worst := 0.0;
         Largest := 0.0;
         for Index in Answer'Range loop
            Worst := Long_Float'Max (Worst, abs (Long_Float (Answer (Index)) - Long_Float (Wanted (Index))));
            Largest := Long_Float'Max (Largest, abs Long_Float (Wanted (Index)));
         end loop;
         Assert (Largest > 1.0E-3 and then Worst <= (if Run = 3 then 3.0E-2 else 1.0E-4) * Largest,
                 "a step" & Run'Image & " differs from the plain computation by" & Worst'Image & " of"
                 & Largest'Image);
         Q.Close (Model);
      end loop;
   end A_Step_Is_The_Plain_Computation;

   --  The noise levels are the reference scheduler's, its own code run in
   --  binary32: forty steps for a 512 picture, eight for the smallest, four
   --  for a 1024 one.
   procedure The_Schedule_Is_The_References (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);

      procedure Expect (Steps, Tokens : Positive; Wanted : N.Real_Array) is
         Have : constant N.Real_Array := Q.Sigmas (Steps, Tokens);
      begin
         for I in Wanted'Range loop
            Assert (abs (Long_Float (Have (Have'First + I - Wanted'First)) - Long_Float (Wanted (I))) <= 1.0E-6,
                    "level" & I'Image & " of" & Steps'Image & " steps over" & Tokens'Image & " tokens is"
                    & Have (Have'First + I - Wanted'First)'Image & ", not" & Wanted (I)'Image);
         end loop;
      end Expect;
   begin
      Expect (40, 1024, [1.0, 0.984919071, 0.969517231, 0.953784466, 0.937709749, 0.921281874, 0.90448916,
                         0.887319148, 0.869759142, 0.851795673, 0.833414555, 0.814601302, 0.79534018, 0.775615156,
                         0.755409241, 0.734704673, 0.713482797, 0.691723764, 0.669407368, 0.646511316, 0.623013139,
                         0.598888755, 0.574112654, 0.548658133, 0.522496819, 0.495599091, 0.467933297, 0.43946588,
                         0.410161793, 0.379983306, 0.34889102, 0.316842556, 0.283793211, 0.249695361, 0.214498103,
                         0.178147733, 0.140586376, 0.10175252, 0.0615805984, 0.0199999809, 0.0]);
      Expect (8, 256, [1.0, 0.903451324, 0.796369314, 0.676930845, 0.542865872, 0.39131254, 0.218610287,
                       0.0199999809, 0.0]);
      Expect (4, 4096, [1.0, 0.766709328, 0.455613732, 0.0199999809, 0.0]);
   end The_Schedule_Is_The_References;

   --  The noise is the reference's to the bit: stable-diffusion.cpp's
   --  PhiloxRNG, compiled and run, for seed 42 at the start, the middle and
   --  the end of a draw and into the next, and for the largest seed.
   procedure The_Noise_Is_The_References (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      function Bits is new Ada.Unchecked_Conversion (N.Real, Interfaces.Unsigned_32);
      use type Interfaces.Unsigned_32;
      Draw   : Model_Runner.Philox.Generator := Model_Runner.Philox.Seeded (42);
      First, Second : N.Real_Array (0 .. 1_999);
      Last   : N.Real_Array (0 .. 2);
      Big    : Model_Runner.Philox.Generator := Model_Runner.Philox.Seeded (Interfaces.Unsigned_64'Last);

      procedure Expect (Value : N.Real; Wanted : Interfaces.Unsigned_32; What : String) is
      begin
         Assert (Bits (Value) = Wanted, What & " is" & Value'Image & ", not the reference's");
      end Expect;
   begin
      Model_Runner.Philox.Draw (Draw, First);
      Model_Runner.Philox.Draw (Draw, Second);
      Expect (First (0), 16#3E46_ACE2#, "the first value");
      Expect (First (1), 16#400A_53F3#, "the second");
      Expect (First (2), 16#BE30_2E08#, "the third");
      Expect (First (3), 16#3F59_5C01#, "the fourth");
      Expect (First (999), 16#3E5E_F789#, "the thousandth");
      Expect (First (1_999), 16#3F12_E1AC#, "the last of a draw");
      Expect (Second (0), 16#3E0E_7A13#, "the first of the next draw");
      Expect (Second (1), 16#BDDD_A045#, "the second of the next draw");
      Expect (Second (1_999), 16#BC0F_3ACD#, "the last of the next draw");
      Model_Runner.Philox.Draw (Big, Last);
      Expect (Last (0), 16#3F21_DE90#, "the largest seed's first");
      Expect (Last (1), 16#3D09_3852#, "the largest seed's second");
      Expect (Last (2), 16#3F56_CE72#, "the largest seed's third");
   end The_Noise_Is_The_References;

   --  A picture's latent is its seed's noise moved along each level's
   --  velocity by the level's step, through the reference's levels: to the
   --  bit what the steps make one at a time.
   procedure A_Latent_Is_Its_Steps (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Grid_Rows    : constant := 2;
      Grid_Columns : constant := 3;
      Text_Rows    : constant := 4;
      Steps        : constant := 3;
      Model  : Q.Denoiser;
      Status : E.Error_Info;
      Text   : N.Real_Array (0 .. Text_Rows * Context - 1);
      Drawn, Wanted, Speed : N.Real_Array (0 .. Latent_Channels * Grid_Rows * Grid_Columns - 1);
      Noise  : Model_Runner.Philox.Generator := Model_Runner.Philox.Seeded (7);
      Levels : constant N.Real_Array := Q.Sigmas (Steps, Grid_Rows * Grid_Columns);
      Seed   : Natural := 5;
   begin
      for Value of Text loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 50.0;
      end loop;
      Write_Denoiser (Blocks => [0]);
      Q.Open (Model, Path, Status);
      Q.Sample (Model, Grid_Rows, Grid_Columns, Steps, 7, Text, Text_Rows, null, Drawn, Status);
      Assert (E.Is_Ok (Status), "the picture's latent was not drawn: " & E.Error_Code'Image (Status.Code));
      Model_Runner.Philox.Draw (Noise, Wanted);
      for Step in 0 .. Steps - 1 loop
         Q.Velocity (Model, Wanted, Grid_Rows, Grid_Columns, Levels (N.Element_Count (Step)) * 1000.0, Text,
                     Text_Rows, null, Speed, Status);
         for I in Wanted'Range loop
            Wanted (I) := Wanted (I) + (Levels (N.Element_Count (Step + 1)) - Levels (N.Element_Count (Step)))
              * Speed (I);
         end loop;
      end loop;
      Assert (N."=" (Drawn, Wanted), "the latent drawn is not its steps taken one at a time");
      Q.Close (Model);
   end A_Latent_Is_Its_Steps;

   --  The VAE written small, as safetensors: its widths a multiple of four
   --  where the published file's are of 144.
   VAE_Path : constant String := "obj/qwen-image-vae.safetensors";
   VAE_Base : constant := 4;
   VAE_Widths : constant array (0 .. 5) of Positive := [8 * VAE_Base, 8 * VAE_Base, 8 * VAE_Base, 4 * VAE_Base,
                                                        2 * VAE_Base, VAE_Base];

   procedure Write_VAE is
      use Ada.Streams.Stream_IO;
      Header : Ada.Strings.Unbounded.Unbounded_String;
      Data   : Ada.Strings.Unbounded.Unbounded_String;
      At_Byte : Natural := 0;
      Seed   : Natural := 11;
      Handle : File_Type;

      procedure Tensor
        (Name : String; Shape : String; Count : Positive; Scale : Long_Float := 0.15; Around : Long_Float := 0.0)
      is
         Values : N.Real_Array (0 .. N.Element_Count (Count) - 1);
      begin
         for Index in Values'Range loop
            Seed := (Seed * 1_103 + 12_345) mod 65_521;
            Values (Index) := N.Real (Around + Long_Float (Seed mod 201 - 100) / 100.0 * Scale);
         end loop;
         Written.Include (Name, Values);
         declare
            Bytes : constant B.Byte_Array := Fixtures.Encode_F32 (Values);
         begin
            if Ada.Strings.Unbounded.Length (Header) > 1 then
               Ada.Strings.Unbounded.Append (Header, ",");
            end if;
            Ada.Strings.Unbounded.Append
              (Header, """" & Name & """:{""dtype"":""F32"",""shape"":" & Shape & ",""data_offsets"":["
               & Ada.Strings.Fixed.Trim (At_Byte'Image, Ada.Strings.Left) & ","
               & Ada.Strings.Fixed.Trim (Natural (At_Byte + Bytes'Length)'Image, Ada.Strings.Left) & "]}");
            for X of Bytes loop
               Ada.Strings.Unbounded.Append (Data, Character'Val (X));
            end loop;
            At_Byte := At_Byte + Bytes'Length;
         end;
      end Tensor;

      function Img (V : Natural) return String is (Ada.Strings.Fixed.Trim (V'Image, Ada.Strings.Left));

      procedure Conv (Name : String; Ins, Outs, Size : Positive; Spread : Long_Float := 0.6) is
      begin
         Tensor (Name & ".weight", "[" & Img (Outs) & "," & Img (Ins) & "," & Img (Size) & "," & Img (Size) & "]",
                 Outs * Ins * Size * Size, Spread / Long_Float (Ins * Size));
         Tensor (Name & ".bias", "[" & Img (Outs) & "]", Outs, 0.05);
      end Conv;

      procedure Gain (Name : String; Width : Positive) is
      begin
         Tensor (Name, "[" & Img (Width) & ",1,1,1]", Width, 0.2, Around => 1.0);
      end Gain;

      procedure Residual (Name : String; Ins, Outs : Positive) is
      begin
         Gain (Name & ".norm1.gamma", Ins);
         Conv (Name & ".conv1", Ins, Outs, 3);
         Gain (Name & ".norm2.gamma", Outs);
         Conv (Name & ".conv2", Outs, Outs, 3);
         if Ins /= Outs then
            Conv (Name & ".conv_shortcut", Ins, Outs, 1);
         end if;
      end Residual;
   begin
      Written.Clear;
      Header := Ada.Strings.Unbounded.To_Unbounded_String ("{");
      Conv ("post_quant_conv", 64, 64, 1);
      Conv ("decoder.conv_in", 64, VAE_Widths (0), 3);
      Residual ("decoder.mid_block.resnets.0", VAE_Widths (0), VAE_Widths (0));
      Gain ("decoder.mid_block.attentions.0.norm.gamma", VAE_Widths (0));
      --  Wide enough that the scores tell the positions apart: a nearly
      --  even softmax reads the same whatever its keys are.
      Conv ("decoder.mid_block.attentions.0.to_qkv", VAE_Widths (0), 3 * VAE_Widths (0), 1, Spread => 12.0);
      Conv ("decoder.mid_block.attentions.0.proj", VAE_Widths (0), VAE_Widths (0), 1);
      Residual ("decoder.mid_block.resnets.1", VAE_Widths (0), VAE_Widths (0));
      for L in 1 .. 5 loop
         for R in 1 .. 3 loop
            Residual ("decoder.up_blocks." & Img (L - 1) & ".resnets." & Img (R - 1),
                      (if R = 1 then VAE_Widths (L - 1) else VAE_Widths (L)), VAE_Widths (L));
         end loop;
         if L < 5 then
            Conv ("decoder.up_blocks." & Img (L - 1) & ".upsampler.resample.1", VAE_Widths (L), VAE_Widths (L), 3);
         end if;
      end loop;
      Gain ("decoder.norm_out.gamma", VAE_Widths (5));
      Conv ("decoder.conv_out", VAE_Widths (5), 4, 3);
      Ada.Strings.Unbounded.Append (Header, "}");
      declare
         Text   : constant String := Ada.Strings.Unbounded.To_String (Header);
         use type Interfaces.Unsigned_64;
         Length : Interfaces.Unsigned_64 := Text'Length;
         Prefix : String (1 .. 8);
      begin
         for I in Prefix'Range loop
            Prefix (I) := Character'Val (Natural (Length and 16#FF#));
            Length := Interfaces.Shift_Right (Length, 8);
         end loop;
         Create (Handle, Out_File, VAE_Path);
         String'Write (Stream (Handle), Prefix & Text & Ada.Strings.Unbounded.To_String (Data));
         Close (Handle);
      end;
   end Write_VAE;

   --  The VAE decoder computed plainly in binary64, from the weights
   --  written, each activation a plane a channel, as the reference
   --  implementation's description has it (stable-diffusion.cpp's
   --  wan_vae.hpp): nothing of the engine's.
   procedure Reference_Decode (Latent : N.Real_Array; Rows, Columns : Positive; Answer : out N.Wide_Real_Array) is
      use Ada.Numerics.Long_Elementary_Functions;
      type Planes is array (Natural range <>, Natural range <>, Natural range <>) of Long_Float;
      Means : constant array (0 .. 63) of Long_Float :=
        [0.5126, 0.7721, -0.0631, 1.3506, -0.7855, -2.1025, -0.3458, 1.3722,
         1.8873, -1.7177, -0.6510, 0.2732, 0.7562, -0.6163, -1.0277, 3.8363,
         2.0210, 0.0472, 0.9320, 2.0087, 2.4954, -0.1391, -1.4249, 1.8464,
         -0.5236, 1.2826, 3.7046, -1.3035, 2.7286, -1.4518, -1.9036, -1.9955,
         -0.0342, -1.0265, -0.7636, 3.0555, 0.0746, -3.0751, -0.1076, 1.7376,
         -1.0914, -1.9435, -0.2784, -1.3680, 0.4809, -0.4433, 0.3764, 0.5729,
         -2.0595, 1.0960, -1.3260, -2.0211, -5.0179, 0.5275, 4.0162, 1.8505,
         0.3026, 1.9373, 1.4937, 0.2632, 0.5547, -1.7121, -0.1562, 0.0304];
      Deviations : constant array (0 .. 63) of Long_Float :=
        [3.2001, 3.2936, 3.4321, 3.0091, 3.1061, 4.0379, 4.0705, 3.7910,
         3.0785, 3.6500, 3.9308, 3.0904, 2.8778, 3.7675, 3.7320, 5.0756,
         3.2864, 4.0397, 3.1317, 4.0443, 2.9249, 3.9454, 3.0988, 4.2489,
         3.4896, 3.8513, 3.9323, 3.4719, 3.7498, 4.2830, 3.5694, 4.2467,
         3.9037, 3.2947, 5.0770, 3.5075, 3.2700, 3.4767, 2.8063, 5.1125,
         3.5327, 4.7833, 3.1286, 4.1819, 3.8527, 3.8312, 3.5605, 4.3875,
         3.9624, 4.0168, 3.5643, 4.0550, 5.5614, 4.2963, 4.4080, 3.4959,
         3.8747, 3.7608, 3.5735, 3.1490, 3.7662, 3.6746, 3.4563, 3.8161];

      --  An element of a tensor written, read in place: Element would copy
      --  the whole tensor for every element.
      function W (Name : String; Index : Natural) return Long_Float
      is (Long_Float (Written.Constant_Reference (Name) (N.Element_Count (Index))));

      function Img (V : Natural) return String is (Ada.Strings.Fixed.Trim (V'Image, Ada.Strings.Left));

      --  A convolution of side Size, zero past the edges, and its bias.
      function Conv (Name : String; X : Planes; Outs, Size : Positive) return Planes is
         Ins  : constant Natural := X'Length (1);
         H    : constant Natural := X'Length (2);
         Wd   : constant Natural := X'Length (3);
         Half : constant Integer := Size / 2;
         Y    : Planes (0 .. Outs - 1, 0 .. H - 1, 0 .. Wd - 1);
      begin
         for O in 0 .. Outs - 1 loop
            for R in 0 .. H - 1 loop
               for C in 0 .. Wd - 1 loop
                  declare
                     Sum : Long_Float := W (Name & ".bias", O);
                  begin
                     for I in 0 .. Ins - 1 loop
                        for DY in 0 .. Size - 1 loop
                           for DX in 0 .. Size - 1 loop
                              declare
                                 SY : constant Integer := R + DY - Half;
                                 SX : constant Integer := C + DX - Half;
                              begin
                                 if SY in 0 .. H - 1 and then SX in 0 .. Wd - 1 then
                                    Sum := Sum + W (Name & ".weight", ((O * Ins + I) * Size + DY) * Size + DX)
                                      * X (I, SY, SX);
                                 end if;
                              end;
                           end loop;
                        end loop;
                     end loop;
                     Y (O, R, C) := Sum;
                  end;
               end loop;
            end loop;
         end loop;
         return Y;
      end Conv;

      --  Normalized over the channels at each pixel, times the gain;
      --  SiLU after where asked.
      function Norm (Name : String; X : Planes; Silu : Boolean := True) return Planes is
         Y : Planes (X'Range (1), X'Range (2), X'Range (3));
      begin
         for R in X'Range (2) loop
            for C in X'Range (3) loop
               declare
                  Sum : Long_Float := 0.0;
               begin
                  for I in X'Range (1) loop
                     Sum := Sum + X (I, R, C) ** 2;
                  end loop;
                  for I in X'Range (1) loop
                     declare
                        V : constant Long_Float := X (I, R, C) / Sqrt (Sum / Long_Float (X'Length (1)) + 1.0E-12)
                          * W (Name, I);
                     begin
                        Y (I, R, C) := (if Silu then V / (1.0 + Exp (-V)) else V);
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         return Y;
      end Norm;

      function Residual (Name : String; X : Planes; Outs : Positive) return Planes is
         A : constant Planes := Conv (Name & ".conv1", Norm (Name & ".norm1.gamma", X), Outs, 3);
         Y : Planes := Conv (Name & ".conv2", Norm (Name & ".norm2.gamma", A), Outs, 3);
      begin
         if X'Length (1) /= Outs then
            declare
               Short : constant Planes := Conv (Name & ".conv_shortcut", X, Outs, 1);
            begin
               for I in Y'Range (1) loop
                  for R in Y'Range (2) loop
                     for C in Y'Range (3) loop
                        Y (I, R, C) := Y (I, R, C) + Short (I, R, C);
                     end loop;
                  end loop;
               end loop;
            end;
         else
            for I in Y'Range (1) loop
               for R in Y'Range (2) loop
                  for C in Y'Range (3) loop
                     Y (I, R, C) := Y (I, R, C) + X (I, R, C);
                  end loop;
               end loop;
            end loop;
         end if;
         return Y;
      end Residual;

      --  The mid block's attention: one head over every pixel.
      function Attention (X : Planes) return Planes is
         Ch : constant Natural := X'Length (1);
         P  : constant Natural := X'Length (2) * X'Length (3);
         QKV : constant Planes := Conv ("decoder.mid_block.attentions.0.to_qkv",
                                        Norm ("decoder.mid_block.attentions.0.norm.gamma", X, Silu => False), 3 * Ch,
                                        1);
         A  : Planes (X'Range (1), X'Range (2), X'Range (3));
         Wd : constant Natural := X'Length (3);
      begin
         for Query in 0 .. P - 1 loop
            declare
               Score : array (0 .. P - 1) of Long_Float;
               Most  : Long_Float := Long_Float'First;
               Sum   : Long_Float := 0.0;
            begin
               for Key in 0 .. P - 1 loop
                  Score (Key) := 0.0;
                  for I in 0 .. Ch - 1 loop
                     Score (Key) :=
                       Score (Key) + QKV (I, Query / Wd, Query mod Wd) * QKV (Ch + I, Key / Wd, Key mod Wd);
                  end loop;
                  Score (Key) := Score (Key) / Sqrt (Long_Float (Ch));
                  Most := Long_Float'Max (Most, Score (Key));
               end loop;
               for Key in 0 .. P - 1 loop
                  Score (Key) := Exp (Score (Key) - Most);
                  Sum := Sum + Score (Key);
               end loop;
               for I in 0 .. Ch - 1 loop
                  A (I, Query / Wd, Query mod Wd) := 0.0;
                  for Key in 0 .. P - 1 loop
                     A (I, Query / Wd, Query mod Wd) :=
                       A (I, Query / Wd, Query mod Wd) + Score (Key) / Sum * QKV (2 * Ch + I, Key / Wd, Key mod Wd);
                  end loop;
               end loop;
            end;
         end loop;
         declare
            Y : Planes := Conv ("decoder.mid_block.attentions.0.proj", A, Ch, 1);
         begin
            for I in Y'Range (1) loop
               for R in Y'Range (2) loop
                  for C in Y'Range (3) loop
                     Y (I, R, C) := Y (I, R, C) + X (I, R, C);
                  end loop;
               end loop;
            end loop;
            return Y;
         end;
      end Attention;

      --  The weightless shortcut, as the reference writes it: the channels
      --  repeated, viewed as (out, frames, 2, 2), the last frame kept.
      function Duplicated (X : Planes; Outs, Frames : Positive) return Planes is
         Repeats : constant Natural := Outs * Frames * 4 / X'Length (1);
         Y : Planes (0 .. Outs - 1, 0 .. 2 * X'Length (2) - 1, 0 .. 2 * X'Length (3) - 1);
      begin
         for C in 0 .. Outs - 1 loop
            for R in X'Range (2) loop
               for Col in X'Range (3) loop
                  for A in 0 .. 1 loop
                     for B_Side in 0 .. 1 loop
                        declare
                           Repeated : constant Natural := ((C * Frames + (Frames - 1)) * 2 + A) * 2 + B_Side;
                        begin
                           Y (C, 2 * R + A, 2 * Col + B_Side) := X (Repeated / Repeats, R, Col);
                        end;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
         return Y;
      end Duplicated;

      function Level (L : Positive; X : Planes) return Planes is
         Lead : constant String := "decoder.up_blocks." & Img (L - 1) & ".";
         Outs : constant Positive := VAE_Widths (L);
         Y1 : constant Planes := Residual (Lead & "resnets.0", X, Outs);
         Y2 : constant Planes := Residual (Lead & "resnets.1", Y1, Outs);
         Y3 : constant Planes := Residual (Lead & "resnets.2", Y2, Outs);
      begin
         if L = 5 then
            return Y3;
         end if;
         declare
            Big : Planes (Y3'Range (1), 0 .. 2 * Y3'Length (2) - 1, 0 .. 2 * Y3'Length (3) - 1);
         begin
            for I in Big'Range (1) loop
               for R in Big'Range (2) loop
                  for C in Big'Range (3) loop
                     Big (I, R, C) := Y3 (I, R / 2, C / 2);
                  end loop;
               end loop;
            end loop;
            declare
               Up    : Planes := Conv (Lead & "upsampler.resample.1", Big, Outs, 3);
               Short : constant Planes := Duplicated (X, Outs, (if L <= 3 then 2 else 1));
            begin
               for I in Up'Range (1) loop
                  for R in Up'Range (2) loop
                     for C in Up'Range (3) loop
                        Up (I, R, C) := Up (I, R, C) + Short (I, R, C);
                     end loop;
                  end loop;
               end loop;
               return Up;
            end;
         end;
      end Level;

      Z : Planes (0 .. 63, 0 .. Rows - 1, 0 .. Columns - 1);
   begin
      for C in 0 .. 63 loop
         for R in 0 .. Rows - 1 loop
            for Col in 0 .. Columns - 1 loop
               Z (C, R, Col) := Long_Float (Latent (Latent'First + N.Element_Count ((C * Rows + R) * Columns + Col)))
                 * Deviations (C) + Means (C);
            end loop;
         end loop;
      end loop;
      declare
         X0 : constant Planes := Conv ("decoder.conv_in", Conv ("post_quant_conv", Z, 64, 1), VAE_Widths (0), 3);
         X1 : constant Planes :=
           Residual ("decoder.mid_block.resnets.1",
                     Attention (Residual ("decoder.mid_block.resnets.0", X0, VAE_Widths (0))), VAE_Widths (0));
         L5 : constant Planes := Level (5, Level (4, Level (3, Level (2, Level (1, X1)))));
         Out_P : constant Planes := Conv ("decoder.conv_out", Norm ("decoder.norm_out.gamma", L5), 4, 3);
         Pixels : constant Natural := Out_P'Length (2) * Out_P'Length (3);
      begin
         for C in 0 .. 3 loop
            for R in Out_P'Range (2) loop
               for Col in Out_P'Range (3) loop
                  Answer (Answer'First + N.Element_Count (C * Pixels + R * Out_P'Length (3) + Col)) :=
                    N.Wide_Real (Out_P (C, R, Col));
               end loop;
            end loop;
         end loop;
      end;
   end Reference_Decode;

   --  A latent decoded is the plain binary64 computation of the same
   --  decoder: unnormalized, the mid block, five levels doubling four
   --  times with the shortcut Wan's temporal factor lays out, the head.
   procedure A_Latent_Decodes_As_The_Plain_Computation (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Dec renames Model_Runner.Qwen_Image.Decoder;
      Grid_Rows    : constant := 2;
      Grid_Columns : constant := 3;
      Latent  : N.Real_Array (0 .. 64 * Grid_Rows * Grid_Columns - 1);
      Picture : N.Real_Array (0 .. 4 * 256 * Grid_Rows * Grid_Columns - 1);
      Wanted  : N.Wide_Real_Array (Picture'Range);
      Decoder : Dec.Picture_Decoder;
      Status  : E.Error_Info;
      Seed    : Natural := 3;
      Worst, Largest : Long_Float := 0.0;
   begin
      for Value of Latent loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 150.0;
      end loop;
      Write_VAE;
      Dec.Open (Decoder, VAE_Path, Status);
      Assert (E.Is_Ok (Status), "the decoder did not open: " & E.Error_Code'Image (Status.Code));
      Dec.Decode (Decoder, Latent, Grid_Rows, Grid_Columns, null, Picture, Status);
      Assert (E.Is_Ok (Status), "the latent was not decoded: " & E.Error_Code'Image (Status.Code));
      Reference_Decode (Latent, Grid_Rows, Grid_Columns, Wanted);
      for Index in Picture'Range loop
         Worst := Long_Float'Max (Worst, abs (Long_Float (Picture (Index)) - Long_Float (Wanted (Index))));
         Largest := Long_Float'Max (Largest, abs Long_Float (Wanted (Index)));
      end loop;
      Assert (Largest > 1.0E-3 and then Worst <= 1.0E-4 * Largest,
              "a decoded picture differs from the plain computation by" & Worst'Image & " of" & Largest'Image);
      Dec.Close (Decoder);
   end A_Latent_Decodes_As_The_Plain_Computation;

   --  A picture written as PNG reads back as the same pixels, with alpha
   --  or without: its rows, its checksums and its deflated stream are what
   --  a reader takes.
   procedure A_PNG_Reads_Back_As_Written (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      use type B.Byte;
      use type B.Byte_Count;
      use type B.Byte_Array_Access;
      Width  : constant := 37;
      Height : constant := 23;
   begin
      for Channels in Model_Runner.PNG_Writer.Channel_Count loop
         declare
            Pixels : B.Byte_Array (0 .. B.Byte_Count (Width * Height * Channels) - 1);
            File   : B.Byte_Array_Access;
            Back   : Model_Runner.Images.Raster;
            Status : E.Error_Info;
         begin
            for Index in Pixels'Range loop
               Pixels (Index) := B.Byte ((Natural (Index) * 7 + Natural (Index) / 13) mod 256);
            end loop;
            Model_Runner.PNG_Writer.Encode (Width, Height, Channels, Pixels, File, Status);
            Assert (E.Is_Ok (Status) and then File /= null, "the picture was not encoded");
            Model_Runner.Images.Decode (File.all, "written", Back, Status);
            Assert (E.Is_Ok (Status), "the written picture did not read back: " & E.Error_Code'Image (Status.Code));
            Assert (Back.Width = Width and then Back.Height = Height, "the picture read back another size");
            for Pixel in 0 .. Width * Height - 1 loop
               for C in 0 .. 2 loop
                  if Channels = 3 then
                     Assert (Back.Pixels (B.Byte_Count (3 * Pixel + C)) = Pixels (B.Byte_Count (3 * Pixel + C)),
                             "a pixel read back otherwise than written");
                  end if;
               end loop;
            end loop;
            B.Free (File);
            Model_Runner.Images.Free (Back);
         end;
      end loop;
   end A_PNG_Reads_Back_As_Written;

   --  A decoded picture's planes become bytes as the reference makes them:
   --  (x + 1) / 2, held to nought and one, times 255 and cut, a pixel's
   --  red, green, blue and alpha together.
   procedure Planes_Become_Bytes_As_The_References (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      use type B.Byte_Array;
      package Dec renames Model_Runner.Qwen_Image.Decoder;
      --  Two pixels, each channel's plane in turn.
      Planes : constant N.Real_Array (0 .. 7) := [-1.0, 1.0, 0.0, 3.0, -2.0, 0.999, 0.002, -0.5];
   begin
      Assert (Dec.To_Pixels (Planes, 2) = [0, 127, 0, 127, 255, 255, 254, 63],
              "the planes did not become the reference's bytes");
   end Planes_Become_Bytes_As_The_References;

   --  The same step with the device open: its products and its attention
   --  there -- the prompt's rows causal, the image's over every key -- the
   --  rest here, and the plain computation still, to the half precision the
   --  device's tiles read their operands in. Nothing to ask where no device
   --  opens.
   procedure A_Step_On_The_Device_Is_The_Plain_Computation (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Device renames Model_Runner.Backend.Device;
      --  Past the 128 rows one device product and one attention take.
      Grid_Rows    : constant := 11;
      Grid_Columns : constant := 12;
      Text_Rows    : constant := 5;
      Model  : Q.Denoiser;
      Status : E.Error_Info;
      Latent : N.Real_Array (0 .. Latent_Channels * Grid_Rows * Grid_Columns - 1);
      Text   : N.Real_Array (0 .. Text_Rows * Context - 1);
      Answer : N.Real_Array (Latent'Range);
      Wanted : N.Wide_Real_Array (Latent'Range);
      Seed   : Natural := 77;
      Worst, Largest : Long_Float := 0.0;
      Ready  : Boolean;
   begin
      Device.Open (Ready);
      if not Ready then
         return;
      end if;
      for Value of Latent loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 100.0;
      end loop;
      for Value of Text loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 50.0;
      end loop;
      Write_Denoiser (Blocks => [0, 1], Eight => True);
      Q.Open (Model, Path, Status, Panels => False);
      Assert (E.Is_Ok (Status), "the denoiser did not open");
      Q.Velocity (Model, Latent, Grid_Rows, Grid_Columns, 500.0, Text, Text_Rows, null, Answer, Status);
      Q.Close (Model);
      Device.Close;
      Assert (E.Is_Ok (Status), "the step on the device failed: " & E.Error_Code'Image (Status.Code));
      Reference_Velocity (Latent, Grid_Rows, Grid_Columns, 500.0, Text, Text_Rows, 2, Wanted);
      for Index in Answer'Range loop
         Worst := Long_Float'Max (Worst, abs (Long_Float (Answer (Index)) - Long_Float (Wanted (Index))));
         Largest := Long_Float'Max (Largest, abs Long_Float (Wanted (Index)));
      end loop;
      Assert (Largest > 1.0E-3 and then Worst <= 2.0E-2 * Largest,
              "a step on the device differs from the plain computation by" & Worst'Image & " of" & Largest'Image);
   end A_Step_On_The_Device_Is_The_Plain_Computation;

   --  The same latent decoded with the device open, its convolutions there:
   --  the plain computation still, to the half precision the device's tiles
   --  read their operands in. Nothing to ask where no device opens.
   procedure A_Latent_Decodes_On_The_Device_As_The_Plain_Computation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Dec renames Model_Runner.Qwen_Image.Decoder;
      Grid_Rows    : constant := 2;
      Grid_Columns : constant := 3;
      Latent  : N.Real_Array (0 .. 64 * Grid_Rows * Grid_Columns - 1);
      Picture : N.Real_Array (0 .. 4 * 256 * Grid_Rows * Grid_Columns - 1);
      Wanted  : N.Wide_Real_Array (Picture'Range);
      Decoder : Dec.Picture_Decoder;
      Status  : E.Error_Info;
      Seed    : Natural := 3;
      Worst, Largest : Long_Float := 0.0;
      Ready   : Boolean;
   begin
      Model_Runner.Backend.Device.Open (Ready);
      if not Ready then
         return;
      end if;
      for Value of Latent loop
         Seed := (Seed * 1_103 + 12_345) mod 65_521;
         Value := N.Real (Seed mod 401 - 200) / 150.0;
      end loop;
      Write_VAE;
      Dec.Open (Decoder, VAE_Path, Status);
      Assert (E.Is_Ok (Status), "the decoder did not open");
      Dec.Decode (Decoder, Latent, Grid_Rows, Grid_Columns, null, Picture, Status);
      Dec.Close (Decoder);
      Model_Runner.Backend.Device.Close;
      Assert (E.Is_Ok (Status), "the latent was not decoded on the device: " & E.Error_Code'Image (Status.Code));
      Reference_Decode (Latent, Grid_Rows, Grid_Columns, Wanted);
      for Index in Picture'Range loop
         Worst := Long_Float'Max (Worst, abs (Long_Float (Picture (Index)) - Long_Float (Wanted (Index))));
         Largest := Long_Float'Max (Largest, abs Long_Float (Wanted (Index)));
      end loop;
      Assert (Largest > 1.0E-3 and then Worst <= 2.0E-2 * Largest,
              "a picture decoded on the device differs from the plain computation by" & Worst'Image & " of"
              & Largest'Image);
   end A_Latent_Decodes_On_The_Device_As_The_Plain_Computation;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("image generation");
   end Name;

   overriding procedure Register_Tests (T : in out Case_Type) is
   begin
      Register_Routine
        (T, The_Denoiser_Is_Read_Off_Its_Shapes'Access,
         "Qwen-Image 2.1's denoiser, a file that states nothing, is read off its tensors' shapes");
      Register_Routine
        (T, Other_Shapes_Are_Refused'Access,
         "a denoiser whose shapes are not Qwen-Image 2.1's is refused, naming what is wrong");
      Register_Routine
        (T, A_Step_Is_The_Plain_Computation'Access,
         "one evaluation of the denoiser is the plain binary64 computation of the same network");
      Register_Routine
        (T, The_Schedule_Is_The_References'Access,
         "the noise levels a picture is drawn through are the reference scheduler's");
      Register_Routine
        (T, The_Noise_Is_The_References'Access,
         "a picture's noise is the reference's to the bit, a seed and a draw at a time");
      Register_Routine
        (T, A_Latent_Is_Its_Steps'Access,
         "a picture's latent is its seed's noise moved along each level's velocity, a step at a time");
      Register_Routine
        (T, A_Latent_Decodes_As_The_Plain_Computation'Access,
         "a latent decoded is the plain binary64 computation of the same VAE decoder");
      Register_Routine
        (T, A_PNG_Reads_Back_As_Written'Access,
         "a picture written as PNG reads back as the same pixels, with alpha or without");
      Register_Routine
        (T, Planes_Become_Bytes_As_The_References'Access,
         "a decoded picture's planes become bytes as the reference makes them");
      Register_Routine
        (T, A_Step_On_The_Device_Is_The_Plain_Computation'Access,
         "one evaluation of the denoiser on the device is the plain computation of the same network");
      Register_Routine
        (T, A_Latent_Decodes_On_The_Device_As_The_Plain_Computation'Access,
         "a latent decoded with the device open is the plain computation of the same VAE decoder");
      Register_Routine
        (T, The_Prompt_Template_Is_The_References'Access,
         "a prompt is read within the reference's template, character for character");
      Register_Routine
        (T, Prompt_Rows_Are_The_States_Before_The_Norm'Access,
         "a prompt's rows are each kept token's state before the final norm, the system turn's dropped");
   end Register_Tests;

end Tests.Image_Cases;
