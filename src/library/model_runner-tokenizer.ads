private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Containers.Vectors;
private with Ada.Finalization;
private with Ada.Strings.Hash;

with Model_Runner.Errors;
with Model_Runner.GGUF.Containers;
with Model_Runner.Limits;
with Model_Runner.Text;

--  Tokenization for the supported model corpus.
--
--  Supported capability declaration. V1 implements exactly one tokenizer
--  model, the SentencePiece unigram vocabulary that GGUF names "llama":
--
--    Vocabulary        token strings with per-token scores and token types
--    Merge behaviour   greedy highest-score adjacent merge over code points
--    Normalization     none beyond the SentencePiece space substitution
--    Pre-tokenization  optional dummy space prefix; U+2581 stands for a space
--    Byte fallback     tokens named <0xNN> for bytes with no vocabulary entry
--    Added tokens      recognized through the token-type array
--    Special tokens    beginning, end, unknown, padding and separator ids
--    BOS and EOS       controlled by the model's add_bos_token/add_eos_token
--    Incremental       decoding buffers partial UTF-8 across token boundaries
--
--  Any other tokenizer model is rejected as unsupported before generation.
--  Nothing here infers behaviour from a file name.
--
--  Task safety: a Vocabulary is built once and is immutable afterwards; a
--  Decoder is mutable state owned by one session.
package Model_Runner.Tokenizer is

   --  A vocabulary index. Negative and out-of-range values are rejected
   --  wherever a token identifier is accepted.
   type Token_Id is range -1 .. 2 ** 31 - 1;

   No_Token : constant Token_Id := -1;

   type Token_Array is array (Positive range <>) of Token_Id;

   --  Tokenizer models this crate can name.
   --  Which algorithm a vocabulary is tokenized with.
   --
   --  SentencePiece merges by score and marks a space with a visible
   --  character; byte-pair encoding merges by rank from a table the file
   --  carries, and represents every byte as a printable character first so
   --  that no merge ever straddles a partial character.
   --
   --  WordPiece neither merges nor ranks: it changes the text first --
   --  lower-cased, accents off, punctuation and ideographs cut loose -- and
   --  then spells each word from the front with the longest piece the
   --  vocabulary carries. A piece that starts a word is written with a
   --  leading U+2581 and one that continues it is written bare, which is
   --  the reverse of the two-hash convention the architecture's papers
   --  describe and is what a converted vocabulary actually holds.
   type Model_Kind is
     (Kind_SentencePiece, Kind_BPE, Kind_WordPiece, Kind_Unsupported);

   --  Per-token classification carried by the model.
   type Token_Class is
     (Class_Normal,
      Class_Unknown,
      Class_Control,
      Class_User_Defined,
      Class_Unused,
      Class_Byte);

   --  A loaded vocabulary. Release with Close, which is idempotent.
   type Vocabulary is tagged limited private;

   --  Load a vocabulary from container metadata.
   --
   --  @param Item Vocabulary to fill in; closed first.
   --  @param Source Validated container.
   --  A key that is absent and a key that is wrong are not the same. Not every
   --  model declares every special token, so a missing identifier leaves it
   --  unset. An identifier that is present but names no token, or a flag that
   --  is present but is not a boolean, stops the load: ignoring it would
   --  tokenize as though the file had said nothing, and change the prompt the
   --  model sees without saying so. Minus one is accepted and means the model
   --  has no such token, which is how files without one write it.
   --
   --  @param Bounds Limits applied to the vocabulary size and token lengths.
   --  @param Status Success, a Tokenizer diagnostic, or the container's own
   --    diagnostic for a metadata key that is present and wrong.
   procedure Load
     (Item   : in out Vocabulary;
      Source : Model_Runner.GGUF.Containers.Container;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a vocabulary.
   --
   --  @param Item Vocabulary to release.
   procedure Close (Item : in out Vocabulary);

   --  Report whether a vocabulary is loaded.
   --
   --  @param Item Vocabulary to inspect.
   --  @return True when Load succeeded.
   function Is_Loaded (Item : Vocabulary) return Boolean;

   --  Number of tokens.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Token count.
   function Size (Item : Vocabulary) return Natural;

   --  Bytes of token text this vocabulary holds.
   --
   --  A real vocabulary is tens of thousands of strings and megabytes of
   --  pool. It was allocated and never accounted for, so a memory report
   --  read zero against the category named for it.
   --
   --  @param Item Vocabulary to measure.
   --  @return Bytes in use, zero when the vocabulary is not loaded.
   function Storage_Bytes (Item : Vocabulary) return Natural;

   --  Tokenizer model the vocabulary was loaded from.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Model kind.
   function Kind (Item : Vocabulary) return Model_Kind;

   --  Stable identifier of the tokenizer model, as written by the file.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Model name such as "llama"; never localized.
   function Model_Name (Item : Vocabulary) return String;

   --  Beginning-of-sequence token, or No_Token.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Token identifier.
   function Beginning_Token (Item : Vocabulary) return Token_Id;

   --  End-of-sequence token, or No_Token.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Token identifier.
   function End_Token (Item : Vocabulary) return Token_Id;

   --  Unknown token, or No_Token.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Token identifier.
   function Unknown_Token (Item : Vocabulary) return Token_Id;

   --  Whether the model asks for a beginning token to be prepended.
   --
   --  @param Item Vocabulary to inspect.
   --  @return True when add_bos_token was set or defaulted on.
   function Adds_Beginning (Item : Vocabulary) return Boolean;

   --  Whether the model asks for an end token to be appended.
   --
   --  @param Item Vocabulary to inspect.
   --  @return True when add_eos_token was set.
   function Adds_End (Item : Vocabulary) return Boolean;

   --  Report whether byte fallback tokens are present.
   --
   --  @param Item Vocabulary to inspect.
   --  @return True when every byte value has a <0xNN> token.
   function Has_Byte_Fallback (Item : Vocabulary) return Boolean;

   --  Raw text of a token, exactly as the vocabulary stores it.
   --
   --  The SentencePiece space marker is not translated here; Decode does that.
   --
   --  @param Item Vocabulary to inspect.
   --  @param Token Token identifier.
   --  @return Stored text, or an empty string when out of range.
   function Token_Text (Item : Vocabulary; Token : Token_Id) return String;

   --  Classification of a token.
   --
   --  @param Item Vocabulary to inspect.
   --  @param Token Token identifier.
   --  @return Token class; Class_Unused when out of range.
   function Class_Of (Item : Vocabulary; Token : Token_Id) return Token_Class;

   --  Look up a token by its exact stored text.
   --
   --  @param Item Vocabulary to inspect.
   --  @param Text Stored text to find.
   --  @return Token identifier, or No_Token.
   function Find (Item : Vocabulary; Text : String) return Token_Id;

   --  Report whether a token identifier is inside the vocabulary.
   --
   --  @param Item Vocabulary to inspect.
   --  @param Token Token identifier.
   --  @return True when the identifier is usable.
   function Is_Valid (Item : Vocabulary; Token : Token_Id) return Boolean;

   ---------------------------------------------------------------------------
   --  Encoding
   ---------------------------------------------------------------------------

   --  Encode text into tokens.
   --
   --  @param Item Loaded vocabulary.
   --  @param Text UTF-8 input.
   --  @param Add_Beginning Prepend the beginning token when the model has one.
   --  @param Add_End Append the end token when the model has one.
   --  @param Target Buffer receiving the tokens.
   --  @param Last Number of tokens written.
   --  @param Status Success, Tokenizer_Invalid_UTF8, Tokenizer_Input_Too_Long
   --    or Tokenizer_Buffer_Too_Small.
   procedure Encode
     (Item          : Vocabulary;
      Text          : String;
      Add_Beginning : Boolean;
      Add_End       : Boolean;
      Target        : out Token_Array;
      Last          : out Natural;
      Status        : out Model_Runner.Errors.Error_Info);

   ---------------------------------------------------------------------------
   --  Decoding
   ---------------------------------------------------------------------------

   --  Text a token contributes, with the space marker and byte tokens
   --  resolved.
   --
   --  @param Item Loaded vocabulary.
   --  @param Token Token identifier.
   --  @param First True when this is the first token of a sequence, which
   --    suppresses the leading space SentencePiece adds.
   --  @return Contributed bytes, possibly an incomplete UTF-8 sequence when
   --    the token is a byte-fallback token.
   function Decode_Token
     (Item  : Vocabulary;
      Token : Token_Id;
      First : Boolean := False) return String;

   --  Decode a whole token sequence.
   --
   --  @param Item Loaded vocabulary.
   --  @param Tokens Tokens to decode.
   --  @return Decoded text.
   function Decode (Item : Vocabulary; Tokens : Token_Array) return String;

   --  Incremental decoder state.
   --
   --  Generated text is released only up to a UTF-8 sequence boundary, so a
   --  code point split across two tokens is never emitted malformed.
   type Decoder is private;

   --  Reset a decoder.
   --
   --  SentencePiece encodes a leading space as part of the token, and a
   --  sequence encoded from its beginning carries a dummy prefix that must
   --  be dropped when decoding. Tokens that continue text already emitted --
   --  a generated continuation after a prompt -- carry no such prefix, and
   --  dropping a space there deletes a character the model produced.
   --
   --  @param Item Decoder to reset.
   --  @param Continuing True when the tokens that follow continue text that
   --    has already been emitted, so the first piece keeps its leading space.
   procedure Reset (Item : out Decoder; Continuing : Boolean := False);

   --  Push one token and return the text that is safe to emit.
   --
   --  @param Item Decoder state.
   --  @param Source Loaded vocabulary.
   --  @param Token Token to decode.
   --  @return Bytes that form complete UTF-8 sequences; possibly empty.
   function Push
     (Item   : in out Decoder;
      Source : Vocabulary;
      Token  : Token_Id) return String;

   --  Release any buffered bytes at the end of a sequence.
   --
   --  Bytes that never completed a sequence are returned as they are, so the
   --  caller sees the model's actual output rather than silence.
   --
   --  @param Item Decoder state.
   --  @return Remaining buffered bytes.
   function Flush (Item : in out Decoder) return String;

private

   Max_Pending : constant := 8;

   type Decoder is record
      Started : Boolean := False;
      Pending : String (1 .. Max_Pending) := [others => ' '];
      Length  : Natural := 0;
   end record;

   type Token_Entry is record
      First  : Natural := 0;
      Last   : Natural := 0;
      Score  : Float := 0.0;
      Class  : Token_Class := Class_Normal;
   end record;

   package Token_Vectors is
     new Ada.Containers.Vectors (Positive, Token_Entry);

   package Token_Maps is
     new Ada.Containers.Indefinite_Hashed_Maps
       (Key_Type        => String,
        Element_Type    => Token_Id,
        Hash            => Ada.Strings.Hash,
        Equivalent_Keys => "=");

   --  Byte-pair merges, keyed by the two pieces with a space between them,
   --  which is how the file writes them. The value is the rank: the lower it
   --  is the earlier the merge is applied, and a pair that is absent is one
   --  the vocabulary never merges.
   --  Which rule cuts text into pieces before any merging.
   --
   --  They differ in what may lead a word and in how digits are grouped, and
   --  the differences are not cosmetic: a model is trained on one answer.
   type Cut_Rule is
     (Rule_GPT2, Rule_Falcon, Rule_SmolLM, Rule_Llama3, Rule_Qwen2);

   package Merge_Maps is
     new Ada.Containers.Indefinite_Hashed_Maps
       (Key_Type        => String,
        Element_Type    => Natural,
        Hash            => Ada.Strings.Hash,
        Equivalent_Keys => "=");

   type Text_Pool is access String;

   type Byte_Token_Array is array (0 .. 255) of Token_Id;

   type Vocabulary is
     limited new Ada.Finalization.Limited_Controlled with record
      Loaded        : Boolean := False;
      Model         : Model_Kind := Kind_Unsupported;
      Model_Text    : Model_Runner.Text.Bounded;
      Pool          : Text_Pool := null;
      Pool_Used     : Natural := 0;
      Entries       : Token_Vectors.Vector;
      Lookup        : Token_Maps.Map;
      Beginning     : Token_Id := No_Token;
      Ending        : Token_Id := No_Token;
      Unknown       : Token_Id := No_Token;
      Add_Beginning : Boolean := True;
      Add_End       : Boolean := False;
      Byte_Tokens   : Byte_Token_Array := [others => No_Token];
      Byte_Fallback : Boolean := False;
      Merges        : Merge_Maps.Map;
      Cutting       : Cut_Rule := Rule_GPT2;

      --  The longest piece this vocabulary calls a control token or one of
      --  its author's own and that opens a bracket, which is as far as the
      --  scan for a marker in the text can ever have to look. Zero when
      --  there is no such piece, and then the scan does not run at all.
      --
      --  It is here because the scan used to reach Max_Token_Bytes at every
      --  bracket in the text, and text is untrusted: sixty thousand brackets
      --  -- well inside the documented input limit -- took twenty-five
      --  seconds where the same length of ordinary text took four
      --  hundredths.
      Longest_Marker : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Vocabulary);

end Model_Runner.Tokenizer;
