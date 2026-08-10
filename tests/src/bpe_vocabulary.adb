with Model_Runner.GGUF;

with Fixtures;

package body BPE_Vocabulary is

   package G renames Model_Runner.GGUF;

   --  U+0120 and U+0109: what a byte-level vocabulary writes where the text
   --  had a space and a tab. Neither byte stands for itself, because a merge
   --  table written as text cannot hold a character the format uses as its
   --  own separator.
   Space_Mark : constant String :=
     [Character'Val (16#C4#), Character'Val (16#A0#)];
   Tab_Mark   : constant String :=
     [Character'Val (16#C4#), Character'Val (16#89#)];

   type Text_Access is access constant String;

   --  The pieces, in identifier order.
   Pieces : constant array (1 .. 27) of Text_Access :=
     [new String'("<unk>"),
      new String'("a"),
      new String'("b"),
      new String'("c"),
      new String'("x"),
      new String'("1"),
      new String'("2"),
      new String'("3"),
      new String'("4"),
      new String'(Space_Mark),
      new String'(Tab_Mark),
      new String'("ab"),
      new String'(Space_Mark & "a"),
      new String'(Space_Mark & "ab"),
      new String'("12"),
      new String'("123"),
      new String'("1234"),
      new String'(Tab_Mark & "a"),
      new String'(Tab_Mark & "ab"),
      new String'(Space_Mark & "1"),
      new String'(Space_Mark & "12"),
      new String'(Space_Mark & "123"),
      new String'(Space_Mark & "1234"),
      new String'("bc"),

      --  Two markers, which a chat template writes into the text it renders.
      --  Their spelling merges into nothing here -- no piece and no merge
      --  covers "<", "|" or any of their letters -- so a reader that missed
      --  them would produce a run of unknown tokens rather than one token,
      --  which is the shape of the mistake this is here to catch.
      new String'("<|im_start|>"),
      new String'("<|im_end|>"),

      --  A marker that is a proper prefix of another one. Without it the
      --  rule that the longest match wins cannot be told from the rule that
      --  the first match does, and a vocabulary is untrusted input: a file
      --  may carry such a pair whether or not a trained model would.
      new String'("<|im_start")];

   --  The merge table, in rank order, which is deliberately not the order the
   --  pieces are written above. "a b" is last and "b c" is next to last, so
   --  in "abc" the leftmost pair the table holds is not the one it ranks
   --  first: by rank that is "a" and "bc", and by position "ab" and "c".
   Merges : constant array (1 .. 13) of Text_Access :=
     [new String'(Space_Mark & " a"),
      new String'(Space_Mark & "a b"),
      new String'(Tab_Mark & " a"),
      new String'(Tab_Mark & "a b"),
      new String'(Space_Mark & " 1"),
      new String'(Space_Mark & "1 2"),
      new String'(Space_Mark & "12 3"),
      new String'(Space_Mark & "123 4"),
      new String'("1 2"),
      new String'("12 3"),
      new String'("123 4"),
      new String'("b c"),
      new String'("a b")];

   -----------
   -- Build --
   -----------

   procedure Build
     (Pre   : String;
      Image : out Model_Runner.Bytes.Byte_Array_Access)
   is
      Builder : Fixtures.Builder;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "llama");
      Fixtures.Add_String (Builder, "tokenizer.ggml.model", "gpt2");

      if Pre /= "" then
         Fixtures.Add_String (Builder, "tokenizer.ggml.pre", Pre);
      end if;

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.tokens", G.Value_String, Pieces'Length);
      for Index in Pieces'Range loop
         Fixtures.String_Element (Builder, Pieces (Index).all);
      end loop;
      Fixtures.End_Array (Builder);

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.merges", G.Value_String, Merges'Length);
      for Index in Merges'Range loop
         Fixtures.String_Element (Builder, Merges (Index).all);
      end loop;
      Fixtures.End_Array (Builder);

      --  Scores are meaningless for a byte-pair vocabulary -- the rank in the
      --  merge table decides -- and are written flat so that a reader that
      --  used them instead would produce a different answer rather than the
      --  same one by accident.
      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.scores", G.Value_Float32, Pieces'Length);
      for Index in Pieces'Range loop
         Fixtures.Float_Element (Builder, 0.0);
      end loop;
      Fixtures.End_Array (Builder);

      Fixtures.Begin_Array
        (Builder, "tokenizer.ggml.token_type", G.Value_Int32, Pieces'Length);
      Fixtures.Int32_Element (Builder, 2);   --  <unk>
      for Index in 2 .. Pieces'Length - 3 loop
         Fixtures.Int32_Element (Builder, 1);
      end loop;
      Fixtures.Int32_Element (Builder, 3);   --  <|im_start|>, a control token
      Fixtures.Int32_Element (Builder, 3);   --  <|im_end|>
      Fixtures.Int32_Element (Builder, 3);   --  <|im_start
      Fixtures.End_Array (Builder);

      --  The markers double as the beginning and end tokens, so that asking
      --  for them and writing them into the text reach the same identifier.
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.unknown_token_id", 0);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.bos_token_id", 24);
      Fixtures.Add_U32 (Builder, "tokenizer.ggml.eos_token_id", 25);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_bos_token", False);
      Fixtures.Add_Bool (Builder, "tokenizer.ggml.add_eos_token", False);

      Fixtures.Build (Builder, Image);
   end Build;

end BPE_Vocabulary;
