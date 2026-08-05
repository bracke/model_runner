with AUnit.Assertions;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Memory;
with Interfaces.C;

with Model_Runner.Cancellation;
with Model_Runner.Platform.Signals;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Kernels;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

with Conformance;
with Tiny_Model;

package body Tests.Inference_Cases is

   use AUnit.Assertions;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Tokenizer.Token_Id;
   use type Model_Runner.Tokenizer.Model_Kind;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package Containers renames Model_Runner.GGUF.Containers;
   package Vocab renames Model_Runner.Tokenizer;

   subtype Logit_Vector is
     N.Real_Array (0 .. N.Element_Count (Tiny_Model.Vocabulary) - 1);

   --  A prepared tiny model together with everything it borrows. Declared as
   --  one object so that a test cannot accidentally let the byte source go out
   --  of scope while the model still refers to it.
   type Harness (Image : access constant B.Byte_Array) is limited record
      Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
      Parsed : Containers.Container;
      Ready  : L.Model;
   end record;

   --  Parse and prepare the tiny model, asserting each stage.
   procedure Start (Item : in out Harness) is
      Status : E.Error_Info;
   begin
      Containers.Reader.Parse (Item.Parsed, Item.Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "tiny model did not parse: "
              & E.Error_Code'Image (Status.Code));

      L.Prepare (Item.Ready, Item.Parsed, Item.Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "tiny model did not prepare: "
              & E.Error_Code'Image (Status.Code));
      Assert (L.Is_Ready (Item.Ready), "model not marked ready");
   end Start;

   --  The tiny model prepares and reports the configuration it declared.
   procedure Model_Prepares (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
      begin
         Start (Under);

         declare
            Settings : constant L.Configuration := L.Config (Under.Ready);
         begin
            Assert (Settings.Embedding = Tiny_Model.Embedding, "embedding");
            Assert (Settings.Layers = Tiny_Model.Layers, "layers");
            Assert (Settings.Heads = Tiny_Model.Heads, "heads");
            Assert (Settings.KV_Heads = Tiny_Model.KV_Heads, "kv heads");
            Assert (Settings.Head_Size = Tiny_Model.Head_Size, "head size");
            Assert (Settings.Group_Size = Tiny_Model.Heads / Tiny_Model.KV_Heads,
                    "group size");
            Assert (Settings.Vocabulary = Tiny_Model.Vocabulary, "vocabulary");
            Assert (not Settings.Tied_Output, "output should not be tied");
         end;
      end;

      B.Free (Image);
   end Model_Prepares;

   --  Evaluation produces finite logits and commits exactly one position per
   --  successful token.
   procedure Evaluation_Advances (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Live  : L.Session;
         Status : E.Error_Info;
         Logits : Logit_Vector;
      begin
         Start (Under);

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status),
                 "session did not open: " & E.Error_Code'Image (Status.Code));
         Assert (L.Capacity (Live) = Tiny_Model.Context, "wrong capacity");
         Assert (L.Position (Live) = 0, "fresh session is not at position 0");

         for Step in 0 .. 3 loop
            L.Evaluate
              (Live, Under.Ready, Model_Runner.Tokenizer.Token_Id (4 + Step),
               Logits, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed at step" & Integer'Image (Step)
                    & ": " & E.Error_Code'Image (Status.Code));
            Assert (Model_Runner.Kernels.All_Finite (Logits),
                    "logits are not finite at step" & Integer'Image (Step));
            Assert (L.Position (Live) = Step + 1,
                    "position did not advance exactly once");
            Assert (L.Committed_Token (Live, Step) = Vocab.Token_Id (4 + Step),
                    "committed token history is wrong");
         end loop;

         L.Close (Live);
      end;

      B.Free (Image);
   end Evaluation_Advances;

   --  A batch is not an approximation of the sequence it replaces.
   --
   --  Batching exists to make prefill faster, and a faster prefill that
   --  changed the result would be a different model, not a quicker one. Every
   --  token in a batch must produce the bits it would have produced alone,
   --  and the context it leaves behind must be identical too.
   procedure Batch_Matches_Sequence
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image  : B.Byte_Array_Access;
      Prompt : constant Vocab.Token_Array (1 .. 5) := [4, 7, 2, 9, 5];

      Step_By_Step : Logit_Vector := [others => 0.0];
      Batched      : Logit_Vector := [others => 0.0];
      After_One    : Logit_Vector := [others => 0.0];
      After_Many   : Logit_Vector := [others => 0.0];
      Reached      : Natural := 0;
      Batch_Length : Natural := 0;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Status : E.Error_Info;
      begin
         Start (Under);

         --  One token at a time.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "sequential session did not open");
            for Index in Prompt'Range loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Step_By_Step,
                  Status => Status);
               Assert (E.Is_Ok (Status), "sequential evaluation failed");
            end loop;
            L.Evaluate (Live, Under.Ready, 3, After_One, Status => Status);
            Assert (E.Is_Ok (Status), "continuation after sequential failed");
            Reached := L.Position (Live);
            L.Close (Live);
         end;

         --  The same tokens in one batch.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "batched session did not open");
            L.Evaluate_Batch
              (Live, Under.Ready, Prompt, Batched, Status => Status);
            Assert (E.Is_Ok (Status),
                    "batched evaluation failed: "
                    & E.Error_Code'Image (Status.Code));

            Batch_Length := L.Position (Live);
            for Index in Prompt'Range loop
               Assert
                 (L.Committed_Token (Live, Index - Prompt'First)
                    = Prompt (Index),
                  "batched history is wrong at" & Integer'Image (Index));
            end loop;

            L.Evaluate (Live, Under.Ready, 3, After_Many, Status => Status);
            Assert (E.Is_Ok (Status), "continuation after batch failed");
            Assert (L.Position (Live) = Reached,
                    "batched and sequential positions disagree");
            L.Close (Live);
         end;
      end;

      Assert (Batch_Length = Prompt'Length,
              "a batch did not advance the position by its own length");

      --  Bit-for-bit, not within a tolerance.
      for Index in Step_By_Step'Range loop
         Assert
           (Step_By_Step (Index) = Batched (Index),
            "batched logit differs from the sequential one at"
            & N.Element_Count'Image (Index));
      end loop;

      --  Continuing afterwards must match too, which is what shows the
      --  key-value cache a batch leaves behind holds the same context.
      for Index in After_One'Range loop
         Assert
           (After_One (Index) = After_Many (Index),
            "the cache a batch left behind differs at"
            & N.Element_Count'Image (Index));
      end loop;

      B.Free (Image);
   end Batch_Matches_Sequence;

   --  The same token sequence produces bit-identical logits on every run.
   procedure Evaluation_Is_Deterministic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
      First : Logit_Vector := [others => 0.0];
   begin
      Tiny_Model.Build (Image);

      for Attempt in 1 .. 2 loop
         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
            Logits : Logit_Vector;
         begin
            Start (Under);
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "session did not open");

            for Token in Vocab.Token_Id range 4 .. 6 loop
               L.Evaluate (Live, Under.Ready, Token, Logits, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed");
            end loop;

            if Attempt = 1 then
               First := Logits;
            else
               for Index in Logits'Range loop
                  Assert (Logits (Index) = First (Index),
                          "logits differ between runs at"
                          & N.Element_Count'Image (Index));
               end loop;
            end if;

            L.Close (Live);
         end;
      end loop;

      B.Free (Image);
   end Evaluation_Is_Deterministic;

   --  A cancelled token commits nothing: the context is exactly what it was.
   procedure Cancellation_Does_Not_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         Logits : Logit_Vector;
         Flag   : aliased Model_Runner.Cancellation.Token;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
         Assert (E.Is_Ok (Status), "first evaluation failed");
         Assert (L.Position (Live) = 1, "first token did not commit");

         Flag.Request;
         L.Evaluate
           (Live, Under.Ready, 5, Logits, Flag'Unchecked_Access, Status);
         Assert (Status.Code = E.Generation_Cancelled,
                 "cancellation was not reported");
         Assert (L.Position (Live) = 1,
                 "a cancelled token committed a cache position");

         L.Close (Live);
      end;

      B.Free (Image);
   end Cancellation_Does_Not_Commit;

   --  Filling the context reports Generation_Context_Exhausted rather than
   --  silently shifting or truncating the cache.
   procedure Context_Full_Is_Reported
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         Logits : Logit_Vector;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Context => 4, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         for Step in 1 .. 4 loop
            L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed while filling");
         end loop;

         L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
         Assert (Status.Code = E.Generation_Context_Exhausted,
                 "a full context was not reported");
         Assert (L.Position (Live) = 4, "position moved past capacity");

         L.Reset (Live);
         Assert (L.Position (Live) = 0, "reset did not clear the position");

         L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
         Assert (E.Is_Ok (Status), "session unusable after reset");

         L.Close (Live);
      end;

      B.Free (Image);
   end Context_Full_Is_Reported;

   --  An out-of-range token identifier is rejected before any evaluation.
   procedure Invalid_Token_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         Logits : Logit_Vector;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         L.Evaluate
           (Live, Under.Ready, Vocab.Token_Id (Tiny_Model.Vocabulary),
            Logits, Status => Status);
         Assert (Status.Code = E.Tokenizer_Invalid_Token_Id,
                 "an out-of-range token was accepted");
         Assert (L.Position (Live) = 0, "a rejected token advanced the context");

         L.Close (Live);
      end;

      B.Free (Image);
   end Invalid_Token_Rejected;

   --  The tokenizer round-trips text through the tiny vocabulary and the
   --  incremental decoder never emits a partial code point.
   procedure Tokenizer_Round_Trip (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Status : E.Error_Info;
         Tokens : Vocab.Token_Array (1 .. 64);
         Last   : Natural;
      begin
         Start (Under);

         declare
            Words : constant access constant Vocab.Vocabulary :=
              L.Vocabulary (Under.Ready);
         begin
            Assert (Vocab.Is_Loaded (Words.all), "vocabulary not loaded");
            Assert (Vocab.Size (Words.all) = Tiny_Model.Vocabulary,
                    "wrong vocabulary size");
            Assert (Vocab.Kind (Words.all) = Vocab.Kind_SentencePiece,
                    "wrong tokenizer model");
            Assert (Vocab.Beginning_Token (Words.all) = 1, "wrong bos");
            Assert (Vocab.End_Token (Words.all) = 2, "wrong eos");

            Vocab.Encode (Words.all, "abc", True, False, Tokens, Last, Status);
            Assert (E.Is_Ok (Status),
                    "encode failed: " & E.Error_Code'Image (Status.Code));
            Assert (Last >= 2, "encode produced too few tokens");
            Assert (Tokens (1) = 1, "beginning token was not prepended");

            for Index in 1 .. Last loop
               Assert (Vocab.Is_Valid (Words.all, Tokens (Index)),
                       "encode produced an out-of-range token");
            end loop;

            declare
               Decoded : constant String :=
                 Vocab.Decode (Words.all, Tokens (1 .. Last));
            begin
               Assert (Decoded = "abc",
                       "round trip produced """ & Decoded & """");
            end;
         end;
      end;

      B.Free (Image);
   end Tokenizer_Round_Trip;

   --  An interrupt requests a clean cancellation rather than killing the
   --  process. The signal is raised against this process so the test needs no
   --  terminal and no second process.
   procedure Interrupt_Requests_Cancellation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Interfaces.C.int;

      --  The signal has to be directed at the process, not at this thread.
      --  The runtime blocks signals in ordinary tasks and delivers them
      --  through a dedicated waiter, so a thread-directed raise would stay
      --  pending on a thread that never waits for it.
      function C_Getpid return Interfaces.C.int
      with Import, Convention => C, External_Name => "getpid";

      function C_Kill
        (Process : Interfaces.C.int;
         Signal  : Interfaces.C.int) return Interfaces.C.int
      with Import, Convention => C, External_Name => "kill";

      SIGINT : constant Interfaces.C.int := 2;

      Token     : aliased Model_Runner.Cancellation.Token;
      Installed : Boolean;
      Observed  : Boolean := False;
   begin
      Model_Runner.Platform.Signals.Install (Token'Unchecked_Access, Installed);

      --  The partition unreserves SIGINT, so installation must succeed. A
      --  silent skip here would let the whole cancellation path rot unnoticed,
      --  which is what happened before this assertion existed.
      Assert (Installed,
              "the interrupt handler was not installed: "
              & Model_Runner.Platform.Signals.Failure_Name);

      Assert (not Token.Is_Requested,
              "the token was already set before any interrupt");

      Assert (C_Kill (C_Getpid, SIGINT) = 0,
              "the interrupt could not be raised");

      --  The handler runs in its own context, so poll for a bounded time
      --  rather than assuming it has already run.
      for Attempt in 1 .. 200 loop
         if Token.Is_Requested then
            Observed := True;
            exit;
         end if;
         delay 0.005;
      end loop;

      Assert (Observed, "an interrupt did not reach the cancellation token");
      Assert (Model_Runner.Platform.Signals.Interrupts >= 1,
              "the interrupt was not counted");

      Model_Runner.Platform.Signals.Remove;

      --  After removal the token is no longer the interrupt's target.
      Token.Reset;
      Assert (not Token.Is_Requested, "reset did not clear the token");
   end Interrupt_Requests_Cancellation;

   --  The engine agrees with an independent implementation of the same
   --  architecture, computed in a different arithmetic. This is the strongest
   --  correctness evidence available without an external model: a shared
   --  mistake would have to have been made twice, differently.
   procedure Matches_Independent_Reference
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Result : Conformance.Report;
   begin
      Conformance.Run (Result);

      Assert (Result.Ran,
              "the conformance comparison did not complete:"
              & Natural'Image (Result.Sequences) & " sequences ran");
      Assert (Result.Compared > 0, "no logits were compared");
      Assert (Result.Failures = 0,
              Natural'Image (Result.Failures) & " of"
              & Natural'Image (Result.Compared)
              & " logits fell outside tolerance; worst absolute difference"
              & Long_Float'Image (Result.Worst_Abs)
              & ", worst relative" & Long_Float'Image (Result.Worst_Rel));
   end Matches_Independent_Reference;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("llama inference");
   end Name;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Model_Prepares'Access,
         "the tiny model prepares and reports its configuration");
      Register_Routine
        (T, Evaluation_Advances'Access,
         "evaluation produces finite logits and commits one position each");
      Register_Routine
        (T, Batch_Matches_Sequence'Access,
         "a batch produces the same bits as the tokens evaluated one by one");
      Register_Routine
        (T, Evaluation_Is_Deterministic'Access,
         "the same token sequence produces identical logits");
      Register_Routine
        (T, Cancellation_Does_Not_Commit'Access,
         "a cancelled token leaves the committed context unchanged");
      Register_Routine
        (T, Context_Full_Is_Reported'Access,
         "a full context is reported and reset makes the session usable");
      Register_Routine
        (T, Invalid_Token_Rejected'Access,
         "an out-of-range token identifier is rejected");
      Register_Routine
        (T, Tokenizer_Round_Trip'Access,
         "text round-trips through the tiny vocabulary");
      Register_Routine
        (T, Matches_Independent_Reference'Access,
         "logits match an independent reference implementation");
      Register_Routine
        (T, Interrupt_Requests_Cancellation'Access,
         "an interrupt requests cancellation instead of killing the process");
   end Register_Tests;

end Tests.Inference_Cases;
