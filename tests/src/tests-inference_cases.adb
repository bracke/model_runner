with Ada.Text_IO;

with AUnit.Assertions;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Files;

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
with Model_Runner.Backend;
with Model_Runner.Backend.Device;
with Model_Runner.Llama;
with Model_Runner.Tensors;
with Model_Runner.Localization;
with Model_Runner.Memory;
with Model_Runner.Numerics;
with Model_Runner.Generation;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Tokenizer;

with Conformance;
with BPE_Vocabulary;
with Unigram_Vocabulary;
with Reference_Tokenizer;
with Reference_Transformer;
with Tiny_Model;

package body Tests.Inference_Cases is

   use type Model_Runner.Cancellation.Token_Reference;

   use AUnit.Assertions;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Real;
   use type Model_Runner.Numerics.Wide_Real;
   use type Model_Runner.Tokenizer.Token_Id;
   use type Model_Runner.Tokenizer.Model_Kind;

   package B renames Model_Runner.Bytes;
   use type B.Byte_Count;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package Containers renames Model_Runner.GGUF.Containers;
   package Vocab renames Model_Runner.Tokenizer;
   use type Model_Runner.Tensors.Real_Array_Access;

   subtype Logit_Vector is
     N.Real_Array (0 .. N.Element_Count (Tiny_Model.Vocabulary) - 1);

   --  A prepared tiny model together with everything it borrows. Declared as
   --  one object so that a test cannot accidentally let the byte source go out
   --  of scope while the model still refers to it.
   type Harness (Image : access constant B.Byte_Array) is limited record
      Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
      Parsed : Containers.Container;
      --  Aliased so that a test can hand this model to something that takes
      --  a reference -- a draft model, say. A component is not aliased by
      --  being in a record.
      Ready  : aliased L.Model;
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

   --------------------------------------------
   -- A_Position_Sees_What_Follows_It --
   --------------------------------------------

   --  The claim a bidirectional model rests on, and the one no comparison
   --  of its own output against itself can make: what the model makes of
   --  the first position depends on a token that comes after it.
   --
   --  A session says where a batch's time went, and only when asked.
   --
   --  Two assertions rather than one, because the switch is half the point:
   --  a run nobody asked a budget of reads no clocks, and the way to see
   --  that from outside is that it reports nothing rather than reporting
   --  something small. The other half is that the phases add up to
   --  something -- not to any particular figure, which would be a
   --  measurement pretending to be a test, but to more than nothing on a
   --  batch that certainly did some work.
   procedure A_Budget_Accounts_For_A_Batch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Image  : B.Byte_Array_Access;
      Total  : Duration := 0.0;
   begin
      Tiny_Model.Build (Image);

      declare
         Under  : Harness (Image);
         Live   : L.Session;
         Status : E.Error_Info;
         Tokens : constant Vocab.Token_Array := [0, 1, 2, 3];
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open");

         declare
            Settings : constant L.Configuration := L.Config (Under.Ready);
            Logits   : N.Real_Array
              (0 .. N.Element_Count (Settings.Vocabulary) - 1);
         begin

         --  Not asked: every phase stays zero.
         L.Evaluate_Batch
           (Live, Under.Ready, Tokens, Logits, Status => Status);
         Assert (E.Is_Ok (Status), "the unaccounted batch failed");

         for Phase in L.Phase loop
            Assert (L.Time_Spent (Live) (Phase) = 0.0,
                    "a session nobody asked reported time in "
                    & L.Phase'Image (Phase));
         end loop;

         --  Asked: the phases hold something.
         L.Account (Live, True);
         L.Evaluate_Batch
           (Live, Under.Ready, Tokens, Logits, Status => Status);
         Assert (E.Is_Ok (Status), "the accounted batch failed");

         for Phase in L.Phase loop
            Total := Total + L.Time_Spent (Live) (Phase);
         end loop;

         Assert (Total > 0.0, "a budget was asked for and came back empty");

         --  And turning it off clears what was there, so the next run is
         --  measured rather than added to.
         L.Account (Live, False);
         for Phase in L.Phase loop
            Assert (L.Time_Spent (Live) (Phase) = 0.0,
                    "turning a budget off left "
                    & L.Phase'Image (Phase) & " behind");
         end loop;
         end;

         L.Close (Live);
      end;

      B.Free (Image);
   end A_Budget_Accounts_For_A_Batch;

   --  A causal model cannot do this and must not: change the last token of
   --  a prompt and the first position's state is what it was. So the test
   --  is the same text twice with one later token different, and the
   --  assertion is that the first position moved -- which fails against an
   --  engine that attends causally while reporting itself bidirectional,
   --  and fails in the other direction against one that lets a causal
   --  model see ahead.
   procedure A_Position_Sees_What_Follows_It
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Every position's state for one text, first position first.
      procedure States_Of
        (Image  : access constant B.Byte_Array;
         Tokens : Vocab.Token_Array;
         Room   : Model_Runner.Tensors.Real_Array_Access)
      is
         Under  : Harness (Image);
         Live   : L.Session;
         Status : E.Error_Info;
         None   : N.Real_Array (1 .. 0);
      begin
         Start (Under);

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "bert session did not open");

         L.Evaluate_Batch
           (Live, Under.Ready, Tokens, None, States => Room,
            Status => Status);
         Assert (E.Is_Ok (Status),
                 "bert batch failed: " & E.Error_Code'Image (Status.Code));

         L.Close (Live);
      end States_Of;

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Bert);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;

         --  Two texts that agree everywhere but the last position.
         One   : constant Vocab.Token_Array := [4, 5, 6];
         Other : constant Vocab.Token_Array := [4, 5, 7];

         --  The width, from the fixture's own declaration rather than
         --  from a model that has to be prepared to be asked.
         Width : constant N.Element_Count :=
           N.Element_Count (Tiny_Model.Embedding);

         First_Room  : Model_Runner.Tensors.Real_Array_Access := null;
         Second_Room : Model_Runner.Tensors.Real_Array_Access := null;

         Moved : N.Real := 0.0;
      begin
         Model_Runner.Tensors.Allocate (3 * Width, First_Room);
         Model_Runner.Tensors.Allocate (3 * Width, Second_Room);
         Assert (First_Room /= null and then Second_Room /= null,
                 "no room for the states");

         States_Of (Held'Access, One, First_Room);
         States_Of (Held'Access, Other, Second_Room);

         --  The first position, which is the one the changed token comes
         --  after. Its state has to have moved.
         for Index in 0 .. Width - 1 loop
            Moved := N.Real'Max
              (Moved, abs (First_Room.all (Index) - Second_Room.all (Index)));
         end loop;

         Assert (Moved > 1.0E-6,
                 "the first position did not move when a later token "
                 & "changed, so attention is not reading ahead");

         --  And the second position moved too, for the same reason: it also
         --  precedes the token that changed.
         Moved := 0.0;
         for Index in Width .. 2 * Width - 1 loop
            Moved := N.Real'Max
              (Moved, abs (First_Room.all (Index) - Second_Room.all (Index)));
         end loop;
         Assert (Moved > 1.0E-6,
                 "the second position did not move when a later token "
                 & "changed");

         Model_Runner.Tensors.Free (First_Room);
         Model_Runner.Tensors.Free (Second_Room);
      end;

      B.Free (Image);
   end A_Position_Sees_What_Follows_It;

   ------------------------------------------------
   -- A_Headless_Model_Refuses_What_It_Cannot_Say --
   ------------------------------------------------

   --  Two refusals, both of which would otherwise be answers.
   --
   --  A model with no projection asked for a distribution could be given a
   --  row of zeros, and a bidirectional model handed half a text could be
   --  given the embedding of that half. Neither would report anything
   --  wrong, and neither is the model's answer.
   procedure A_Headless_Model_Refuses_What_It_Cannot_Say
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Bert);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;

         Settings : L.Configuration;
      begin
         Start (Under);
         Settings := L.Config (Under.Ready);

         Assert (not Settings.Has_Head,
                 "the bert fixture was read as having an output projection");
         Assert (not Settings.Causal,
                 "the bert fixture was read as attending one way");

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "bert session did not open");

         --  A distribution, from a model that has none to give.
         declare
            Logits : N.Real_Array
              (0 .. N.Element_Count (Settings.Vocabulary) - 1);
         begin
            L.Evaluate_Batch
              (Live, Under.Ready, [4, 5], Logits, Status => Status);
            Assert (E.Is_Error (Status)
                    and then Status.Code = E.Arch_No_Output_Head,
                    "a distribution was not refused by name: "
                    & E.Error_Code'Image (Status.Code));
         end;

         --  And a single token, which exists to find out what comes next.
         declare
            Logits : N.Real_Array
              (0 .. N.Element_Count (Settings.Vocabulary) - 1);
         begin
            L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
            Assert (E.Is_Error (Status)
                    and then Status.Code = E.Arch_No_Output_Head,
                    "a single token was not refused by name: "
                    & E.Error_Code'Image (Status.Code));
         end;

         --  Half a text, which the engine has to refuse rather than embed:
         --  the first half would have been computed without the second.
         declare
            None : N.Real_Array (1 .. 0);
            Room : Model_Runner.Tensors.Real_Array_Access := null;
            Width : constant N.Element_Count :=
              N.Element_Count (Settings.Embedding);
         begin
            Model_Runner.Tensors.Allocate (2 * Width, Room);
            Assert (Room /= null, "no room for the states");

            L.Evaluate_Batch
              (Live, Under.Ready, [4, 5], None, States => Room,
               Status => Status);
            Assert (E.Is_Ok (Status),
                    "the first half was refused: "
                    & E.Error_Code'Image (Status.Code));

            L.Evaluate_Batch
              (Live, Under.Ready, [6, 7], None, States => Room,
               Status => Status);
            Assert (E.Is_Error (Status)
                    and then Status.Code = E.Arch_Text_Not_Whole,
                    "a second batch into a written cache was not refused: "
                    & E.Error_Code'Image (Status.Code));

            Model_Runner.Tensors.Free (Room);
         end;

         L.Close (Live);
      end;

      B.Free (Image);
   end A_Headless_Model_Refuses_What_It_Cannot_Say;

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
            Logits, Cancel => Flag'Unchecked_Access, Status => Status);
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

   ------------------------------------------------
   -- A_Refused_Evaluation_Is_Not_A_Clean_Sweep --
   ------------------------------------------------

   --  A conformance run that could not evaluate something is not clean.
   --
   --  It used to be. A comparison whose evaluation ended in a diagnostic was
   --  not counted, compared nothing, and said nothing; the only trace was
   --  that the sweep's total came up short against what it expected to run.
   --  Three hundred of them -- every single-token comparison of a new
   --  architecture, failing on a buffer a head wide where an embedding was
   --  wanted -- left exactly that trace and cost an afternoon to find.
   --
   --  What is tested is the verdict rather than a sweep that fails, because
   --  arranging a failing evaluation inside the sweep means breaking the
   --  engine on purpose, and a test that does that is a test that passes
   --  when the engine is broken. The verdict is where the decision lives:
   --  refused evaluations are as disqualifying as logits outside tolerance,
   --  and a report that says otherwise is the fault this exists to catch.
   procedure A_Refused_Evaluation_Is_Not_A_Clean_Sweep
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Said : Conformance.Report;
   begin
      --  A run that did everything it meant to.
      Said.Ran := True;
      Said.Compared := 100;
      Assert (Conformance.Is_Clean (Said),
              "a run that compared everything and agreed was called unclean");

      --  One evaluation that never produced logits, and nothing outside
      --  tolerance because nothing was compared -- which is exactly how this
      --  reads when it goes wrong.
      Said.Refused := 1;
      Assert (not Conformance.Is_Clean (Said),
              "a run that could not evaluate something was called clean, "
              & "which is what let three hundred refusals hide behind a "
              & "count nobody read");

      Said.Refused := 0;
      Assert (Conformance.Is_Clean (Said),
              "the verdict did not come back once the refusal was gone, so "
              & "it is not the refusal it is answering");
   end A_Refused_Evaluation_Is_Not_A_Clean_Sweep;

   --  The engine agrees with an independent implementation of the same
   --  architecture, computed in a different arithmetic -- the strongest
   --  correctness evidence available without an external model, since a
   --  shared mistake would have to have been made twice, differently.
   --
   --  It is not run from here. This called Conformance.Run, which is the
   --  same sweep the gate runs as a stage of its own and `tests conformance`
   --  runs alone, so the gate did it twice: 948 s inside the suite and 650 s
   --  again beside it. Sixteen of the suite's twenty-eight minutes were this
   --  one routine, and nothing said so while the suite was the one stage the
   --  gate did not time.
   --
   --  What is lost is that `tests test` on its own no longer compares
   --  against the reference. That is the right place to lose it: the suite
   --  is what runs in a second and a half of somebody's attention, and a
   --  sixteen-minute comparison belongs in the gate that already has one.

   ----------------------------------------
   -- Device_Reads_A_Model_In_Any_Format --
   ----------------------------------------

   --  A model in any format the program reads loads on the device.
   --
   --  This test used to say the opposite, and the opposite was true: the
   --  shader decoded three of the fifteen formats, so a Q4_1 model on
   --  --backend device was refused while it loaded, naming the tensor and
   --  the format, and reaching a device at all meant --repack f32 -- a pass
   --  over the whole model and four bytes a weight afterwards, which for a
   --  four-bit model is eight times what it was quantized to. The shader now
   --  has a branch per format, so the refusal is gone and what is checked
   --  here is that it is gone: the same fixture that was refused loads.
   --
   --  The loader's refusal is still written, and still right -- a format
   --  added to the program and not to the shader must stop here rather than
   --  in the middle of a token. Nothing can reach it from outside any more,
   --  because a view can only hold a format the program decodes and the
   --  device now decodes all of those. What holds the two lists together is
   --  the test that compares Describe against Is_Supported, and beneath it
   --  the one that multiplies a matrix in every format on both backends.
   procedure Device_Reads_A_Model_In_Any_Format
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      Words : Model_Runner.Localization.Catalog;

   begin
      Model_Runner.Localization.Open
        (Words, Model_Runner.Platform.Catalog_Path, "en");
      Assert (Model_Runner.Localization.Is_Ready (Words),
              "the catalog would not open");

      Tiny_Model.Build (Image, Tiny_Model.Q4_1);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Item   : Containers.Container;
         Model  : L.Model;
         Status : E.Error_Info;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse
           (Item, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         --  The processor reads it.
         L.Prepare (Model, Item, Source, Status => Status);
         Assert (E.Is_Ok (Status),
                 "a q4_1 model was refused by the processor, which decodes "
                 & "it");
         L.Close (Model, Status);

         --  And so does the device, without being asked to repack anything.
         --  A machine with no device refuses for want of one, which is a
         --  different code and is not what this is about.
         L.Prepare
           (Model, Item, Source,
            Backend => Model_Runner.Backend.Backend_Device,
            Status  => Status);

         if Status.Code = E.Backend_No_Device then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device read a q4_1 model here");
         else
            Assert (E.Is_Ok (Status),
                    "a q4_1 model was refused by the device backend, which "
                    & "now decodes it: " & E.Error_Code'Image (Status.Code));
         end if;

         --  And the two lists that have to agree do. Said here as well as in
         --  the backend's own test because this is the level a user meets it
         --  at: a format the loader lets through and the shader has no
         --  branch for is a model that runs and answers wrongly.
         declare
            Said : constant Model_Runner.Backend.Capabilities :=
              Model_Runner.Backend.Device.Describe;
         begin
            for Format in Model_Runner.GGUF.Tensor_Type loop
               Assert (Model_Runner.Backend.Supports (Said, Format)
                       = Model_Runner.GGUF.Is_Supported (Format),
                       "the device backend and the program disagree about "
                       & Model_Runner.GGUF.Type_Name (Format));
            end loop;
         end;

         --  A model that closes takes the device's memory of it with it.
         --
         --  The device remembers a matrix by where its bytes lie, what shape
         --  they are and what format they are in, and that names a matrix
         --  only while it exists. Once this model's storage is freed another
         --  model's tensor can land on the same address with the same shape,
         --  and the device would answer for the second with the first one's
         --  weights.
         --
         --  That is not a hypothetical, which is how it was found: the
         --  conformance sweep opens and closes a model per format and
         --  architecture with the device open across all of them, and about
         --  half its runs came out wrong -- by a fifth of a logit, which is
         --  a wrong answer rather than a rounding difference, and it moved
         --  from run to run because it depended on what the allocator handed
         --  back.
         --
         --  What is checked here is the invariant rather than the symptom,
         --  because the symptom needs an allocator to reuse an address and a
         --  test cannot insist on that. The sweep is what would catch a
         --  behaviour regression; this catches the mechanism going away.
         if Model_Runner.Backend.Device.Is_Ready then
            Assert (Model_Runner.Backend.Device.Resident > 0,
                    "the device held nothing before the model closed, so "
                    & "what follows would pass whatever the close did");
            L.Close (Model, Status);
            Assert (Model_Runner.Backend.Device.Resident = 0,
                    "the device still held"
                    & Natural'Image (Model_Runner.Backend.Device.Resident)
                    & " matrices of a model that has closed, so the next "
                    & "model to take those addresses would be answered with "
                    & "this one's weights");

            --  And saying it again to a device holding nothing is harmless,
            --  which the spec promises and the model path relies on: a model
            --  that never touched a device says it too, because a model
            --  cannot know whether the device holds its addresses.
            Model_Runner.Backend.Device.Forget_Matrices;
            Assert (Model_Runner.Backend.Device.Resident = 0,
                    "forgetting an empty device left something behind");
         end if;

         L.Close (Model, Status);
         Containers.Close (Item);
      end;

      Model_Runner.Localization.Close (Words);
      B.Free (Image);
   end Device_Reads_A_Model_In_Any_Format;

   ---------------------------------------------
   -- Device_Says_When_A_Model_Will_Not_Fit --
   ---------------------------------------------

   --  A model whose matrices are larger than the device will hold is refused
   --  while it loads, with both numbers in the message.
   --
   --  It could be run instead -- what does not fit is given back and
   --  uploaded again as it is wanted, which is correct -- but it would run
   --  slower than the processor and say nothing about why. So the refusal is
   --  the diagnostic, and it names what was needed and what there was.
   --
   --  The device is opened with a budget rather than the model being made
   --  enormous, because the case worth testing is the one this machine
   --  cannot produce: a heap smaller than a model.
   procedure Device_Says_When_A_Model_Will_Not_Fit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
      Ready : Boolean;

      Words : Model_Runner.Localization.Catalog;
   begin
      Model_Runner.Backend.Device.Close;
      Model_Runner.Backend.Device.Open (Ready, Budget => 1024);

      if not Ready then
         return;
      end if;

      Model_Runner.Localization.Open
        (Words, Model_Runner.Platform.Catalog_Path, "en");
      Assert (Model_Runner.Localization.Is_Ready (Words),
              "the catalog would not open");

      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Item   : Containers.Container;
         Model  : L.Model;
         Status : E.Error_Info;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse
           (Item, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare
           (Model, Item, Source,
            Backend => Model_Runner.Backend.Backend_Device,
            Status  => Status);
         Assert (Status.Code = E.Memory_Limit_Exceeded,
                 "a model larger than the device would hold was not refused: "
                 & E.Error_Code'Image (Status.Code));

         declare
            Shown : constant String :=
              Model_Runner.Localization.Describe (Words, Status);
         begin
            Assert (Shown'Length > 0 and then Shown (Shown'First) /= '<',
                    "the refusal did not render: " & Shown);
         end;

         L.Close (Model, Status);
         Containers.Close (Item);
      end;

      Model_Runner.Localization.Close (Words);
      B.Free (Image);
      Model_Runner.Backend.Device.Close;
   end Device_Says_When_A_Model_Will_Not_Fit;

   -------------------------------------------
   -- Sessions_On_One_Model_Do_Not_Collide --
   -------------------------------------------

   --  The same two sessions in one pass, which is what a round is: every
   --  member gets, bit for bit, the logits it would have got alone.
   --
   --  This is the gate the round exists behind. That the products do not
   --  care how many rows they are given is already measured -- one digest at
   --  nine batch sizes on two backends -- so what is left to hold is the new
   --  part: that no row reads another member's cache and each writes only
   --  its own. Two sequences that differ, stepped together, and compared
   --  step by step against themselves run alone.
   procedure Round_Members_Get_What_They_Would_Alone
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      Steps : constant := 4;

      First_Prompt  : constant array (1 .. Steps) of Vocab.Token_Id :=
        [4, 5, 6, 7];
      Second_Prompt : constant array (1 .. Steps) of Vocab.Token_Id :=
        [9, 8, 7, 6];

      type Trail is array (1 .. Steps) of Logit_Vector;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);

         Alone_First, Alone_Second : Trail :=
           [others => [others => 0.0]];

         Row    : Logit_Vector := [others => 0.0];
         Status : E.Error_Info;
      begin
         Start (Under);

         --  Each on its own, keeping what it said at every step rather than
         --  only at the last: a round is compared step for step.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the first session did not open");

            for Step in First_Prompt'Range loop
               L.Evaluate (Live, Under.Ready, First_Prompt (Step),
                           Alone_First (Step), Status => Status);
               Assert (E.Is_Ok (Status), "the first sequence failed");
            end loop;

            L.Close (Live);
         end;

         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the second session did not open");

            for Step in Second_Prompt'Range loop
               L.Evaluate (Live, Under.Ready, Second_Prompt (Step),
                           Alone_Second (Step), Status => Status);
               Assert (E.Is_Ok (Status), "the second sequence failed");
            end loop;

            L.Close (Live);
         end;

         --  The two differ, or the comparison below would hold however
         --  badly the rows collided.
         declare
            Same : Boolean := True;
         begin
            for Index in Logit_Vector'Range loop
               if Alone_First (Steps) (Index)
                 /= Alone_Second (Steps) (Index)
               then
                  Same := False;
                  exit;
               end if;
            end loop;

            Assert (not Same,
                    "the two sequences produce the same logits, so this "
                    & "fixture cannot tell a collision from a coincidence");
         end;

         --  And now as a round: one token from each, in one pass.
         declare
            One, Two : aliased L.Session;

            Both : Model_Runner.Tensors.Real_Array_Access := null;
         begin
            L.Open (One, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the first of a round did not open");

            L.Open (Two, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the second of a round did not open");

            Model_Runner.Tensors.Allocate
              (2 * N.Element_Count (Tiny_Model.Vocabulary), Both);
            Assert (Both /= null, "the round had no room for its logits");

            for Step in First_Prompt'Range loop
               L.Evaluate_Round
                 (Members => [One'Unchecked_Access, Two'Unchecked_Access],
                  Source  => Under.Ready,
                  Tokens  =>
                    [First_Prompt (Step), Second_Prompt (Step)],
                  Logits  => Both,
                  Status  => Status);

               Assert (E.Is_Ok (Status),
                       "a round of two failed at step"
                       & Integer'Image (Step) & ": "
                       & E.Error_Code'Image (Status.Code));

               for Index in Logit_Vector'Range loop
                  Row (Index) := Both.all (Both.all'First + Index);
               end loop;

               for Index in Logit_Vector'Range loop
                  Assert (Row (Index) = Alone_First (Step) (Index),
                          "the first member of a round differed from the "
                          & "same sequence run alone, at step"
                          & Integer'Image (Step) & " element"
                          & N.Element_Count'Image (Index));
               end loop;

               for Index in Logit_Vector'Range loop
                  Row (Index) :=
                    Both.all (Both.all'First
                              + N.Element_Count (Tiny_Model.Vocabulary)
                              + Index);
               end loop;

               for Index in Logit_Vector'Range loop
                  Assert (Row (Index) = Alone_Second (Step) (Index),
                          "the second member of a round differed from the "
                          & "same sequence run alone, at step"
                          & Integer'Image (Step) & " element"
                          & N.Element_Count'Image (Index));
               end loop;
            end loop;

            Assert (L.Position (One) = Steps and then L.Position (Two) = Steps,
                    "the members of a round did not each advance by one "
                    & "position a step");

            --  And what a round refuses. A token a member is the shape it
            --  takes, and a member that is not open cannot be in one: both
            --  are refused by name, because a round that ran anyway would
            --  give somebody another sequence's attention.
            L.Evaluate_Round
              (Members => [One'Unchecked_Access, Two'Unchecked_Access],
               Source  => Under.Ready,
               Tokens  => [1 => First_Prompt (1)],
               Logits  => Both,
               Status  => Status);

            Assert (Status.Code = E.Generation_Batch_Too_Large,
                    "a round with fewer tokens than members was not "
                    & "refused as a shape: "
                    & E.Error_Code'Image (Status.Code));

            L.Close (Two);

            L.Evaluate_Round
              (Members => [One'Unchecked_Access, Two'Unchecked_Access],
               Source  => Under.Ready,
               Tokens  => [First_Prompt (1), Second_Prompt (1)],
               Logits  => Both,
               Status  => Status);

            Assert (Status.Code = E.Lifecycle_Session_Closed,
                    "a round holding a closed member was not refused: "
                    & E.Error_Code'Image (Status.Code));

            Model_Runner.Tensors.Free (Both);
            L.Close (One);
            L.Close (Two);
         end;

         L.Close (Under.Ready, Status);
         Assert (E.Is_Ok (Status),
                 "the model would not close after a round: "
                 & E.Error_Code'Image (Status.Code));
      end;

      B.Free (Image);
   end Round_Members_Get_What_They_Would_Alone;

   --  Two sessions on one prepared model, evaluated a token at a time in
   --  turn, each get what they would have got alone.
   --
   --  What this holds is that a model carries no state belonging to an
   --  evaluation. It was one session per model until now, so nothing had
   --  ever asked: the activations, the normalized copies and the query and
   --  key rows all live in the session, and if any of them had drifted into
   --  the model the two sequences would read each other's arithmetic and
   --  neither would be wrong in a way anybody would notice.
   --
   --  Interleaved rather than run one after the other, because sequential
   --  sessions would pass on a model that did hold such state.
   procedure Sessions_On_One_Model_Do_Not_Collide
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      First_Prompt  : constant array (1 .. 4) of Vocab.Token_Id :=
        [4, 5, 6, 7];
      Second_Prompt : constant array (1 .. 4) of Vocab.Token_Id :=
        [9, 8, 7, 6];
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);

         Alone_First  : Logit_Vector := [others => 0.0];
         Alone_Second : Logit_Vector := [others => 0.0];
         Together     : Logit_Vector := [others => 0.0];

         Status : E.Error_Info;
      begin
         Start (Under);

         --  Each on its own first, which is what the interleaved pair has
         --  to reproduce.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the first session did not open");
            for Token of First_Prompt loop
               L.Evaluate (Live, Under.Ready, Token, Alone_First,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the first sequence failed");
            end loop;
            L.Close (Live);
         end;

         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the second session did not open");
            for Token of Second_Prompt loop
               L.Evaluate (Live, Under.Ready, Token, Alone_Second,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the second sequence failed");
            end loop;
            L.Close (Live);
         end;

         --  The two sequences differ, or the comparison below would hold
         --  however badly the sessions collided.
         declare
            Same : Boolean := True;
         begin
            for Index in Alone_First'Range loop
               if Alone_First (Index) /= Alone_Second (Index) then
                  Same := False;
                  exit;
               end if;
            end loop;
            Assert (not Same,
                    "the two sequences produce the same logits, so this "
                    & "fixture cannot tell a collision from a coincidence");
         end;

         --  And now together, a token each in turn.
         declare
            One, Two : L.Session;
         begin
            L.Open (One, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the first of two did not open");

            L.Open (Two, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a second session on one model was refused: "
                    & E.Error_Code'Image (Status.Code));

            for Step in First_Prompt'Range loop
               L.Evaluate (One, Under.Ready, First_Prompt (Step), Together,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the interleaved first failed");

               L.Evaluate (Two, Under.Ready, Second_Prompt (Step),
                           Alone_Second, Status => Status);
               Assert (E.Is_Ok (Status), "the interleaved second failed");
            end loop;

            for Index in Together'Range loop
               Assert (Together (Index) = Alone_First (Index),
                       "an interleaved session got different logits from "
                       & "the same sequence run alone, at"
                       & N.Element_Count'Image (Index));
            end loop;

            Assert (L.Position (One) = First_Prompt'Length
                      and then L.Position (Two) = Second_Prompt'Length,
                    "the two sessions did not each advance by their own "
                    & "tokens");

            L.Close (One);
            L.Close (Two);
         end;

         --  And the model closes once they have gone, which is what says
         --  the count went up twice and down twice.
         L.Close (Under.Ready, Status);
         Assert (E.Is_Ok (Status),
                 "the model would not close after two sessions: "
                 & E.Error_Code'Image (Status.Code));
      end;

      B.Free (Image);
   end Sessions_On_One_Model_Do_Not_Collide;

   -----------------------------------
   -- Rewind_Gives_Back_Positions --
   -----------------------------------

   --  A session put back to an earlier position evaluates from there, and
   --  gets what it would have got had it never gone further.
   --
   --  This is what checking a guess needs: a caller that evaluated several
   --  tokens on the strength of a proposal and found the proposal wrong has
   --  to put the context back to where it stopped being right. If anything
   --  past the position were still read, the run would attend to tokens
   --  nobody said -- and the text would be plausible, which is the failure
   --  worth testing for.
   procedure Rewind_Gives_Back_Positions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      Prefix : constant array (1 .. 3) of Vocab.Token_Id := [4, 5, 6];
      Wrong  : constant array (1 .. 2) of Vocab.Token_Id := [9, 9];
      After  : constant Vocab.Token_Id := 7;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         Straight, Rewound : Logit_Vector := [others => 0.0];
         Status : E.Error_Info;
      begin
         Start (Under);

         --  The prefix and then one more token, without going astray.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");
            for Token of Prefix loop
               L.Evaluate (Live, Under.Ready, Token, Straight,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the prefix failed");
            end loop;
            L.Evaluate (Live, Under.Ready, After, Straight, Status => Status);
            Assert (E.Is_Ok (Status), "the continuation failed");
            L.Close (Live);
         end;

         --  The prefix, two tokens that turn out to be wrong, back to the
         --  prefix, and then the same one more token.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");
            for Token of Prefix loop
               L.Evaluate (Live, Under.Ready, Token, Rewound,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the prefix failed");
            end loop;
            for Token of Wrong loop
               L.Evaluate (Live, Under.Ready, Token, Rewound,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the wrong turn failed");
            end loop;

            Assert (L.Position (Live) = Prefix'Length + Wrong'Length,
                    "the session is not where the tokens put it");

            L.Rewind (Live, Prefix'Length, Status);
            Assert (E.Is_Ok (Status),
                    "the rewind was refused: "
                    & E.Error_Code'Image (Status.Code));
            Assert (L.Position (Live) = Prefix'Length,
                    "the rewind did not move the position");

            L.Evaluate (Live, Under.Ready, After, Rewound, Status => Status);
            Assert (E.Is_Ok (Status), "the continuation failed");

            --  Forward is not rewinding.
            L.Rewind (Live, Prefix'Length + 10, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "a rewind past the end was accepted");

            L.Close (Live);
         end;

         for Index in Straight'Range loop
            Assert (Straight (Index) = Rewound (Index),
                    "a rewound session got different logits at"
                    & N.Element_Count'Image (Index));
         end loop;
      end;

      B.Free (Image);
   end Rewind_Gives_Back_Positions;

   ---------------------------------------
   -- Drafting_Produces_The_Same_Text --
   ---------------------------------------

   --  A run with a draft model produces exactly the text of the same run
   --  without one.
   --
   --  That is the whole guarantee, and it is why drafting is confined to
   --  temperature zero: there a proposal either is what the target would
   --  have chosen or it is not, so keeping the ones that match cannot change
   --  the answer. What it changes is how many passes over the target's
   --  weights it took to get there, which is a speed question and not a
   --  correctness one.
   --
   --  The model drafts for itself here. A model is a perfect draft of
   --  itself, so every proposal is accepted and the whole path is
   --  exercised -- the batch, the per-position logits, the acceptance test
   --  and the rewind on both sessions -- while the answer stays checkable
   --  against the run beside it. A draft that agreed with nothing would
   --  exercise the rewind and little else.
   procedure Drafting_Produces_The_Same_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      Image : B.Byte_Array_Access;

      Prompt : constant String := "ab";
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         --  Two runs, told apart by whether the second is given a draft.

         procedure Turn
           (With_Draft : Boolean;
            Text       : out Model_Runner.Bytes.Byte_Array_Access;
            Length     : out Natural;
            Proposed   : out Natural;
            Accepted   : out Natural)
         is
            Live    : L.Session;
            Second  : aliased L.Session;
            Request : Gen.Request;
            Stop    : Model_Runner.Stops.Set;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
         begin
            L.Open (Live, Under.Ready, Status => Local);
            Assert (E.Is_Ok (Local), "the session did not open");

            if With_Draft then
               L.Open (Second, Under.Ready, Status => Local);
               Assert (E.Is_Ok (Local), "the draft session did not open");
            end if;

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 6;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 7;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;
            Request.Retain_Text := True;
            Request.Draft_Tokens := (if With_Draft then 3 else 0);

            Gen.Generate
              (Under.Ready, Live, Prompt, Request, Stop, null, null,
               null, null, null, null,
               Draft =>
                 (if With_Draft then Under.Ready'Unchecked_Access
                  else null),
               Draft_Session =>
                 (if With_Draft then Second'Unchecked_Access else null),
               Outcome => Outcome);

            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Text := Outcome.Text;
            Length := Outcome.Text_Length;
            Proposed := Outcome.Drafted;
            Accepted := Outcome.Accepted;

            Model_Runner.Stops.Close (Stop);
            if With_Draft then
               L.Close (Second);
            end if;
            L.Close (Live);
         end Turn;

         Plain_Text, Draft_Text : Model_Runner.Bytes.Byte_Array_Access;
         Plain_Last, Draft_Last : Natural;
         Ignored_A, Ignored_B   : Natural;
         Proposed, Accepted     : Natural;
      begin
         Start (Under);

         Turn (False, Plain_Text, Plain_Last, Ignored_A, Ignored_B);
         Turn (True, Draft_Text, Draft_Last, Proposed, Accepted);

         Assert (Plain_Last > 0, "the plain run produced nothing");
         Assert (Draft_Last = Plain_Last,
                 "the drafted run produced" & Natural'Image (Draft_Last)
                 & " bytes against" & Natural'Image (Plain_Last));

         Assert (B."/=" (Plain_Text, null)
                   and then B."/=" (Draft_Text, null),
                 "a run retained no text");
         Assert (B."=" (Plain_Text.all (1 .. B.Byte_Index (Plain_Last)),
                        Draft_Text.all (1 .. B.Byte_Index (Draft_Last))),
                 "a run with a draft produced different text");

         --  And the draft path was actually taken, rather than the run
         --  quietly falling back to one token at a time.
         Assert (Proposed > 0,
                 "the drafted run proposed nothing, so this compares two "
                 & "runs of the same path");
         Assert (Accepted = Proposed,
                 "a model drafting for itself had"
                 & Natural'Image (Accepted) & " of"
                 & Natural'Image (Proposed) & " proposals accepted, and a "
                 & "model always agrees with itself");

         B.Free (Plain_Text);
         B.Free (Draft_Text);
      end;

      B.Free (Image);
   end Drafting_Produces_The_Same_Text;

   ------------------------------------------
   -- Drafting_Shifts_When_The_Room_Runs_Out --
   ------------------------------------------

   --  A drafted run drops its oldest positions when the context fills, as a
   --  run without a draft does.
   --
   --  The shift lived on the single-token path only, so --context-shift did
   --  nothing at all beside --draft-model: the round's batch met the full
   --  context and ended the run. Two options that each worked alone and one
   --  of which quietly stopped working in company.
   --
   --  Both sessions are shifted together, because a draft proposing from a
   --  context the target no longer has proposes badly -- which costs speed
   --  and not correctness, and would therefore go unnoticed.
   procedure Drafting_Shifts_When_The_Room_Runs_Out
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      Image : B.Byte_Array_Access;

      Prompt : constant String := "abab";
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         Live    : L.Session;
         Second  : aliased L.Session;
         Request : Gen.Request;
         Stop    : Model_Runner.Stops.Set;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);

         L.Open (Live, Under.Ready, 16, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         L.Open (Second, Under.Ready, 16, Status => Status);
         Assert (E.Is_Ok (Status), "the draft session did not open");

         Model_Runner.Stops.Open (Stop);
         Request.Max_Tokens := 24;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Seed := 1;
         Request.Has_Seed := True;
         Request.Add_Beginning := True;
         Request.Draft_Tokens := 3;
         Request.Context_Shift := 6;
         Request.Context_Keep := 1;

         Gen.Generate
           (Under.Ready, Live, Prompt, Request, Stop, null, null,
            null, null, null, null,
            Draft => Under.Ready'Unchecked_Access,
            Draft_Session => Second'Unchecked_Access,
            Outcome => Outcome);

         Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                 "the run failed: "
                 & E.Error_Code'Image (Outcome.Error.Code));
         Assert (not Gen."=" (Outcome.Reason, Gen.Context_Full),
                 "a drafted run ended for want of room with --context-shift "
                 & "asked for");
         Assert (Outcome.Generated_Tokens = 24,
                 "a drafted rolling run produced"
                 & Natural'Image (Outcome.Generated_Tokens)
                 & " tokens of twenty-four");
         Assert (Outcome.Shifted > 0,
                 "a drafted run past its context never dropped anything");

         Model_Runner.Stops.Close (Stop);
         L.Close (Second);
         L.Close (Live);
      end;

      B.Free (Image);
   end Drafting_Shifts_When_The_Room_Runs_Out;

   ------------------------------------
   -- Drafting_Runs_On_A_Device --
   ------------------------------------

   --  A drafted run on the device backend says what the device says without
   --  a draft.
   --
   --  Checking proposals asks the engine for something nothing else asks
   --  for: the logits of every position of a batch, which is the output
   --  projection once per position rather than once per batch. On the
   --  device that is a separate product per position through the same
   --  resident matrix, and the comparison here is against the device's own
   --  answer rather than the processor's -- what is being checked is the
   --  drafting, not the arithmetic, and the two backends round differently
   --  by design.
   --
   --  Skipped where there is no device.
   procedure Drafting_Runs_On_A_Device
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      Image : B.Byte_Array_Access;
      Ready : Boolean;

      Prompt : constant String := "abab";
   begin
      Model_Runner.Backend.Device.Close;
      Model_Runner.Backend.Device.Open (Ready);

      if not Ready then
         return;
      end if;

      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Item   : Containers.Container;

         Target : aliased L.Model;
         Draft  : aliased L.Model;

         Status : E.Error_Info;

         procedure Turn
           (With_Draft : Boolean;
            Text       : out Model_Runner.Bytes.Byte_Array_Access;
            Length     : out Natural;
            Accepted   : out Natural)
         is
            Live    : L.Session;
            Second  : aliased L.Session;
            Request : Gen.Request;
            Stop    : Model_Runner.Stops.Set;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
         begin
            L.Open (Live, Target, Status => Local);
            Assert (E.Is_Ok (Local), "the session did not open");

            if With_Draft then
               L.Open (Second, Draft, Status => Local);
               Assert (E.Is_Ok (Local), "the draft session did not open");
            end if;

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 6;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 5;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;
            Request.Retain_Text := True;
            Request.Draft_Tokens := (if With_Draft then 3 else 0);

            Gen.Generate
              (Target, Live, Prompt, Request, Stop, null, null,
               null, null, null, null,
               Draft => (if With_Draft then Draft'Unchecked_Access else null),
               Draft_Session =>
                 (if With_Draft then Second'Unchecked_Access else null),
               Outcome => Outcome);

            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Text := Outcome.Text;
            Length := Outcome.Text_Length;
            Accepted := Outcome.Accepted;

            Model_Runner.Stops.Close (Stop);
            if With_Draft then
               L.Close (Second);
            end if;
            L.Close (Live);
         end Turn;

         Plain_Text, Draft_Text : Model_Runner.Bytes.Byte_Array_Access;
         Plain_Last, Draft_Last : Natural;
         Ignored, Accepted      : Natural;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse
           (Item, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare
           (Target, Item, Source,
            Backend => Model_Runner.Backend.Backend_Device,
            Status  => Status);
         Assert (E.Is_Ok (Status),
                 "the device would not take the fixture: "
                 & E.Error_Code'Image (Status.Code));

         --  The same model again as its own draft, which on a device is the
         --  same resident matrices read twice.
         L.Prepare
           (Draft, Item, Source,
            Backend => Model_Runner.Backend.Backend_Device,
            Status  => Status);
         Assert (E.Is_Ok (Status), "the draft would not prepare");

         Turn (False, Plain_Text, Plain_Last, Ignored);
         Turn (True, Draft_Text, Draft_Last, Accepted);

         Assert (Plain_Last > 0, "the plain run produced nothing");
         Assert (Draft_Last = Plain_Last
                   and then B."="
                     (Plain_Text.all (1 .. B.Byte_Index (Plain_Last)),
                      Draft_Text.all (1 .. B.Byte_Index (Draft_Last))),
                 "a drafted run on the device said something else");
         Assert (Accepted > 0,
                 "no proposal was accepted, so the batch path was never "
                 & "checked");

         B.Free (Plain_Text);
         B.Free (Draft_Text);

         L.Close (Target, Status);
         L.Close (Draft, Status);
         Containers.Close (Item);
      end;

      B.Free (Image);
      Model_Runner.Backend.Device.Close;
   end Drafting_Runs_On_A_Device;

   --------------------------------------------------
   -- Drafting_Reports_The_Same_Probabilities --
   --------------------------------------------------

   --  Asking what the model made of each position gets the same answer with
   --  a draft as without one.
   --
   --  A verified token was chosen from a particular distribution -- the
   --  first of a round from what the round began with, the rest from the
   --  batch's own rows -- and the obvious implementation reports whichever
   --  distribution the round ended at, which is the right answer only for
   --  the last token of each round. Nothing about the text would show it:
   --  the tokens are correct either way and only the numbers beside them
   --  are wrong.
   procedure Drafting_Reports_The_Same_Probabilities
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;
      package Sample renames Model_Runner.Sampling;

      Room : constant := 32;

      --  Somewhere to keep what was reported, so two runs can be compared.
      type Ledger is limited new Gen.Explainer with record
         Count  : Natural := 0;
         Tokens : Vocab.Token_Array (1 .. Room) := [others => 0];
         Values : N.Real_Array (0 .. Room - 1) := [others => 0.0];
      end record;

      overriding procedure Explain
        (Item : in out Ledger; Report : Sample.Explanation);

      overriding procedure Explain
        (Item : in out Ledger; Report : Sample.Explanation) is
      begin
         if Item.Count < Room then
            Item.Count := Item.Count + 1;
            Item.Tokens (Item.Count) := Report.Chosen;
            Item.Values (N.Element_Count (Item.Count) - 1) := Report.Log_Of;
         end if;
      end Explain;

      Image : B.Byte_Array_Access;
      Rough : B.Byte_Array_Access;

      Prompt : constant String := "abab";
   begin
      Tiny_Model.Build (Image);
      Tiny_Model.Build (Rough, Tiny_Model.Q4_0);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         Other : aliased constant B.Byte_Array := Rough.all;
         Aside : aliased Harness (Other'Access);

         procedure Turn (With_Draft : Boolean; Told : out Ledger) is
            Live    : L.Session;
            Second  : aliased L.Session;
            Request : Gen.Request;
            Stop    : Model_Runner.Stops.Set;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
            Book    : aliased Ledger;
         begin
            L.Open (Live, Under.Ready, Status => Local);
            Assert (E.Is_Ok (Local), "the session did not open");

            if With_Draft then
               L.Open (Second, Aside.Ready, Status => Local);
               Assert (E.Is_Ok (Local), "the draft session did not open");
            end if;

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 8;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 3;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;
            Request.Logprobs := 3;
            Request.Draft_Tokens := (if With_Draft then 4 else 0);

            Gen.Generate
              (Under.Ready, Live, Prompt, Request, Stop, null, null,
               null, null, null, null,
               Draft =>
                 (if With_Draft then Aside.Ready'Unchecked_Access else null),
               Draft_Session =>
                 (if With_Draft then Second'Unchecked_Access else null),
               Reporter => Book'Unchecked_Access,
               Outcome => Outcome);

            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Told.Count := Book.Count;
            Told.Tokens := Book.Tokens;
            Told.Values := Book.Values;

            Model_Runner.Stops.Close (Stop);
            if With_Draft then
               L.Close (Second);
            end if;
            L.Close (Live);
         end Turn;

         Plain, Drafted : Ledger;
      begin
         Start (Under);
         Start (Aside);

         Turn (False, Plain);
         Turn (True, Drafted);

         Assert (Plain.Count > 1,
                 "the plain run reported" & Natural'Image (Plain.Count)
                 & " positions, too few to compare");
         Assert (Drafted.Count = Plain.Count,
                 "the drafted run reported" & Natural'Image (Drafted.Count)
                 & " positions against" & Natural'Image (Plain.Count));

         for Index in 1 .. Plain.Count loop
            Assert (Drafted.Tokens (Index) = Plain.Tokens (Index),
                    "the drafted run reported another token at"
                    & Natural'Image (Index));
            Assert (abs (Drafted.Values (N.Element_Count (Index) - 1)
                         - Plain.Values (N.Element_Count (Index) - 1))
                    < 1.0E-6,
                    "the drafted run reported a different probability at"
                    & Natural'Image (Index) & ":"
                    & N.Real'Image
                        (Drafted.Values (N.Element_Count (Index) - 1))
                    & " against"
                    & N.Real'Image (Plain.Values (N.Element_Count (Index) - 1)));
         end loop;
      end;

      B.Free (Image);
      B.Free (Rough);
   end Drafting_Reports_The_Same_Probabilities;

   -------------------------------------------
   -- Drafting_Survives_A_Draft_That_Errs --
   -------------------------------------------

   --  A draft that guesses wrong changes how long the run takes and not
   --  what it says.
   --
   --  The test beside this one has a model drafting for itself, where every
   --  proposal is accepted -- so it never exercises the half of the round
   --  that matters when a draft is a different model: the mismatch, the
   --  rewind of both sessions, and the next round starting from a position
   --  neither of them ended at.
   --
   --  Here the draft is the same model quantized, which agrees with it often
   --  and not always. What is held is that the text is still exactly the
   --  text of the run with no draft at all, and that some proposals really
   --  were refused -- without which this would be the first test again,
   --  written twice.
   procedure Drafting_Survives_A_Draft_That_Errs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      Image : B.Byte_Array_Access;
      Rough : B.Byte_Array_Access;

      Prompt : constant String := "abab";
   begin
      Tiny_Model.Build (Image);
      Tiny_Model.Build (Rough, Tiny_Model.Q4_0);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         Other : aliased constant B.Byte_Array := Rough.all;
         Aside : aliased Harness (Other'Access);

         procedure Turn
           (With_Draft : Boolean;
            Text       : out Model_Runner.Bytes.Byte_Array_Access;
            Length     : out Natural;
            Proposed   : out Natural;
            Accepted   : out Natural)
         is
            Live    : L.Session;
            Second  : aliased L.Session;
            Request : Gen.Request;
            Stop    : Model_Runner.Stops.Set;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
         begin
            L.Open (Live, Under.Ready, Status => Local);
            Assert (E.Is_Ok (Local), "the session did not open");

            if With_Draft then
               L.Open (Second, Aside.Ready, Status => Local);
               Assert (E.Is_Ok (Local), "the draft session did not open");
            end if;

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 8;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 3;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;
            Request.Retain_Text := True;
            Request.Draft_Tokens := (if With_Draft then 4 else 0);

            Gen.Generate
              (Under.Ready, Live, Prompt, Request, Stop, null, null,
               null, null, null, null,
               Draft =>
                 (if With_Draft then Aside.Ready'Unchecked_Access else null),
               Draft_Session =>
                 (if With_Draft then Second'Unchecked_Access else null),
               Outcome => Outcome);

            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Text := Outcome.Text;
            Length := Outcome.Text_Length;
            Proposed := Outcome.Drafted;
            Accepted := Outcome.Accepted;

            Model_Runner.Stops.Close (Stop);
            if With_Draft then
               L.Close (Second);
            end if;
            L.Close (Live);
         end Turn;

         Plain_Text, Draft_Text : Model_Runner.Bytes.Byte_Array_Access;
         Plain_Last, Draft_Last : Natural;
         Ignored_A, Ignored_B   : Natural;
         Proposed, Accepted     : Natural;
      begin
         Start (Under);
         Start (Aside);

         Turn (False, Plain_Text, Plain_Last, Ignored_A, Ignored_B);
         Turn (True, Draft_Text, Draft_Last, Proposed, Accepted);

         Assert (Plain_Last > 0, "the plain run produced nothing");
         Assert (Draft_Last = Plain_Last,
                 "the drafted run produced" & Natural'Image (Draft_Last)
                 & " bytes against" & Natural'Image (Plain_Last));
         Assert (B."=" (Plain_Text.all (1 .. B.Byte_Index (Plain_Last)),
                        Draft_Text.all (1 .. B.Byte_Index (Draft_Last))),
                 "a draft that guesses wrong changed the text");

         Assert (Proposed > 0, "the drafted run proposed nothing");
         Assert (Accepted < Proposed,
                 "every one of" & Natural'Image (Proposed)
                 & " proposals was accepted, so this fixture does not "
                 & "exercise a draft that errs");

         B.Free (Plain_Text);
         B.Free (Draft_Text);
      end;

      B.Free (Image);
      B.Free (Rough);
   end Drafting_Survives_A_Draft_That_Errs;

   --------------------------------------
   -- Adapters_Stack_And_Come_Off_Again --
   --------------------------------------

   --  Adapters add, so they stack; and a scale of minus one subtracts, so
   --  one comes off again.
   --
   --  Both follow from what a merge is -- the weights gain the adapter's
   --  difference times a scale -- and neither was written down or checked.
   --  What is held here is the arithmetic: merging twice moves the logits
   --  twice as far as merging once, and merging with plus one and then minus
   --  one puts them back where they started.
   --
   --  Back to within rounding rather than exactly. A binary32 weight that
   --  has had a number added and subtracted is not the bit pattern it began
   --  with, and a test demanding it would be asserting something about the
   --  arithmetic nobody promised.
   procedure Adapters_Stack_And_Come_Off_Again
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Image   : B.Byte_Array_Access;
      Adapter : constant String := "obj/stacking-adapter.gguf";

      Prompt : constant array (1 .. 3) of Vocab.Token_Id := [4, 5, 6];

      --  Logits after merging the adapter How_Many times at that scale.
      procedure Reading
        (How_Many : Natural;
         Scale    : N.Real;
         Result   : out Logit_Vector)
      is
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed : Containers.Container;
         Ready  : L.Model;
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Result := [others => 0.0];

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare
           (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
         Assert (E.Is_Ok (Status), "the model did not prepare");

         for Round in 1 .. How_Many loop
            declare
               From   : Model_Runner.Byte_Sources.Files.File_Source;
               Second : Containers.Container;
               Local  : E.Error_Info;
            begin
               Model_Runner.Byte_Sources.Files.Open
                 (From, Adapter, Status => Local);
               Assert (E.Is_Ok (Local), "the adapter did not open");

               Containers.Reader.Parse (Second, From, Status => Local);
               Assert (E.Is_Ok (Local), "the adapter did not parse");

               L.Merge_Adapter (Ready, Second, From, Scale, Local);
               Assert (E.Is_Ok (Local),
                       "merge" & Natural'Image (Round) & " was refused: "
                       & E.Error_Code'Image (Local.Code));

               Containers.Close (Second);
               Model_Runner.Byte_Sources.Files.Close (From);
            end;
         end loop;

         L.Open (Live, Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Ready, Token, Result, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");
         end loop;

         L.Close (Live);
         L.Close (Ready, Status);
         Containers.Close (Parsed);
      end Reading;

      Plain, Once, Twice : Logit_Vector;

      --  What a merge moved, summed over the vocabulary.
      function Distance (Left, Right : Logit_Vector) return N.Wide_Real is
         Total : N.Wide_Real := 0.0;
      begin
         for Index in Left'Range loop
            Total := Total + abs (N.Wide_Real (Left (Index))
                                  - N.Wide_Real (Right (Index)));
         end loop;
         return Total;
      end Distance;
   begin
      Tiny_Model.Build (Image);
      Tiny_Model.Write_Adapter (Adapter);

      Reading (0, 1.0, Plain);
      Reading (1, 1.0, Once);
      Reading (2, 1.0, Twice);

      declare
         Moved : constant N.Wide_Real := Distance (Plain, Once);
         Again : constant N.Wide_Real := Distance (Once, Twice);
      begin
         Assert (Moved > 1.0E-4,
                 "merging an adapter changed nothing, so this fixture "
                 & "cannot say what stacking does");

         --  The second merge moves the logits about as far as the first.
         --  Not exactly as far: the model is not linear in its weights, and
         --  what is held is that a second adapter is applied at all rather
         --  than replacing or being swallowed by the first.
         Assert (Again > Moved * 0.5,
                 "a second merge moved the logits by"
                 & N.Wide_Real'Image (Again) & " against"
                 & N.Wide_Real'Image (Moved) & " for the first, so it was "
                 & "not applied on top of it");
      end;

      --  And off again.
      declare
         Restored : Logit_Vector;
         Session  : L.Session;
         pragma Unreferenced (Session);
      begin
         --  Plus one and then minus one, in one model.
         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Ready  : L.Model;
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            L.Prepare
              (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
            Assert (E.Is_Ok (Status), "the model did not prepare");

            for Scale of N.Real_List'(1.0, -1.0) loop
               declare
                  From   : Model_Runner.Byte_Sources.Files.File_Source;
                  Second : Containers.Container;
                  Local  : E.Error_Info;
               begin
                  Model_Runner.Byte_Sources.Files.Open
                    (From, Adapter, Status => Local);
                  Assert (E.Is_Ok (Local), "the adapter did not open");

                  Containers.Reader.Parse (Second, From, Status => Local);
                  Assert (E.Is_Ok (Local), "the adapter did not parse");

                  L.Merge_Adapter (Ready, Second, From, Scale, Local);
                  Assert (E.Is_Ok (Local),
                          "a merge at scale" & N.Real'Image (Scale)
                          & " was refused: "
                          & E.Error_Code'Image (Local.Code));

                  Containers.Close (Second);
                  Model_Runner.Byte_Sources.Files.Close (From);
               end;
            end loop;

            L.Open (Live, Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            Restored := [others => 0.0];
            for Token of Prompt loop
               L.Evaluate (Live, Ready, Token, Restored, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed");
            end loop;

            L.Close (Live);
            L.Close (Ready, Status);
            Containers.Close (Parsed);
         end;

         Assert (Distance (Plain, Restored) < Distance (Plain, Once) * 0.01,
                 "merging at minus one did not take the adapter off: the "
                 & "logits are"
                 & N.Wide_Real'Image (Distance (Plain, Restored))
                 & " from the plain model against"
                 & N.Wide_Real'Image (Distance (Plain, Once))
                 & " with the adapter on");
      end;

      B.Free (Image);
   end Adapters_Stack_And_Come_Off_Again;

   -------------------------------------------
   -- A_Shifted_Context_Saves_And_Restores --
   -------------------------------------------

   --  A context that has been shifted can be written out and read back, and
   --  answers the same afterwards.
   --
   --  A saved context carries the positions it was written with. After a
   --  shift those are not the positions the tokens were first evaluated at,
   --  and a snapshot that recorded the old ones -- or a restore that put
   --  them back where they were -- would give a session whose cache and
   --  whose history disagreed. Neither would raise anything.
   procedure A_Shifted_Context_Saves_And_Restores
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      Whole : constant array (1 .. 9) of Vocab.Token_Id :=
        [4, 5, 6, 7, 8, 9, 10, 11, 12];

      Next : constant Vocab.Token_Id := 6;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         Straight, Restored : Logit_Vector := [others => 0.0];
         Status : E.Error_Info;

         Room : B.Byte_Array_Access;
      begin
         Start (Under);

         --  Shift, then continue -- and keep the context as it stood
         --  before that continuation.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            for Token of Whole loop
               L.Evaluate (Live, Under.Ready, Token, Straight,
                           Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed");
            end loop;

            L.Shift (Live, Under.Ready, 1, 4, Status);
            Assert (E.Is_Ok (Status), "the shift was refused");

            L.Snapshot (Live, Under.Ready, Room, Status);
            Assert (E.Is_Ok (Status),
                    "a shifted context would not be written out: "
                    & E.Error_Code'Image (Status.Code));

            L.Evaluate (Live, Under.Ready, Next, Straight, Status => Status);
            Assert (E.Is_Ok (Status), "the continuation failed");
            L.Close (Live);
         end;

         --  The same continuation, from the context read back.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            L.Adopt (Live, Under.Ready, Room.all, Status);
            Assert (E.Is_Ok (Status),
                    "a shifted context would not be read back: "
                    & E.Error_Code'Image (Status.Code));

            L.Evaluate (Live, Under.Ready, Next, Restored, Status => Status);
            Assert (E.Is_Ok (Status), "the continuation failed");
            L.Close (Live);
         end;

         B.Free (Room);

         for Index in Straight'Range loop
            Assert (Straight (Index) = Restored (Index),
                    "a shifted context read back answers differently at"
                    & N.Element_Count'Image (Index));
         end loop;
      end;

      B.Free (Image);
   end A_Shifted_Context_Saves_And_Restores;

   ---------------------------------------
   -- Shifting_Moves_The_Positions --
   ---------------------------------------

   --  Dropping the oldest positions renumbers what is left and lets the run
   --  go on.
   --
   --  What is checked here is the bookkeeping: the position, the history,
   --  and that generation continues from the shifted cache with finite
   --  logits. What is deliberately not checked is that a shifted context
   --  equals the same remaining tokens read afresh, because it does not:
   --  the keys and values that stay were computed while the dropped tokens
   --  were still there, and moving them renumbers their positions without
   --  recomputing them. The first version of this test asserted that
   --  equality and failed by half a logit, which is the approximation
   --  showing rather than a fault.
   --
   --  The part that would be a fault -- the rotation that renumbers a key --
   --  is exact, and is held at the kernel level where it can be.
   procedure Shifting_Moves_The_Positions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      Whole : constant array (1 .. 9) of Vocab.Token_Id :=
        [4, 5, 6, 7, 8, 9, 10, 11, 12];

      Keep : constant := 1;
      Drop : constant := 4;

      Next : constant Vocab.Token_Id := 6;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         Logits : Logit_Vector := [others => 0.0];
         Status : E.Error_Info;

         Live : L.Session;
      begin
         Start (Under);

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Whole loop
            L.Evaluate (Live, Under.Ready, Token, Logits, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");
         end loop;

         L.Shift (Live, Under.Ready, Keep, Drop, Status);
         Assert (E.Is_Ok (Status),
                 "the shift was refused: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = Whole'Length - Drop,
                 "the shift left" & Natural'Image (L.Position (Live))
                 & " positions, not"
                 & Natural'Image (Whole'Length - Drop));

         --  And the run goes on from there.
         L.Evaluate (Live, Under.Ready, Next, Logits, Status => Status);
         Assert (E.Is_Ok (Status), "the continuation failed");
         Assert (Model_Runner.Kernels.All_Finite (Logits),
                 "a shifted context produced logits that are not numbers");

         --  Dropping more than there is is refused rather than clamped.
         L.Shift (Live, Under.Ready, 0, 1_000, Status);
         Assert (Status.Code = E.Tensor_Shape_Mismatch,
                 "dropping more positions than exist was accepted");

         L.Close (Live);
      end;

      B.Free (Image);
   end Shifting_Moves_The_Positions;

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

   --  The WordPiece road, against a reader written from the description.
   --
   --  It shares nothing with the engine's: it folds and cuts a code point at
   --  a time where the engine builds a folded copy as it goes, it spells by
   --  scanning the whole vocabulary for the longest match where the engine
   --  hashes, and it reads UTF-8 with its own decoder. What the two have in
   --  common is the description they were both written from.
   procedure Word_Piece_Matches_An_Independent_One
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image  : B.Byte_Array_Access;
      Parsed : Containers.Container;
      Status : E.Error_Info;
      Loaded : Boolean;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Bert);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Words  : Vocab.Vocabulary;
         Second : Reference_Tokenizer.Vocabulary;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the bert fixture did not parse");

         Vocab.Load (Words, Parsed, Status => Status);
         Assert (E.Is_Ok (Status), "the engine did not read the vocabulary");

         Reference_Tokenizer.Load (Second, Parsed, Loaded);
         Assert (Loaded, "the independent reader did not read it");

         --  Each case is one thing the road does, chosen against a reader
         --  that leaves it out: a word carried whole, a word spelled from a
         --  piece and a continuation, folding of case and of accents,
         --  punctuation cut loose from the word before it, an ideograph
         --  standing alone, and a word the vocabulary cannot spell.
         declare
            Acute : constant String :=
              [1 => Character'Val (16#C3#), 2 => Character'Val (16#A1#)];

            --  A CJK ideograph, which stands alone however it is spaced.
            Middle : constant String :=
              [1 => Character'Val (16#E4#), 2 => Character'Val (16#B8#),
               3 => Character'Val (16#AD#)];

            type Case_Text is access constant String;
            Cases : constant array (1 .. 12) of Case_Text :=
              [new String'(""),
               new String'("a"),
               new String'("ab"),
               new String'("abc"),
               new String'("abc ab"),
               new String'("xb"),
               new String'("xB, Ac"),
               new String'(Acute & "B"),
               new String'("a" & Middle & "b"),
               new String'("1x"),
               new String'("  ab  "),
               new String'("ab.")];
         begin
            for Which of Cases loop
               declare
                  Mine   : Vocab.Token_Array (1 .. 64);
                  Mine_N : Natural;
                  Theirs : Reference_Tokenizer.Token_Vector (1 .. 64);
                  Theirs_N : Natural;
               begin
                  Vocab.Encode
                    (Words, Which.all, False, False, Mine, Mine_N, Status);
                  Assert (E.Is_Ok (Status),
                          "the engine refused """ & Which.all & """");

                  Reference_Tokenizer.Encode
                    (Second, Which.all, False, Theirs, Theirs_N);

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

         Vocab.Close (Words);
         Reference_Tokenizer.Close (Second);
      end;

      Containers.Close (Parsed);
      B.Free (Image);
   end Word_Piece_Matches_An_Independent_One;

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
      --  One name per rule, and then one more name for each rule that
      --  another name is mapped onto. The engine and this reader each carry
      --  their own table from a name to a rule, and nothing else compares
      --  the two: a name mapped one way here and another way there would
      --  otherwise be found by no test at all. Starcoder was such a name
      --  and was wrong.
      Rules : constant array (1 .. 12) of Case_Text :=
        [new String'(""),
         new String'("default"),
         new String'("gpt-2"),
         new String'("mpt"),
         new String'("falcon"),
         new String'("smollm"),
         new String'("starcoder"),
         new String'("command-r"),
         new String'("llama3"),
         new String'("dbrx"),
         new String'("qwen2"),
         new String'("stablelm2")];

      --  Text that reaches every part of the rule: a bare word, the markers
      --  a chat template writes and two strings that open a bracket without
      --  being one, a word whose merges are decided by rank rather than by
      --  position, a word led by a space, a tab before a word, runs of
      --  digits of each length the groupings tell apart, a contraction, a
      --  space before a full stop and before a grave accent, and a run of
      --  punctuation with a letter on each side.
      Cases : constant array (1 .. 15) of Case_Text :=
        [new String'("ab"),
         new String'("<|im_start|>ab<|im_end|>"),
         new String'("<ab"),
         new String'("<|im_"),
         new String'("abc"),
         new String'("x ab"),
         new String'("x" & Tab & "ab"),
         new String'("ab 1234"),
         new String'("x 12 abc"),
         new String'("ab's 4321"),
         new String'("a's"),
         new String'("x ."),
         new String'("x `"),
         new String'("ab.`'x 1"),
         new String'("x 1234567 ab")];
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

   procedure Unigram_Matches_An_Independent_One
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Vocab renames Model_Runner.Tokenizer;
      use type Reference_Tokenizer.Model_Kind;

      type Case_Text is access constant String;

      --  Text that reaches each part of the road: the one word where the
      --  two roads part, a word the vocabulary spells exactly, a character
      --  it cannot spell at all, two such characters in a row -- which the
      --  road answers with one unknown and not two -- a marker, and spaces,
      --  which this vocabulary keeps rather than merges.
      Cases : constant array (1 .. 9) of Case_Text :=
        [new String'("abc"),
         new String'("ab"),
         new String'("a"),
         new String'("z"),
         new String'("zz"),
         new String'("azb"),
         new String'("a b"),
         new String'("a  b"),
         new String'("<s>abc</s>")];

      Image  : B.Byte_Array_Access;
      Parsed : Containers.Container;
      Status : E.Error_Info;
      Loaded : Boolean;
   begin
      Unigram_Vocabulary.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Words  : Vocab.Vocabulary;
         Second : Reference_Tokenizer.Vocabulary;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the unigram fixture did not parse");

         Vocab.Load (Words, Parsed, Status => Status);
         Assert (E.Is_Ok (Status),
                 "the engine did not read the unigram vocabulary: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Vocab.Kind (Words) = Vocab.Kind_Unigram,
                 "the engine read it as something else");

         Reference_Tokenizer.Load (Second, Parsed, Loaded);
         Assert (Loaded, "the reference did not read the vocabulary");
         Assert (Reference_Tokenizer.Kind (Second)
                 = Reference_Tokenizer.Unigram,
                 "the reference read it as something else");

         --  The whole reason this road exists, said as an assertion rather
         --  than only as a comment: on this text the best path is not what
         --  merging arrives at. Merging takes the marker and "a" together,
         --  then that and "b", and is left with the marker-a-b piece and
         --  "c" -- which sums to -7. The best path takes marker-a and "bc",
         --  which sums to -6 and which no order of merges can reach.
         declare
            Mine   : Vocab.Token_Array (1 .. 16);
            Mine_N : Natural;
         begin
            Vocab.Encode (Words, "abc", False, False, Mine, Mine_N, Status);
            Assert (E.Is_Ok (Status), "encoding ""abc"" failed");
            Assert (Mine_N = 2,
                    "the best path over ""abc"" is two pieces, not"
                    & Natural'Image (Mine_N));
            Assert (Mine (1) = 7 and then Mine (2) = 9,
                    "the best path over ""abc"" was not the marked a and bc:"
                    & Vocab.Token_Id'Image (Mine (1))
                    & Vocab.Token_Id'Image (Mine (2)));
         end;

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
                       "the engine refused """ & Which.all & """: "
                       & E.Error_Code'Image (Status.Code));

               Reference_Tokenizer.Encode
                 (Second, Which.all, False, Theirs, Theirs_N);

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

         Reference_Tokenizer.Close (Second);
         Vocab.Close (Words);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Unigram_Matches_An_Independent_One;

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
              (Under.Ready, Live, Prompt, Request, Stop, null, null,
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

   --  Two refusals the engine makes that no test had made it make.
   --
   --  A code is a promise that a wrong input is turned away and named, and
   --  the raise being written is not evidence that the branch is taken. The
   --  check that every code is produced somewhere counts a raise nobody
   --  reaches exactly as it counts a raise everybody reaches, so these sat
   --  between "declared" and "reached" with nothing saying so.
   procedure Unreached_Engine_Refusals_Are_Reached
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Gen renames Model_Runner.Generation;

      Image : B.Byte_Array_Access;
   begin
      --  A context larger than the model declares. The session refuses it
      --  rather than opening one the weights cannot fill.
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Live  : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);

         L.Open
           (Live, Under.Ready, Context => 1_000_000, Status => Status);
         Assert (Status.Code = E.Arch_Context_Too_Large,
                 "a context past what the model declares was accepted: "
                 & E.Error_Code'Image (Status.Code));

         --  And zero, which is the other end of the same test and would be
         --  a session that can hold nothing.
         L.Open (Live, Under.Ready, Context => 0, Status => Status);
         Assert (E.Is_Ok (Status),
                 "asking for the model's own context was refused: "
                 & E.Error_Code'Image (Status.Code));
         L.Close (Live);
      end;

      B.Free (Image);

      --  A prompt that makes no tokens at all. On the byte-pair road empty
      --  text is empty -- there is no dummy word marker to stand in for it
      --  -- so a vocabulary that adds no beginning token leaves generation
      --  with nothing to evaluate, and it says so rather than generating
      --  from an empty context.
      Tiny_Model.Build (Image, Adds_Beginning => False, Byte_Pair => True);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Live    : L.Session;
         Status  : E.Error_Info;
         Request : Gen.Request;
         Stop    : Model_Runner.Stops.Set;
         Outcome : Gen.Result;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         Model_Runner.Stops.Open (Stop);
         Request.Max_Tokens := 1;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Seed := 1;
         Request.Has_Seed := True;
         Request.Add_Beginning := True;

         Gen.Generate
           (Under.Ready, Live, "", Request, Stop, null, null, null, null,
            null, null, Outcome => Outcome);

         Assert (Outcome.Error.Code = E.Generation_Empty_Prompt,
                 "a prompt that makes no tokens was accepted: "
                 & E.Error_Code'Image (Outcome.Error.Code));

         Model_Runner.Stops.Close (Stop);
         L.Close (Live);
      end;

      B.Free (Image);
   end Unreached_Engine_Refusals_Are_Reached;

   --  A snapshot of a model whose key and value heads are different
   --  widths.
   --
   --  The round-trip above uses a model where they are the same number,
   --  and a cache written with the two widths crossed round-trips
   --  perfectly when they are the same number. So does one written with
   --  the value width where the key width belongs. Neither would survive a
   --  model that states them apart, which is what this uses: key heads
   --  twice the width the embedding implies and value heads three times
   --  it.
   --
   --  Same test as the plain one, then. What makes it a different test is
   --  the fixture.
   procedure Snapshot_Keeps_The_Two_Widths_Apart
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7];

      Image : B.Byte_Array_Access;
      Kept  : B.Byte_Array_Access;
      Direct, Restored : Logit_Vector;
   begin
      Tiny_Model.Build (Image, Apart_Widths => True);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);

         declare
            Read : constant L.Configuration := L.Config (Under.Ready);
         begin
            Assert (Read.Head_Size /= Read.Value_Size,
                    "this fixture is meant to have the two widths apart, "
                    & "and they are both"
                    & Natural'Image (Read.Head_Size));
         end;

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Direct, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");
         end loop;

         L.Snapshot (Live, Under.Ready, Kept, Status);
         Assert (E.Is_Ok (Status),
                 "the session did not snapshot: "
                 & E.Error_Code'Image (Status.Code));

         L.Evaluate (Live, Under.Ready, 4, Direct, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed after the snapshot");
         L.Close (Live);
      end;

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the second session did not open");

         L.Adopt (Live, Under.Ready, Kept.all, Status);
         Assert (E.Is_Ok (Status),
                 "the snapshot was not adopted: "
                 & E.Error_Code'Image (Status.Code));

         L.Evaluate (Live, Under.Ready, 4, Restored, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed after adopting");
         L.Close (Live);
      end;

      declare
         Worst : Model_Runner.Numerics.Real := 0.0;
      begin
         for Index in Direct'Range loop
            Worst := Model_Runner.Numerics.Real'Max
              (Worst, abs (Direct (Index) - Restored (Index)));
         end loop;

         Assert (Worst = 0.0,
                 "a cache whose keys and values are different widths did "
                 & "not survive being written out and read back; the "
                 & "logits moved by"
                 & Model_Runner.Numerics.Real'Image (Worst));
      end;

      B.Free (Kept);
      B.Free (Image);
   end Snapshot_Keeps_The_Two_Widths_Apart;

   --  A context saved before an adapter was merged is not a context after
   --  it was.
   --
   --  A cache is what the model made of what it read, so it belongs to the
   --  weights that made it. Merging an adapter replaces those weights, and
   --  a cache from before the merge describes attention the merged model
   --  never computed. Read into it, the model would continue a
   --  conversation it did not have -- and nothing about the text would
   --  look wrong.
   --
   --  So the model a snapshot names has to be the model as it will be
   --  used, adapter and all.
   procedure Adapter_Changes_Which_Model_A_Context_Belongs_To
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Adapter : constant String := "obj/context-adapter.gguf";
      Prompt  : constant Vocab.Token_Array := [1, 4, 5, 6, 7];

      Image : B.Byte_Array_Access;
      Kept  : B.Byte_Array_Access;

      --  Prepare the fixture, optionally with the adapter merged, and run
      --  the given action against it.
      procedure With_Model
        (Adapted : Boolean;
         Take    : Boolean;
         Outcome : out E.Error_Info)
      is
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed : Containers.Container;
         Ready  : L.Model;
         Live   : L.Session;
         Status : E.Error_Info;
         Logits : Logit_Vector;
      begin
         Outcome := E.Success;

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare
           (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
         Assert (E.Is_Ok (Status), "the model did not prepare");

         if Adapted then
            declare
               From   : Model_Runner.Byte_Sources.Files.File_Source;
               Second : Containers.Container;
               Local  : E.Error_Info;
            begin
               Model_Runner.Byte_Sources.Files.Open
                 (From, Adapter, Status => Local);
               Assert (E.Is_Ok (Local), "the adapter did not open");

               Containers.Reader.Parse (Second, From, Status => Local);
               Assert (E.Is_Ok (Local), "the adapter did not parse");

               L.Merge_Adapter (Ready, Second, From, Status => Local);
               Assert (E.Is_Ok (Local),
                       "the adapter did not merge: "
                       & E.Error_Code'Image (Local.Code));

               Containers.Close (Second);
               Model_Runner.Byte_Sources.Files.Close (From);
            end;
         end if;

         L.Open (Live, Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         if Take then
            for Token of Prompt loop
               L.Evaluate (Live, Ready, Token, Logits, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed");
            end loop;

            L.Snapshot (Live, Ready, Kept, Outcome);
         else
            L.Adopt (Live, Ready, Kept.all, Outcome);
         end if;

         L.Close (Live);
         L.Close (Ready, Status);
         Containers.Close (Parsed);
      end With_Model;

      Status : E.Error_Info;
   begin
      --  A quantized fixture on purpose. With binary32 weights the merge
      --  writes into the file's own bytes -- nothing was repacked, so the
      --  views still point there -- and the fingerprint samples those, so
      --  the two models come out different for a reason that has nothing to
      --  do with the merge being recorded. A quantized model is repacked
      --  into a second buffer, the merge writes there, and the file's bytes
      --  are untouched: which is every model anyone would use an adapter
      --  with, and the case where this can actually go wrong.
      Tiny_Model.Build (Image, Tiny_Model.Q4_K);
      Tiny_Model.Write_Adapter (Adapter, Deep => True);

      --  Taken from the model as it comes.
      With_Model (Adapted => False, Take => True, Outcome => Status);
      Assert (E.Is_Ok (Status), "the snapshot was refused");

      --  Read back into the same model: fine.
      With_Model (Adapted => False, Take => False, Outcome => Status);
      Assert (E.Is_Ok (Status),
              "a context was refused by the model it came from: "
              & E.Error_Code'Image (Status.Code));

      --  And into the model with the adapter merged, which is a different
      --  model however the file is spelled.
      With_Model (Adapted => True, Take => False, Outcome => Status);
      Assert (Status.Code = E.Lifecycle_Cache_Mismatched,
              "a context from before an adapter was merged was read into "
              & "the merged model: " & E.Error_Code'Image (Status.Code));

      B.Free (Kept);
      B.Free (Image);
   end Adapter_Changes_Which_Model_A_Context_Belongs_To;

   --  A snapshot of a halved cache is a halved cache.
   --
   --  Two features that arrived separately and meet here. The snapshot
   --  writes four bytes an element whichever precision the session holds,
   --  so a half-precision cache goes out with sixteen bits of every word
   --  meaning nothing -- and comes back into a session that has to be
   --  holding halves for those bytes to mean what they said.
   --
   --  The pairing that is refused matters as much as the one that works.
   --  A snapshot of an exact cache read into a halved session would be
   --  read as halves and produce a conversation the model never had, so
   --  the precision is part of what a snapshot says about itself.
   procedure Halved_Cache_Snapshots_As_Halved
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7];

      Image : B.Byte_Array_Access;
      Kept  : B.Byte_Array_Access;
      Direct, Restored : Logit_Vector;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Cache => L.Halved, Status => Status);
         Assert (E.Is_Ok (Status), "the halved session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Direct, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");
         end loop;

         L.Snapshot (Live, Under.Ready, Kept, Status);
         Assert (E.Is_Ok (Status),
                 "a halved session did not snapshot: "
                 & E.Error_Code'Image (Status.Code));

         L.Evaluate (Live, Under.Ready, 4, Direct, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed after the snapshot");

         L.Close (Live);
      end;

      --  Back into a halved session: the same answer, exactly.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Cache => L.Halved, Status => Status);
         Assert (E.Is_Ok (Status), "the second halved session did not open");

         L.Adopt (Live, Under.Ready, Kept.all, Status);
         Assert (E.Is_Ok (Status),
                 "a halved snapshot was not adopted: "
                 & E.Error_Code'Image (Status.Code));

         L.Evaluate (Live, Under.Ready, 4, Restored, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed after adopting");
         L.Close (Live);
      end;

      declare
         Worst : Model_Runner.Numerics.Real := 0.0;
      begin
         for Index in Direct'Range loop
            Worst := Model_Runner.Numerics.Real'Max
              (Worst, abs (Direct (Index) - Restored (Index)));
         end loop;

         Assert (Worst = 0.0,
                 "a halved cache did not survive being written out and "
                 & "read back; the logits moved by"
                 & Model_Runner.Numerics.Real'Image (Worst));
      end;

      --  And into an exact one, which it is not.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the exact session did not open");

         L.Adopt (Live, Under.Ready, Kept.all, Status);
         Assert (Status.Code = E.Lifecycle_Cache_Mismatched,
                 "a halved snapshot was read into an exact cache: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = 0,
                 "a refused adoption left something behind");

         L.Close (Live);
      end;

      B.Free (Kept);
      B.Free (Image);
   end Halved_Cache_Snapshots_As_Halved;

   --  A snapshot is the session it was taken from.
   --
   --  The point of taking one is not to re-read a prompt, so what has to
   --  be true is that a session filled from it answers exactly as the one
   --  it came from would have. Evaluating the same next token through both
   --  is what says so: the logits depend on every key and value of every
   --  layer, so a cache read back one position out, one layer out, or with
   --  the keys and values crossed would not produce them.
   --
   --  And bytes that do not belong are refused rather than read. The cases
   --  below are the ones a person actually meets: a context of another
   --  size, and something that is not a snapshot at all.
   procedure Snapshot_Is_The_Session
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7];

      Image  : B.Byte_Array_Access;
      Kept   : B.Byte_Array_Access;
      Direct, Restored : Logit_Vector;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Direct, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");
         end loop;

         L.Snapshot (Live, Under.Ready, Kept, Status);
         Assert (E.Is_Ok (Status),
                 "the session did not snapshot: "
                 & E.Error_Code'Image (Status.Code));
         Assert (B."/=" (Kept, null), "the snapshot produced no bytes");

         --  One more token, from the session that read the prompt.
         L.Evaluate (Live, Under.Ready, 4, Direct, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed after the snapshot");

         L.Close (Live);
      end;

      --  A fresh session, filled from those bytes, asked for the same
      --  token.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the second session did not open");

         L.Adopt (Live, Under.Ready, Kept.all, Status);
         Assert (E.Is_Ok (Status),
                 "the snapshot was not adopted: "
                 & E.Error_Code'Image (Status.Code));

         Assert (L.Position (Live) = Prompt'Length,
                 "the filled session holds"
                 & Natural'Image (L.Position (Live))
                 & " positions where it took"
                 & Natural'Image (Prompt'Length));

         L.Evaluate (Live, Under.Ready, 4, Restored, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed after adopting");

         L.Close (Live);
      end;

      declare
         Worst : Model_Runner.Numerics.Real := 0.0;
      begin
         for Index in Direct'Range loop
            Worst := Model_Runner.Numerics.Real'Max
              (Worst, abs (Direct (Index) - Restored (Index)));
         end loop;

         Assert (Worst = 0.0,
                 "a session filled from a snapshot answered differently "
                 & "from the one it came from, by"
                 & Model_Runner.Numerics.Real'Image (Worst));
      end;

      --  A context of another size is another cache, whatever the model.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Context => 8, Status => Status);
         Assert (E.Is_Ok (Status), "the narrow session did not open");

         L.Adopt (Live, Under.Ready, Kept.all, Status);
         Assert (Status.Code = E.Lifecycle_Cache_Mismatched,
                 "a snapshot taken at another context was adopted: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = 0,
                 "a refused adoption left something behind");

         --  And bytes that are not a snapshot at all. The model's own,
         --  which are to hand and are certainly not one.
         L.Adopt (Live, Under.Ready, Held, Status);
         Assert (Status.Code = E.Lifecycle_Cache_Unreadable,
                 "a model file was adopted as a snapshot: "
                 & E.Error_Code'Image (Status.Code));

         --  And a snapshot cut short.
         L.Adopt
           (Live, Under.Ready,
            Kept.all (Kept.all'First .. Kept.all'First + 40), Status);
         Assert (E.Is_Error (Status),
                 "a truncated snapshot was adopted");

         L.Close (Live);
      end;

      B.Free (Kept);
      B.Free (Image);
   end Snapshot_Is_The_Session;

   --  Merging an adapter into a weight that is not square.
   --
   --  The test above uses this fixture's query projection, which is as
   --  many rows as it has columns. A merge that had its rows and columns
   --  the wrong way round would read the pair transposed and still fit,
   --  still run, and still produce a plausible model. Nothing about a
   --  square matrix can tell the two apart.
   --
   --  The fixture that states its key and value head widths separately has
   --  a query projection of sixteen rows by eight columns, so it can.
   procedure Adapter_Merges_Into_A_Tall_Weight
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt  : constant Vocab.Token_Array := [1, 4, 5, 6, 7];
      Adapter : constant String := "obj/tall-adapter.gguf";

      --  The logits from a model built with the difference already in it,
      --  or from the plain one with the adapter merged.
      procedure Answer
        (Baked  : Boolean;
         Result : out Logit_Vector;
         Merge  : out E.Error_Info)
      is
         Image : B.Byte_Array_Access;
      begin
         Merge := E.Success;
         Tiny_Model.Build
           (Image, Apart_Widths => True, Merged => Baked);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Ready  : L.Model;
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            L.Prepare
              (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
            Assert (E.Is_Ok (Status), "the model did not prepare");

            if not Baked then
               Tiny_Model.Write_Adapter (Adapter, Apart => True);

               declare
                  From   : Model_Runner.Byte_Sources.Files.File_Source;
                  Second : Containers.Container;
                  Local  : E.Error_Info;
               begin
                  Model_Runner.Byte_Sources.Files.Open
                    (From, Adapter, Status => Local);
                  Assert (E.Is_Ok (Local), "the adapter did not open");

                  Containers.Reader.Parse (Second, From, Status => Local);
                  Assert (E.Is_Ok (Local), "the adapter did not parse");

                  L.Merge_Adapter (Ready, Second, From, Status => Merge);

                  Containers.Close (Second);
                  Model_Runner.Byte_Sources.Files.Close (From);
               end;
            end if;

            if E.Is_Ok (Merge) then
               L.Open (Live, Ready, Status => Status);
               Assert (E.Is_Ok (Status), "the session did not open");

               for Token of Prompt loop
                  L.Evaluate (Live, Ready, Token, Result, Status => Status);
                  Assert (E.Is_Ok (Status), "evaluation failed");
               end loop;

               L.Close (Live);
            else
               Result := [others => 0.0];
            end if;

            L.Close (Ready, Status);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Answer;

      Adapted, Baked : Logit_Vector;
      Merge : E.Error_Info;
      Worst : Model_Runner.Numerics.Real := 0.0;
   begin
      Answer (Baked => False, Result => Adapted, Merge => Merge);
      Assert (E.Is_Ok (Merge),
              "an adapter on a weight that is not square did not merge: "
              & E.Error_Code'Image (Merge.Code));

      Answer (Baked => True, Result => Baked, Merge => Merge);

      for Index in Baked'Range loop
         Worst := Model_Runner.Numerics.Real'Max
           (Worst, abs (Baked (Index) - Adapted (Index)));
      end loop;

      Assert (Worst < 1.0E-4,
              "merging into a weight of sixteen rows by eight columns and "
              & "writing the same difference into the weights disagree by"
              & Model_Runner.Numerics.Real'Image (Worst));
   end Adapter_Merges_Into_A_Tall_Weight;

   --  Merging an adapter is the arithmetic it claims.
   --
   --  An adapter says what a fine-tune changed, as a pair of small
   --  matrices whose product is the difference. Nothing about that is
   --  visible from outside except the answer, so the check is against a
   --  model file written with the same difference already in its weights:
   --  merge the pair into the plain model and it has to become the other
   --  one, logit for logit.
   --
   --  Built by the fixture from the same two vectors, which is the point.
   --  A test that asked the engine what the difference was and then
   --  compared the engine against itself would pass whatever the merge
   --  did.
   procedure Adapter_Merges_What_It_Describes
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7];

      Adapter : constant String := "obj/tiny-adapter.gguf";

      --  The logits a model produces, optionally after merging the
      --  adapter above into it.
      procedure Answer
        (Merged : Boolean;
         Apply  : Boolean;
         Half   : Boolean;
         Alien  : Boolean;
         Result : out Logit_Vector;
         Merge  : out E.Error_Info)
      is
         Image : B.Byte_Array_Access;
      begin
         Merge := E.Success;
         Tiny_Model.Build (Image, Merged => Merged);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Ready  : L.Model;
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            L.Prepare
              (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
            Assert (E.Is_Ok (Status), "the model did not prepare");

            if Apply then
               Tiny_Model.Write_Adapter
                 (Adapter, Half => Half, Foreign => Alien);

               declare
                  From   : Model_Runner.Byte_Sources.Files.File_Source;
                  Second : Containers.Container;
                  Local  : E.Error_Info;
               begin
                  Model_Runner.Byte_Sources.Files.Open
                    (From, Adapter, Status => Local);
                  Assert (E.Is_Ok (Local), "the adapter did not open");

                  Containers.Reader.Parse (Second, From, Status => Local);
                  Assert (E.Is_Ok (Local), "the adapter did not parse");

                  L.Merge_Adapter (Ready, Second, From, Status => Merge);

                  Containers.Close (Second);
                  Model_Runner.Byte_Sources.Files.Close (From);
               end;
            end if;

            if E.Is_Ok (Merge) then
               L.Open (Live, Ready, Status => Status);
               Assert (E.Is_Ok (Status), "the session did not open");

               for Token of Prompt loop
                  L.Evaluate (Live, Ready, Token, Result, Status => Status);
                  Assert (E.Is_Ok (Status), "evaluation failed");
               end loop;

               L.Close (Live);
            else
               Result := [others => 0.0];
            end if;

            L.Close (Ready, Status);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Answer;

      Plain, Adapted, Baked : Logit_Vector;
      Merge : E.Error_Info;
      Worst : Model_Runner.Numerics.Real := 0.0;
   begin
      Answer (Merged => False, Apply => False, Half => False,
              Alien => False, Result => Plain, Merge => Merge);
      Answer (Merged => False, Apply => True, Half => False,
              Alien => False, Result => Adapted, Merge => Merge);
      Assert (E.Is_Ok (Merge),
              "the adapter did not merge: "
              & E.Error_Code'Image (Merge.Code));
      Answer (Merged => True, Apply => False, Half => False,
              Alien => False, Result => Baked, Merge => Merge);

      --  The merge changed something.
      declare
         Moved : Model_Runner.Numerics.Real := 0.0;
      begin
         for Index in Plain'Range loop
            Moved := Model_Runner.Numerics.Real'Max
              (Moved, abs (Plain (Index) - Adapted (Index)));
         end loop;
         Assert (Moved > 0.0,
                 "merging an adapter left every logit where it was");
      end;

      --  And what it changed them to is the model with the difference
      --  already in it.
      for Index in Baked'Range loop
         Worst := Model_Runner.Numerics.Real'Max
           (Worst, abs (Baked (Index) - Adapted (Index)));
      end loop;

      Assert (Worst < 1.0E-4,
              "a merged adapter and a model written with the same "
              & "difference disagree by"
              & Model_Runner.Numerics.Real'Image (Worst));

      --  Half a pair describes half a difference, which is nothing.
      Answer (Merged => False, Apply => True, Half => True,
              Alien => False, Result => Adapted, Merge => Merge);
      Assert (Merge.Code = E.Arch_Missing_Tensor,
              "half an adapter pair was accepted: "
              & E.Error_Code'Image (Merge.Code));

      --  An adapter for a weight this profile does not adapt touches
      --  nothing, and says so rather than reporting a merge.
      Answer (Merged => False, Apply => True, Half => False,
              Alien => True, Result => Adapted, Merge => Merge);
      Assert (Merge.Code = E.Arch_Missing_Tensor,
              "an adapter naming no weight this profile adapts was "
              & "accepted: " & E.Error_Code'Image (Merge.Code));
   end Adapter_Merges_What_It_Describes;

   --  The hidden state is reported, and refused when there is none.
   --
   --  What the embedding command prints comes from here. Through the command
   --  only the successful path is reached, and the two refusals matter more
   --  than the success does: a session with nothing evaluated would
   --  otherwise report a buffer of zeros as though the model had made that
   --  of something, and a caller passing the wrong width would be told
   --  nothing at all.
   procedure Hidden_State_Is_Reported
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image  : B.Byte_Array_Access;
      Logits : Logit_Vector;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;

         State : Model_Runner.Numerics.Real_Array
           (0 .. Model_Runner.Numerics.Element_Count (Tiny_Model.Embedding) - 1);
      begin
         Start (Under);
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         --  Nothing has been evaluated, so there is no state to report.
         L.Hidden_State (Live, State, Status);
         Assert (Status.Code = E.Lifecycle_Invalid_State,
                 "a session with nothing evaluated reported a state: "
                 & E.Error_Code'Image (Status.Code));
         Assert ((for all Value of State => Value = 0.0),
                 "a refused state left something in the target");

         L.Evaluate (Live, Under.Ready, 4, Logits, Status => Status);
         Assert (E.Is_Ok (Status), "evaluation failed");

         L.Hidden_State (Live, State, Status);
         Assert (E.Is_Ok (Status),
                 "the state was refused after a token: "
                 & E.Error_Code'Image (Status.Code));

         --  It is a state and not a distribution: the vector is as wide as
         --  the model, not as wide as its vocabulary, and something in it is
         --  not zero.
         Assert ((for some Value of State => Value /= 0.0),
                 "the state was all zeros after a token was evaluated");

         --  And a target of the wrong width is refused rather than filled
         --  as far as it goes.
         declare
            Narrow : Model_Runner.Numerics.Real_Array (0 .. 1);
         begin
            L.Hidden_State (Live, Narrow, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "a target of the wrong width was accepted: "
                    & E.Error_Code'Image (Status.Code));
         end;

         L.Close (Live);
      end;

      B.Free (Image);
   end Hidden_State_Is_Reported;

   --  A half-precision cache holds half the bytes and answers the same.
   --
   --  Two claims, and the sweep makes only the second. That the engine and
   --  the independent implementation still agree within a measured bound is
   --  what `tests conformance` reports; what it cannot report is that the
   --  session actually holds less, because a session that quietly stored
   --  binary32 under another name would agree perfectly.
   --
   --  So the memory is asserted where a caller reads it -- the plan, which
   --  is what `inspect` prints and what a memory limit is judged against --
   --  and the answer is asserted to be close but not identical, since a
   --  halved cache that changed nothing at all would mean the rounding
   --  never happened.
   procedure Halved_Cache_Holds_Half
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      Image  : B.Byte_Array_Access;
      Exact_Logits, Halved_Logits : Logit_Vector;
      Apart : Model_Runner.Numerics.Real := 0.0;

      procedure Answer
        (Cache  : L.Cache_Precision;
         Under  : in out Harness;
         Result : out Logit_Vector)
      is
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         L.Open (Live, Under.Ready, Cache => Cache, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");
         Assert (L."=" (L.Precision (Live), Cache),
                 "the session did not hold the precision it was opened with");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed: " & E.Error_Code'Image (Status.Code));
         end loop;

         L.Close (Live);
      end Answer;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
      begin
         Start (Under);

         --  What the two would hold, before either is opened.
         declare
            use type Interfaces.Unsigned_64;

            Wide, Narrow : Model_Runner.Memory.Session_Plan;
            Status : E.Error_Info;
         begin
            L.Plan_Session (Under.Ready, 0, Wide, Status, L.Exact);
            Assert (E.Is_Ok (Status), "the exact plan was refused");

            L.Plan_Session (Under.Ready, 0, Narrow, Status, L.Halved);
            Assert (E.Is_Ok (Status), "the halved plan was refused");

            Assert (Wide.KV_Cache_Bytes = 2 * Narrow.KV_Cache_Bytes,
                    "a halved cache did not plan for half the bytes:"
                    & Interfaces.Unsigned_64'Image (Wide.KV_Cache_Bytes)
                    & " against"
                    & Interfaces.Unsigned_64'Image (Narrow.KV_Cache_Bytes));

            Assert (Narrow.KV_Cache_Bytes > 0,
                    "a halved cache planned for nothing at all");
         end;

         Answer (L.Exact, Under, Exact_Logits);
         Answer (L.Halved, Under, Halved_Logits);
      end;

      for Index in Exact_Logits'Range loop
         Apart := Model_Runner.Numerics.Real'Max
           (Apart, abs (Exact_Logits (Index) - Halved_Logits (Index)));
      end loop;

      Assert (Apart > 0.0,
              "a half-precision cache produced exactly the logits of a "
              & "binary32 one, so nothing was rounded");

      --  And close, by the bound the sweep measured this against.
      Assert (Long_Float (Apart) < Conformance.Cached_Absolute_Tolerance,
              "a half-precision cache moved a logit by"
              & Model_Runner.Numerics.Real'Image (Apart));

      B.Free (Image);
   end Halved_Cache_Holds_Half;

   --  A mixture under the qwen3moe keys is read as one.
   --
   --  The sweep crosses llama, qwen2 and qwen3 with every format and path,
   --  and leaves this one out on purpose: it is qwen3 with its metadata
   --  under another prefix, so crossing it would buy one string comparison
   --  for a third of the run time. What it is worth checking on its own is
   --  exactly that the prefix is followed -- the expert count, the used
   --  count and the expert width are read under the architecture's own name,
   --  and a profile that looked for them under another would find a dense
   --  model and quietly evaluate one.
   procedure Mixture_Under_Its_Own_Keys
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      Image  : B.Byte_Array_Access;
      Result : Logit_Vector;
   begin
      Tiny_Model.Build
        (Image, Kind => Tiny_Model.Qwen3_MoE,
         Experts => 4, Experts_Used => 2);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);

         declare
            Read : constant L.Configuration := L.Config (Under.Ready);
         begin
            Assert (L."=" (Read.Kind, L.Qwen3_MoE),
                    "the architecture was not read from the file");
            Assert (Read.Experts = 4 and then Read.Experts_Used = 2,
                    "the expert counts were not read under the "
                    & "architecture's own keys:"
                    & Natural'Image (Read.Experts)
                    & Natural'Image (Read.Experts_Used));
         end;

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed: " & E.Error_Code'Image (Status.Code));
         end loop;

         L.Close (Live);
      end;

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed : Containers.Container;
         Status : E.Error_Info;
         Second : Reference_Transformer.Model;
         Loaded, Made : Boolean;

         Tokens   : Reference_Transformer.Token_Vector (Prompt'Range);
         Expected : Reference_Transformer.Real_Vector
           (0 .. Tiny_Model.Vocabulary - 1);
         Worst : Long_Float := 0.0;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         Reference_Transformer.Load (Second, Parsed, Held, Loaded);
         Assert (Loaded, "the reference did not read the model");

         for Index in Prompt'Range loop
            Tokens (Index) := Integer (Prompt (Index));
         end loop;

         Reference_Transformer.Run (Second, Tokens, Expected, Made);
         Assert (Made, "the reference produced no logits");

         for Index in Expected'Range loop
            Worst := Long_Float'Max
              (Worst,
               abs (Long_Float (Result
                      (Model_Runner.Numerics.Element_Count (Index)))
                    - Expected (Index)));
         end loop;

         Assert (Worst < 1.0E-3,
                 "the engine and the independent implementation disagree "
                 & "about a qwen3moe model by" & Long_Float'Image (Worst));

         Reference_Transformer.Close (Second);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Mixture_Under_Its_Own_Keys;

   --  Key and value heads may be different widths, and neither need be the
   --  embedding divided by the head count.
   --
   --  Three assumptions were built into the shape of every buffer: that a
   --  head is as wide as the embedding implies, that a key head and a value
   --  head are the same width, and that what attention produces is as wide
   --  as the embedding. A file may state otherwise, and this one does --
   --  key heads twice that width, value heads three times it.
   --
   --  What the sweep cannot say is that the file was read rather than
   --  ignored: a fixture whose widths never reached the engine would still
   --  agree with a reference that read the same file the same wrong way, as
   --  long as the tensors matched. So the widths are asserted where they
   --  land -- the model reports them, and the session holds a cache sized by
   --  them -- and then the answer is compared.
   procedure Head_Widths_May_Differ
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      Image  : B.Byte_Array_Access;
      Result : Logit_Vector;
   begin
      Tiny_Model.Build (Image, Apart_Widths => True);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);

         declare
            Read : constant L.Configuration := L.Config (Under.Ready);
         begin
            Assert (Read.Head_Size = 2 * Tiny_Model.Head_Size,
                    "the key width the file states was not read:"
                    & Natural'Image (Read.Head_Size));
            Assert (Read.Value_Size = 3 * Tiny_Model.Head_Size,
                    "the value width the file states was not read:"
                    & Natural'Image (Read.Value_Size));
         end;

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed: " & E.Error_Code'Image (Status.Code));
         end loop;

         L.Close (Live);
      end;

      --  And the answer is the one the independent implementation reaches
      --  from the same file.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed : Containers.Container;
         Status : E.Error_Info;
         Second : Reference_Transformer.Model;
         Loaded, Made : Boolean;

         Tokens   : Reference_Transformer.Token_Vector (Prompt'Range);
         Expected : Reference_Transformer.Real_Vector
           (0 .. Tiny_Model.Vocabulary - 1);
         Worst : Long_Float := 0.0;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         Reference_Transformer.Load (Second, Parsed, Held, Loaded);
         Assert (Loaded, "the reference did not read the model");

         for Index in Prompt'Range loop
            Tokens (Index) := Integer (Prompt (Index));
         end loop;

         Reference_Transformer.Run (Second, Tokens, Expected, Made);
         Assert (Made, "the reference produced no logits");

         for Index in Expected'Range loop
            Worst := Long_Float'Max
              (Worst,
               abs (Long_Float (Result
                      (Model_Runner.Numerics.Element_Count (Index)))
                    - Expected (Index)));
         end loop;

         Assert (Worst < 1.0E-3,
                 "the engine and the independent implementation disagree "
                 & "about separate head widths by" & Long_Float'Image (Worst));

         Reference_Transformer.Close (Second);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Head_Widths_May_Differ;

   --  Each way of stretching the rotation changes the answer, and to the
   --  answer written from the description.
   --
   --  The conformance sweep runs a model that declares yarn and carries a
   --  table of divisors at once, over every format and every path. What it
   --  cannot say is that either of them did anything: a fixture whose table
   --  never loaded would agree with a reference whose table never loaded.
   --  This holds one thing still at a time.
   --
   --  Four models: as trained, linearly stretched, stretched by yarn, and
   --  as trained but carrying the divisor table. Each has to differ from
   --  the one before it and to match the independent implementation.
   procedure Rotary_Scaling_Changes_The_Rotation
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array :=
        [1, 4, 5, 6, 7, 4, 5, 6];

      procedure Engine_Logits
        (Stretch : Tiny_Model.Rope_Stretch;
         Table   : Boolean;
         Result  : out Logit_Vector)
      is
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Stretch => Stretch, Rope_Table => Table);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Start (Under);
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            for Token of Prompt loop
               L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
               Assert (E.Is_Ok (Status),
                       "evaluation failed: "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            L.Close (Live);
         end;

         B.Free (Image);
      end Engine_Logits;

      procedure Reference_Logits
        (Stretch : Tiny_Model.Rope_Stretch;
         Table   : Boolean;
         Result  : out Reference_Transformer.Real_Vector)
      is
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Stretch => Stretch, Rope_Table => Table);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Status : E.Error_Info;
            Second : Reference_Transformer.Model;
            Loaded : Boolean;
            Made   : Boolean;

            Tokens : Reference_Transformer.Token_Vector (Prompt'Range);
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            Reference_Transformer.Load (Second, Parsed, Held, Loaded);
            Assert (Loaded, "the reference did not read the model");

            for Index in Prompt'Range loop
               Tokens (Index) := Integer (Prompt (Index));
            end loop;

            Reference_Transformer.Run (Second, Tokens, Result, Made);
            Assert (Made, "the reference produced no logits");

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Reference_Logits;

      --  How far apart two logit vectors are.
      function Apart (Left, Right : Logit_Vector) return Long_Float is
         Worst : Long_Float := 0.0;
      begin
         for Index in Left'Range loop
            Worst := Long_Float'Max
              (Worst, abs (Long_Float (Left (Index))
                           - Long_Float (Right (Index))));
         end loop;
         return Worst;
      end Apart;

      --  And how far the engine is from the implementation written from the
      --  description, for the same model.
      procedure Agrees
        (Stretch : Tiny_Model.Rope_Stretch;
         Table   : Boolean;
         About   : String;
         Result  : out Logit_Vector)
      is
         Expected : Reference_Transformer.Real_Vector
           (0 .. Tiny_Model.Vocabulary - 1);
         Worst : Long_Float := 0.0;
      begin
         Engine_Logits (Stretch, Table, Result);
         Reference_Logits (Stretch, Table, Expected);

         for Index in Expected'Range loop
            Worst := Long_Float'Max
              (Worst,
               abs (Long_Float (Result
                      (Model_Runner.Numerics.Element_Count (Index)))
                    - Expected (Index)));
         end loop;

         Assert (Worst < 1.0E-3,
                 "the engine and the independent implementation disagree "
                 & "about " & About & " by" & Long_Float'Image (Worst));
      end Agrees;

      Trained, Straight, Ramped, Divided : Logit_Vector;
   begin
      Agrees (Tiny_Model.Plain, False, "an unscaled rotation", Trained);
      Agrees (Tiny_Model.Linear, False, "a linear stretch", Straight);
      Agrees (Tiny_Model.Yarn, False, "a yarn stretch", Ramped);
      Agrees (Tiny_Model.Plain, True, "a table of divisors", Divided);

      Assert (Apart (Trained, Straight) > 0.0,
              "a model declaring a linear stretch computed what an unscaled "
              & "one computes, so the factor was not applied");

      Assert (Apart (Straight, Ramped) > 0.0,
              "a model declaring yarn computed what a linear stretch of the "
              & "same factor computes, so the ramp was not applied");

      Assert (Apart (Trained, Divided) > 0.0,
              "a model carrying a table of divisors computed what a model "
              & "without one computes, so the table was not read");
   end Rotary_Scaling_Changes_The_Rotation;

   --  A mixture of experts routes each position and mixes what it chose.
   --
   --  Three claims. The model has to run at all -- a router, four stacked
   --  expert matrices a layer and none of the dense ones the loader used to
   --  require. What it computes has to be the one an implementation written
   --  from the description arrives at. And the used count has to matter:
   --  a model that runs two experts and computes what one expert alone
   --  computes has routed nothing, which is what a mixture that ignores its
   --  own weights would look like from outside.
   --
   --  The comparison is exact rather than within a tolerance: binary32
   --  weights, no repacking, so the two run the same arithmetic and may
   --  differ only by summation order. The sweep in Conformance covers the
   --  mixture across every format, backend, repack mode and evaluation path.
   procedure Mixture_Of_Experts_Routes_Each_Position
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array :=
        [1, 4, 5, 6, 7, 4, 5, 6];

      Experts : constant := 4;

      --  The logits after the whole prompt, from the engine.
      procedure Engine_Logits
        (Used   : Natural;
         Result : out Logit_Vector)
      is
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Experts => Experts, Experts_Used => Used);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Start (Under);
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            for Token of Prompt loop
               L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
               Assert (E.Is_Ok (Status),
                       "evaluation failed: "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            L.Close (Live);
         end;

         B.Free (Image);
      end Engine_Logits;

      --  And from the implementation written from the description.
      procedure Reference_Logits
        (Used   : Natural;
         Result : out Reference_Transformer.Real_Vector;
         Made   : out Boolean)
      is
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Experts => Experts, Experts_Used => Used);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Status : E.Error_Info;
            Second : Reference_Transformer.Model;
            Loaded : Boolean;

            Tokens : Reference_Transformer.Token_Vector (Prompt'Range);
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            Reference_Transformer.Load (Second, Parsed, Held, Loaded);
            Assert (Loaded, "the reference did not read the model");

            for Index in Prompt'Range loop
               Tokens (Index) := Integer (Prompt (Index));
            end loop;

            Reference_Transformer.Run (Second, Tokens, Result, Made);
            Assert (Made, "the reference produced no logits");

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Reference_Logits;

      Alone, Mixed : Logit_Vector;
      Apart : Model_Runner.Numerics.Real := 0.0;
   begin
      Engine_Logits (1, Alone);
      Engine_Logits (2, Mixed);

      for Index in Alone'Range loop
         Apart := Model_Runner.Numerics.Real'Max
           (Apart, abs (Alone (Index) - Mixed (Index)));
      end loop;

      Assert (Apart > 0.0,
              "a model running two experts computed what one expert alone "
              & "computes, so the second one contributed nothing");

      --  And the mixed answer is the one the reference arrives at.
      declare
         Expected : Reference_Transformer.Real_Vector
           (0 .. Tiny_Model.Vocabulary - 1);
         Worst : Long_Float := 0.0;
         Made  : Boolean;
      begin
         Reference_Logits (2, Expected, Made);

         for Index in Expected'Range loop
            Worst := Long_Float'Max
              (Worst,
               abs (Long_Float (Mixed
                      (Model_Runner.Numerics.Element_Count (Index)))
                    - Expected (Index)));
         end loop;

         Assert (Worst < 1.0E-3,
                 "the engine and the independent implementation disagree "
                 & "about a mixture of experts by" & Long_Float'Image (Worst));
      end;
   end Mixture_Of_Experts_Routes_Each_Position;

   --  A sliding window narrows what a position may attend to.
   --
   --  Two claims, and the second is worthless without the first. The window
   --  has to change the answer -- a model that declares one and computes the
   --  same logits as a model that does not has not implemented anything --
   --  and the answer it changes to has to be the one an implementation
   --  written from the description arrives at independently.
   --
   --  The comparison is exact rather than within a tolerance: no repacking,
   --  binary32 weights, so the two run the same arithmetic on the same
   --  values and may differ only by summation order. The sweep in
   --  Conformance covers the window across every format, backend and repack
   --  mode; this is the sharp case, where the window is two and every
   --  position past the second has something to forget.
   procedure Sliding_Window_Narrows_Attention
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array :=
        [1, 4, 5, 6, 7, 4, 5, 6];

      --  The logits after the whole prompt, from the engine.
      procedure Engine_Logits
        (Window : Natural;
         Result : out Logit_Vector)
      is
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build (Image, Window => Window);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Start (Under);
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            for Token of Prompt loop
               L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
               Assert (E.Is_Ok (Status),
                       "evaluation failed: "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            L.Close (Live);
         end;

         B.Free (Image);
      end Engine_Logits;

      --  And from the implementation written from the description.
      procedure Reference_Logits
        (Window : Natural;
         Result : out Reference_Transformer.Real_Vector;
         Made   : out Boolean)
      is
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build (Image, Window => Window);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Status : E.Error_Info;
            Second : Reference_Transformer.Model;
            Loaded : Boolean;

            Tokens : Reference_Transformer.Token_Vector (Prompt'Range);
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            Reference_Transformer.Load (Second, Parsed, Held, Loaded);
            Assert (Loaded, "the reference did not read the model");

            for Index in Prompt'Range loop
               Tokens (Index) := Integer (Prompt (Index));
            end loop;

            Reference_Transformer.Run (Second, Tokens, Result, Made);
            Assert (Made, "the reference produced no logits");

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Reference_Logits;

      Windowed, Whole : Logit_Vector;
      Apart : Model_Runner.Numerics.Real := 0.0;
   begin
      Engine_Logits (0, Whole);
      Engine_Logits (2, Windowed);

      for Index in Whole'Range loop
         Apart := Model_Runner.Numerics.Real'Max
           (Apart, abs (Whole (Index) - Windowed (Index)));
      end loop;

      Assert (Apart > 0.0,
              "a model declaring a window of two produced the logits of a "
              & "model with no window, so the window narrowed nothing");

      --  And the narrowed answer is the one the reference arrives at.
      declare
         Expected : Reference_Transformer.Real_Vector
           (0 .. Tiny_Model.Vocabulary - 1);
         Worst : Long_Float := 0.0;
         Made  : Boolean;
      begin
         Reference_Logits (2, Expected, Made);

         for Index in Expected'Range loop
            Worst := Long_Float'Max
              (Worst,
               abs (Long_Float (Windowed
                      (Model_Runner.Numerics.Element_Count (Index)))
                    - Expected (Index)));
         end loop;

         Assert (Worst < 1.0E-3,
                 "the engine and the independent implementation disagree "
                 & "about a windowed model by" & Long_Float'Image (Worst));
      end;
   end Sliding_Window_Narrows_Attention;

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

   --  Head_Dot's two paths answer the same thing.
   --
   --  The insertion is what the attention scores are computed with wherever
   --  the host has the wide lanes, and the loop below it is what they are
   --  computed with everywhere else. The two are not bit for bit -- the
   --  insertion keeps eight binary32 lanes and folds them at the end, the
   --  loop keeps one binary64 sum -- so what is asserted is that they agree
   --  to what binary32 can hold, which is the bound the conformance sweep
   --  holds the whole evaluator to and the same bound the device's scores
   --  are held to.
   --
   --  Use_Wide_Lanes is what the backend calls once at elaboration and what
   --  this drives directly. On a host without the instructions the wide
   --  path is never entered: turning it on there would run instructions the
   --  processor has not got, so this asks the host the same question the
   --  backend asks and does nothing where the answer is no.
   --
   --  The spans that are not a multiple of eight and the ones that leave
   --  their vector are here too, because both are answered by the guard
   --  rather than by the arithmetic.
   procedure Both_Head_Dots_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Wide : constant Boolean := Model_Runner.Platform.Wide_Vectors;

      Spans  : constant array (1 .. 6) of N.Element_Count :=
        [8, 16, 64, 128, 7, 33];
      Starts : constant array (1 .. 3) of N.Element_Count := [0, 1, 64];

      Room : constant N.Element_Count := 256;
      Left  : N.Real_Array (0 .. Room - 1);
      Right : N.Real_Array (0 .. Room - 1);

      Seen : Natural := 0;
   begin
      --  Values that use a range rather than a constant, so that a path
      --  reading the wrong elements answers differently rather than
      --  accidentally the same.
      for Index in Left'Range loop
         Left (Index) :=
           N.Real (Integer (Index) mod 13) - 6.0
           + N.Real (Integer (Index) mod 5) * 0.125;
         Right (Index) :=
           N.Real (Integer (Index) mod 7) - 3.0
           - N.Real (Integer (Index) mod 11) * 0.0625;
      end loop;

      --  Sixty-four is the head width this model uses; the others say the
      --  answer does not depend on it, and the two that are not a multiple
      --  of eight say the guard sends them to the loop.
      for Span of Spans loop
         for At_Left of Starts loop
            declare
               Plain, Chosen : N.Real;
               Bound : constant N.Real := 1.0e-4 * N.Real (Span);
            begin
               MK.Use_Wide_Lanes (False);
               Plain := MK.Head_Dot (Left, At_Left, Right, 0, Span);

               MK.Use_Wide_Lanes (Wide);
               Chosen := MK.Head_Dot (Left, At_Left, Right, 0, Span);

               Assert (abs (Plain - Chosen) <= Bound,
                       "the two dot products disagree at span"
                       & N.Element_Count'Image (Span) & " from"
                       & N.Element_Count'Image (At_Left) & ":"
                       & N.Real'Image (Plain) & " against"
                       & N.Real'Image (Chosen));

               Seen := Seen + 1;
            end;
         end loop;
      end loop;

      --  A span that leaves its vector is refused rather than read, on
      --  either path, and an empty one likewise.
      for Allowed in Boolean'Range loop
         MK.Use_Wide_Lanes (Allowed and Wide);

         Assert (MK.Head_Dot (Left, Room - 8, Right, 0, 16) = 0.0,
                 "a span past the end of the left vector was answered");
         Assert (MK.Head_Dot (Left, 0, Right, Room - 8, 16) = 0.0,
                 "a span past the end of the right vector was answered");
         Assert (MK.Head_Dot (Left, 0, Right, 0, 0) = 0.0,
                 "an empty span was answered");
      end loop;

      MK.Use_Wide_Lanes (Wide);
      Assert (Seen = 18, "a span was not compared");
   end Both_Head_Dots_Agree;

   --  Blend_Run's two paths agree, and both refuse what leaves a vector.
   --
   --  Not bit for bit: the insertion fuses the multiply and the add, so a
   --  product is rounded once where the loop rounds it twice, and the
   --  fused one is the more accurate. What is asserted is that they agree
   --  to what binary32 holds over the number of positions a run sums.
   --
   --  Sixty-four components is the width the insertion is written for and
   --  the width this model's heads have; the other two say the guard sends
   --  a different width to the loop and that the loop is what answers it.
   procedure Both_Blend_Runs_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Wide : constant Boolean := Model_Runner.Platform.Wide_Vectors;

      Spans : constant array (1 .. 3) of N.Element_Count := [64, 32, 17];

      Stride : constant N.Element_Count := 96;
      Steps  : constant N.Element_Count := 40;

      Weights : N.Real_Array (0 .. Steps - 1);
      Values  : N.Real_Array (0 .. Stride * Steps - 1);

      Seen : Natural := 0;
   begin
      for Index in Weights'Range loop
         Weights (Index) :=
           N.Real (Integer (Index) mod 9) * 0.125 - 0.5;
      end loop;

      for Index in Values'Range loop
         Values (Index) :=
           N.Real (Integer (Index) mod 23) - 11.0
           + N.Real (Integer (Index) mod 7) * 0.0625;
      end loop;

      for Span of Spans loop
         declare
            Plain, Chosen : N.Real_Array (0 .. Span - 1) := [others => 0.0];
            Bound : constant N.Real := 1.0e-3 * N.Real (Steps);
         begin
            MK.Use_Wide_Lanes (False);
            MK.Blend_Run (Plain, Weights, 0, Values, 0, Stride, Steps);

            MK.Use_Wide_Lanes (Wide);
            MK.Blend_Run (Chosen, Weights, 0, Values, 0, Stride, Steps);

            for Component in Plain'Range loop
               Assert (abs (Plain (Component) - Chosen (Component)) <= Bound,
                       "the two blends disagree at span"
                       & N.Element_Count'Image (Span) & " component"
                       & N.Element_Count'Image (Component) & ":"
                       & N.Real'Image (Plain (Component)) & " against"
                       & N.Real'Image (Chosen (Component)));
            end loop;

            Seen := Seen + 1;
         end;
      end loop;

      --  A run that would read past the values, a stride narrower than the
      --  run, and no positions at all: each leaves the sums untouched on
      --  either path rather than reading what it was not given.
      for Allowed in Boolean'Range loop
         MK.Use_Wide_Lanes (Allowed and Wide);

         declare
            Sums : N.Real_Array (0 .. 63) := [others => 7.0];

            function Untouched return Boolean is
              (for all Component of Sums => Component = 7.0);
         begin
            MK.Blend_Run (Sums, Weights, 0, Values, 0, Stride, Steps + 1);
            Assert (Untouched, "a run past the end of the values was taken");

            MK.Blend_Run (Sums, Weights, 0, Values, 0, 32, Steps);
            Assert (Untouched, "a stride narrower than the run was taken");

            MK.Blend_Run (Sums, Weights, 0, Values, 0, Stride, 0);
            Assert (Untouched, "a run of no positions was taken");
         end;
      end loop;

      MK.Use_Wide_Lanes (Wide);
      Assert (Seen = Spans'Length, "a span was not compared");
   end Both_Blend_Runs_Agree;

   --  The same, for a cache kept at half precision: the narrow kernels
   --  answer what the scalar path answers, within what half precision can
   --  say.
   procedure Both_Halved_Kernels_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Wide : constant Boolean := Model_Runner.Platform.Wide_Vectors;

      Stride : constant N.Element_Count := 96;
      Steps  : constant N.Element_Count := 40;
      Span   : constant N.Element_Count := 64;

      Weights : N.Real_Array (0 .. Steps - 1);
      Values  : N.Half_Array (0 .. Stride * Steps - 1);
      Query   : N.Real_Array (0 .. Span - 1);

      Seen : Natural := 0;
   begin
      for Index in Weights'Range loop
         Weights (Index) :=
           N.Real (Integer (Index) mod 9) * 0.125 - 0.5;
      end loop;

      for Index in Query'Range loop
         Query (Index) := N.Real (Integer (Index) mod 11) * 0.25 - 1.25;
      end loop;

      --  Values a half can hold exactly, so that the two paths differ only
      --  in how they add and not in what they were given.
      for Index in Values'Range loop
         Values (Index) :=
           N.To_Half (N.Real (Integer (Index) mod 17) * 0.5 - 4.0);
      end loop;

      declare
         Plain, Chosen : N.Real_Array (0 .. Span - 1) := [others => 0.0];
         Bound : constant N.Real := 1.0e-3 * N.Real (Steps);
      begin
         MK.Use_Wide_Lanes (False);
         MK.Blend_Run_Halved (Plain, Weights, 0, Values, 0, Stride, Steps);

         MK.Use_Wide_Lanes (Wide);
         MK.Blend_Run_Halved (Chosen, Weights, 0, Values, 0, Stride, Steps);

         for Component in Plain'Range loop
            Assert (abs (Plain (Component) - Chosen (Component)) <= Bound,
                    "the two halved blends disagree at component"
                    & N.Element_Count'Image (Component) & ":"
                    & N.Real'Image (Plain (Component)) & " against"
                    & N.Real'Image (Chosen (Component)));
         end loop;

         Seen := Seen + 1;
      end;

      declare
         Bound : constant N.Real := 1.0e-2;
         Flat, Lane : N.Real;
      begin
         MK.Use_Wide_Lanes (False);
         Flat := MK.Head_Dot_Halved (Query, 0, Values, 0, Span);

         MK.Use_Wide_Lanes (Wide);
         Lane := MK.Head_Dot_Halved (Query, 0, Values, 0, Span);

         Assert (abs (Flat - Lane) <= Bound,
                 "the two halved dot products disagree:"
                 & N.Real'Image (Flat) & " against" & N.Real'Image (Lane));

         Seen := Seen + 1;
      end;

      --  And the refusals, which are the exact kernels' refusals: a run
      --  past the end of the values, a stride narrower than the run, and no
      --  positions at all leave the sums alone on either path.
      for Allowed in Boolean'Range loop
         MK.Use_Wide_Lanes (Allowed and Wide);

         declare
            Sums : N.Real_Array (0 .. Span - 1) := [others => 7.0];

            function Untouched return Boolean is
              (for all Component of Sums => Component = 7.0);
         begin
            MK.Blend_Run_Halved
              (Sums, Weights, 0, Values, 0, Stride, Steps + 1);
            Assert (Untouched, "a halved run past the values was taken");

            MK.Blend_Run_Halved (Sums, Weights, 0, Values, 0, 32, Steps);
            Assert (Untouched, "a halved stride under the run was taken");

            MK.Blend_Run_Halved (Sums, Weights, 0, Values, 0, Stride, 0);
            Assert (Untouched, "a halved run of no positions was taken");

            Assert (MK.Head_Dot_Halved (Query, 0, Values, 0, 0) = 0.0,
                    "a halved dot product of no components was taken");
         end;
      end loop;

      MK.Use_Wide_Lanes (Wide);
      Assert (Seen = 2, "a halved kernel was not compared");
   end Both_Halved_Kernels_Agree;

   --  And for a context kept as one byte an element with a scale a row.
   procedure Both_Byte_Kernels_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;
      package MB renames Model_Runner.Bytes;


      Wide : constant Boolean := Model_Runner.Platform.Wide_Vectors;

      Stride : constant N.Element_Count := 96;
      Steps  : constant N.Element_Count := 40;
      Span   : constant N.Element_Count := 64;

      Weights : N.Real_Array (0 .. Steps - 1);
      Scales  : N.Real_Array (0 .. Steps - 1);
      Query   : N.Real_Array (0 .. Span - 1);
      Values  : MB.Byte_Array (0 .. MB.Byte_Count (Stride * Steps) - 1);

      Seen : Natural := 0;
   begin
      for Index in Weights'Range loop
         Weights (Index) :=
           N.Real (Integer (Index) mod 9) * 0.125 - 0.5;
         Scales (Index) := 0.0625 + N.Real (Integer (Index) mod 5) * 0.03125;
      end loop;

      for Index in Query'Range loop
         Query (Index) := N.Real (Integer (Index) mod 11) * 0.25 - 1.25;
      end loop;

      for Index in Values'Range loop
         Values (Index) := MB.Byte (Integer (Index) mod 251);
      end loop;

      declare
         Plain, Chosen : N.Real_Array (0 .. Span - 1) := [others => 0.0];
         Bound : constant N.Real := 1.0e-2 * N.Real (Steps);
      begin
         MK.Use_Wide_Lanes (False);
         MK.Blend_Run_Eighth
           (Plain, Weights, 0, Scales, 0, Values, 0, Stride, Steps);

         MK.Use_Wide_Lanes (Wide);
         MK.Blend_Run_Eighth
           (Chosen, Weights, 0, Scales, 0, Values, 0, Stride, Steps);

         for Component in Plain'Range loop
            Assert (abs (Plain (Component) - Chosen (Component)) <= Bound,
                    "the two byte blends disagree at component"
                    & N.Element_Count'Image (Component) & ":"
                    & N.Real'Image (Plain (Component)) & " against"
                    & N.Real'Image (Chosen (Component)));
         end loop;

         Seen := Seen + 1;
      end;

      declare
         Bound : constant N.Real := 1.0e-2;
         Flat, Lane : N.Real;
      begin
         MK.Use_Wide_Lanes (False);
         Flat := MK.Head_Dot_Eighth (Query, 0, Values, 0, 0.125, Span);

         MK.Use_Wide_Lanes (Wide);
         Lane := MK.Head_Dot_Eighth (Query, 0, Values, 0, 0.125, Span);

         Assert (abs (Flat - Lane) <= Bound,
                 "the two byte dot products disagree:"
                 & N.Real'Image (Flat) & " against" & N.Real'Image (Lane));

         Seen := Seen + 1;
      end;

      for Allowed in Boolean'Range loop
         MK.Use_Wide_Lanes (Allowed and Wide);

         declare
            Sums : N.Real_Array (0 .. Span - 1) := [others => 7.0];

            function Untouched return Boolean is
              (for all Component of Sums => Component = 7.0);
         begin
            MK.Blend_Run_Eighth
              (Sums, Weights, 0, Scales, 0, Values, 0, Stride, Steps + 1);
            Assert (Untouched, "a byte run past the values was taken");

            MK.Blend_Run_Eighth
              (Sums, Weights, 0, Scales, 0, Values, 0, 32, Steps);
            Assert (Untouched, "a byte stride under the run was taken");

            MK.Blend_Run_Eighth
              (Sums, Weights, 0, Scales, 0, Values, 0, Stride, 0);
            Assert (Untouched, "a byte run of no positions was taken");

            Assert (MK.Head_Dot_Eighth (Query, 0, Values, 0, 0.125, 0) = 0.0,
                    "a byte dot product of no components was taken");
         end;
      end loop;

      MK.Use_Wide_Lanes (Wide);
      Assert (Seen = 2, "a byte kernel was not compared");
   end Both_Byte_Kernels_Agree;

   --  Rotating a position's queries and its keys together is what rotating
   --  them apart gives, to the bit: the angles are the same for both and the
   --  pair call computes them once.
   procedure Both_Rotations_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Heads     : constant N.Element_Count := 4;
      Key_Heads : constant N.Element_Count := 2;
      Head_Size : constant N.Element_Count := 16;
      Rotary    : constant N.Element_Count := 16;

      function Made (Count : N.Element_Count) return N.Real_Array;

      function Made (Count : N.Element_Count) return N.Real_Array is
         Out_Of : N.Real_Array (0 .. Count * Head_Size - 1);
      begin
         for Index in Out_Of'Range loop
            Out_Of (Index) :=
              N.Real (Integer (Index) mod 13) * 0.25 - 1.5;
         end loop;
         return Out_Of;
      end Made;

      Seen : Natural := 0;
   begin
      for Place in 0 .. 3 loop
         for Pairing in MK.Rotary_Pairing'Range loop
            declare
               Query_Apart : N.Real_Array := Made (Heads);
               Key_Apart   : N.Real_Array := Made (Key_Heads);
               Query_Pair  : N.Real_Array := Made (Heads);
               Key_Pair    : N.Real_Array := Made (Key_Heads);

               Position : constant Natural := Place * 37;
            begin
               MK.Apply_Rotary
                 (Query_Apart, Heads, Head_Size, Rotary, Position,
                  10_000.0, Pairing => Pairing);
               MK.Apply_Rotary
                 (Key_Apart, Key_Heads, Head_Size, Rotary, Position,
                  10_000.0, Pairing => Pairing);

               MK.Apply_Rotary_Pair
                 (Query_Pair, Heads, Key_Pair, Key_Heads, Head_Size, Rotary,
                  Position, 10_000.0, Pairing => Pairing);

               for Index in Query_Apart'Range loop
                  Assert (Query_Pair (Index) = Query_Apart (Index),
                          "the paired rotation moved a query at position"
                          & Natural'Image (Position) & " element"
                          & N.Element_Count'Image (Index));
               end loop;

               for Index in Key_Apart'Range loop
                  Assert (Key_Pair (Index) = Key_Apart (Index),
                          "the paired rotation moved a key at position"
                          & Natural'Image (Position) & " element"
                          & N.Element_Count'Image (Index));
               end loop;

               Seen := Seen + 1;
            end;
         end loop;
      end loop;

      --  And a second vector of no heads, which is what the single-vector
      --  call asks for: the first is rotated and nothing else is touched.
      declare
         One     : N.Real_Array := Made (Heads);
         Another : N.Real_Array := Made (Heads);
         Empty   : N.Real_Array (1 .. 0);
      begin
         MK.Apply_Rotary (One, Heads, Head_Size, Rotary, 5, 10_000.0);
         MK.Apply_Rotary_Pair
           (Another, Heads, Empty, 0, Head_Size, Rotary, 5, 10_000.0);

         for Index in One'Range loop
            Assert (One (Index) = Another (Index),
                    "a pair with no second vector rotated the first "
                    & "differently at element"
                    & N.Element_Count'Image (Index));
         end loop;
      end;

      Assert (Seen = 8, "a position or pairing was not compared");
   end Both_Rotations_Agree;

   --  A run of scores answers what one at a time answers.
   --
   --  Head_Scores folds eight accumulators together where Head_Dot folds
   --  one, so the two are not bit for bit and the ordering of that fold is
   --  exactly what could be silently wrong: a reduction that pairs the
   --  wrong lanes gives plausible numbers in the wrong places. So this
   --  checks every score of a run against the one Head_Dot gives for the
   --  same key, which catches a permutation where a total would not.
   --
   --  Runs that are not a multiple of eight, and a head that is not
   --  sixty-four wide, are here because both go down the tail path a score
   --  at a time and that path is the one every host without the wide lanes
   --  takes for all of them.
   procedure Score_Runs_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Wide : constant Boolean := Model_Runner.Platform.Wide_Vectors;

      Stride : constant N.Element_Count := 80;
      Steps  : constant N.Element_Count := 27;

      Spans : constant array (1 .. 2) of N.Element_Count := [64, 40];

      Query : N.Real_Array (0 .. 63);
      Keys  : N.Real_Array (0 .. Stride * Steps - 1);

      Seen : Natural := 0;
   begin
      for Index in Query'Range loop
         Query (Index) :=
           N.Real (Integer (Index) mod 11) * 0.25 - 1.5;
      end loop;

      for Index in Keys'Range loop
         Keys (Index) :=
           N.Real (Integer (Index) mod 17) * 0.125 - 1.0
           + N.Real (Integer (Index) mod 5) * 0.03125;
      end loop;

      for Span of Spans loop
         declare
            Scale  : constant N.Real := 0.125;
            Run    : N.Real_Array (0 .. Steps - 1) := [others => 0.0];
            Bound  : constant N.Real := 1.0e-3;
         begin
            MK.Use_Wide_Lanes (Wide);
            MK.Head_Scores
              (Query, 0, Keys, 0, Stride, Steps, Span, Scale, Run, 0);

            for Step in 0 .. Steps - 1 loop
               declare
                  Said : constant N.Real :=
                    MK.Head_Dot (Query, 0, Keys, Step * Stride, Span) * Scale;
               begin
                  Assert (abs (Run (Step) - Said) <= Bound,
                          "the run and the single dot disagree at span"
                          & N.Element_Count'Image (Span) & " step"
                          & N.Element_Count'Image (Step) & ":"
                          & N.Real'Image (Run (Step)) & " against"
                          & N.Real'Image (Said));
                  Seen := Seen + 1;
               end;
            end loop;
         end;
      end loop;

      --  A run that would read past the keys leaves the scores alone
      --  rather than reading what it was not given.
      declare
         Run : N.Real_Array (0 .. Steps - 1) := [others => 9.0];

         function Untouched return Boolean is
           (for all Score of Run => Score = 9.0);
      begin
         MK.Head_Scores
           (Query, 0, Keys, 0, Stride, Steps + 1, 64, 1.0, Run, 0);
         Assert (Untouched, "a run past the end of the keys was taken");

         MK.Head_Scores (Query, 0, Keys, 0, 32, Steps, 64, 1.0, Run, 0);
         Assert (Untouched, "a stride narrower than the head was taken");
      end;

      Assert (Seen = Natural (Steps) * Spans'Length,
              "a step was not compared");
   end Score_Runs_Agree;

   --  Every head at once answers what one head at a time answers.
   --
   --  Head_Scores_Across is the same run issued from the same string, so
   --  this is a bit-for-bit comparison rather than a bounded one: what it
   --  is really checking is the address arithmetic that replaced the two
   --  loops in the caller. A head reads its query at one offset, its keys
   --  at another that only moves every Share heads, and writes at a third,
   --  and getting any of the three wrong gives a plausible run of numbers
   --  in the wrong place.
   --
   --  From_Head is not a multiple of Share on purpose. The heads are shared
   --  out between workers without regard for the groups, so a slice that
   --  starts partway into a group is the ordinary case rather than an edge
   --  one, and it is the case the group counter inside can get wrong.
   --
   --  A run that is not a multiple of eight and a head that is not
   --  sixty-four wide are here for the same reason they are in the test
   --  above: both take the tail path, which is what every host without the
   --  wide lanes takes for everything.
   procedure Scores_Across_Heads_Agree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Wide : constant Boolean := Model_Runner.Platform.Wide_Vectors;

      Heads  : constant N.Element_Count := 8;
      Share  : constant N.Element_Count := 3;
      Room   : constant N.Element_Count := 40;
      Steps  : constant N.Element_Count := 27;
      Stride : constant N.Element_Count := 256;

      Spans : constant array (1 .. 2) of N.Element_Count := [64, 40];

      Query : N.Real_Array (0 .. Heads * 64 - 1);
      Keys  : N.Real_Array (0 .. Stride * Steps - 1);

      Seen : Natural := 0;
   begin
      for Index in Query'Range loop
         Query (Index) :=
           N.Real (Integer (Index) mod 13) * 0.25 - 1.5;
      end loop;

      for Index in Keys'Range loop
         Keys (Index) :=
           N.Real (Integer (Index) mod 17) * 0.125 - 1.0
           + N.Real (Integer (Index) mod 5) * 0.03125;
      end loop;

      MK.Use_Wide_Lanes (Wide);

      for Span of Spans loop
         declare
            Scale : constant N.Real := 0.125;
            First : constant N.Element_Count := 2;
            Last  : constant N.Element_Count := Heads - 1;

            Across : N.Real_Array (0 .. Heads * Room - 1) := [others => 9.0];
            Apiece : N.Real_Array (0 .. Heads * Room - 1) := [others => 9.0];
         begin
            MK.Head_Scores_Across
              (Query     => Query,
               At_Query  => 0,
               Keys      => Keys,
               At_Key    => 0,
               Stride    => Stride,
               Steps     => Steps,
               Span      => Span,
               From_Head => First,
               To_Head   => Last,
               Share     => Share,
               Room      => Room,
               Scale     => Scale,
               Scores    => Across,
               At_Score  => 0);

            for Head in First .. Last loop
               MK.Head_Scores
                 (Query    => Query,
                  At_Query => Head * Span,
                  Keys     => Keys,
                  At_Key   => (Head / Share) * Span,
                  Stride   => Stride,
                  Steps    => Steps,
                  Span     => Span,
                  Scale    => Scale,
                  Scores   => Apiece,
                  At_Score => Head * Room);
            end loop;

            for Index in Across'Range loop
               Assert (Across (Index) = Apiece (Index),
                       "the heads taken together and one at a time "
                       & "disagree at span"
                       & N.Element_Count'Image (Span) & " element"
                       & N.Element_Count'Image (Index) & ":"
                       & N.Real'Image (Across (Index)) & " against"
                       & N.Real'Image (Apiece (Index)));
               Seen := Seen + 1;
            end loop;

            --  And the heads outside the slice were not written.
            for Head in 0 .. First - 1 loop
               for Step in 0 .. Room - 1 loop
                  Assert (Across (Head * Room + Step) = 9.0,
                          "a head outside the slice was scored");
               end loop;
            end loop;
         end;
      end loop;

      --  A call that would read past the keys, or write past the scores,
      --  leaves them alone rather than reading what it was not given.
      declare
         Room  : constant N.Element_Count := Steps;
         Run   : N.Real_Array (0 .. Heads * Room - 1) := [others => 9.0];

         function Untouched return Boolean is
           (for all Score of Run => Score = 9.0);
      begin
         MK.Head_Scores_Across
           (Query, 0, Keys, 0, Stride, Steps + 1, 64,
            0, Heads - 1, Share, Room, 1.0, Run, 0);
         Assert (Untouched, "a run past the end of the keys was taken");

         MK.Head_Scores_Across
           (Query, 0, Keys, 0, 32, Steps, 64,
            0, Heads - 1, Share, Room, 1.0, Run, 0);
         Assert (Untouched, "a stride narrower than the head was taken");

         MK.Head_Scores_Across
           (Query, 0, Keys, 0, Stride, Steps, 64,
            0, Heads, Share, Room, 1.0, Run, 0);
         Assert (Untouched, "a head past the end of the queries was taken");

         MK.Head_Scores_Across
           (Query, 0, Keys, 0, Stride, Steps, 64,
            0, Heads - 1, 0, Room, 1.0, Run, 0);
         Assert (Untouched, "a share of no heads was taken");
      end;

      Assert (Seen = Natural (Heads * Room) * Spans'Length,
              "a score was not compared");
   end Scores_Across_Heads_Agree;

   --  The vectorized exponential answers what the library's does.
   --
   --  Not bit for bit and not meant to be: this is a degree five polynomial
   --  in binary32 where the library's is binary64, which is the whole point
   --  of it. What is asserted is a relative agreement of a few parts in a
   --  million over the range a softmax actually hands it -- the scores of
   --  an attention row less the largest of them, so zero down to well past
   --  where binary32 gives up.
   --
   --  The floor is the case worth naming. Below eighty-seven the true value
   --  is smaller than binary32 holds, and what matters is that the answer
   --  is a very small number or zero rather than a large one: the exponent
   --  this builds would wrap rather than saturate if the floor were not
   --  there, and a score far behind the leader would come back ahead of it.
   procedure The_Exponential_Agrees
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package MK renames Model_Runner.Kernels;

      Room : constant N.Element_Count := 96;
      Run  : N.Real_Array (0 .. Room - 1);
      Want : N.Real_Array (0 .. Room - 1);
   begin
      --  Zero down to a hundred and twenty, which is past the floor.
      for Index in Run'Range loop
         Run (Index) := -1.25 * N.Real (Integer (Index));
         Want (Index) :=
           N.Real (N.Exp (N.Wide_Real (Run (Index))));
      end loop;

      MK.Exponentiate (Run, 0.0);

      for Index in Run'Range loop
         declare
            Got  : constant N.Real := Run (Index);
            Said : constant N.Real := Want (Index);
         begin
            --  Above the floor, a relative bound; below it, both are
            --  smaller than anything a softmax can be moved by, and what
            --  is asserted is only that neither has become large.
            if Said > 1.0e-30 then
               Assert (abs (Got - Said) <= 1.0e-5 * Said,
                       "the exponential disagrees at"
                       & N.Real'Image (-1.25 * N.Real (Integer (Index)))
                       & ":" & N.Real'Image (Got)
                       & " against" & N.Real'Image (Said));
            else
               Assert (Got >= 0.0 and then Got <= 1.0e-30,
                       "past the floor the exponential answered"
                       & N.Real'Image (Got) & ", which is not small");
            end if;
         end;
      end loop;

      --  And the subtraction it is given rather than doing itself: the
      --  largest element taken off leaves that element at one.
      declare
         Scores : N.Real_Array (0 .. 3) := [2.5, -1.0, 7.25, 0.0];
      begin
         MK.Exponentiate (Scores, 7.25);

         Assert (abs (Scores (2) - 1.0) <= 1.0e-6,
                 "the largest score did not come back as one:"
                 & N.Real'Image (Scores (2)));

         for Index in Scores'Range loop
            Assert (Scores (Index) > 0.0 and then Scores (Index) <= 1.0,
                    "a weight left the range a softmax needs:"
                    & N.Real'Image (Scores (Index)));
         end loop;
      end;
   end The_Exponential_Agrees;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Tokenizer_Matches_An_Independent_One'Access,
         "the tokenizer agrees with one written from the description");
      Register_Routine
        (T, Word_Piece_Matches_An_Independent_One'Access,
         "the WordPiece road agrees with one written from the description");
      Register_Routine
        (T, Byte_Pair_Matches_An_Independent_One'Access,
         "the byte-pair tokenizer agrees with one written from the "
         & "description");
      Register_Routine
        (T, Unigram_Matches_An_Independent_One'Access,
         "the unigram tokenizer agrees with one written from the "
         & "description");
      Register_Routine
        (T, Byte_Pair_Model_Runs_End_To_End'Access,
         "a byte-pair model prepares, evaluates and reads back");
      Register_Routine
        (T, Sliding_Window_Narrows_Attention'Access,
         "a sliding window narrows what a position may attend to");
      Register_Routine
        (T, Snapshot_Keeps_The_Two_Widths_Apart'Access,
         "a snapshot keeps the key and value widths apart");
      Register_Routine
        (T, Adapter_Changes_Which_Model_A_Context_Belongs_To'Access,
         "a context saved before an adapter was merged is not a context "
         & "after it was");
      Register_Routine
        (T, Halved_Cache_Snapshots_As_Halved'Access,
         "a snapshot of a halved cache is a halved cache");
      Register_Routine
        (T, Snapshot_Is_The_Session'Access,
         "a snapshot is the session it was taken from");
      Register_Routine
        (T, Adapter_Merges_Into_A_Tall_Weight'Access,
         "an adapter merges into a weight that is not square");
      Register_Routine
        (T, Adapter_Merges_What_It_Describes'Access,
         "merging an adapter is the arithmetic it claims");
      Register_Routine
        (T, Hidden_State_Is_Reported'Access,
         "the hidden state is reported, and refused when there is none");
      Register_Routine
        (T, Halved_Cache_Holds_Half'Access,
         "a half-precision cache holds half the bytes and answers the same");
      Register_Routine
        (T, Mixture_Under_Its_Own_Keys'Access,
         "a mixture under the qwen3moe keys is read as one");
      Register_Routine
        (T, Head_Widths_May_Differ'Access,
         "key and value heads may be different widths, and neither the "
         & "embedding divided by the head count");
      Register_Routine
        (T, Rotary_Scaling_Changes_The_Rotation'Access,
         "each way of stretching the rotation changes the answer, and to "
         & "the one written from the description");
      Register_Routine
        (T, Mixture_Of_Experts_Routes_Each_Position'Access,
         "a mixture of experts routes each position and mixes what it "
         & "chose");
      Register_Routine
        (T, One_Beginning_Token_However_It_Arrives'Access,
         "a prompt carries exactly one beginning token, however it arrives");
      Register_Routine
        (T, Unreached_Engine_Refusals_Are_Reached'Access,
         "refusals the engine had never been made to make are made");
      Register_Routine
        (T, Reused_Prefix_Changes_Nothing'Access,
         "reusing a committed prefix changes nothing about the answer");
      Register_Routine
        (T, Model_Prepares'Access,
         "the tiny model prepares and reports its configuration");
      Register_Routine
        (T, A_Position_Sees_What_Follows_It'Access,
         "a bidirectional model lets a position see what follows it");
      Register_Routine
        (T, A_Headless_Model_Refuses_What_It_Cannot_Say'Access,
         "a model with no head refuses a distribution, and half a text is "
         & "refused whole");
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
        (T, A_Refused_Evaluation_Is_Not_A_Clean_Sweep'Access,
         "a conformance run that could not evaluate something is not clean");
      Register_Routine
        (T, Interrupt_Requests_Cancellation'Access,
         "an interrupt requests cancellation instead of killing the process");

      Register_Routine
        (T, Refused_Generation_Names_Its_Reason'Access,
         "a generation the engine refuses is reported with the code it "
         & "refused with, not as a bare failure");
      Register_Routine
        (T, A_Shifted_Context_Saves_And_Restores'Access,
         "a context that has been shifted can be written out and read back "
         & "and answers the same afterwards");
      Register_Routine
        (T, Shifting_Moves_The_Positions'Access,
         "dropping the oldest positions renumbers what is left and lets the "
         & "run go on");
      Register_Routine
        (T, Adapters_Stack_And_Come_Off_Again'Access,
         "adapters stack, and a scale of minus one takes one off again");
      Register_Routine
        (T, Drafting_Shifts_When_The_Room_Runs_Out'Access,
         "a drafted run drops its oldest positions when the context fills, "
         & "as a run without a draft does");
      Register_Routine
        (T, Drafting_Runs_On_A_Device'Access,
         "a drafted run on the device backend says what the device says "
         & "without a draft");
      Register_Routine
        (T, Drafting_Reports_The_Same_Probabilities'Access,
         "asking what the model made of each position gets the same answer "
         & "with a draft as without one");
      Register_Routine
        (T, Drafting_Survives_A_Draft_That_Errs'Access,
         "a draft that guesses wrong changes how long the run takes and not "
         & "what it says");
      Register_Routine
        (T, Rewind_Gives_Back_Positions'Access,
         "a session put back to an earlier position evaluates from there "
         & "and gets what it would have got had it never gone further");
      Register_Routine
        (T, Drafting_Produces_The_Same_Text'Access,
         "a run with a draft model produces exactly the text of the same "
         & "run without one");
      Register_Routine
        (T, Sessions_On_One_Model_Do_Not_Collide'Access,
         "two sessions on one model, evaluated in turn, each get what they "
         & "would have got alone");
      Register_Routine
        (T, Round_Members_Get_What_They_Would_Alone'Access,
         "every member of a round gets, bit for bit, the logits it would "
         & "have got alone");
      Register_Routine
        (T, Device_Says_When_A_Model_Will_Not_Fit'Access,
         "a model whose matrices are larger than the device will hold is "
         & "refused while it loads, with both numbers");
      Register_Routine
        (T, Device_Reads_A_Model_In_Any_Format'Access,
         "a model in any format the program reads loads on the device, "
         & "without being repacked first");
      Register_Routine
        (T, Score_Runs_Agree'Access,
         "a run of attention scores answers what the same scores answer "
         & "taken one at a time");
      Register_Routine
        (T, Scores_Across_Heads_Agree'Access,
         "a slice of heads scored together answers what the same heads "
         & "answer one at a time");
      Register_Routine
        (T, The_Exponential_Agrees'Access,
         "the vectorized exponential answers what the library's does, over "
         & "the range a softmax hands it");
      Register_Routine
        (T, Both_Blend_Runs_Agree'Access,
         "one run of an attention head's output is the same whether the "
         & "host's wide lanes are used or not");
      Register_Routine
        (T, Both_Rotations_Agree'Access,
         "rotating a position's queries and keys together answers what "
         & "rotating them apart answers, to the bit");
      Register_Routine
        (T, Both_Byte_Kernels_Agree'Access,
         "the kernels that read a byte context answer what the scalar path "
         & "answers, wide lanes or not");
      Register_Routine
        (T, Both_Halved_Kernels_Agree'Access,
         "the kernels that read a half-precision context answer what the "
         & "scalar path answers, wide lanes or not");
      Register_Routine
        (T, Both_Head_Dots_Agree'Access,
         "the attention dot product answers the same whether the host's "
         & "wide lanes are used or not");
      Register_Routine
        (T, A_Budget_Accounts_For_A_Batch'Access,
         "a session asked for a budget says where a batch's time went, and "
         & "one not asked says nothing");
   end Register_Tests;

end Tests.Inference_Cases;
