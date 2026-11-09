with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;
with System;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Float_Panels;
with Model_Runner.GGUF.Containers;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

--  Whisper: speech to text, an encoder that hears thirty seconds of sound
--  and a decoder that writes what was said.
--
--  This is a model of its own and not an architecture of Model_Runner.Llama:
--  its decoder attends to the encoder's output (cross-attention), its norms
--  are centred with biases, its unit is the exact GELU, and its positions
--  are learned tables -- none of which the decoder-only plan takes, and none
--  of which this package asks of it. Nothing here depends on Llama, and
--  nothing in Llama on this.
--
--  The model, as openai/whisper's model.py defines it:
--
--  * Encoder. The log-Mel spectrogram (Audio.Spectrograms), 3,000 frames;
--    a convolution of width three to the model's width, GELU; another,
--    stride two, GELU -- 1,500 positions; the learned position table
--    added; blocks of LayerNorm, attention both ways (queries and values
--    with biases, keys without), residual, LayerNorm, a feed-forward of
--    GELU, residual; a last LayerNorm.
--  * Decoder. A token's row of the table and its position's row; blocks
--    of LayerNorm, causal self-attention, residual; LayerNorm, attention
--    to the encoder's output, residual; LayerNorm, feed-forward, residual;
--    a last LayerNorm; the logits are the product with the token table.
--
--  A Model holds the weights, read from a GGUF file of the Whisper profile
--  (docs/plan-speech.md), and nothing that changes once prepared. A Session
--  holds everything a transcription writes: the encoder's output for the
--  window being heard, each decoder block's keys and values of the
--  encoder's output (made once a window), the decoder's own cache, and the
--  scratch the products write. Sessions on one model are independent.
--
--  Transcribing follows the reference's transcribe(): the recording is cut
--  into windows of thirty seconds; each is decoded greedily from the
--  start-of-transcript prompt -- the language, detected from the first
--  window where none is given, then <|transcribe|> -- with the text of the
--  windows before it as a bounded prompt (<|startofprev|>); times are
--  decoded with the text, and where a window ends on a time the next window
--  starts there, so speech cut by a window's edge is heard again whole
--  rather than twice or half.
--
--  What is reported is what was decoded. A window the model judges silent
--  (its no-speech probability above the threshold and its average log
--  probability below the other) is kept as a segment marked silent with no
--  text; one that repeats itself (compression above the threshold) or that
--  the model was unsure of is decoded again, as the reference's
--  decode_with_fallback does: at 0.2, 0.4 and on to 1, five drawn at each
--  and the likeliest over its length kept; one unsure at every temperature
--  is kept, marked uncertain. Draws come from a seeded stream of this
--  package's own, so a window decoded again is the reference's in kind and
--  not to the token. Nothing decoded is dropped or rewritten unasked.
--
--  Task safety: a Model may be read by every session on it once prepared;
--  Prepare and Close are the owner's. A Session is one task's.
package Model_Runner.Whisper is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;

   --  The profile of the file this reads.
   Profile_Version : constant := 1;

   --  The most blocks a side and the most languages a file may state.
   Max_Blocks    : constant := 64;
   Max_Languages : constant := 128;

   --  Samples a window hears and frames its spectrogram is: thirty seconds.
   Window_Samples : constant := 480_000;
   Window_Frames  : constant := 3_000;

   ------------
   -- Models --
   ------------

   type Model is limited private;

   --  Read a Whisper file and prepare its weights.
   --
   --  Either the model is ready afterwards or it holds nothing: a refusal
   --  part way leaves no half-read model behind.
   --
   --  @param Item The model; closed first.
   --  @param Path The GGUF file.
   --  @param Status Success; the container's own diagnostics;
   --    Arch_Unsupported for a file that is not Whisper's or of another
   --    profile; Arch_Missing_Metadata, Arch_Invalid_Metadata,
   --    Arch_Invalid_Dimensions; Arch_Missing_Tensor,
   --    Arch_Invalid_Tensor_Shape, Arch_Invalid_Tensor_Format naming the
   --    tensor; the tokenizer's diagnostics; Memory_Allocation_Failed.
   procedure Prepare
     (Item   : in out Model;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a model.
   --
   --  @param Item The model.
   --  @param Status Success; Lifecycle_Session_Active while a session is
   --    open on it, which leaves it as it was.
   procedure Close (Item : in out Model; Status : out Model_Runner.Errors.Error_Info);

   --  @param Item A model.
   --  @return Whether Prepare succeeded and Close has not run since.
   function Is_Ready (Item : Model) return Boolean;

   --  @param Item A ready model.
   --  @return The file's general.name, or "".
   function Name (Item : Model) return String;

   --  @param Item A ready model.
   --  @return Whether it hears more than English.
   function Is_Multilingual (Item : Model) return Boolean;

   --  @param Item A ready model.
   --  @return How many languages it names.
   function Language_Count (Item : Model) return Natural;

   --  @param Item A ready model.
   --  @param Index 1 .. Language_Count.
   --  @return The language's code, as "da".
   function Language_Code (Item : Model; Index : Positive) return String;

   --  @param Item A ready model.
   --  @param Code A language's code.
   --  @return Whether the model names it.
   function Knows_Language (Item : Model; Code : String) return Boolean;

   --  @param Item A ready model.
   --  @return The bytes its weights take where they lie.
   function Weight_Bytes (Item : Model) return Model_Runner.Bytes.Byte_Count;

   --  @param Item A ready model.
   --  @return The bytes a session on it allocates when opened.
   function Session_Bytes (Item : Model) return Model_Runner.Bytes.Byte_Count;

   --  @param Item A ready model.
   --  @return How many sessions are open on it.
   function Sessions_Open (Item : Model) return Natural;

   -----------------
   -- Transcripts --
   -----------------

   --  The temperatures a window is decoded at, in turn, until one is not
   --  refused: the reference's 0, 0.2, 0.4, 0.6, 0.8 and 1.
   Max_Temperatures : constant := 8;

   type Temperature_List is array (1 .. Max_Temperatures) of Real;

   Reference_Temperatures : constant Temperature_List := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, others => 0.0];

   --  How to transcribe.
   type Options is record
      --  The language spoken, as its code; empty, the model detects it from
      --  the first window.
      Language : Ada.Strings.Unbounded.Unbounded_String;
      --  Tokens a window may decode: the reference's n_text_ctx / 2.
      Max_Tokens : Positive := 224;
      --  Text to prompt the first window with -- a spelling, a name --
      --  bounded as the previous window's text is.
      Initial_Prompt : Ada.Strings.Unbounded.Unbounded_String;
      --  Whether a window is prompted with the text before it.
      Condition_On_Previous : Boolean := True;
      --  Where no language is given: whether it is read off the first
      --  window as decoded -- the logits at <|startoftranscript|> the
      --  no-speech probability is read from already -- rather than from an
      --  encoder pass of its own over the spectrogram's first thirty
      --  seconds as they are, as the reference reads it. The first window's
      --  frames past a short recording are zeros one way and the padding's
      --  own the other, so the two may name different languages on a
      --  recording that barely says; the encoder runs once instead of
      --  twice.
      Detect_From_Window : Boolean := False;
      --  Translate what is said into English, rather than write it in the
      --  language spoken (<|translate|> for <|transcribe|>).
      Translate : Boolean := False;
      --  The temperatures a window is decoded at until it is not refused --
      --  repeating itself past Compression_Threshold, or less likely on
      --  average than Log_Prob_Threshold, and not silent -- the first of
      --  them greedy and the rest sampled, Best_Of times each, the likeliest
      --  of those by its log probability over its length kept. One
      --  temperature of nought is greedy alone.
      Temperatures      : Temperature_List := Reference_Temperatures;
      Temperature_Count : Positive range 1 .. Max_Temperatures := 6;
      Best_Of           : Positive := 5;
      --  Whether each segment's words are timed, as the reference's
      --  word_timestamps times them: the alignment heads' attention over the
      --  window's tokens, warped to its frames. A window then starts where
      --  its last word ended, unless it ended on a time alone.
      Word_Timestamps   : Boolean := False;
      --  Where the draws for sampling start.
      Seed              : Interfaces.Unsigned_64 := 0;
      --  The reference's thresholds.
      No_Speech_Threshold   : Real := 0.6;
      Log_Prob_Threshold    : Real := -1.0;
      Compression_Threshold : Real := 2.4;
   end record;

   --  One word and when it was said, where word times are asked.
   type Word_Timing is record
      Text          : Ada.Strings.Unbounded.Unbounded_String;
      Start_Seconds : Real := 0.0;
      End_Seconds   : Real := 0.0;
      --  Its tokens' probabilities, averaged.
      Probability   : Real := 0.0;
   end record;

   package Word_Vectors is new Ada.Containers.Vectors (Positive, Word_Timing);

   --  One stretch of the recording and what was said in it.
   type Segment is record
      Start_Seconds, End_Seconds : Real := 0.0;
      Text : Ada.Strings.Unbounded.Unbounded_String;
      Average_Log_Probability : Real := 0.0;
      No_Speech_Probability   : Real := 0.0;
      Compression_Ratio       : Real := 0.0;
      --  The window it came from was judged silent: no text.
      Silent    : Boolean := False;
      --  The window it came from repeated itself or was decoded with
      --  little confidence at every temperature: kept, for the reader to
      --  judge.
      Uncertain : Boolean := False;
      --  The temperature its window was decoded at.
      Temperature : Real := 0.0;
      --  Its window decoded Max_Tokens without ending.
      Cut_Short : Boolean := False;
      --  Its words and their times, where Word_Timestamps asked.
      Words : Word_Vectors.Vector;
   end record;

   package Segment_Vectors is new Ada.Containers.Vectors (Positive, Segment);

   --  Where the time went.
   type Statistics is record
      Audio_Seconds       : Real := 0.0;
      Spectrogram_Seconds : Duration := 0.0;
      Encoder_Seconds     : Duration := 0.0;
      Decoder_Seconds     : Duration := 0.0;
      Windows             : Natural := 0;
      Tokens              : Natural := 0;
      --  Of the decoder's positions, those run on the device.
      Device_Positions    : Natural := 0;
   end record;

   --  A recording transcribed.
   type Transcript is record
      --  Every segment's text, in order, as the reference joins them.
      Text     : Ada.Strings.Unbounded.Unbounded_String;
      --  The language heard or given, as its code.
      Language : Ada.Strings.Unbounded.Unbounded_String;
      Segments : Segment_Vectors.Vector;
      Figures  : Statistics;
   end record;

   --------------
   -- Sessions --
   --------------

   type Session is tagged limited private;

   --  Open a session on a model.
   --
   --  @param Item The session; closed first.
   --  @param Source A ready model; it is told, and refuses to close until
   --    the session does.
   --  @param Team The workers products are shared over, or null for this
   --    task alone. The session does not own them.
   --  @param Status Success, Lifecycle_Model_Not_Ready or
   --    Memory_Allocation_Failed.
   procedure Open
     (Item   : in out Session;
      Source : not null access Model;
      Team   : Model_Runner.Backend.CPU.Pool_Reference;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a session. Idempotent.
   --
   --  @param Item The session.
   procedure Close (Item : in out Session);

   --  @param Item A session.
   --  @return Whether it is open.
   function Is_Open (Item : Session) return Boolean;

   --  Whether the encoder's products go to the device where one is open
   --  (Backend.Device): its matrices uploaded once and kept, its thousands
   --  of rows multiplied there; a product the device declines is taken on
   --  the pool. The decoder's few rows stay on the pool either way.
   --
   --  The device knows a matrix by where its bytes lie, so a session that
   --  shares it with a conversation's model gives its matrices back at the
   --  end of each encode, while it still has the turn: kept past it, a
   --  model read again at the same place, or another's, would be answered
   --  with them. One that has the device to itself keeps them, and the
   --  device's closing gives them back.
   --
   --  @param Item The session.
   --  @param On True to use the device.
   --  @param Keep True to keep the matrices on the device between encodes.
   procedure Use_Device (Item : in out Session; On : Boolean; Keep : Boolean := False);

   --  Transcribe a recording.
   --
   --  @param Item An open session.
   --  @param Samples The recording: one channel at sixteen kilohertz.
   --  @param Settings How.
   --  @param Result What was said; empty unless Status is success.
   --  @param Status Success; Generation_Invalid_Request for a language the
   --    model does not name; Generation_Cancelled where Cancel was set;
   --    the spectrogram's, the products' or the tokenizer's diagnostics.
   --  @param Cancel Looked at between windows and between tokens.
   procedure Transcribe
     (Item     : in out Session;
      Samples  : Real_Array;
      Settings : Options;
      Result   : out Transcript;
      Status   : out Model_Runner.Errors.Error_Info;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null);

   --  The encoder over one window's spectrogram, its output kept in the
   --  session for the decoder; what Transcribe does first for each window.
   --
   --  @param Item An open session.
   --  @param Mel The window: Mels rows of Window_Frames.
   --  @param Status Success or the products' diagnostics.
   procedure Encode
     (Item   : in out Session;
      Mel    : Real_Array;
      Status : out Model_Runner.Errors.Error_Info);

   --  The encoder's output for the window last encoded.
   --
   --  @param Item An open session that has encoded a window.
   --  @param Into Receives 1,500 positions of the model's width.
   procedure Copy_Encoded (Item : Session; Into : out Real_Array);

   --  The decoder over a sequence, its cache started again: the logits at
   --  its last token.
   --
   --  @param Item An open session that has encoded a window.
   --  @param Tokens The sequence.
   --  @param Logits Receives one a token of the vocabulary.
   --  @param Status Success, Generation_Prompt_Too_Long or the products'
   --    diagnostics.
   procedure Decode
     (Item   : in out Session;
      Tokens : Model_Runner.Tokenizer.Token_Array;
      Logits : out Real_Array;
      Status : out Model_Runner.Errors.Error_Info);

private

   package T renames Model_Runner.Tensors;

   type Norm is record
      Weight, Bias : T.Real_Array_Access;
   end record;

   type Projection is record
      Weight : T.View;
      Bias   : T.Real_Array_Access;
   end record;

   type Attention_Weights is record
      Q, K, V, Output : Projection;
   end record;

   --  An encoder block's two normalizations' pairs, a block at a time.
   type Pair_List is array (1 .. 2) of T.Real_Array_Access;
   type Pair_Lists is array (1 .. 64) of Pair_List;

   type Block is record
      Attention_Norm : Norm;
      Attention      : Attention_Weights;
      Cross_Norm     : Norm;
      Cross          : Attention_Weights;
      Feed_Norm      : Norm;
      Up, Down       : Projection;
   end record;

   --  On the heap: a block is some twenty views, and a model's two stacks of
   --  sixty-four would be a large frame wherever a Model is declared.
   type Block_Array is array (Positive range <>) of Block;
   type Block_Array_Access is access Block_Array;

   type Code is record
      Text   : String (1 .. 8) := [others => ' '];
      Length : Natural := 0;
   end record;

   type Code_Array is array (1 .. Max_Languages) of Code;

   --  The most tokens a file may list as suppressed.
   Max_Suppressed : constant := 1_024;

   type Token_List is array (1 .. Max_Suppressed) of Model_Runner.Tokenizer.Token_Id;

   --  The most heads word timing reads.
   Max_Alignment_Heads : constant := 64;

   type Head_Place is record
      Block : Positive := 1;
      Head  : Natural := 0;
   end record;

   type Head_List is array (1 .. Max_Alignment_Heads) of Head_Place;

   type Model is limited record
      Ready     : Boolean := False;
      File      : Model_Runner.Byte_Sources.Files.File_Source;
      Container : Model_Runner.GGUF.Containers.Container;
      Arena     : Model_Runner.Bytes.Byte_Array_Access;
      Base      : System.Address := System.Null_Address;
      Span      : Model_Runner.Bytes.Byte_Count := 0;
      Vocabulary : Model_Runner.Tokenizer.Vocabulary;
      Title     : Ada.Strings.Unbounded.Unbounded_String;

      Width          : Element_Count := 0;
      Mels           : Positive := 80;
      Audio_Context  : Element_Count := 1_500;
      Text_Context   : Element_Count := 448;
      Encoder_Blocks, Decoder_Blocks : Natural := 0;
      Encoder_Heads, Decoder_Heads   : Positive := 1;
      Encoder_Feed, Decoder_Feed     : Element_Count := 0;
      Vocabulary_Size : Element_Count := 0;
      Epsilon        : Real := 1.0E-5;
      Multilingual   : Boolean := False;

      End_Of_Text, Start_Of_Transcript, Transcribe_Token, Translate_Token,
      Start_Of_Previous, Start_Of_LM, No_Timestamps, No_Speech, Timestamp_Begin,
      First_Language : Model_Runner.Tokenizer.Token_Id := 0;
      Languages      : Code_Array;
      Language_Total : Natural := 0;
      Suppressed, Begin_Suppressed : Token_List := [others => 0];
      Suppressed_Count, Begin_Suppressed_Count : Natural := 0;
      --  The heads word timing reads: the file's, or the upper half of the
      --  decoder's every head where it names none, as the reference has it.
      Alignment : Head_List;
      Alignment_Count : Natural := 0;

      Conv1, Conv2           : Projection;
      Audio_Positions        : T.Real_Array_Access;
      Encoder                : Block_Array_Access;
      Encoder_Norm           : Norm;
      Token_Table            : T.View;
      Text_Positions         : T.Real_Array_Access;
      Decoder                : Block_Array_Access;
      Decoder_Norm           : Norm;

      Open_Sessions : Natural := 0 with Atomic;
   end record;

   type Model_Access is access all Model;

   type Panel_Array is array (Positive range <>) of Model_Runner.Float_Panels.Panel_Set;
   type Panel_Array_Access is access Panel_Array;

   type Session is tagged limited record
      Source  : Model_Access := null;
      Team    : Model_Runner.Backend.CPU.Pool_Reference := null;
      --  The encoder's output: 1,500 positions of the width.
      Encoded : T.Real_Array_Access;
      Has_Encoded : Boolean := False;
      --  Each decoder block's keys and values of the encoder's output, and
      --  of the decoder's own positions, a row a position.
      Cross_K, Cross_V : T.Group_Room_Access;
      Self_K, Self_V   : T.Group_Room_Access;
      --  Positions the decoder's cache holds.
      Held : Element_Count := 0;
      --  The encoder's scratch.
      Work_A, Work_B, Work_C, Work_D, Work_E : T.Real_Array_Access;
      Scores  : T.Real_Array_Access;
      --  A weight decoded to binary32, and laid out in panels.
      Decoded : T.Real_Array_Access;
      Weight_Panels, Key_Panels, Value_Panels : Model_Runner.Float_Panels.Panel_Set;
      --  Every matrix the encoder multiplies, and the decoder's keys and
      --  values of it, laid out in panels the first time it is heard and
      --  kept: decoding and laying them out again each window was a third
      --  of the encoder's time.
      Packed : Panel_Array_Access;
      --  Each decoder block's keys of what was heard, a head a set, and its
      --  values turned: the two products a token's cross-attention is.
      Cross_Keys, Cross_Values : Panel_Array_Access;
      --  The decoder's scratch: a row a position, the context's rows.
      Dec_X, Dec_H, Dec_Q, Dec_K, Dec_V, Dec_A, Dec_F : T.Real_Array_Access;
      Dec_Scores : T.Real_Array_Access;
      Last_Row, Logits : T.Real_Array_Access;
      --  The alignment heads' scaled scores over the tokens a pass reads,
      --  kept while Capturing: head a, token t, position p at
      --  (a * Count + t) * Audio_Context + p.
      Capturing : Boolean := False;
      Captured  : T.Real_Array_Access;
      --  Whether the encoder's products go to the device; see Use_Device.
      On_Device : Boolean := False;
      --  Whether an encode has the device's turn now.
      Borrowed  : Boolean := False;
      --  Whether the matrices stay on the device between encodes.
      Keep_On_Device : Boolean := False;
      --  Where Whisper's part of the device's cache begins: past the
      --  conversation's, as it stood when the turn was borrowed. Each
      --  decoder block's keys and values of what was heard, then its own
      --  positions', then the encoder's attention's scratch.
      Cache_Base : Element_Count := 0;
      --  Whether what was heard is in the device's cache for this turn,
      --  and the decoder's own positions too: a token then runs on the
      --  device, a sequence a block.
      Cross_On_Device, Self_On_Device : Boolean := False;
      --  Each decoder norm's gain then bias, as the device's norm step
      --  reads one: three a block, then the last. Then each block's keys'
      --  bias, which is nought, and its values', as the device's heads step
      --  reads the two.
      Norm_Pairs : T.Real_Array_Access;
      --  And the encoder's blocks' two normalizations, each its weight and
      --  then its bias, kept with the session: the device keeps what it is
      --  given by where it lies, so a pair made afresh for each window could
      --  lie where the last one did and be read as it.
      Encoder_Pairs : Pair_Lists := [others => [others => null]];
      --  Whether the conversation read halves of the cache before the turn
      --  was borrowed, to be put back.
      Halves_Were : Boolean := False;
      --  Decoder positions run on the device since the session opened.
      Device_Fed : Natural := 0;
      --  Whether the device refused a token's biases folded into its
      --  products, so that they are named apart from then on.
      Folds_Refused : Boolean := False;
      --  How many candidates a window may draw together, for which the
      --  device's cache holds a wide row a position past the rest: each
      --  candidate's keys and values in its own columns. Nought for none.
      Wide : Natural := 0;
      --  A window's candidates drawn together: each one's keys and values
      --  of its own positions (candidate c, block b at (c - 1) * blocks +
      --  b), their logits a row each, and a row's query and blend while
      --  its attention runs.
      Candidate_K, Candidate_V : T.Group_Room_Access;
      Candidate_Logits, Candidate_Query, Candidate_Blend : T.Real_Array_Access;
   end record;

end Model_Runner.Whisper;
