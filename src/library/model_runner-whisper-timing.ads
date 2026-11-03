with Model_Runner.Numerics;

--  When each word was said: the reference's timing.py, its arithmetic.
--
--  A few of the decoder's cross-attention heads (the file's alignment heads)
--  look, at each token, at the stretch of sound the token was heard in.
--  Their scores over a window's tokens and frames are made into a cost the
--  way find_alignment makes them:
--
--  1. a softmax of each head's scores over the frames heard (the window's
--     content, halved: an encoder position is two frames);
--  2. each frame's column standardized over the tokens (its mean taken
--     away and divided by its deviation, the population's);
--  3. a median over seven frames along each row, the ends reflected;
--  4. the heads averaged;
--
--  and dynamic time warping walks the cheapest path from the first token
--  and frame to the last, a token's first frame on the path being when it
--  was said. The steps are the reference's to the tie: a diagonal where it
--  is cheaper than both others, down where cheaper than both others,
--  across otherwise.
--
--  Task safety: pure.
package Model_Runner.Whisper.Timing is

   subtype Wide_Real is Model_Runner.Numerics.Wide_Real;

   type Cost_Matrix is array (Natural range <>, Natural range <>) of Wide_Real;

   --  The cost of a token at a frame from the heads' scores.
   --
   --  @param Scores Each head's scaled scores: head a, token t, frame f at
   --    (a * Tokens + t) * Stride + f.
   --  @param Heads The heads the scores are of.
   --  @param Tokens The tokens they are of.
   --  @param Frames The frames heard.
   --  @param Stride Frames a row of scores holds, past those heard.
   --  @param Into Receives the averaged, filtered, standardized weights,
   --    Tokens by Frames.
   procedure Weights
     (Scores                 : Model_Runner.Numerics.Real_Array;
      Heads, Tokens, Frames  : Positive;
      Stride                 : Positive;
      Into                   : out Cost_Matrix)
   with Pre => Into'Length (1) = Tokens and then Into'Length (2) = Frames;

   --  A median over Width frames along each row, the ends reflected.
   --
   --  @param Item The rows; filtered in place.
   --  @param Width An odd width.
   procedure Median_Filter (Item : in out Cost_Matrix; Width : Positive := 7);

   type Index_List is array (Positive range <>) of Natural;

   --  The cheapest path through a cost, from (0, 0) to the last cell.
   --
   --  @param Cost Rows by columns.
   --  @param Rows_Of Receives each step's row, first to last.
   --  @param Columns_Of Receives each step's column.
   --  @param Steps How many steps the path took.
   procedure Warp
     (Cost       : Cost_Matrix;
      Rows_Of    : out Index_List;
      Columns_Of : out Index_List;
      Steps      : out Natural)
   with Pre => Rows_Of'Length >= Cost'Length (1) + Cost'Length (2)
     and then Columns_Of'Length = Rows_Of'Length;

end Model_Runner.Whisper.Timing;
