with AUnit.Assertions;

with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Interfaces;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Kernels;
with Model_Runner.Numerics;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

package body Tests.Sampling_Cases is

   use AUnit.Assertions;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Tokenizer.Token_Id;

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package S renames Model_Runner.Sampling;
   package Stop renames Model_Runner.Stops;
   package Tmpl renames Model_Runner.Templates;
   package Vocab renames Model_Runner.Tokenizer;

   Vocabulary : constant := 8;

   subtype Logit_Vector is N.Real_Array (0 .. Vocabulary - 1);

   --  The sampler refuses what it cannot sample from.
   --
   --  Four checks stood unheld: a configuration whose temperature is not a
   --  number a distribution can be built from, a sampler opened for a
   --  vocabulary of nothing, sampling from a sampler that was never opened
   --  or has been closed, and sampling when every candidate has been
   --  forbidden. The last is not exotic -- forbidding tokens is a caller's
   --  own operation, and forbidding all of them is a thing a loop can do.
   procedure Sampler_Refuses_What_It_Cannot_Sample
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Config  : S.Configuration;
      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;
      Logits  : Logit_Vector := [others => 0.0];
   begin
      --  A temperature that is not a number, and one below zero. Both would
      --  otherwise reach the softmax, where a negative temperature does not
      --  fail: it quietly ranks the least likely token first.
      Config := S.Greedy_Configuration;
      Config.Temperature := -1.0;
      S.Validate (Config, Status);
      Assert (Status.Code = E.Sampling_Invalid_Configuration,
              "a negative temperature was accepted: "
              & E.Error_Code'Image (Status.Code));

      Config.Temperature := 0.8;
      S.Validate (Config, Status);
      Assert (E.Is_Ok (Status),
              "an ordinary temperature was refused: "
              & E.Error_Code'Image (Status.Code));

      --  A vocabulary of nothing has no token to return.
      S.Open (Sampler, S.Greedy_Configuration, 0, 1, Status);
      Assert (Status.Code = E.Sampling_Vocabulary_Mismatch,
              "a sampler opened for an empty vocabulary: "
              & E.Error_Code'Image (Status.Code));
      Assert (not S.Is_Open (Sampler),
              "a refused open left the sampler open");

      --  Sampling from a sampler that was never opened.
      S.Sample (Sampler, Logits, Token, Status);
      Assert (Status.Code = E.Sampling_Invalid_Configuration,
              "an unopened sampler produced a token: "
              & E.Error_Code'Image (Status.Code));
      Assert (Token = Vocab.No_Token,
              "an unopened sampler named a token anyway");

      --  And from one that was opened and then closed, which is the same
      --  state reached the way a caller actually reaches it.
      S.Open (Sampler, S.Greedy_Configuration, Vocabulary, 1, Status);
      Assert (E.Is_Ok (Status), "sampler did not open");
      S.Close (Sampler);

      S.Sample (Sampler, Logits, Token, Status);
      Assert (Status.Code = E.Sampling_Invalid_Configuration,
              "a closed sampler produced a token: "
              & E.Error_Code'Image (Status.Code));

      --  Every candidate forbidden. There is nothing left to choose, and
      --  saying so is better than choosing something forbidden.
      S.Open (Sampler, S.Greedy_Configuration, Vocabulary, 1, Status);
      Assert (E.Is_Ok (Status), "sampler did not reopen");

      Logits := [others => 1.0];
      for Token_Index in 0 .. Vocabulary - 1 loop
         S.Forbid (Sampler, Vocab.Token_Id (Token_Index));
      end loop;

      S.Sample (Sampler, Logits, Token, Status);
      Assert (Status.Code = E.Sampling_No_Candidates,
              "a sampler with everything forbidden produced a token: "
              & E.Error_Code'Image (Status.Code));
      Assert (Token = Vocab.No_Token,
              "a refused sample named a token anyway");

      --  The same with a temperature, which is a different path through the
      --  sampler: greedy selection scans the mask itself, while sampling
      --  gathers candidates first and has its own reason to find none.
      S.Close (Sampler);
      Config := S.Greedy_Configuration;
      Config.Temperature := 0.8;
      Config.Top_P := 1.0;
      S.Open (Sampler, Config, Vocabulary, 1, Status);
      Assert (E.Is_Ok (Status), "sampling sampler did not open");

      for Token_Index in 0 .. Vocabulary - 1 loop
         S.Forbid (Sampler, Vocab.Token_Id (Token_Index));
      end loop;

      S.Sample (Sampler, Logits, Token, Status);
      Assert (Status.Code = E.Sampling_No_Candidates,
              "sampling with everything forbidden produced a token: "
              & E.Error_Code'Image (Status.Code));
      Assert (Token = Vocab.No_Token,
              "a refused sampling named a token anyway");

      --  With one token left it picks that one, so the refusal above is
      --  about there being nothing rather than about forbidding at all.
      --
      --  Reopened rather than reset: a reset clears the history and reseeds
      --  the generator, and a forbidden token is forbidden ever, which is
      --  what the operation says and what a caller masking a control token
      --  for a whole run depends on.
      S.Close (Sampler);
      S.Open (Sampler, S.Greedy_Configuration, Vocabulary, 1, Status);
      Assert (E.Is_Ok (Status), "sampler did not reopen for the last case");

      for Token_Index in 0 .. Vocabulary - 1 loop
         if Token_Index /= 5 then
            S.Forbid (Sampler, Vocab.Token_Id (Token_Index));
         end if;
      end loop;

      S.Sample (Sampler, Logits, Token, Status);
      Assert (E.Is_Ok (Status) and then Token = 5,
              "the one candidate left was not chosen: "
              & E.Error_Code'Image (Status.Code));

      S.Close (Sampler);
   end Sampler_Refuses_What_It_Cannot_Sample;

   --  Greedy selection picks the maximum and breaks ties towards the lowest
   --  token identifier, without touching the generator.
   procedure Greedy_Selects_Maximum (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;
      Logits  : Logit_Vector := [others => 0.0];
   begin
      S.Open (Sampler, S.Greedy_Configuration, Vocabulary, 12345, Status);
      Assert (E.Is_Ok (Status), "greedy sampler did not open");

      Logits := [0 => 1.0, 1 => 3.0, 2 => 2.0, others => 0.0];
      S.Sample (Sampler, Logits, Token, Status);
      Assert (E.Is_Ok (Status) and then Token = 1,
              "greedy did not select the maximum");

      --  Two equally maximal candidates: the lower identifier wins.
      Logits := [0 => 0.0, 3 => 5.0, 6 => 5.0, others => 0.0];
      S.Sample (Sampler, Logits, Token, Status);
      Assert (E.Is_Ok (Status) and then Token = 3,
              "greedy tie-breaking did not prefer the lower token");

      S.Close (Sampler);
   end Greedy_Selects_Maximum;

   --  Greedy mode must not consume random state, so two samplers with
   --  different seeds agree exactly.
   procedure Greedy_Ignores_Entropy (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      First, Second : S.Sampler;
      Status        : E.Error_Info;
      Left, Right   : Vocab.Token_Id;
      Logits        : constant Logit_Vector :=
        [0 => 0.5, 1 => 0.25, 2 => 4.0, 3 => 1.0, others => 0.0];
   begin
      S.Open (First, S.Greedy_Configuration, Vocabulary, 1, Status);
      Assert (E.Is_Ok (Status), "first sampler did not open");
      S.Open (Second, S.Greedy_Configuration, Vocabulary, 999_999, Status);
      Assert (E.Is_Ok (Status), "second sampler did not open");

      for Step in 1 .. 8 loop
         S.Sample (First, Logits, Left, Status);
         Assert (E.Is_Ok (Status), "first sample failed");
         S.Sample (Second, Logits, Right, Status);
         Assert (E.Is_Ok (Status), "second sample failed");
         Assert (Left = Right,
                 "greedy selection depended on the seed at step"
                 & Integer'Image (Step));
      end loop;

      S.Close (First);
      S.Close (Second);
   end Greedy_Ignores_Entropy;

   --  A fixed seed reproduces the same token sequence exactly.
   procedure Fixed_Seed_Reproduces (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Config : constant S.Configuration :=
        (Temperature => 1.0, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
         Repeat_Penalty => 1.0, Repeat_Window => 0,
         others => <>);
      Logits : constant Logit_Vector :=
        [0 => 0.1, 1 => 0.9, 2 => 0.4, 3 => 0.7,
         4 => 0.2, 5 => 0.6, 6 => 0.3, 7 => 0.8];
      Runs   : array (1 .. 2, 1 .. 24) of Vocab.Token_Id :=
        [others => [others => 0]];

      --  Recorded from this build, and identical on any host that runs the
      --  same arithmetic on the same seed.
      Expected : constant array (1 .. 24) of Vocab.Token_Id :=
        [1, 1, 6, 3, 4, 7, 5, 2, 7, 1, 1, 3, 1, 3, 1, 6, 6, 1, 0, 4, 1, 3,
         0, 2];
   begin
      for Attempt in 1 .. 2 loop
         declare
            Sampler : S.Sampler;
            Status  : E.Error_Info;
            Token   : Vocab.Token_Id;
         begin
            S.Open (Sampler, Config, Vocabulary, 16#DEAD_BEEF#, Status);
            Assert (E.Is_Ok (Status), "sampler did not open");

            for Step in 1 .. 24 loop
               S.Sample (Sampler, Logits, Token, Status);
               Assert (E.Is_Ok (Status), "sample failed");
               Runs (Attempt, Step) := Token;
            end loop;

            S.Close (Sampler);
         end;
      end loop;

      for Step in 1 .. 24 loop
         --  The same run twice says the generator is deterministic within a
         --  build. What it cannot say is that the stream is the same
         --  elsewhere, and the specification claims exactly that: xoshiro256++
         --  was chosen because it "produces the same stream on every host".
         --  So the tokens are written down. This suite runs on Linux, macOS
         --  and Windows, and a host that disagreed would say so here.
         --
         --  The pipeline order decides which token a stream position becomes,
         --  and the specification says changing that order changes the answer
         --  for a given seed. So this fails for two different reasons: the
         --  generator drifting, or the pipeline being reordered. Both are
         --  changes to a published behaviour and both should be deliberate.
         Assert (Runs (1, Step) = Expected (Step),
                 "step" & Natural'Image (Step) & " produced token"
                 & Vocab.Token_Id'Image (Runs (1, Step))
                 & " where this build has always produced"
                 & Vocab.Token_Id'Image (Expected (Step)));

         Assert (Runs (1, Step) = Runs (2, Step),
                 "fixed seed did not reproduce step" & Integer'Image (Step));
      end loop;
   end Fixed_Seed_Reproduces;

   --  Top-k restricts selection to the k highest-scoring candidates.
   procedure Top_K_Restricts (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : constant S.Configuration :=
        (Temperature => 1.0, Top_K => 2, Top_P => 1.0, Min_P => 0.0,
         Repeat_Penalty => 1.0, Repeat_Window => 0,
         others => <>);
      Logits : constant Logit_Vector :=
        [0 => 0.0, 1 => 0.0, 2 => 10.0, 3 => 0.0,
         4 => 0.0, 5 => 9.0, 6 => 0.0, 7 => 0.0];
      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;
   begin
      S.Open (Sampler, Config, Vocabulary, 7, Status);
      Assert (E.Is_Ok (Status), "sampler did not open");

      for Step in 1 .. 64 loop
         S.Sample (Sampler, Logits, Token, Status);
         Assert (E.Is_Ok (Status), "sample failed");
         Assert (Token = 2 or else Token = 5,
                 "top-k admitted a candidate outside the two highest:"
                 & Vocab.Token_Id'Image (Token));
      end loop;

      S.Close (Sampler);
   end Top_K_Restricts;

   --  Minimum-p drops candidates far below the most probable one.
   procedure Min_P_Restricts (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : constant S.Configuration :=
        (Temperature => 1.0, Top_K => 0, Top_P => 1.0, Min_P => 0.5,
         Repeat_Penalty => 1.0, Repeat_Window => 0,
         others => <>);
      Logits : constant Logit_Vector :=
        [0 => 5.0, 1 => 4.9, others => -20.0];
      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;
   begin
      S.Open (Sampler, Config, Vocabulary, 3, Status);
      Assert (E.Is_Ok (Status), "sampler did not open");

      for Step in 1 .. 64 loop
         S.Sample (Sampler, Logits, Token, Status);
         Assert (E.Is_Ok (Status), "sample failed");
         Assert (Token = 0 or else Token = 1,
                 "min-p admitted an improbable candidate:"
                 & Vocab.Token_Id'Image (Token));
      end loop;

      S.Close (Sampler);
   end Min_P_Restricts;

   --  A repetition penalty pushes a recently produced token down.
   procedure Repetition_Penalty_Applies
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Config : constant S.Configuration :=
        (Temperature => 0.01, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
         Repeat_Penalty => 10.0, Repeat_Window => 8,
         others => <>);
      Logits : constant Logit_Vector :=
        [0 => 4.0, 1 => 3.0, others => -10.0];
      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;
   begin
      S.Open (Sampler, Config, Vocabulary, 11, Status);
      Assert (E.Is_Ok (Status), "sampler did not open");

      S.Sample (Sampler, Logits, Token, Status);
      Assert (E.Is_Ok (Status) and then Token = 0,
              "the highest logit was not selected first");

      --  After recording token 0, its logit is divided by the penalty and
      --  token 1 becomes the most probable.
      S.Record_Token (Sampler, 0);
      S.Sample (Sampler, Logits, Token, Status);
      Assert (E.Is_Ok (Status) and then Token = 1,
              "the repetition penalty did not demote the repeated token");

      S.Close (Sampler);
   end Repetition_Penalty_Applies;

   --  Presence subtracts once however often; frequency subtracts every time.
   --
   --  The two are told apart by counting. A token said twice must be pushed
   --  down twice as far by a frequency penalty and no further by a presence
   --  one, which is the whole difference between them and the only thing that
   --  can go wrong in a way the compiler will not catch.
   procedure Frequency_And_Presence_Differ
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Half a point apart, so one subtraction of one point flips them and
      --  a second changes nothing that the first did not.
      Logits : constant Logit_Vector :=
        [0 => 2.0, 1 => 1.5, others => -10.0];

      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;

      procedure Say_Zero_Twice (Config : S.Configuration; Expect : Vocab.Token_Id;
                                What : String) is
      begin
         S.Open (Sampler, Config, Vocabulary, 11, Status);
         Assert (E.Is_Ok (Status), "sampler did not open for " & What);

         S.Record_Token (Sampler, 0);
         S.Record_Token (Sampler, 0);
         S.Sample (Sampler, Logits, Token, Status);

         Assert (E.Is_Ok (Status) and then Token = Expect,
                 What & " selected" & Vocab.Token_Id'Image (Token)
                 & " rather than" & Vocab.Token_Id'Image (Expect));
         S.Close (Sampler);
      end Say_Zero_Twice;
   begin
      --  Presence, once: token 0 falls to 1.4 and token 1 wins.
      Say_Zero_Twice
        ((Temperature => 0.01, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Presence_Penalty => 0.6, others => <>),
         1, "a presence penalty");

      --  Presence again, larger than one repetition but applied only once:
      --  it is subtracted a single time whatever the count, so a penalty of
      --  0.4 leaves token 0 at 1.6 and it still wins.
      Say_Zero_Twice
        ((Temperature => 0.01, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Presence_Penalty => 0.4, others => <>),
         0, "a presence penalty below the gap");

      --  Frequency, twice: the same 0.4 is subtracted once per occurrence,
      --  so token 0 falls to 1.2 and loses. This is the case that separates
      --  the two, and it fails if the count is treated as a flag.
      Say_Zero_Twice
        ((Temperature => 0.01, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Frequency_Penalty => 0.4, others => <>),
         1, "a frequency penalty counted twice");

      --  And a token never said is untouched by either.
      Say_Zero_Twice
        ((Temperature => 0.01, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Frequency_Penalty => 5.0, Presence_Penalty => 5.0),
         1, "penalties that spare an unsaid token");
   end Frequency_And_Presence_Differ;

   --  A penalty large enough to make every logit infinite is refused.
   procedure Penalty_Range_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Status : E.Error_Info;
   begin
      S.Validate
        ((Temperature => 1.0, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Frequency_Penalty => 1.0E6, others => <>), Status);
      Assert (E.Is_Error (Status), "an enormous frequency penalty was accepted");

      S.Validate
        ((Temperature => 1.0, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Presence_Penalty => -1.0E6, others => <>), Status);
      Assert (E.Is_Error (Status), "an enormous presence penalty was accepted");

      --  A negative value of ordinary size is meaningful: it encourages
      --  repetition rather than discouraging it, and is accepted.
      S.Validate
        ((Temperature => 1.0, Top_K => 0, Top_P => 1.0, Min_P => 0.0,
          Repeat_Penalty => 1.0, Repeat_Window => 8,
          Frequency_Penalty => -0.5, others => <>), Status);
      Assert (E.Is_Ok (Status), "a negative frequency penalty was refused");
   end Penalty_Range_Rejected;

   --  Non-finite logits and impossible configurations are rejected.
   procedure Invalid_Inputs_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Sampler : S.Sampler;
      Status  : E.Error_Info;
      Token   : Vocab.Token_Id;
      Logits  : Logit_Vector := [others => 1.0];
      Broken  : S.Configuration;
   begin
      Broken := S.Greedy_Configuration;
      Broken.Top_P := 0.0;
      S.Validate (Broken, Status);
      Assert (Status.Code = E.Sampling_Invalid_Configuration,
              "top_p of zero was accepted");

      Broken := S.Greedy_Configuration;
      Broken.Min_P := 2.0;
      S.Validate (Broken, Status);
      Assert (Status.Code = E.Sampling_Invalid_Configuration,
              "min_p above one was accepted");

      Broken := S.Greedy_Configuration;
      Broken.Repeat_Penalty := 0.0;
      S.Validate (Broken, Status);
      Assert (Status.Code = E.Sampling_Invalid_Configuration,
              "a zero repetition penalty was accepted");

      S.Open (Sampler, S.Greedy_Configuration, Vocabulary, 1, Status);
      Assert (E.Is_Ok (Status), "sampler did not open");

      --  This test manufactures the values a hostile model file could carry
      --  and checks they are refused. Storing and passing them is the point,
      --  so validity checking is suppressed here for the same reason the
      --  engine suppresses it where it inspects them: the check fires on the
      --  read, before anything can decide the value is unacceptable.
      declare
         pragma Suppress (Validity_Check);
      begin
         Logits (2) := N.From_Bits (16#7FC0_0000#);
         S.Sample (Sampler, Logits, Token, Status);
         Assert (Status.Code = E.Sampling_Non_Finite_Logit,
                 "a NaN logit was accepted");

         Logits (2) := N.From_Bits (16#7F80_0000#);
         S.Sample (Sampler, Logits, Token, Status);
         Assert (Status.Code = E.Sampling_Non_Finite_Logit,
                 "an infinite logit was accepted");
      end;

      declare
         Wrong : constant N.Real_Array (0 .. 2) := [others => 0.0];
      begin
         S.Sample (Sampler, Wrong, Token, Status);
         Assert (Status.Code = E.Sampling_Vocabulary_Mismatch,
                 "a wrongly sized logit vector was accepted");
      end;

      S.Close (Sampler);
   end Invalid_Inputs_Rejected;

   --  Stop strings match across a boundary and the longest wins at the
   --  earliest position.
   procedure Stop_Strings_Match (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Set    : Stop.Set;
      Status : E.Error_Info;
      First  : Natural;
      Length : Natural;
   begin
      Stop.Open (Set);

      --  A token that is not a token. Stop conditions come from the command
      --  line, and a negative identifier compared against generated tokens
      --  would simply never match, which looks like a stop condition that
      --  was accepted and then ignored.
      Stop.Add_Token (Set, -1, Status);
      Assert (Status.Code = E.Tokenizer_Invalid_Token_Id,
              "a negative stop token was accepted: "
              & E.Error_Code'Image (Status.Code));

      Stop.Add_Token (Set, 0, Status);
      Assert (E.Is_Ok (Status),
              "token zero was refused as a stop token: "
              & E.Error_Code'Image (Status.Code));

      Stop.Add_String (Set, "END", Status);
      Assert (E.Is_Ok (Status), "adding a stop string failed");
      Stop.Add_String (Set, "ENDING", Status);
      Assert (E.Is_Ok (Status), "adding an overlapping stop string failed");

      Assert (Stop.Longest_String (Set) = 6, "longest stop string is wrong");

      Stop.Scan (Set, "abc", First, Length);
      Assert (First = 0, "a match was reported where there is none");

      --  Both stop strings start here; the longest must win.
      Stop.Scan (Set, "xxENDINGyy", First, Length);
      Assert (First = 3 and then Length = 6,
              "overlapping stop strings did not resolve to the longest");

      --  Only the short one fits.
      Stop.Scan (Set, "xxENDyy", First, Length);
      Assert (First = 3 and then Length = 3,
              "the short stop string was not matched");

      --  The earliest position wins even when a later match is longer.
      Stop.Scan (Set, "aENDbENDING", First, Length);
      Assert (First = 2 and then Length = 3,
              "a later match was preferred over an earlier one");

      Stop.Close (Set);
   end Stop_Strings_Match;

   --  Stop-set bounds are enforced.
   procedure Stop_Bounds_Enforced (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Set    : Stop.Set;
      Status : E.Error_Info;
      Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
   begin
      Bounds.Max_Stop_Strings := 1;
      Bounds.Max_Stop_String_Bytes := 4;
      Stop.Open (Set, Bounds);

      Stop.Add_String (Set, "", Status);
      Assert (E.Is_Error (Status), "an empty stop string was accepted");

      Stop.Add_String (Set, "abcde", Status);
      Assert (E.Is_Error (Status), "an oversized stop string was accepted");

      Stop.Add_String (Set, "abc", Status);
      Assert (E.Is_Ok (Status), "a legal stop string was rejected");

      Stop.Add_String (Set, "def", Status);
      Assert (E.Is_Error (Status), "the stop-string count bound was not applied");

      Stop.Close (Set);
   end Stop_Bounds_Enforced;

   --  A ChatML-style template renders exactly, including the generation
   --  prompt and the whitespace-control markers.
   procedure Template_Renders_Exactly
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        "{% for message in messages %}"
        & "{{ '<|im_start|>' + message['role'] + '\n' + message['content']"
        & " + '<|im_end|>' + '\n' }}"
        & "{% endfor %}"
        & "{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}"
        & "{% endif %}";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 1024);
      Last     : Natural;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "template did not compile: " & E.Error_Code'Image (Status.Code));
      Assert (Tmpl.Is_Compiled (Item), "template not marked compiled");

      Conv.Open (Messages, Status => Status);
      Assert (E.Is_Ok (Status), "history did not open");
      Conv.Append (Messages, Conv.System_Role, "be brief", Status);
      Assert (E.Is_Ok (Status), "system message rejected");
      Conv.Append (Messages, Conv.User_Role, "hello", Status);
      Assert (E.Is_Ok (Status), "user message rejected");

      Tmpl.Render (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "render failed: " & E.Error_Code'Image (Status.Code));

      declare
         Expected : constant String :=
           "<|im_start|>system" & ASCII.LF & "be brief<|im_end|>" & ASCII.LF
           & "<|im_start|>user" & ASCII.LF & "hello<|im_end|>" & ASCII.LF
           & "<|im_start|>assistant" & ASCII.LF;
      begin
         Assert (Target (1 .. Last) = Expected,
                 "rendered """ & Target (1 .. Last) & """");
      end;

      --  Without the generation prompt the trailing marker disappears.
      Tmpl.Render (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (E.Is_Ok (Status), "second render failed");
      Assert (Model_Runner.Text.Ends_With
                (Target (1 .. Last), "<|im_end|>" & ASCII.LF),
              "output did not end with the last message marker");
      Assert (not Model_Runner.Text.Ends_With
                    (Target (1 .. Last), "assistant" & ASCII.LF),
              "the generation prompt was emitted when not requested");

      Conv.Close (Messages);
      Tmpl.Close (Item);
   end Template_Renders_Exactly;

   --  Conditionals, elif, else, loop.last and whitespace control all work.
   procedure Template_Branches (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        "{% for message in messages %}"
        & "{%- if message['role'] == 'user' -%}U:{{ message['content'] }}"
        & "{%- elif message['role'] == 'system' -%}S:{{ message['content'] }}"
        & "{%- else -%}A:{{ message['content'] }}{%- endif -%}"
        & "{% if not loop.last %}|{% endif %}"
        & "{% endfor %}";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 512);
      Last     : Natural;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "branching template did not compile: "
              & E.Error_Code'Image (Status.Code));

      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.System_Role, "s", Status);
      Conv.Append (Messages, Conv.User_Role, "u", Status);
      Conv.Append (Messages, Conv.Assistant_Role, "a", Status);
      Assert (E.Is_Ok (Status), "messages rejected");

      Tmpl.Render (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (E.Is_Ok (Status), "branching render failed");
      Assert (Target (1 .. Last) = "S:s|U:u|A:a",
              "rendered """ & Target (1 .. Last) & """");

      Conv.Close (Messages);
      Tmpl.Close (Item);
   end Template_Branches;

   --  Constructs outside the supported subset are rejected at compile time,
   --  and the engine has no operation that could reach a file or a process.
   procedure Template_Rejects_Unsupported
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Item   : Tmpl.Compiled;
      Status : E.Error_Info;

      procedure Reject (Source : String; Why : String) is
      begin
         Tmpl.Compile (Item, Source, Status => Status);
         Assert (E.Is_Error (Status), Why & " was accepted");
         Assert (not Tmpl.Is_Compiled (Item),
                 Why & " left a compiled template");
      end Reject;
   begin
      Reject ("{% set x = 1 %}", "set");
      Reject ("{% macro m() %}{% endmacro %}", "macro");
      Reject ("{% include 'other' %}", "include");
      Reject ("{{ raise_exception('no') }}", "raise_exception");
      Reject ("{{ message['content'] | trim }}", "a filter");
      Reject ("{{ messages[0]['role'] }}", "message indexing");
      Reject ("{% for x in other %}{% endfor %}", "iteration over a non-list");
      Reject ("{% if true %}", "an unbalanced if");
      Reject ("{% endfor %}", "a stray endfor");
      Reject ("{{ unknown_variable }}", "an unknown variable");
      Reject ("{{ oops", "an unterminated tag");

      Tmpl.Close (Item);
   end Template_Rejects_Unsupported;

   --------------------------
   -- Automatic_Seed_Works --
   --------------------------

   --  Every other test pins a seed so that its result is reproducible, which
   --  left the path a user actually takes -- no --seed at all -- with no
   --  coverage. It was broken: the host source computed the span from the
   --  real-time epoch as a Duration in its declarative part, that conversion
   --  overflowed, and the resulting Constraint_Error escaped past the
   --  subprogram's own handler, since a handler does not cover the
   --  declarations of the body it belongs to.
   procedure Automatic_Seed_Works (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Model_Runner.Entropy.Seed_Value;

      Host   : aliased Model_Runner.Entropy.Host_Source;
      Drawn  : array (1 .. 32) of Model_Runner.Entropy.Seed_Value;
      Varies : Boolean := False;
   begin
      for Index in Drawn'Range loop
         Model_Runner.Entropy.Draw (Host'Unchecked_Access, Drawn (Index));
      end loop;

      --  A source that always returned the documented fallback would satisfy
      --  a "did not raise" assertion while silently making every automatic
      --  run identical, so require that the values actually move.
      for Index in Drawn'First + 1 .. Drawn'Last loop
         Varies := Varies or else Drawn (Index) /= Drawn (Drawn'First);
      end loop;

      Assert (Varies, "automatic seeding returned the same value every time");

      for Index in Drawn'Range loop
         Assert
           (Drawn (Index) /= Model_Runner.Entropy.Fallback_Seed,
            "automatic seeding fell back to the fixed seed, so the host"
            & " source failed and was silently absorbed");
      end loop;

      --  A null source is a documented, non-raising case.
      declare
         Absent : Model_Runner.Entropy.Seed_Value;
      begin
         Model_Runner.Entropy.Draw (null, Absent);
         Assert
           (Absent = Model_Runner.Entropy.Fallback_Seed,
            "an absent source must yield the documented fallback seed");
      end;
   end Automatic_Seed_Works;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("sampling, stops and templates");
   end Name;

   --  A sampler with nothing left to choose says so.
   --
   --  Every token can be forbidden, and then there is no answer to give. The
   --  refusal exists and nothing named it; without a test, a sampler that
   --  returned a forbidden token instead would look the same from outside.
   procedure Sampling_Without_Candidates
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Width  : constant := 8;
      Item   : S.Sampler;
      Status : E.Error_Info;
      Logits : N.Real_Array (0 .. Width - 1) := [others => 0.0];
      Token  : S.Token_Id;
   begin
      S.Open
        (Item, S.Greedy_Configuration, Width, 1, Status);
      Assert (E.Is_Ok (Status), "the sampler did not open");

      --  With one token left, that is the one chosen however small its logit.
      for Index in 1 .. Width - 1 loop
         S.Forbid (Item, S.Token_Id (Index));
      end loop;
      Logits (0) := -100.0;

      S.Sample (Item, Logits, Token, Status);
      Assert (E.Is_Ok (Status),
              "a sampler with one candidate refused: "
              & E.Error_Code'Image (Status.Code));
      Assert (Token = 0,
              "the only permitted token was not chosen:"
              & S.Token_Id'Image (Token));

      --  With none left there is no answer, and saying so is the answer.
      S.Forbid (Item, 0);
      S.Sample (Item, Logits, Token, Status);
      Assert (Status.Code = E.Sampling_No_Candidates,
              "a sampler with every token forbidden chose one anyway: "
              & E.Error_Code'Image (Status.Code));

      S.Close (Item);
   end Sampling_Without_Candidates;

   --  The kernels answer degenerate input instead of trapping on it.
   --
   --  Conformance checks the kernels against an independent implementation,
   --  but only on a model that makes sense. What a hostile file can produce is
   --  a layer of zeros, a weight vector of the wrong length, or logits that
   --  are not finite -- and each of those reaches the arithmetic before any
   --  check the caller performs on the result.
   --
   --  The engine's rule is that the arithmetic stays finite and the caller's
   --  own finiteness check reports the condition. A kernel that divided by a
   --  zero scale instead would take the process with it.
   procedure Kernels_Survive_Degenerate_Input
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package K renames Model_Runner.Kernels;

      Zeros  : constant N.Real_Array (0 .. 3) := [others => 0.0];
      Ones   : constant N.Real_Array (0 .. 3) := [others => 1.0];
      Result : N.Real_Array (0 .. 3) := [others => 9.0];
   begin
      --  A layer of zeros has no scale to normalize by. The fallback keeps
      --  the output finite rather than dividing by zero.
      K.RMS_Norm (Zeros, Ones, 0.0, Result);
      for Value of Result loop
         Assert (N.Is_Finite (Value),
                 "normalizing a zero vector produced a value that is not"
                 & " finite");
      end loop;

      --  A weight vector of the wrong length is refused by leaving the target
      --  zeroed, rather than by reading past either array.
      declare
         Short  : constant N.Real_Array (0 .. 1) := [others => 1.0];
         Filled : N.Real_Array (0 .. 3) := [others => 9.0];
      begin
         K.RMS_Norm (Zeros, Short, 1.0E-5, Filled);
         for Value of Filled loop
            Assert (Value = 0.0,
                    "a length mismatch left something behind in the target");
         end loop;
      end;

      --  Softmax over logits that are not finite leaves the target alone
      --  rather than propagating them into a distribution.
      declare
         Broken : N.Real_Array (0 .. 3) := [others => 0.0];
         Usable : Boolean;
      begin
         Broken (1) := N.Real'Last;
         Broken (2) := -N.Real'Last;
         K.Softmax (Broken, Usable);
         for Value of Broken loop
            Assert (N.Is_Finite (Value),
                    "softmax produced a value that is not finite");
         end loop;
      end;

      --  And an ordinary vector still normalizes to one, so none of the
      --  above can come from kernels that decline to compute.
      declare
         Ordinary : N.Real_Array (0 .. 3) := [1.0, 2.0, 3.0, 4.0];
         Total    : N.Real := 0.0;
         Usable   : Boolean;
      begin
         K.Softmax (Ordinary, Usable);
         Assert (Usable, "an ordinary softmax was reported unusable");
         for Value of Ordinary loop
            Total := Total + Value;
         end loop;
         Assert (abs (Total - 1.0) < 1.0E-5,
                 "an ordinary softmax did not sum to one:"
                 & N.Real'Image (Total));
      end;
   end Kernels_Survive_Degenerate_Input;

   --  Whatever it is given, the sampler returns a usable token or says it
   --  cannot.
   --
   --  The token this returns is used as an index: into the vocabulary to find
   --  its text, into the cache to place its position, into the history for
   --  the repetition penalty. A token outside the vocabulary would be a fault
   --  in three places at once, and the hand-written cases each exercise one
   --  setting at a time.
   --
   --  So this varies all of them together, over logits that include the
   --  values a model produces when something has gone wrong, and asks for the
   --  property the rest of the engine relies on: either an error, or a token
   --  that is inside the vocabulary and not one that was forbidden.
   procedure Any_Sampling_Returns_A_Usable_Token
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Interfaces.Unsigned_64;

      Width : constant := 16;

      State : Interfaces.Unsigned_64 := 3_141_592_653_589_793_238;

      function Draw (Bound : Positive) return Natural is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return Natural (State mod Interfaces.Unsigned_64 (Bound));
      end Draw;

      --  A logit, including the values that mean something went wrong.
      function Some_Logit return N.Real is
      begin
         case Draw (8) is
            when 0 => return 0.0;
            when 1 => return 1.0;
            when 2 => return -1.0;
            when 3 => return N.Real (Draw (2_000)) / 100.0 - 10.0;
            when 4 => return N.Real'Last;
            when 5 => return -N.Real'Last;
            when 6 => return N.Real (Draw (1_000_000));
            when others => return N.Real (Draw (100)) / 1000.0;
         end case;
      end Some_Logit;

      Answered : Natural := 0;
      Sampled  : Natural := 0;
      Refused  : Natural := 0;
   begin
      for Case_Number in 1 .. 2_000 loop
         declare
            Config  : S.Configuration;
            Item    : S.Sampler;
            Logits  : N.Real_Array (0 .. Width - 1);
            Token   : S.Token_Id;
            Status  : E.Error_Info;
            Opened  : E.Error_Info;
            Forbid  : constant Natural := Draw (Width);
         begin
            --  Every setting varied together, including the combinations a
            --  person writing cases would not think to pair.
            Config.Temperature := N.Real (Draw (300)) / 100.0;
            Config.Top_K := Draw (Width + 4);
            Config.Top_P := N.Real (Draw (101)) / 100.0;
            Config.Min_P := N.Real (Draw (101)) / 100.0;
            Config.Repeat_Penalty := N.Real (Draw (300)) / 100.0;
            Config.Repeat_Window := Draw (Width + 4);

            S.Open (Item, Config, Width,
                    Interfaces.Unsigned_64 (Case_Number), Opened);

            if E.Is_Ok (Opened) then
               for Index in Logits'Range loop
                  Logits (Index) := Some_Logit;
               end loop;

               for Ignored in 1 .. Forbid loop
                  S.Forbid (Item, S.Token_Id (Draw (Width)));
               end loop;

               S.Sample (Item, Logits, Token, Status);
               Answered := Answered + 1;

               if E.Is_Ok (Status) then
                  Sampled := Sampled + 1;
                  Assert (Token >= 0 and then Natural (Token) < Width,
                          "case" & Natural'Image (Case_Number)
                          & " chose a token outside the vocabulary:"
                          & S.Token_Id'Image (Token));
               end if;
            else
               --  A configuration the sampler will not accept is a refusal
               --  too, and refusing before opening is the safest of the
               --  outcomes.
               Answered := Answered + 1;
               Refused := Refused + 1;
            end if;

            S.Close (Item);
         end;
      end loop;

      Assert (Answered = 2_000,
              "only" & Natural'Image (Answered)
              & " of two thousand configurations were answered");

      --  And that they were answered both ways. Every configuration being
      --  refused before it opened would satisfy the count above while
      --  sampling nothing at all, and the property this exists for -- that
      --  a token which comes back is one the vocabulary has -- would then
      --  be tested by no case.
      Assert (Sampled > 1_000,
              "only" & Natural'Image (Sampled)
              & " configurations reached a token, so the check on which "
              & "token came back had almost nothing to look at");

      --  Refusals are the thin side here: the generator draws mostly
      --  configurations the sampler accepts, and about one in a hundred is
      --  turned away before it opens. That is the shape this test has, and
      --  the bound is set to catch it collapsing rather than to claim the
      --  refusal path is well covered -- which it is not, here. The
      --  refusals that matter are held by name elsewhere, one condition at
      --  a time.
      Assert (Refused > 5,
              "only" & Natural'Image (Refused)
              & " configurations were refused, so the generator has stopped "
              & "producing any that are");
   end Any_Sampling_Returns_A_Usable_Token;

   --  The stop-string matcher agrees with a plain reading of its rule.
   --
   --  The rule is that the earliest match wins and the longest at that
   --  position wins among those. The engine's matcher is written to scan once
   --  and stop early; this test writes the rule out the slow, obvious way and
   --  compares them over generated sets and buffers.
   --
   --  Comparing an implementation against itself proves nothing, which is the
   --  trap a streaming test in this suite fell into. The reference below is
   --  written from the rule rather than from the code, so a disagreement is a
   --  fault in one of them and not a restatement.
   --
   --  What rests on it: the text before a match is released and the match
   --  itself never is, so a matcher that reported a position one byte late
   --  would emit the first byte of a stop string to the reader.
   procedure Stop_Matching_Agrees_With_Its_Rule
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Interfaces.Unsigned_64;

      State : Interfaces.Unsigned_64 := 1_442_695_040_888_963_407;

      function Draw (Bound : Positive) return Natural is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return Natural (State mod Interfaces.Unsigned_64 (Bound));
      end Draw;

      --  Two letters, so that matches and overlaps are common rather than
      --  rare enough to make the comparison decorative.
      function Letters (Length : Natural) return String is
         Result : String (1 .. Length);
      begin
         for Index in Result'Range loop
            Result (Index) := (if Draw (2) = 0 then 'a' else 'b');
         end loop;
         return Result;
      end Letters;

      Matched : Natural := 0;
   begin
      for Case_Number in 1 .. 2_000 loop
         declare
            Count  : constant Natural := 1 + Draw (4);
            Buffer : constant String := Letters (Draw (21));

            type Piece is record
               Text : String (1 .. 5);
               Size : Natural;
            end record;

            Wanted : array (1 .. 4) of Piece;
            Set    : Model_Runner.Stops.Set;
            Status : E.Error_Info;

            Found_First  : Natural;
            Found_Length : Natural;

            Rule_First  : Natural := 0;
            Rule_Length : Natural := 0;
         begin
            Model_Runner.Stops.Open (Set);

            for Index in 1 .. Count loop
               declare
                  Text : constant String := Letters (1 + Draw (5));
               begin
                  Wanted (Index).Size := Text'Length;
                  Wanted (Index).Text (1 .. Text'Length) := Text;
                  Model_Runner.Stops.Add_String (Set, Text, Status);
               end;
            end loop;

            --  The rule, written out: walk the buffer from the left, and at
            --  the first position where anything matches take the longest.
            Position_Loop :
            for Start in Buffer'Range loop
               for Index in 1 .. Count loop
                  declare
                     Text : String renames
                       Wanted (Index).Text (1 .. Wanted (Index).Size);
                  begin
                     if Start + Text'Length - 1 <= Buffer'Last
                       and then Buffer (Start .. Start + Text'Length - 1) = Text
                       and then Text'Length > Rule_Length
                     then
                        Rule_First := Start;
                        Rule_Length := Text'Length;
                     end if;
                  end;
               end loop;

               exit Position_Loop when Rule_First /= 0;
            end loop Position_Loop;

            Model_Runner.Stops.Scan (Set, Buffer, Found_First, Found_Length);

            Assert (Found_First = Rule_First and then Found_Length = Rule_Length,
                    "case" & Natural'Image (Case_Number)
                    & " over """ & Buffer & """: the matcher said"
                    & Natural'Image (Found_First) & " for"
                    & Natural'Image (Found_Length)
                    & " and the rule says" & Natural'Image (Rule_First)
                    & " for" & Natural'Image (Rule_Length));

            if Rule_First /= 0 then
               Matched := Matched + 1;
            end if;

            Model_Runner.Stops.Close (Set);
         end;
      end loop;

      --  Reached, rather than agreeing because nothing ever matched.
      Assert (Matched > 1_000,
              "too few buffers contained a stop string to be comparing:"
              & Natural'Image (Matched));
   end Stop_Matching_Agrees_With_Its_Rule;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Sampler_Refuses_What_It_Cannot_Sample'Access,
         "the sampler refuses what it cannot sample from");
      Register_Routine
        (T, Stop_Matching_Agrees_With_Its_Rule'Access,
         "the stop-string matcher agrees with a plain reading of its rule");
      Register_Routine
        (T, Any_Sampling_Returns_A_Usable_Token'Access,
         "any configuration returns a usable token or says it cannot");
      Register_Routine
        (T, Kernels_Survive_Degenerate_Input'Access,
         "the kernels answer degenerate input instead of trapping on it");
      Register_Routine
        (T, Sampling_Without_Candidates'Access,
         "a sampler with nothing left to choose says so");
      Register_Routine
        (T, Greedy_Selects_Maximum'Access,
         "greedy selects the maximum and breaks ties towards the lowest token");
      Register_Routine
        (T, Greedy_Ignores_Entropy'Access,
         "greedy selection does not depend on the seed");
      Register_Routine
        (T, Fixed_Seed_Reproduces'Access,
         "a fixed seed reproduces the same token sequence");
      Register_Routine
        (T, Top_K_Restricts'Access,
         "top-k restricts selection to the highest-scoring candidates");
      Register_Routine
        (T, Min_P_Restricts'Access,
         "minimum-p drops candidates far below the most probable one");
      Register_Routine
        (T, Repetition_Penalty_Applies'Access,
         "the repetition penalty demotes a recently produced token");
      Register_Routine
        (T, Invalid_Inputs_Rejected'Access,
         "non-finite logits and impossible configurations are rejected");
      Register_Routine
        (T, Stop_Strings_Match'Access,
         "stop strings resolve to the earliest and then longest match");
      Register_Routine
        (T, Stop_Bounds_Enforced'Access,
         "stop-set count and length bounds are enforced");
      Register_Routine
        (T, Template_Renders_Exactly'Access,
         "a chat template renders exactly");
      Register_Routine
        (T, Template_Branches'Access,
         "template conditionals and whitespace control behave");
      Register_Routine
        (T, Template_Rejects_Unsupported'Access,
         "constructs outside the supported subset are rejected");
      Register_Routine
        (T, Automatic_Seed_Works'Access,
         "the default seeding path produces varying seeds without raising");

      Register_Routine
        (T, Frequency_And_Presence_Differ'Access,
         "a frequency penalty counts repetitions and a presence penalty "
         & "does not");
      Register_Routine
        (T, Penalty_Range_Rejected'Access,
         "a penalty large enough to make every logit infinite is refused, "
         & "and an ordinary negative one is not");   end Register_Tests;

end Tests.Sampling_Cases;
