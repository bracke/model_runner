with Model_Runner.GGUF.Containers;

--  A second tokenizer, written from the description rather than the code.
--
--  The forward pass has had an independent reader since the beginning:
--  Reference_Transformer computes the same logits by different arithmetic, on
--  a fixture this repository owns, and 1170 sequences compare them. The
--  tokenizer had nothing of the sort. What checked it was a set of
--  expectations recorded from llama.cpp -- evidence, and good evidence, but
--  it lives in three `.expect` files that each need a model nobody can
--  commit, so on a clean checkout the strongest thing said about the
--  tokenizer was that its own unit tests agreed with themselves.
--
--  This reads the vocabulary out of the container and encodes text by the
--  rule the format describes: replace each space with the word marker,
--  put one in front, split what is left into UTF-8 characters, then merge
--  the adjacent pair whose combined piece has the best score, over and over,
--  until no pair in the vocabulary is left. A character with no piece of its
--  own becomes its byte-fallback tokens, and failing that the unknown token.
--
--  It shares no code with the engine: it looks pieces up by scanning the
--  vocabulary it read, which is slow and obvious, where the engine keeps a
--  hash table and a symbol list. A mistake in either is unlikely to be the
--  same mistake.
--
--  Task safety: one instance per task.
package Reference_Tokenizer is

   type Vocabulary is limited private;

   Max_Tokens : constant := 4096;

   type Token_Vector is array (Positive range <>) of Integer;

   --  Read the vocabulary from a parsed container.
   --
   --  @param Item Vocabulary to fill.
   --  @param Source Parsed container.
   --  @param Loaded False when the container carries no usable vocabulary.
   procedure Load
     (Item   : in out Vocabulary;
      Source : Model_Runner.GGUF.Containers.Container;
      Loaded : out Boolean);

   --  Release a vocabulary. Idempotent.
   --
   --  @param Item Vocabulary to release.
   procedure Close (Item : in out Vocabulary);

   --  How many pieces the vocabulary holds.
   --
   --  @param Item Vocabulary to inspect.
   --  @return Piece count.
   function Size (Item : Vocabulary) return Natural;

   --  Encode text.
   --
   --  @param Item Loaded vocabulary.
   --  @param Text Text to encode.
   --  @param Add_Beginning Whether to emit the beginning-of-text token first.
   --  @param Tokens Identifiers produced.
   --  @param Last Number produced.
   procedure Encode
     (Item          : Vocabulary;
      Text          : String;
      Add_Beginning : Boolean;
      Tokens        : out Token_Vector;
      Last          : out Natural);

private

   Max_Pieces : constant := 4096;
   Max_Piece  : constant := 64;

   type Piece is record
      Text  : String (1 .. Max_Piece) := [others => ' '];
      Last  : Natural := 0;
      Score : Float := 0.0;
   end record;

   type Piece_Array is array (1 .. Max_Pieces) of Piece;
   type Piece_Array_Access is access Piece_Array;

   type Vocabulary is limited record
      Pieces    : Piece_Array_Access := null;
      Count     : Natural := 0;
      Beginning : Integer := -1;
      Unknown   : Integer := -1;
   end record;

end Reference_Tokenizer;
