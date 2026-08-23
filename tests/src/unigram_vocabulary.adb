with Model_Runner.GGUF;
with Model_Runner.Numerics;

with Interfaces;

with Fixtures;

package body Unigram_Vocabulary is

   package G renames Model_Runner.GGUF;

   use type Model_Runner.Numerics.Real;

   --  U+2581, which this road writes where the text had a space and puts in
   --  front of the first word of a text.
   Mark : constant String :=
     [Character'Val (16#E2#), Character'Val (16#96#), Character'Val (16#81#)];

   type Text_Access is access constant String;

   --  The pieces, in identifier order. The scores below are what make this
   --  fixture worth having: on the text "abc", which this road sees as
   --  <mark>abc, the two roads part.
   --
   --  Merging by score takes the best-scoring adjacent join first. The
   --  joins available are <mark>a at -3.0 and bc at -3.0; the leftmost of
   --  equals wins, so <mark>a goes first, and then <mark>ab at -1.0 beats
   --  bc, leaving <mark>ab and c -- which sums to -7.0.
   --
   --  The best path is <mark>a and bc, which sums to -6.0. Nothing about
   --  the second answer is reachable by merging: the merge that would have
   --  led to it was taken away by the one before it.
   Pieces : constant array (1 .. 10) of Text_Access :=
     [new String'("<unk>"),
      new String'("<s>"),
      new String'("</s>"),
      new String'(Mark),
      new String'("a"),
      new String'("b"),
      new String'("c"),
      new String'(Mark & "a"),
      new String'(Mark & "ab"),
      new String'("bc")];

   --  One score a piece, in the same order. The three special ones score
   --  nothing and are never on a path; the rest are log probabilities, which
   --  is why they are negative and why they are summed.
   Scores : constant array (1 .. 10) of Model_Runner.Numerics.Real :=
     [0.0, 0.0, 0.0,
      -8.0,    --  the marker alone: expensive, so no path takes it bare
      -7.0,    --  a
      -7.0,    --  b
      -6.0,    --  c
      -3.0,    --  <mark>a
      -1.0,    --  <mark>ab
      -3.0];   --  bc

   --  The token type as the file writes it: two is the unknown piece, three
   --  a control token, one an ordinary piece.
   Sorts : constant array (1 .. 10) of Interfaces.Integer_32 :=
     [2, 3, 3, 1, 1, 1, 1, 1, 1, 1];

   -----------
   -- Build --
   -----------

   procedure Build (Image : out Model_Runner.Bytes.Byte_Array_Access) is
      Builder : Fixtures.Builder;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "t5");

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.tokens", G.Value_String, Pieces'Length);
      for Index in Pieces'Range loop
         Fixtures.String_Element (Builder, Pieces (Index).all);
      end loop;
      Fixtures.End_Array (Builder);

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.scores", G.Value_Float32, Scores'Length);
      for Index in Scores'Range loop
         Fixtures.Float_Element (Builder, Scores (Index));
      end loop;
      Fixtures.End_Array (Builder);

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.token_type", G.Value_Int32, Sorts'Length);
      for Index in Sorts'Range loop
         Fixtures.Int32_Element (Builder, Sorts (Index));
      end loop;
      Fixtures.End_Array (Builder);

      Fixtures.Add_U32 (Builder, "tokenizer.ggml.unknown_token_id", 0);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 1);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.eos_token_id", 2);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_bos_token", False);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_eos_token", False);

      --  Stated, and stated as the published file states them: a marker in
      --  front of the first word, and a run of spaces left as it stands.
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_space_prefix", True);
      Fixtures.Add_Bool
        (Builder, "tokenizer.ggml.remove_extra_whitespaces", False);

      Fixtures.Build (Builder, Image);
   end Build;

end Unigram_Vocabulary;
