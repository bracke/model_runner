with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Qwen_Image;
with Model_Runner.Qwen_Image.Prompts;
with Model_Runner.Tensors;
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

   --  The denoiser written small: four heads of sixteen, a feed-forward of
   --  ninety-six, eight latent channels, a text of thirty-two.
   Width   : constant := 64;
   Head    : constant := 16;
   Feed    : constant := 96;
   Latent  : constant := 8;
   Context : constant := 32;

   Path : constant String := "obj/qwen-image-denoiser.gguf";

   type Index_List is array (Positive range <>) of Natural;

   --  Write a denoiser of the blocks numbered, every tensor under Prefix,
   --  less the one named Omit, the one named Narrow a column short, and
   --  saying it is Said where that is not empty.
   procedure Write_Denoiser
     (Prefix  : String := "model.diffusion_model.";
      Blocks  : Index_List := [0, 1];
      Omit    : String := "";
      Narrow  : String := "";
      Said    : String := "")
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
         Fixtures.Add_Tensor
           (Builder, Prefix & Name,
            (if Rows = 1 then [G.U64 (Wide)] else [G.U64 (Wide), G.U64 (Rows)]),
            G.Type_F32, Fixtures.Encode_F32 (Values));
      end Tensor;
   begin
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
        (T, The_Prompt_Template_Is_The_References'Access,
         "a prompt is read within the reference's template, character for character");
      Register_Routine
        (T, Prompt_Rows_Are_The_States_Before_The_Norm'Access,
         "a prompt's rows are each kept token's state before the final norm, the system turn's dropped");
   end Register_Tests;

end Tests.Image_Cases;
