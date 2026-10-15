with Quantizer;

--  Which format each tensor of a model gets, for the mixtures people ship.
--
--  `llama-quantize` does not write one format through a file. Asked for
--  Q4_K_M it writes Q4_K *mostly*: the feed-forward's down projection and
--  attention's values are Q6_K in some layers and not others, the output
--  projection is Q6_K throughout, and which layers get more is decided by an
--  arithmetic rule over the layer index. Every comparison this repository
--  made before this passed `--pure` to turn that off, which measured the
--  encoders honestly and left the recipes unwritten.
--
--  THE RECIPE IS THE ONLY PART OF QUANTIZING THAT IS AN OPINION. Which
--  levels a block gets is arithmetic; which tensors deserve more bits is a
--  judgement, and llama.cpp has spent years accumulating one in a single
--  function of ninety-nine branches. This is that judgement for the
--  mixtures a llama-shaped model is actually distributed in, transcribed
--  rather than invented, and checked the same way everything else here is:
--  against the file the other implementation writes.
--
--  WHAT IS HERE AND WHAT IS NOT. The branches this architecture reaches.
--  llama.cpp's policy also asks whether the model is a Falcon, whether it
--  has eight experts, whether it is a seventy-billion-parameter model, and
--  whether an importance matrix was given; the first three are answered no
--  by every model this can be checked against, and are refused by name
--  rather than assumed away -- see Fits.
package Recipes is

   --  The mixtures, by the names `llama-quantize` takes.
   type Recipe is
     (Q2_K_Mix, Q3_K_S, Q3_K_M, Q3_K_L, Q4_K_S, Q4_K_M, Q5_K_S, Q5_K_M);

   --  What a recipe writes where it has no opinion.
   --
   --  @param Item The recipe.
   --  @return The format most of its tensors get.
   function Base_Of (Item : Recipe) return Quantizer.Target
   is (case Item is
          when Q2_K_Mix => Quantizer.Q2_K,
          when Q3_K_S | Q3_K_M | Q3_K_L => Quantizer.Q3_K,
          when Q4_K_S | Q4_K_M => Quantizer.Q4_K,
          when Q5_K_S | Q5_K_M => Quantizer.Q5_K);

   --  The name a recipe is asked for by.
   --
   --  llama.cpp calls its Q2_K mixture plain `Q2_K`, which here would be
   --  the pure format of that name: `--format q2_k` writes Q2_K through the
   --  file and `--format q2_k_m` writes the mixture.
   --
   --  @param Item The recipe.
   --  @return Its name.
   function Name_Of (Item : Recipe) return String
   is (case Item is
          when Q2_K_Mix => "q2_k_m",
          when Q3_K_S => "q3_k_s",
          when Q3_K_M => "q3_k_m",
          when Q3_K_L => "q3_k_l",
          when Q4_K_S => "q4_k_s",
          when Q4_K_M => "q4_k_m",
          when Q5_K_S => "q5_k_s",
          when Q5_K_M => "q5_k_m");

   --  A name, or a name nobody here writes.
   --
   --  @param Text A recipe's name, in any case.
   --  @param Item The recipe named.
   --  @param Known True when the name was one of them.
   procedure Named (Text : String; Item : out Recipe; Known : out Boolean);

   --  How far through the model the policy is.
   --
   --  The rules count tensors of a kind rather than layers: the third
   --  attention-value matrix is the third one seen, and a model that skips
   --  one skips a number. Kept by the caller because the order matters, and
   --  the order that matters is llama.cpp's and not the file's: its loader
   --  sorts the tensors by the layer in their names and then by name, and
   --  a caller asking Type_For in any other order counts differently. See
   --  Comes_Before.
   type Progress is record
      Values : Natural := 0;
      Downs  : Natural := 0;
      Gates  : Natural := 0;
      Ups    : Natural := 0;
   end record;

   --  What the model is, so far as the policy asks.
   type Shape is record
      Layers : Natural := 0;

      --  Query heads over key-value heads. Several rules turn on this being
      --  four or more, which is every model that shares its keys widely.
      Grouped : Natural := 1;

      --  Whether the output projection shares the embedding's weights, in
      --  which case the embedding is quantized as the output would be.
      Tied : Boolean := False;

      --  How many matrices the attention-value rules count: every one whose
      --  name holds attn_v, attn_qkv or attn_kv_b -- llama.cpp's
      --  n_attention_wv, which is the denominator of the rule that spends
      --  more bits on some of them.
      Values : Natural := 0;
   end record;

   --  Whether a tensor's name puts it under the attention-value rules.
   --
   --  The fused projection and the key-value one count: llama.cpp's
   --  category_is_attn_v takes all three, so a model that fuses its
   --  queries, keys and values has every attn_qkv judged as an attn_v.
   --
   --  @param Name The tensor's name.
   --  @return True for attn_v, attn_qkv and attn_kv_b.
   function Is_Attention_Value (Name : String) return Boolean;

   --  The order llama.cpp's loader walks a model's tensors in: by the layer
   --  in the name, a tensor with none before every layer, and then by name.
   --
   --  @param Left One tensor's name.
   --  @param Right Another's.
   --  @return True when Left comes first.
   function Comes_Before (Left, Right : String) return Boolean;

   --  Whether llama.cpp quantizes this tensor at all.
   --
   --  Its tensor_allows_quantization: only matrices, only names ending in
   --  "weight", and not the norms, the router, the positional and
   --  token-type embeddings, the small convolutions and RWKV's mixing
   --  weights, the relative position bias, the vision tower's patch and
   --  position embeddings, nor the handful of small per-layer tensors it
   --  names. A tensor it does not quantize is copied as it stands.
   --
   --  @param Name The tensor's name.
   --  @param Rank How many dimensions it has.
   --  @return True when it is quantized.
   function Allows (Name : String; Rank : Positive) return Boolean;

   --  What a tensor is written as when its row will not divide into the
   --  format's blocks.
   type Fitted is record
      Format  : Quantizer.Target := Quantizer.Q8_0;

      --  The fallback could not hold the row either: written as F16.
      As_Half : Boolean := False;

      --  llama.cpp defines no fallback for the format and stops.
      Refused : Boolean := False;
   end record;

   --  llama.cpp's tensor_type_fallback, applied to every quantized tensor
   --  whether a mixture chose its format or the caller did.
   --
   --  A row a 256-wide super-block cannot divide takes a 32-wide format of
   --  about the bits -- Q2_K and Q3_K Q4_0, Q4_K Q5_0, Q5_K Q5_1, Q6_K
   --  Q8_0, IQ4_XS IQ4_NL -- and a row not even 32 wide is written F16. A
   --  32-wide format has no fallback there, which the reference treats as
   --  an error rather than a choice.
   --
   --  @param Wanted The format the tensor was meant to get.
   --  @param Columns The tensor's first dimension.
   --  @return What it gets.
   function Fall_Back
     (Wanted : Quantizer.Target; Columns : Long_Long_Integer) return Fitted;

   --  Whether this model is one the transcribed policy actually covers.
   --
   --  False for a Falcon, a mixture of experts, or a seventy-billion
   --  model, each of which llama.cpp's policy treats specially and this
   --  does not. A caller that gets False should refuse rather than write a
   --  file that would differ for reasons nothing here records.
   --
   --  @param Architecture The model's architecture name, as the file says.
   --  @param Experts How many experts a layer routes between, or zero.
   --  @param Parameters How many parameters the model holds.
   --  @return True when the policy below is the whole of llama.cpp's for
   --    this model.
   function Fits
     (Architecture : String;
      Experts      : Natural;
      Parameters   : Long_Long_Integer) return Boolean;

   --  Which format this tensor gets.
   --
   --  @param Item The recipe.
   --  @param Name The tensor's name, as the file names it.
   --  @param Model What the model is.
   --  @param Seen How many of each kind have gone before; advanced here.
   --  @param Columns The tensor's first dimension, for the output
   --    projection's own rule. A row its format cannot divide is not
   --    answered here: see Fall_Back.
   --  @return The format the policy gives it.
   function Type_For
     (Item    : Recipe;
      Name    : String;
      Model   : Shape;
      Seen    : in out Progress;
      Columns : Long_Long_Integer) return Quantizer.Target;

end Recipes;
