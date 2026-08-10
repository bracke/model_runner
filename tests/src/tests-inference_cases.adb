with AUnit.Assertions;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Memory;

with Model_Runner.Cancellation;
with Model_Runner.Limits;
with Model_Runner.Progress;
with External_Model;
with Model_Runner.Platform.Signals;

with Raise_Interrupt;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Kernels;
with Interfaces;
with Model_Runner.Llama;
with Model_Runner.Memory;
with Model_Runner.Numerics;
with Model_Runner.Generation;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Tokenizer;

with Conformance;
with BPE_Vocabulary;
with Reference_Tokenizer;
with Tiny_Model;

package body Tests.Inference_Cases is

   use type Model_Runner.Cancellation.Token_Reference;

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
   --  An observer that asks for cancellation once it has seen enough stages.
   --
   --  Loading reports its progress stage by stage, and the cancellation points
   --  sit between those stages. Asking from inside the observer is therefore
   --  the way to arrive at a point in the middle of a load without reaching
   --  into anything private.
   type Cancel_After is limited new Model_Runner.Progress.Observer with record
      Flag  : Model_Runner.Cancellation.Token_Reference := null;
      After : Natural := 1;
      Seen  : Natural := 0;
   end record;

   overriding procedure Notify
     (Self : in out Cancel_After;
      Item : Model_Runner.Progress.Event);

   overriding procedure Notify
     (Self : in out Cancel_After;
      Item : Model_Runner.Progress.Event)
   is
      pragma Unreferenced (Item);
   begin
      Self.Seen := Self.Seen + 1;
      if Self.Seen = Self.After and then Self.Flag /= null then
         Self.Flag.all.Request;
      end if;
   end Notify;

   --  Cancellation is honoured while a model is loading, not only once it is
   --  generating.
   --
   --  The engine says it observes cancellation between parser sections,
   --  tensors and layers as well as between tokens. Only the token one was
   --  tested. The others matter more for a large model: loading is where the
   --  seconds are, and it is where an impatient reader presses Ctrl-C.
   procedure Cancellation_Stops_A_Load
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Image   : B.Byte_Array_Access;
      Stopped : Natural := 0;
      Stages  : Natural := 0;
   begin
      Tiny_Model.Build (Image);

      --  How many stages a whole load reports, so the sweep below covers
      --  every one of them rather than a guessed number.
      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Source  : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Counter : aliased Cancel_After := (Flag => null, After => 0, Seen => 0);
         Item    : Containers.Container;
         Model   : L.Model;
         Status  : E.Error_Info;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse
           (Item, Source, Model_Runner.Limits.Default_Model_Limits,
            null, Counter'Unchecked_Access, Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare
           (Model, Item, Source,
            Observer => Counter'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not prepare");

         Stages := Counter.Seen;
         L.Close (Model, Status);
         Containers.Close (Item);
      end;

      Assert (Stages > 1,
              "loading reported" & Natural'Image (Stages)
              & " stages, too few to cancel between");

      --  Ask at each stage in turn. Every request must either stop the load
      --  or arrive after it finished; what must never happen is a load that
      --  was asked to stop and carried on to a usable model.
      for Point in 1 .. Stages loop
         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Flag   : aliased Model_Runner.Cancellation.Token;
            Asking : aliased Cancel_After :=
              (Flag => Flag'Unchecked_Access, After => Point, Seen => 0);
            Item   : Containers.Container;
            Model  : L.Model;
            Status : E.Error_Info;
            Parsed : E.Error_Info;
         begin
            Model_Runner.GGUF.Containers.Reader.Parse
              (Item, Source, Model_Runner.Limits.Default_Model_Limits,
               Flag'Unchecked_Access, Asking'Unchecked_Access, Parsed);

            if Parsed.Code = E.Generation_Cancelled then
               Stopped := Stopped + 1;
            else
               Assert (E.Is_Ok (Parsed),
                       "parsing failed for a reason other than cancellation: "
                       & E.Error_Code'Image (Parsed.Code));

               L.Prepare
                 (Model, Item, Source,
                  Cancel   => Flag'Unchecked_Access,
                  Observer => Asking'Unchecked_Access,
                  Status   => Status);

               if Status.Code = E.Generation_Cancelled then
                  Stopped := Stopped + 1;
               else
                  Assert (E.Is_Ok (Status),
                          "preparation failed for a reason other than"
                          & " cancellation: "
                          & E.Error_Code'Image (Status.Code));
               end if;

               L.Close (Model, Status);
            end if;

            Containers.Close (Item);
         end;
      end loop;

      --  Asking during the load has to stop it at least sometimes; if no
      --  request ever landed, the observation points are not being reached.
      --  Nine of the eleven stages stop the load. The last two are past the
      --  final observation point, so a request arriving there has nothing left
      --  to check it; everything earlier must stop. Asserting only that some
      --  request landed would pass with a single surviving observation point.
      --
      --  What this pins down, measured one check at a time rather than
      --  assumed. Removing both cancellation checks in preparation fails it:
      --  nine of eleven becomes four. Removing either one alone does not,
      --  because the other catches the request at the next stage, so this
      --  test holds the pair rather than either member.
      --
      --  The checks inside the two evaluation loops, and the parser's own,
      --  belong to the standing-request test above rather than to this one:
      --  with the parser's disabled, the preparation checks here still stop
      --  nine of the eleven. Worth writing down, because a test that stops a
      --  load looks from the outside as though it must cover every point that
      --  could stop one.
      Assert (Stopped >= Stages - 2,
              "only" & Natural'Image (Stopped) & " of"
              & Natural'Image (Stages)
              & " requests made during a load stopped it");

      B.Free (Image);
   end Cancellation_Stops_A_Load;

   --  A request that is already standing stops the parser and the batched
   --  forward pass, and leaves the cache where it was.
   --
   --  These are the two observation points no test held. The batched pass is
   --  the one that matters in use: prefill is the long part of answering a
   --  large prompt, so it is where an interrupt actually lands, and a request
   --  arriving between its layers has to leave the cache describing exactly
   --  the context that was valid before the call.
   --
   --  Asking before the call rather than during it is deliberate. A request
   --  raised from another task would land somewhere unpredictable in a model
   --  this small, and the point being checked is that the observation happens
   --  at all, not when.
   procedure Standing_Cancellation_Stops_Each_Stage
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      --  The parser.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Flag   : aliased Model_Runner.Cancellation.Token;
         Item   : Containers.Container;
         Status : E.Error_Info;
      begin
         Flag.Request;
         Model_Runner.GGUF.Containers.Reader.Parse
           (Item, Source, Model_Runner.Limits.Default_Model_Limits,
            Flag'Unchecked_Access, null, Status);

         Assert (Status.Code = E.Generation_Cancelled,
                 "a standing request did not stop the parser: "
                 & E.Error_Code'Image (Status.Code));
         Containers.Close (Item);
      end;

      --  The batched forward pass, and the single-token one beside it.
      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Live    : L.Session;
         Flag    : aliased Model_Runner.Cancellation.Token;
         Status  : E.Error_Info;
         Logits  : Logit_Vector;
         Before  : Natural;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         --  Evaluate something first, so the cache holds a position that a
         --  cancelled call could damage.
         L.Evaluate
           (Live, Under.Ready,
            Model_Runner.Tokenizer.Token_Id (1), Logits, Status => Status);
         Assert (E.Is_Ok (Status), "the first token did not evaluate");
         Before := L.Position (Live);
         Assert (Before > 0, "nothing was committed to cancel against");

         Flag.Request;

         L.Evaluate_Batch
           (Live, Under.Ready,
            [Model_Runner.Tokenizer.Token_Id (2),
             Model_Runner.Tokenizer.Token_Id (3)],
            Logits, Flag'Unchecked_Access, Status);
         Assert (Status.Code = E.Generation_Cancelled,
                 "a standing request did not stop the batched pass: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = Before,
                 "a cancelled batch moved the cache from"
                 & Natural'Image (Before)
                 & " to" & Natural'Image (L.Position (Live)));

         L.Evaluate
           (Live, Under.Ready, Model_Runner.Tokenizer.Token_Id (2),
            Logits, Flag'Unchecked_Access, Status);
         Assert (Status.Code = E.Generation_Cancelled,
                 "a standing request did not stop the single-token pass: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = Before,
                 "a cancelled token moved the cache");

         L.Close (Live);
      end;

      B.Free (Image);
   end Standing_Cancellation_Stops_Each_Stage;

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

   --  A batch is refused at the same boundary a single token is, and refusing
   --  it leaves the cache where it was.
   --
   --  The two paths guard the context with different lines: one token asks
   --  whether a slot is free, a batch asks whether the whole batch fits. Only
   --  the first was tested, and the second is the one where being wrong
   --  writes past the end of the cache rather than one slot into it.
   procedure Batch_Respects_The_Context_Bound
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room  : constant := 4;
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

         --  A batch that fills the context exactly is accepted. The bound is
         --  a bound and not one less.
         L.Open (Live, Under.Ready, Context => Room, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         L.Evaluate_Batch
           (Live, Under.Ready, [4, 4, 4, 4], Logits, Status => Status);
         Assert (E.Is_Ok (Status),
                 "a batch filling the context exactly was refused: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = Room,
                 "a filling batch left the position at"
                 & Natural'Image (L.Position (Live)));

         --  And one more token has nowhere to go.
         L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
         Assert (Status.Code = E.Generation_Context_Exhausted,
                 "a token past a full context was accepted");

         --  A batch larger than the whole context is refused before anything
         --  is written, and the cache is untouched.
         L.Reset (Live);
         Assert (L.Position (Live) = 0, "reset did not empty the cache");

         L.Evaluate_Batch
           (Live, Under.Ready, [4, 4, 4, 4, 4], Logits, Status => Status);
         Assert (Status.Code = E.Generation_Context_Exhausted,
                 "a batch larger than the context was accepted: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = 0,
                 "a refused batch moved the cache to"
                 & Natural'Image (L.Position (Live)));

         --  A batch that would fit an empty context but not the room left is
         --  refused too, which is the case the single-token guard cannot see.
         L.Evaluate_Batch
           (Live, Under.Ready, [4, 4], Logits, Status => Status);
         Assert (E.Is_Ok (Status), "a batch inside the context was refused");

         L.Evaluate_Batch
           (Live, Under.Ready, [4, 4, 4], Logits, Status => Status);
         Assert (Status.Code = E.Generation_Context_Exhausted,
                 "a batch past the room left was accepted: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = 2,
                 "a refused batch moved the cache from two to"
                 & Natural'Image (L.Position (Live)));

         L.Close (Live);
      end;

      B.Free (Image);
   end Batch_Respects_The_Context_Bound;

   --  A reset session answers exactly as a fresh one does.
   --
   --  Reset is cheap on purpose: it moves the commit point back to zero and
   --  leaves the cache allocated, so the previous turn's keys and values are
   --  still sitting in it. That is only sound while attention reads no
   --  further than the commit point. If it ever read past it, the abandoned
   --  turn would colour the next one -- and it would do so silently, because
   --  logits stained by a stale key still look like logits.
   procedure Reset_Leaves_No_Trace_Of_The_Previous_Turn
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Image : B.Byte_Array_Access;
      Alone : Logit_Vector := [others => 0.0];
      After : Logit_Vector := [others => 0.0];
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         Scrap  : Logit_Vector;
      begin
         Start (Under);

         L.Open (Live, Under.Ready, Context => 8, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         --  What the model says about one token with nothing behind it.
         L.Evaluate (Live, Under.Ready, 1, Alone, Status => Status);
         Assert (E.Is_Ok (Status), "the first evaluation failed");

         --  Now put a different turn through the same cache, so that the
         --  slots the next turn will read are full of somebody else's work.
         L.Reset (Live);
         for Token in Vocab.Token_Id range 4 .. 7 loop
            L.Evaluate (Live, Under.Ready, Token, Scrap, Status => Status);
            Assert (E.Is_Ok (Status), "filling the cache failed");
         end loop;
         Assert (L.Position (Live) = 4, "the cache did not fill");

         L.Reset (Live);
         Assert (L.Position (Live) = 0, "reset did not empty the cache");

         --  And the same token again, over a cache that still holds the
         --  other turn. The answer must not have moved at all.
         L.Evaluate (Live, Under.Ready, 1, After, Status => Status);
         Assert (E.Is_Ok (Status), "the evaluation after reset failed");

         L.Close (Live);
      end;

      --  Bit-for-bit. A tolerance here would accept exactly the leak this
      --  test exists to refuse: a stale key moves a logit a little.
      for Index in Alone'Range loop
         Assert
           (Alone (Index) = After (Index),
            "the abandoned turn changed the logit at"
            & N.Element_Count'Image (Index));
      end loop;

      B.Free (Image);
   end Reset_Leaves_No_Trace_Of_The_Previous_Turn;

   --  Weights are used where the file put them, not repacked into a copy.
   --
   --  This is one of three things the README names as absent, and the only
   --  one with a handle: the accounting has a category for converted weights,
   --  so the program already counts what a repacking would produce. A runtime
   --  that repacked would show a converted total near the weight total; one
   --  that reads the file's layout shows almost nothing there.
   --
   --  Almost, rather than nothing. The norm vectors are dequantized once when
   --  the model is prepared, which is a conversion and is counted as one.
   --  What is held here is that the matrices are not: they are what the
   --  weight total is made of, and converting any of them would move the
   --  converted total by more than this allows.
   procedure Weights_Are_Not_Repacked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Interfaces.Unsigned_64;

      Image : B.Byte_Array_Access;
   begin
      --  Quantized, so that a repacking would have something to unpack into
      --  and would show.
      Tiny_Model.Build (Image, Format => Tiny_Model.Q8_0);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
      begin
         Start (Under);

         declare
            Books : constant Model_Runner.Memory.Account := L.Account (Under.Ready);

            Weights   : constant Interfaces.Unsigned_64 :=
              Books.By_Category (Model_Runner.Memory.Model_Weights);
            Converted : constant Interfaces.Unsigned_64 :=
              Books.By_Category (Model_Runner.Memory.Converted_Weights);
         begin
            Assert (Weights > 0,
                    "no weights were accounted for, so this compares nothing");

            --  The norms are converted, so the category is not empty and the
            --  bound below is not satisfied by the feature being absent.
            Assert (Converted > 0,
                    "nothing was converted at all, which is not what this "
                    & "model does");

            --  And they are all that is: a matrix is at least an order of
            --  magnitude larger than the norms beside it, so repacking one
            --  could not fit under this.
            Assert (Converted * 4 < Weights,
                    "converted" & Interfaces.Unsigned_64'Image (Converted)
                    & " bytes against" & Interfaces.Unsigned_64'Image (Weights)
                    & " of weights: too much to be the norms alone");
         end;
      end;

      B.Free (Image);
   end Weights_Are_Not_Repacked;

   --  Evaluation refuses arguments it cannot serve.
   --
   --  These are the checks at the top of both evaluation entries: that the
   --  logit buffer is the vocabulary's width, and that a batch holds between
   --  one and Max_Batch tokens. They are the contract the engine offers a
   --  caller who is not the command line -- and past them, a buffer of the
   --  wrong width is written to for the width the model has, not the width
   --  the caller brought.
   procedure Evaluation_Refuses_Arguments_It_Cannot_Serve
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
         Narrow : N.Real_Array (0 .. Logit_Vector'Length - 2);
         Wide   : N.Real_Array (0 .. Logit_Vector'Length);

         Nothing  : constant Vocab.Token_Array (1 .. 0) := [];
         Too_Many : constant Vocab.Token_Array (1 .. L.Max_Batch + 1) :=
           [others => 1];

         procedure Refused (What : String) is
         begin
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    What & ": expected TENSOR_SHAPE_MISMATCH but got "
                    & E.Error_Code'Image (Status.Code));
            Assert (L.Position (Live) = 0,
                    What & ": a refused call committed a cache position");
         end Refused;
      begin
         Start (Under);

         L.Open (Live, Under.Ready, Context => 8, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         --  A logit buffer narrower than the vocabulary, and one wider. The
         --  width has to be the model's, not merely enough room: a caller
         --  reading a wider buffer would read positions the model never
         --  wrote and take them for logits.
         L.Evaluate (Live, Under.Ready, 1, Narrow, Status => Status);
         Refused ("a logit buffer one element short");

         L.Evaluate (Live, Under.Ready, 1, Wide, Status => Status);
         Refused ("a logit buffer one element long");

         L.Evaluate_Batch (Live, Under.Ready, [1, 2], Narrow, Status => Status);
         Refused ("a batch into a logit buffer one element short");

         --  A batch of nothing is not a batch, and one past the documented
         --  limit is refused at the limit rather than wherever the scratch
         --  buffers happen to give out.
         L.Evaluate_Batch (Live, Under.Ready, Nothing, Logits, Status => Status);
         Refused ("a batch of no tokens");

         L.Evaluate_Batch
           (Live, Under.Ready, Too_Many, Logits, Status => Status);
         Refused ("a batch of more than Max_Batch tokens");

         --  The same calls with the width the model has, so that every
         --  refusal above is about the argument and not the state.
         L.Evaluate (Live, Under.Ready, 1, Logits, Status => Status);
         Assert (E.Is_Ok (Status),
                 "a well-formed evaluation failed after the refusals: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = 1, "the accepted token did not commit");

         L.Close (Live);
      end;

      B.Free (Image);
   end Evaluation_Refuses_Arguments_It_Cannot_Serve;

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

      if not Raise_Interrupt.Can_Request then
         --  Windows. The engine handles console control events, but a process
         --  may only send one to its whole console group, and firing it at a
         --  test runner wedges the shell that started it. What can be checked
         --  here is checked: the handler installed above, and Remove below
         --  puts it back. Delivery is exercised by hand on that host.
         Model_Runner.Platform.Signals.Remove;
         Token.Reset;
         Assert (not Token.Is_Requested, "reset did not clear the token");
         return;
      end if;

      Assert (Raise_Interrupt.Request,
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

   -------------------------------------------
   -- Refused_Generation_Names_Its_Reason --
   -------------------------------------------

   --  A run the engine refuses says which refusal it was.
   --
   --  The external-model runner used to report "generation failed" and stop
   --  there, discarding the diagnostic the engine had already written. The
   --  README published an invocation of it that cannot succeed -- the
   --  committed fixture holds sixteen tokens of context and the runner asks
   --  for sixteen by default, so a prompt of any length leaves no room -- and
   --  nobody noticed for two years, because the message said nothing worth
   --  chasing.
   --
   --  This asks for that refusal on purpose and requires the code in the
   --  answer. The fixture is the small one this repository owns, so the test
   --  is mandatory rather than skipped.

   --  The tokenizer agrees with one written from the description.
   --
   --  The forward pass has had an independent reader since the beginning and
   --  the tokenizer had none: what checked it was a set of expectations
   --  recorded from llama.cpp, which need a model nobody can commit, so on a
   --  clean checkout the strongest thing said about it was that its own unit
   --  tests agreed with themselves. Reference_Tokenizer reads the same
   --  vocabulary out of the container and encodes by the rule the format
   --  describes, scanning where the engine hashes.

   procedure Tokenizer_Matches_An_Independent_One
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image  : B.Byte_Array_Access;
      Parsed : Containers.Container;
      Status : E.Error_Info;
      Loaded : Boolean;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Words  : Vocab.Vocabulary;
         Second : Reference_Tokenizer.Vocabulary;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         Vocab.Load (Words, Parsed, Status => Status);
         Assert (E.Is_Ok (Status), "the engine did not read the vocabulary");

         Reference_Tokenizer.Load (Second, Parsed, Loaded);
         Assert (Loaded, "the reference did not read the vocabulary");
         Assert (Reference_Tokenizer.Size (Second) = Vocab.Size (Words),
                 "the two read different vocabularies");

         --  Text that reaches each rule: a piece of its own, a merge, a
         --  merge that competes with a longer one, a space, and a character
         --  the vocabulary does not carry, which becomes bytes.
         --
         --  The last two are the ones that say the merges happen in the
         --  right order rather than merely happening. In "cabc" the pairs
         --  "ab" and "bc" overlap and "bc" scores higher, so a reader that
         --  took the leftmost pair would produce "c ab c" where the rule
         --  produces "c a bc". Without them a leftmost-pair reader agrees
         --  with the engine on every case above, which was checked by
         --  writing one.
         declare
            type Case_Text is access constant String;
            Cases : constant array (1 .. 14) of Case_Text :=
              [new String'(""),
               new String'("a"),
               new String'("ab"),
               new String'("abc"),
               new String'("a b"),
               new String'("bca"),
               new String'("dab"),
               new String'("a" & Character'Val (16#0A#) & "b"),
               new String'("cabc"),
               new String'("cabcab"),

               --  A control token written into the text, which is what a
               --  chat template does with bos_token and eos_token before
               --  anything is tokenized. Until the rule that reads them was
               --  made to cover this road too, "</s>" came back as its
               --  letters, one byte token each.
               new String'("a</s>b"),
               new String'("<s>ab"),
               new String'("</s>"),
               new String'("<s>a</s>")];
         begin
            for Which of Cases loop
               declare
                  Mine   : Vocab.Token_Array (1 .. 64);
                  Mine_N : Natural;
                  Theirs : Reference_Tokenizer.Token_Vector (1 .. 64);
                  Theirs_N : Natural;
               begin
                  Vocab.Encode
                    (Words, Which.all, True, False, Mine, Mine_N, Status);
                  Assert (E.Is_Ok (Status),
                          "the engine refused """ & Which.all & """");

                  Reference_Tokenizer.Encode
                    (Second, Which.all, True, Theirs, Theirs_N);

                  Assert (Mine_N = Theirs_N,
                          "the two disagree on how many tokens """
                          & Which.all & """ makes:"
                          & Natural'Image (Mine_N) & " against"
                          & Natural'Image (Theirs_N));

                  for Index in 1 .. Natural'Min (Mine_N, Theirs_N) loop
                     Assert (Integer (Mine (Index)) = Theirs (Index),
                             "the two disagree on token"
                             & Natural'Image (Index) & " of """
                             & Which.all & """:"
                             & Vocab.Token_Id'Image (Mine (Index))
                             & " against" & Integer'Image (Theirs (Index)));
                  end loop;
               end;
            end loop;
         end;

         --  Said outright, because the two agreeing would not tell a rule
         --  that reads control tokens from two readers that both miss them.
         --  A chat template substitutes bos_token and eos_token as their
         --  spelling before anything is tokenized, so this is the shape the
         --  tokenizer is handed on every templated turn.
         declare
            Mine   : Vocab.Token_Array (1 .. 16);
            Mine_N : Natural;
         begin
            Vocab.Encode
              (Words, "a</s>b", True, False, Mine, Mine_N, Status);
            Assert (E.Is_Ok (Status), "the engine refused a control token");
            Assert (Mine_N = 4,
                    "a control token in the text was not one token:"
                    & Natural'Image (Mine_N) & " tokens where four were due");
            Assert (Mine (1) = 1 and then Mine (2) = 9
                    and then Mine (3) = 2 and then Mine (4) = 5,
                    "the control token did not come back as itself");
         end;

         Reference_Tokenizer.Close (Second);
         Vocab.Close (Words);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Tokenizer_Matches_An_Independent_One;

   --  The same comparison for a byte-pair vocabulary, under every rule.
   --
   --  The reader written from the description covers both halves of the
   --  tokenizer or it covers neither: the byte-pair half decides a merge by
   --  rank rather than by score and cuts the text before merging at all, so
   --  agreement on one says nothing about the other. This runs the same
   --  strings under all five cutting rules, which is thirty comparisons of
   --  identifiers against a reader that shares no code with the engine.
   procedure Byte_Pair_Matches_An_Independent_One
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type Reference_Tokenizer.Model_Kind;

      Tab : constant String := [1 => Character'Val (16#09#)];

      type Case_Text is access constant String;
      Rules : constant array (1 .. 5) of Case_Text :=
        [new String'("gpt-2"),
         new String'("falcon"),
         new String'("smollm"),
         new String'("llama3"),
         new String'("qwen2")];

      --  Text that reaches every part of the rule: a bare word, the markers
      --  a chat template writes and two strings that open a bracket without
      --  being one, a word whose merges are decided by rank rather than by
      --  position, a word led by a space, a tab before a word, runs of
      --  digits of each length the three groupings tell apart, and a
      --  contraction.
      Cases : constant array (1 .. 10) of Case_Text :=
        [new String'("ab"),
         new String'("<|im_start|>ab<|im_end|>"),
         new String'("<ab"),
         new String'("<|im_"),
         new String'("abc"),
         new String'("x ab"),
         new String'("x" & Tab & "ab"),
         new String'("ab 1234"),
         new String'("x 12 abc"),
         new String'("ab's 4321")];
   begin
      for Rule of Rules loop
         declare
            Image  : B.Byte_Array_Access;
            Parsed : Containers.Container;
            Status : E.Error_Info;
            Loaded : Boolean;
         begin
            BPE_Vocabulary.Build (Rule.all, Image);

            declare
               Held   : aliased constant B.Byte_Array := Image.all;
               Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
                 (Held'Access);
               Words  : Vocab.Vocabulary;
               Second : Reference_Tokenizer.Vocabulary;
            begin
               Containers.Reader.Parse (Parsed, Source, Status => Status);
               Assert (E.Is_Ok (Status),
                       "the byte-pair fixture did not parse");

               Vocab.Load (Words, Parsed, Status => Status);
               Assert (E.Is_Ok (Status),
                       "the engine did not read the byte-pair vocabulary");

               Reference_Tokenizer.Load (Second, Parsed, Loaded);
               Assert (Loaded,
                       "the reference did not read the byte-pair vocabulary");
               Assert (Reference_Tokenizer.Kind (Second)
                       = Reference_Tokenizer.Byte_Pair,
                       "the reference read it as something else");

               for Which of Cases loop
                  declare
                     Mine     : Vocab.Token_Array (1 .. 64);
                     Mine_N   : Natural;
                     Theirs   : Reference_Tokenizer.Token_Vector (1 .. 64);
                     Theirs_N : Natural;
                  begin
                     Vocab.Encode
                       (Words, Which.all, False, False, Mine, Mine_N, Status);
                     Assert (E.Is_Ok (Status),
                             "the engine refused """ & Which.all
                             & """ under " & Rule.all & ": "
                             & E.Error_Code'Image (Status.Code));

                     Reference_Tokenizer.Encode
                       (Second, Which.all, False, Theirs, Theirs_N);

                     Assert (Mine_N = Theirs_N,
                             "under " & Rule.all
                             & " the two disagree on how many tokens """
                             & Which.all & """ makes:"
                             & Natural'Image (Mine_N) & " against"
                             & Natural'Image (Theirs_N));

                     for Index in 1 .. Natural'Min (Mine_N, Theirs_N) loop
                        Assert (Integer (Mine (Index)) = Theirs (Index),
                                "under " & Rule.all
                                & " the two disagree on token"
                                & Natural'Image (Index) & " of """
                                & Which.all & """:"
                                & Vocab.Token_Id'Image (Mine (Index))
                                & " against"
                                & Integer'Image (Theirs (Index)));
                     end loop;
                  end;
               end loop;

               Reference_Tokenizer.Close (Second);
               Vocab.Close (Words);
               Containers.Close (Parsed);
            end;

            B.Free (Image);
         end;
      end loop;
   end Byte_Pair_Matches_An_Independent_One;

   --  A byte-pair model, driven rather than called.
   --
   --  Every session this suite ran, every token it generated and the whole
   --  conformance sweep went through a SentencePiece vocabulary, because the
   --  fixture writer could write no other kind. The byte-pair road was well
   --  covered as a tokenizer and covered nowhere as part of a run, so a
   --  defect in how a session hands tokens to it -- the end-token policy, the
   --  streaming decoder between turns, a stop string matched against text
   --  that came back through the stand-in mapping -- would have shown up
   --  nowhere at all.
   procedure Byte_Pair_Model_Runs_End_To_End
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Byte_Pair => True);

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
            Assert (Vocab.Is_Loaded (Words.all),
                    "the byte-pair vocabulary did not load in a session");
            Assert (Vocab.Kind (Words.all) = Vocab.Kind_BPE,
                    "the session read it as something other than byte-pair");
            Assert (Vocab.Size (Words.all) = Tiny_Model.Vocabulary,
                    "the byte-pair vocabulary is a different size");
            Assert (Vocab.Beginning_Token (Words.all) = 1, "wrong bos");
            Assert (Vocab.End_Token (Words.all) = 2, "wrong eos");

            --  A prompt through the whole path: encode, evaluate every
            --  position, and read the logits the last one leaves.
            Vocab.Encode
              (Words.all, "abc ab", True, False, Tokens, Last, Status);
            Assert (E.Is_Ok (Status),
                    "the session could not encode a prompt: "
                    & E.Error_Code'Image (Status.Code));
            Assert (Last >= 3, "the prompt made too few tokens");
            Assert (Tokens (1) = 1, "the beginning token was not prepended");

            for Index in 1 .. Last loop
               Assert (Vocab.Is_Valid (Words.all, Tokens (Index)),
                       "the prompt made a token outside the vocabulary");
            end loop;

            declare
               Decoded : constant String :=
                 Vocab.Decode (Words.all, Tokens (2 .. Last));
            begin
               Assert (Decoded = "abc ab",
                       "the prompt did not survive the round trip: """
                       & Decoded & """");
            end;

            declare
               Live   : L.Session;
               Scores : Logit_Vector;
            begin
               L.Open (Live, Under.Ready, Status => Status);
               Assert (E.Is_Ok (Status),
                       "a session did not open on a byte-pair model: "
                       & E.Error_Code'Image (Status.Code));

               for Index in 1 .. Last loop
                  L.Evaluate
                    (Live, Under.Ready, Tokens (Index), Scores,
                     Status => Status);
                  Assert (E.Is_Ok (Status),
                          "evaluation failed at position"
                          & Natural'Image (Index) & ": "
                          & E.Error_Code'Image (Status.Code));
                  Assert (Model_Runner.Kernels.All_Finite (Scores),
                          "a byte-pair prompt produced a logit that is not"
                          & " finite");
               end loop;

               Assert (L.Position (Live) = Last,
                       "the session did not commit one position per token");

               --  What generation would do next: take a token from those
               --  logits and read it back as text through the stand-in
               --  mapping, one token at a time, as streaming does.
               declare
                  Best   : Vocab.Token_Id := 0;
                  Stream : Vocab.Decoder;
               begin
                  for Index in Scores'Range loop
                     if Scores (Index)
                       > Scores (N.Element_Count (Best))
                     then
                        Best := Vocab.Token_Id (Index);
                     end if;
                  end loop;

                  Assert (Vocab.Is_Valid (Words.all, Best),
                          "the most probable token is outside the vocabulary");

                  Vocab.Reset (Stream);
                  declare
                     Shown : constant String :=
                       Vocab.Push (Stream, Words.all, Best);
                  begin
                     Assert (Shown'Length <= 32,
                             "streaming a byte-pair token produced more text"
                             & " than one piece can hold");
                  end;
               end;

               L.Close (Live);
            end;
         end;
      end;

      B.Free (Image);
   end Byte_Pair_Model_Runs_End_To_End;

   --  Exactly one beginning token, whoever put it there.
   --
   --  Two paths reach the tokenizer with a prompt. With --raw there is no
   --  template, the request asks for the beginning token and the vocabulary
   --  decides whether it wants one. With a template the template writes the
   --  token's own text, where the model expects it, and the tokenizer turns
   --  that spelling back into the token -- so the request must not ask as
   --  well. Whether it does was one uncommented line and no test at all.
   --
   --  The cost of getting it wrong is not a rounding difference. A beginning
   --  marker in front of a model that declares it wants none moved a logit by
   --  nearly two, where two honest implementations of the same arithmetic
   --  differ by hundredths; it is written up in docs/reference-runtime.md.
   procedure One_Beginning_Token_However_It_Arrives
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;

      --  How many times the beginning token appears.
      function Beginnings
        (Words : Vocab.Vocabulary; Tokens : Vocab.Token_Array) return Natural
      is
         Seen : Natural := 0;
      begin
         for Token of Tokens loop
            if Token = Vocab.Beginning_Token (Words) then
               Seen := Seen + 1;
            end if;
         end loop;
         return Seen;
      end Beginnings;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed : Containers.Container;
         Words  : Vocab.Vocabulary;
         Status : E.Error_Info;
         Tokens : Vocab.Token_Array (1 .. 32);
         Last   : Natural;

         --  What a template that writes bos_token renders to: the token's
         --  own text in front of the conversation.
         Rendered : constant String := "<s>" & "abc";
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");
         Vocab.Load (Words, Parsed, Status => Status);
         Assert (E.Is_Ok (Status), "the vocabulary did not load");

         --  The templated path: the request does not ask, the text carries
         --  it. One beginning token, and it is the first.
         Vocab.Encode
           (Words, Rendered, False, False, Tokens, Last, Status);
         Assert (E.Is_Ok (Status), "a rendered prompt was refused");
         Assert (Tokens (1) = Vocab.Beginning_Token (Words),
                 "a rendered prompt did not begin with the beginning token");
         Assert (Beginnings (Words, Tokens (1 .. Last)) = 1,
                 "a rendered prompt carried"
                 & Natural'Image (Beginnings (Words, Tokens (1 .. Last)))
                 & " beginning tokens where one was due");

         --  The raw path: no template, so the request asks. One again.
         Vocab.Encode (Words, "abc", True, False, Tokens, Last, Status);
         Assert (E.Is_Ok (Status), "a raw prompt was refused");
         Assert (Tokens (1) = Vocab.Beginning_Token (Words),
                 "a raw prompt did not begin with the beginning token");
         Assert (Beginnings (Words, Tokens (1 .. Last)) = 1,
                 "a raw prompt carried more than one beginning token");

         --  Both at once is what the rule exists to prevent, and it is worth
         --  saying that the two would in fact collide rather than trusting
         --  that they would.
         Vocab.Encode (Words, Rendered, True, False, Tokens, Last, Status);
         Assert (E.Is_Ok (Status), "asking twice was refused");
         Assert (Beginnings (Words, Tokens (1 .. Last)) = 2,
                 "asking for the beginning token over a prompt that already"
                 & " spells it did not produce two, so the rule that keeps"
                 & " them apart is guarding nothing");

         Vocab.Close (Words);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end One_Beginning_Token_However_It_Arrives;

   --  Reusing a committed prefix must not change the answer.
   --
   --  An interactive turn re-renders the whole conversation and hands it over
   --  again. Evaluating all of it every turn would be quadratic in the
   --  conversation, so a request may ask for the committed context to be kept
   --  when the tokens already evaluated are an exact prefix of the sequence
   --  about to be evaluated, and only the new suffix is evaluated. Anything
   --  else resets the session.
   --
   --  Nothing tested it. Three occurrences in the tree, all in src. A wrong
   --  answer in the reusing direction does not crash: it feeds the model a
   --  context that does not match the text that was rendered, so the turn
   --  answers a different conversation and says nothing about it.
   --
   --  Two properties, and both are needed. The cheap one is that reuse
   --  happened at all -- prefill starting past the committed tokens, which
   --  the progress events say outright. The one that matters is that it
   --  changed nothing: the same turn on a session that reused and on a
   --  session that did not must produce the same tokens.
   procedure Reused_Prefix_Changes_Nothing
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Gen renames Model_Runner.Generation;

      use type Model_Runner.Progress.Event_Kind;
      use type Model_Runner.Progress.Generation_Stage;
      use type Gen.Completion_Reason;
      use type B.Byte_Array;

      --  Where prefill began, which is the only outside sign that a prefix
      --  was kept. The first Prefill_Progress event reports how many prompt
      --  tokens have been evaluated, counting the ones that were skipped.
      type Watcher is limited new Model_Runner.Progress.Observer with record
         First_Report : Natural := 0;
         Seen         : Boolean := False;
      end record;

      overriding procedure Notify
        (Self : in out Watcher; Item : Model_Runner.Progress.Event);

      overriding procedure Notify
        (Self : in out Watcher; Item : Model_Runner.Progress.Event) is
      begin
         if Item.Kind = Model_Runner.Progress.Generation_Event
           and then Item.Generation = Model_Runner.Progress.Prefill_Progress
           and then not Self.Seen
         then
            Self.First_Report := Natural (Item.Completed);
            Self.Seen := True;
         end if;
      end Notify;

      --  A prompt whose tokens extend by exactly one: "abb" is "ab" and one
      --  more piece, where "abc" would not be -- the merge that takes b and c
      --  together changes the token before it.
      Prompt : constant String := "abb";

      Image  : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);

         Status : E.Error_Info;
         Tokens : Vocab.Token_Array (1 .. 32);
         Last   : Natural;

         --  Run the turn on a session, having first committed the tokens
         --  given, and report what came back.
         procedure Turn
           (Prime   : Vocab.Token_Array;
            Reuse   : Boolean;
            Started : out Natural;
            Text    : out Model_Runner.Bytes.Byte_Array_Access;
            Length  : out Natural)
         is
            Live    : L.Session;
            Logits  : Logit_Vector;
            Request : Gen.Request;
            Stop    : Model_Runner.Stops.Set;
            Watch   : aliased Watcher;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
         begin
            L.Open (Live, Under.Ready, Status => Local);
            Assert (E.Is_Ok (Local), "the session did not open");

            for Token of Prime loop
               L.Evaluate (Live, Under.Ready, Token, Logits, Status => Local);
               Assert (E.Is_Ok (Local), "priming the session failed");
            end loop;

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 3;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 7;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;
            Request.Retain_Text := True;
            Request.Reuse_Committed_Prefix := Reuse;

            --  One token a pass, so that the progress events count up rather
            --  than arriving as a single report for the whole prompt. With
            --  the default batch the first event already says the prompt is
            --  done and says nothing about where it started -- which is how
            --  the first version of this test read a reset session as a
            --  reused one.
            Request.Batch_Size := 1;

            Gen.Generate
              (Under.Ready, Live, Prompt, Request, Stop, null,
               Watch'Unchecked_Access, null, null, null, Outcome => Outcome);

            Assert (Outcome.Reason /= Gen.Runtime_Error,
                    "the turn failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Started := Watch.First_Report;
            Text := Outcome.Text;
            Length := Outcome.Text_Length;

            Model_Runner.Stops.Close (Stop);
            L.Close (Live);
         end Turn;
      begin
         Start (Under);

         declare
            Words : constant access constant Vocab.Vocabulary :=
              L.Vocabulary (Under.Ready);
         begin
            Vocab.Encode
              (Words.all, Prompt, True, False, Tokens, Last, Status);
            Assert (E.Is_Ok (Status), "the prompt did not encode");
            Assert (Last >= 3,
                    "the prompt makes too few tokens to leave a prefix");
         end;

         declare
            --  Everything but the last token: an exact prefix.
            Exact : constant Vocab.Token_Array := Tokens (1 .. Last - 1);

            --  The same length, differing in the last token, which is not.
            Wrong : Vocab.Token_Array := Tokens (1 .. Last - 1);

            Fresh_At, Reused_At, Reset_At : Natural;
            Fresh_Text, Reused_Text, Reset_Text : B.Byte_Array_Access;
            Fresh_N, Reused_N, Reset_N : Natural;
         begin
            Wrong (Wrong'Last) :=
              (if Tokens (Last - 1) = 4 then 5 else 4);

            --  No prefix to keep, so prefill starts at the beginning. This
            --  is the answer the other two have to match.
            Turn ([], False, Fresh_At, Fresh_Text, Fresh_N);

            --  An exact prefix, kept. Prefill reports past it.
            Turn (Exact, True, Reused_At, Reused_Text, Reused_N);

            --  The same number of tokens, one of them different, so the
            --  session is reset and everything is evaluated again.
            Turn (Wrong, True, Reset_At, Reset_Text, Reset_N);

            Assert (Reused_At > Exact'Length,
                    "prefill began at" & Natural'Image (Reused_At)
                    & " over a committed prefix of"
                    & Natural'Image (Exact'Length)
                    & ", so nothing was reused and the rest of this test "
                    & "would pass on a build where the option does nothing");

            Assert (Reset_At <= Exact'Length,
                    "prefill began at" & Natural'Image (Reset_At)
                    & " over a committed sequence that is not a prefix, so a "
                    & "context describing a different conversation was kept");

            Assert (Reused_N = Fresh_N
                    and then Reused_Text.all
                               (1 .. B.Byte_Index (Reused_N))
                             = Fresh_Text.all (1 .. B.Byte_Index (Fresh_N)),
                    "reusing a committed prefix changed the answer");

            Assert (Reset_N = Fresh_N
                    and then Reset_Text.all (1 .. B.Byte_Index (Reset_N))
                             = Fresh_Text.all (1 .. B.Byte_Index (Fresh_N)),
                    "resetting after a mismatched prefix changed the answer");

            B.Free (Fresh_Text);
            B.Free (Reused_Text);
            B.Free (Reset_Text);
         end;
      end;

      B.Free (Image);
   end Reused_Prefix_Changes_Nothing;

   procedure Refused_Generation_Names_Its_Reason
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      use type External_Model.Outcome;

      Model : constant String := Tiny_Model.Suite_Fixture;
      Found : External_Model.Report;
      Fits  : External_Model.Report;
   begin
      --  Written rather than assumed: the fixture is not committed, so a
      --  clean checkout has none until something makes one.
      Tiny_Model.Write_Suite_Fixture;

      --  More tokens than the context can hold, which the engine refuses
      --  before it generates anything.
      External_Model.Run
        (Path    => Model,
         Prompt  => "ab",
         Tokens  => 16,
         Threads => 2,
         Result  => Found);

      if Found.Result = External_Model.Skipped then
         --  Run from somewhere the fixture is not; nothing to hold.
         return;
      end if;

      Assert (Found.Result = External_Model.Failed,
              "a request larger than the context was not refused");
      declare
         Said  : constant String := External_Model.Detail_Text (Found);
         Named : Boolean := False;
      begin
         for Index in Said'Range loop
            if Index + 6 <= Said'Last
              and then Said (Index .. Index + 6) = "MR-GEN-"
            then
               Named := True;
            end if;
         end loop;
         Assert (Named,
                 "the refusal does not name a diagnostic code: """
                 & Said & """");
      end;

      --  And a request that fits still runs, so the check above is not
      --  passing because this model cannot generate at all.
      External_Model.Run
        (Path    => Model,
         Prompt  => "ab",
         Tokens  => 8,
         Threads => 2,
         Result  => Fits);

      Assert (Fits.Result = External_Model.Ran,
              "a request that fits the context did not run: "
              & External_Model.Detail_Text (Fits));
   end Refused_Generation_Names_Its_Reason;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Tokenizer_Matches_An_Independent_One'Access,
         "the tokenizer agrees with one written from the description");
      Register_Routine
        (T, Byte_Pair_Matches_An_Independent_One'Access,
         "the byte-pair tokenizer agrees with one written from the "
         & "description");
      Register_Routine
        (T, Byte_Pair_Model_Runs_End_To_End'Access,
         "a byte-pair model prepares, evaluates and reads back");
      Register_Routine
        (T, One_Beginning_Token_However_It_Arrives'Access,
         "a prompt carries exactly one beginning token, however it arrives");
      Register_Routine
        (T, Reused_Prefix_Changes_Nothing'Access,
         "reusing a committed prefix changes nothing about the answer");
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
        (T, Standing_Cancellation_Stops_Each_Stage'Access,
         "a standing request stops the parser and the batched pass");
      Register_Routine
        (T, Cancellation_Stops_A_Load'Access,
         "cancellation is honoured while a model is loading");
      Register_Routine
        (T, Cancellation_Does_Not_Commit'Access,
         "a cancelled token leaves the committed context unchanged");
      Register_Routine
        (T, Batch_Respects_The_Context_Bound'Access,
         "a batch is refused at the same boundary a single token is");
      Register_Routine
        (T, Reset_Leaves_No_Trace_Of_The_Previous_Turn'Access,
         "a reset session answers exactly as a fresh one does");
      Register_Routine
        (T, Weights_Are_Not_Repacked'Access,
         "weights are used where the file put them, not repacked");
      Register_Routine
        (T, Evaluation_Refuses_Arguments_It_Cannot_Serve'Access,
         "evaluation refuses arguments it cannot serve");
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

      Register_Routine
        (T, Refused_Generation_Names_Its_Reason'Access,
         "a generation the engine refuses is reported with the code it "
         & "refused with, not as a bare failure");
   end Register_Tests;

end Tests.Inference_Cases;
