with Model_Runner.Tokenizer;

--  Tokens proposed from the text already read, with no second model.
--
--  Speculative decoding needs somewhere for proposals to come from, and the
--  usual somewhere is a smaller model of the same vocabulary: it guesses,
--  the target checks the guesses in one pass, and the guesses it agrees with
--  are had for the price of one. That works and it costs a second model
--  resident in memory and one pass of that model per proposal.
--
--  A context is also a source of guesses, and it is free. Text repeats: a
--  model asked to quote, edit, summarize or continue something says what it
--  has already read, and what followed a phrase the last time it appeared is
--  a good guess at what follows it now. So the proposal is a search rather
--  than an inference -- find the most recent earlier occurrence of the last
--  few tokens, and propose the tokens that came after it.
--
--  WHAT IT IS WORTH, and the range is the point rather than the best of it.
--  Replayed over real token streams from this engine, counting how many
--  passes over the weights a run would have taken:
--
--    quoting the prompt back    5.00 tokens a pass
--    prose with nothing to
--      look up                  1.49
--
--  The first is a repetition task and flatters this; the second had a
--  fourteen-token prompt and is the floor. Priced against this host --
--  twenty-five milliseconds a generated token, about three an extra row of
--  a batch -- that is about 2.6 times on text that quotes its context and
--  1.36 on prose that does not.
--
--  WHY IT CANNOT LOSE MUCH. A proposal the target rejects costs one row of a
--  batch that was going to happen anyway, and a row is an eighth of what a
--  pass costs on this host. A round that proposes eight and has all eight
--  refused costs about a third more than the single token it would have
--  produced alone; a round that has them accepted costs a third more than
--  one token and produces nine.
--
--  Task safety: pure functions over arrays; no state.
package Model_Runner.Lookup is

   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;
   subtype Token_Array is Model_Runner.Tokenizer.Token_Array;

   --  How many tokens at the end of the history are matched against it.
   --
   --  TWO, and it is a measurement rather than a preference. Replayed over
   --  three real token streams -- a repetition, a continuation and fresh
   --  prose -- a key of two gave 5.00, 5.43 and 1.52 tokens a pass where
   --  three gave 4.27, 3.79 and 1.46 and four gave 3.73 and less. A longer
   --  key proposes less often and is not enough more often right to pay for
   --  it: what it buys is precision on a thing whose failures are nearly
   --  free.
   --
   --  One is not the floor of this. A single token matches nearly anywhere
   --  and its proposals are mostly wrong, and it still read 6.21 on the
   --  repetition -- but that is a task where everything works, and it is the
   --  case where a wrong proposal is cheapest. Two is where all three
   --  streams agree.
   Default_Key : constant := 2;

   --  Propose what followed the end of this history the last time it
   --  occurred.
   --
   --  The search runs backwards from the end, so a phrase that occurs many
   --  times proposes what followed it MOST RECENTLY rather than most often.
   --  That is llama.cpp's simple form and it is what the figures above were
   --  measured with; a map from n-grams to the m-grams that followed them,
   --  with counts and acceptance feedback, is the elaborate form and is not
   --  this.
   --
   --  Nothing is proposed when the history is shorter than a key and a
   --  match, when no earlier occurrence exists, or when the occurrence found
   --  is the one at the end with nothing after it.
   --
   --  @param History Tokens read and generated so far, oldest first.
   --  @param Into Receives the proposal, filled from its first index.
   --  @param Count How many of Into were filled, which may be zero.
   --  @param Key How many tokens at the end of History must match.
   procedure Propose
     (History : Token_Array;
      Into    : out Token_Array;
      Count   : out Natural;
      Key     : Positive := Default_Key);

end Model_Runner.Lookup;
