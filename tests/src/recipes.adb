with Ada.Strings.Fixed;

with Model_Runner.Text;

package body Recipes is

   --  Whether a layer is one of the ones the policy spends more on.
   --
   --  The first eighth, the last eighth, and every third one of what is
   --  left. Transcribed rather than reasoned about: it is llama.cpp's
   --  `use_more_bits` and the point of it is to match, not to be defended.
   function More_Bits (Which, Layers : Natural) return Boolean
   is (Which < Layers / 8
       or else Which >= 7 * Layers / 8
       or else (Which - Layers / 8) mod 3 = 2);

   --  Which layer a tensor belongs to, from its own name.
   --
   --  NOT FROM A COUNTER, which is what the reference uses and what this
   --  used first. A counter is right only if the tensors arrive in layer
   --  order, and in a GGUF they arrive in the order the converter wrote
   --  them -- which for this model is lexicographic: blk.1, blk.10, blk.11,
   --  and blk.2 twelve places later. llama.cpp walks its own list, built by
   --  the loader and ordered by layer, so its counter and its layer agree;
   --  a reader walking the file's own order has to ask the name. Counting
   --  instead put a tenth of the layers' extra bits on the wrong ones.
   --
   --  Minus one where the name carries no layer.
   function Layer_Of (Name : String) return Integer;

   function Layer_Of (Name : String) return Integer is
      Head : constant String := "blk.";
      From : Natural;
      Upto : Natural;
      Value : Integer := 0;
   begin
      if Name'Length <= Head'Length
        or else Name (Name'First .. Name'First + Head'Length - 1) /= Head
      then
         return -1;
      end if;

      From := Name'First + Head'Length;
      Upto := From;

      while Upto <= Name'Last and then Name (Upto) in '0' .. '9' loop
         Upto := Upto + 1;
      end loop;

      if Upto = From then
         return -1;
      end if;

      for Index in From .. Upto - 1 loop
         Value := Value * 10 + (Character'Pos (Name (Index))
                                - Character'Pos ('0'));
      end loop;

      return Value;
   end Layer_Of;

   --  Whether a name ends in a suffix.
   function Ends_With (Name, Tail : String) return Boolean
   is (Name'Length >= Tail'Length
       and then Name (Name'Last - Tail'Length + 1 .. Name'Last) = Tail);

   --  Whether a name holds a piece anywhere, which is how llama.cpp asks:
   --  std::string::find, not a suffix.
   function Holds (Name, Piece : String) return Boolean
   is (Ada.Strings.Fixed.Index (Name, Piece) /= 0);

   ------------------------
   -- Is_Attention_Value --
   ------------------------

   function Is_Attention_Value (Name : String) return Boolean
   is (Holds (Name, "attn_qkv.weight")
       or else Holds (Name, "attn_kv_b.weight")
       or else Holds (Name, "attn_v.weight"));

   ------------------
   -- Comes_Before --
   ------------------

   function Comes_Before (Left, Right : String) return Boolean is
      Left_Layer  : constant Integer := Layer_Of (Left);
      Right_Layer : constant Integer := Layer_Of (Right);
   begin
      if Left_Layer /= Right_Layer then
         return Left_Layer < Right_Layer;
      end if;
      return Left < Right;
   end Comes_Before;

   ------------
   -- Allows --
   ------------

   function Allows (Name : String; Rank : Positive) return Boolean is
   begin
      if Rank < 2 or else not Ends_With (Name, "weight") then
         return False;
      end if;

      --  The positional and token-type embeddings are matched whole, by
      --  the names llama.cpp's own table gives them.
      if Name = "position_embd.weight" or else Name = "token_types.weight"
      then
         return False;
      end if;

      return not
        (Holds (Name, "_norm.weight")
         or else Holds (Name, "ffn_gate_inp.weight")
         or else Holds (Name, "ffn_gate_tid2eid.weight")
         or else Holds (Name, "altup")
         or else Holds (Name, "laurel")
         or else Holds (Name, "per_layer_model_proj")
         or else Holds (Name, "ssm_conv1d")
         or else Holds (Name, "shortconv.conv.weight")
         or else Holds (Name, "indexer.k_proj.weight")
         or else Holds (Name, "indexer.q_proj.weight")
         or else Holds (Name, "time_mix_first.weight")
         or else Holds (Name, "time_mix_w0.weight")
         or else Holds (Name, "time_mix_w1.weight")
         or else Holds (Name, "time_mix_w2.weight")
         or else Holds (Name, "time_mix_v0.weight")
         or else Holds (Name, "time_mix_v1.weight")
         or else Holds (Name, "time_mix_v2.weight")
         or else Holds (Name, "time_mix_a0.weight")
         or else Holds (Name, "time_mix_a1.weight")
         or else Holds (Name, "time_mix_a2.weight")
         or else Holds (Name, "time_mix_g1.weight")
         or else Holds (Name, "time_mix_g2.weight")
         or else Holds (Name, "time_mix_decay_w1.weight")
         or else Holds (Name, "time_mix_decay_w2.weight")
         or else Holds (Name, "time_mix_lerp_fused.weight")
         or else Holds (Name, "attn_rel_b.weight")
         or else Holds (Name, ".position_embd")
         or else Holds (Name, "sam.pos_embd")
         or else Holds (Name, "sam.neck.")
         or else Holds (Name, "sam.net_")
         or else Holds (Name, ".rel_pos")
         or else Holds (Name, ".patch_embd")
         or else Holds (Name, ".patch_merger")
         or else Holds (Name, "a.rvq.codebook")
         or else Holds (Name, "mm.a.code_embd"));
   end Allows;

   ---------------
   -- Fall_Back --
   ---------------

   function Fall_Back
     (Wanted : Quantizer.Target; Columns : Long_Long_Integer) return Fitted
   is
      use type Quantizer.Target;

      Chosen : Quantizer.Target := Wanted;
   begin
      if Columns mod Long_Long_Integer (Quantizer.Block_Of (Wanted)) = 0 then
         return (Format => Wanted, others => False);
      end if;

      case Wanted is
         when Quantizer.IQ4_XS => Chosen := Quantizer.IQ4_NL;
         when Quantizer.Q2_K | Quantizer.Q3_K => Chosen := Quantizer.Q4_0;
         when Quantizer.Q4_K => Chosen := Quantizer.Q5_0;
         when Quantizer.Q5_K => Chosen := Quantizer.Q5_1;
         when Quantizer.Q6_K => Chosen := Quantizer.Q8_0;
         when others =>
            return (Format => Wanted, As_Half => False, Refused => True);
      end case;

      if Columns mod Long_Long_Integer (Quantizer.Block_Of (Chosen)) /= 0 then
         return (Format => Chosen, As_Half => True, Refused => False);
      end if;

      return (Format => Chosen, others => False);
   end Fall_Back;

   -----------
   -- Named --
   -----------

   procedure Named (Text : String; Item : out Recipe; Known : out Boolean) is
      Said : constant String := Model_Runner.Text.To_Lower (Text);
   begin
      Known := True;
      for Which in Recipe loop
         if Name_Of (Which) = Said then
            Item := Which;
            return;
         end if;
      end loop;

      Item := Q4_K_M;
      Known := False;
   end Named;

   ----------
   -- Fits --
   ----------

   function Fits
     (Architecture : String;
      Experts      : Natural;
      Parameters   : Long_Long_Integer) return Boolean is
   begin
      --  A Falcon takes a different branch at nearly every rule, a mixture
      --  of experts takes another, and llama.cpp gives a model of about
      --  seventy billion parameters more bits on its attention values
      --  because eight heads share them. None of those is transcribed, and
      --  a file written as though they were would differ for a reason
      --  nothing here would record.
      return Architecture /= "falcon"
        and then Experts <= 1
        and then Parameters < 60_000_000_000;
   end Fits;

   --------------
   -- Type_For --
   --------------

   function Type_For
     (Item    : Recipe;
      Name    : String;
      Model   : Shape;
      Seen    : in out Progress;
      Columns : Long_Long_Integer) return Quantizer.Target
   is
      Chosen : Quantizer.Target := Base_Of (Item);

      Wide : constant Boolean := Model.Grouped >= 4;

      --  The layer this tensor is in, which is the number in its name and
      --  not how many of its kind have gone before.
      Layer : constant Integer := Layer_Of (Name);

      --  The embedding, and Gemma 3n's per-layer one beside it: llama.cpp
      --  puts both in the one category, so tying lifts both.
      Is_Embedding : constant Boolean :=
        Name = "token_embd.weight" or else Name = "per_layer_token_embd.weight";
   begin
      --  The output projection, and the embedding when it is the same
      --  tensor. Six bits, unless the row cannot be cut into super-blocks.
      if Name = "output.weight"
        or else (Model.Tied and then Is_Embedding)
      then
         return (if Columns mod 256 /= 0 then Quantizer.Q8_0
                 else Quantizer.Q6_K);
      end if;

      --  The embedding on its own. Every recipe here leaves it at the base
      --  format; the ones that do not are the very low-bit mixtures, which
      --  are not written here.
      if Is_Embedding then
         return Chosen;
      end if;

      --  The attention values, and the fused projections that hold them:
      --  counted, not read from the layer, because the rule is over how
      --  many of them there are and a model need not have one a layer.
      if Is_Attention_Value (Name) then
         case Item is
            when Q2_K_Mix =>
               Chosen := (if Wide then Quantizer.Q4_K else Quantizer.Q3_K);
            when Q3_K_M =>
               Chosen :=
                 (if Seen.Values < 2 then Quantizer.Q5_K
                  else Quantizer.Q4_K);
            when Q3_K_L =>
               Chosen := Quantizer.Q5_K;
            when Q4_K_M | Q5_K_M =>
               if More_Bits (Seen.Values, Model.Values) then
                  Chosen := Quantizer.Q6_K;
               end if;
            when Q4_K_S =>
               if Seen.Values < 4 then
                  Chosen := Quantizer.Q5_K;
               end if;
            when others =>
               null;
         end case;

         Seen.Values := Seen.Values + 1;

      elsif Holds (Name, "ffn_down") then
         case Item is
            when Q2_K_Mix =>
               Chosen := Quantizer.Q3_K;
            when Q3_K_M =>
               Chosen :=
                 (if Layer < Model.Layers / 16 then Quantizer.Q5_K
                  else Quantizer.Q4_K);
            when Q3_K_L =>
               Chosen := Quantizer.Q5_K;
            when Q4_K_M | Q5_K_M =>
               if More_Bits (Layer, Model.Layers) then
                  Chosen := Quantizer.Q6_K;
               end if;
            when Q4_K_S =>
               if Layer < Model.Layers / 8 then
                  Chosen := Quantizer.Q5_K;
               end if;
            when others =>
               null;
         end case;

         Seen.Downs := Seen.Downs + 1;

      elsif Holds (Name, "attn_output.weight") then
         case Item is
            when Q2_K_Mix => Chosen := Quantizer.Q3_K;
            when Q3_K_M   => Chosen := Quantizer.Q4_K;
            when Q3_K_L   => Chosen := Quantizer.Q5_K;
            when others   => null;
         end case;

      --  No branch for attn_qkv of its own: llama.cpp has one, after the
      --  attention-value branch that every attn_qkv has already taken, so
      --  it is never reached and transcribing it gave fused projections
      --  rules they never get.

      elsif Holds (Name, "ffn_up") then
         Seen.Ups := Seen.Ups + 1;

      elsif Holds (Name, "ffn_gate") then
         Seen.Gates := Seen.Gates + 1;
      end if;

      return Chosen;
   end Type_For;

end Recipes;
