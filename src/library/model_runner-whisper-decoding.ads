with Interfaces;

with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

--  What a Whisper decoder may say next, and which of it it says.
--
--  The rules are the reference's (openai/whisper, decoding.py), applied to
--  one step's logits in the reference's order:
--
--  1. SuppressBlank. At the first sampled step, a blank (token 220, " ")
--     and the end of text are not allowed: a transcript does not begin
--     empty or with a space alone.
--  2. SuppressTokens. The tokens the file lists -- the non-speech symbols,
--     and the task and context markers -- are never said.
--  3. ApplyTimestampRules, where the transcript carries times:
--     * <|notimestamps|> is never said.
--     * Times come in pairs, except right before the end: after a time
--       that closed a pair, text must follow; after one that opened a
--       pair, another time or the end must.
--     * Times do not go back, and a segment is not of zero length: a time
--       is no earlier than the last one, and later than it unless it
--       closes the pair the last one opened.
--     * The first step is a time, no later than one second
--       (max_initial_timestamp, fifty steps of 0.02 s).
--     * Where all the times together are likelier than the likeliest
--       text token, a time is said.
--
--  Greedy decoding picks the largest logit left -- the first of equals --
--  and the log probability it adds is its log-softmax over what is left.
--
--  Task safety: pure functions on their arguments.
package Model_Runner.Whisper.Decoding is

   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;
   subtype Token_Array is Model_Runner.Tokenizer.Token_Array;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   --  The most tokens a file may list as suppressed.
   Max_Suppressed : constant := 1_024;

   type Token_List is array (1 .. Max_Suppressed) of Token_Id;

   --  What the rules need of a model's vocabulary.
   type Rules is record
      End_Of_Text     : Token_Id := 0;
      No_Timestamps   : Token_Id := 0;
      Timestamp_Begin : Token_Id := 0;
      --  Tokens the logits cover.
      Vocabulary      : Natural := 0;
      Suppressed      : Token_List := [others => 0];
      Suppressed_Count : Natural := 0;
      Begin_Suppressed : Token_List := [others => 0];
      Begin_Suppressed_Count : Natural := 0;
      --  Whether the transcript carries times.
      Timestamps      : Boolean := True;
      --  The latest first time, in steps of 0.02 s.
      Max_Initial_Timestamp : Natural := 50;
   end record;

   --  Apply the rules to one step's logits.
   --
   --  @param Item The rules.
   --  @param Sampled The tokens said so far in this window, after the
   --    prompt.
   --  @param Logits The step's logits, one a token from index 0; those
   --    not allowed become minus infinity.
   procedure Apply (Item : Rules; Sampled : Token_Array; Logits : in out Real_Array)
   with Pre => Logits'Length = Model_Runner.Numerics.Element_Count (Item.Vocabulary);

   --  The largest logit's token: the first of equals.
   --
   --  @param Logits The logits, from index 0.
   --  @return Its token.
   function Pick (Logits : Real_Array) return Token_Id;

   --  A token's log probability under the logits: its log-softmax.
   --
   --  @param Logits The logits, from index 0; minus infinity is allowed.
   --  @param Token The token.
   --  @return Its log probability, in binary64.
   function Log_Probability (Logits : Real_Array; Token : Token_Id) return Model_Runner.Numerics.Wide_Real;

   --  The probability of one token under the softmax of all of them.
   --
   --  @param Logits The logits, from index 0.
   --  @param Token The token.
   --  @return Its probability.
   function Probability (Logits : Real_Array; Token : Token_Id) return Model_Runner.Numerics.Wide_Real;

   --  A stream of uniform draws for sampling, the same for the same seed:
   --  SplitMix64. The reference draws from torch's generator, which nothing
   --  here imitates, so a sampled window is the reference's in kind, not to
   --  the token.
   type Stream is private;

   --  @param Seed Where the stream starts.
   --  @return The stream.
   function Seeded (Seed : Interfaces.Unsigned_64) return Stream;

   --  The next draw.
   --
   --  @param Item The stream, moved on.
   --  @param Draw Receives a value in [0, 1).
   procedure Next (Item : in out Stream; Draw : out Model_Runner.Numerics.Wide_Real);

   --  A token drawn from the softmax of the logits over a temperature, as
   --  the reference's Categorical (logits / temperature) draws one: the
   --  first token whose running probability passes the draw.
   --
   --  @param Logits The logits, from index 0; minus infinity never drawn.
   --  @param Temperature Above nought.
   --  @param Draw A value in [0, 1).
   --  @return The token.
   function Sample
     (Logits : Real_Array; Temperature : Model_Runner.Numerics.Real; Draw : Model_Runner.Numerics.Wide_Real)
      return Token_Id;

   --  How much a text compresses: its bytes over its zlib stream's at
   --  level 6, as the reference measures a transcript that repeats itself.
   --
   --  @param Text The text.
   --  @return The ratio; 0 for an empty text.
   function Compression_Ratio (Text : String) return Model_Runner.Numerics.Wide_Real;

private

   type Stream is record
      State : Interfaces.Unsigned_64 := 0;
   end record;

end Model_Runner.Whisper.Decoding;
