with AUnit.Assertions;

with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Limits;
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
         Repeat_Penalty => 1.0, Repeat_Window => 0);
      Logits : constant Logit_Vector :=
        [0 => 0.1, 1 => 0.9, 2 => 0.4, 3 => 0.7,
         4 => 0.2, 5 => 0.6, 6 => 0.3, 7 => 0.8];
      Runs   : array (1 .. 2, 1 .. 24) of Vocab.Token_Id :=
        [others => [others => 0]];
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
         Assert (Runs (1, Step) = Runs (2, Step),
                 "fixed seed did not reproduce step" & Integer'Image (Step));
      end loop;
   end Fixed_Seed_Reproduces;

   --  Top-k restricts selection to the k highest-scoring candidates.
   procedure Top_K_Restricts (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : constant S.Configuration :=
        (Temperature => 1.0, Top_K => 2, Top_P => 1.0, Min_P => 0.0,
         Repeat_Penalty => 1.0, Repeat_Window => 0);
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
         Repeat_Penalty => 1.0, Repeat_Window => 0);
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
         Repeat_Penalty => 10.0, Repeat_Window => 8);
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

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
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
   end Register_Tests;

end Tests.Sampling_Cases;
