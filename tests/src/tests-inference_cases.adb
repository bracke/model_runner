with Ada.Text_IO;

with AUnit.Assertions;

with Model_Runner.Lookup;
with Model_Runner.Text;
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
with Model_Runner.Serving;
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

   --  Greedily, which is the only rule a test can compare two runs by: the
   --  same prompt through the same rule is the same text, and anything else
   --  would be comparing two draws from a generator.
   function Best_Of (Row : Logit_Vector) return N.Element_Count;

   function Best_Of (Row : Logit_Vector) return N.Element_Count is
      Best : N.Element_Count := Row'First;
   begin
      for Index in Row'Range loop
         if Row (Index) > Row (Best) then
            Best := Index;
         end if;
      end loop;

      return Best;
   end Best_Of;

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
   procedure Start
     (Item    : in out Harness;
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Ready   : out Boolean)
   is
      Status : E.Error_Info;
   begin
      Ready := False;

      Containers.Reader.Parse (Item.Parsed, Item.Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "tiny model did not parse: "
              & E.Error_Code'Image (Status.Code));

      L.Prepare
        (Item.Ready, Item.Parsed, Item.Source,
         Backend => Backend, Status => Status);

      --  A machine with no device is not a failure of anything this asks
      --  about, and the caller is told rather than the test refused.
      if Status.Code = E.Backend_No_Device then
         return;
      end if;

      Assert (E.Is_Ok (Status),
              "tiny model did not prepare: "
              & E.Error_Code'Image (Status.Code));
      Assert (L.Is_Ready (Item.Ready), "model not marked ready");
      Ready := True;
   end Start;

   procedure Start (Item : in out Harness) is
      Ready : Boolean;
   begin
      Start (Item, Ready => Ready);
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

   --------------------------------------------------
   -- A_Fused_Layer_Is_Not_Charged_To_Attending --
   --------------------------------------------------

   --  A layer that went over to the device as one sequence is charged to
   --  Fusing, and to nothing else.
   --
   --  It used to be charged to Attending, and that made the budget say
   --  attending was the largest cost on the device -- 0.215 s of a 0.511 s
   --  run -- when an ablation of attention.comp puts attention at a
   --  thirtieth of it. A whole layer wearing one part's name is worse than
   --  no reading at all, because it is a reading somebody will act on: two
   --  entries of docs/measured-figures.txt did.
   --
   --  What this asks is only what can be asked without a clock: that the
   --  phase which grows with the context is not the one holding a whole
   --  layer. A machine with no device is told and not failed.
   procedure A_Fused_Layer_Is_Not_Charged_To_Attending
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Image : B.Byte_Array_Access;
   begin
      --  The quantized fixture rather than the narrow one: a layer goes
      --  over as a sequence only where the device keeps its matrices, and
      --  a seven-kilobyte model of binary32 is not worth keeping. This is
      --  the shape the trace says the device holds.
      Tiny_Model.Build (Image, Format => Tiny_Model.Q8_0);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         Able   : Boolean;
      begin
         --  The backend is a singleton and the suite leaves it closed, so
         --  this opens it rather than assuming somebody else did.
         declare
            Awake : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Awake);

            if not Awake then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "note: no device fused a layer here");
               B.Free (Image);
               return;
            end if;
         end;

         Start (Under, Model_Runner.Backend.Backend_Device, Able);

         if not Able then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device fused a layer here");
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "session did not open on the device");

         declare
            Settings : constant L.Configuration := L.Config (Under.Ready);
            Logits   : N.Real_Array
              (0 .. N.Element_Count (Settings.Vocabulary) - 1);
            Spent    : L.Phase_Times;
         begin
            --  A prompt first, unaccounted: a batch does not fuse and
            --  its attending is real attending, which would answer the
            --  question below with the wrong run's time.
            L.Evaluate_Batch
              (Live, Under.Ready, [0, 1, 2], Logits, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the device batch failed: "
                    & E.Error_Code'Image (Status.Code));

            --  And then a generated token, which is the shape that fuses:
            --  its layers go over one sequence each.
            L.Account (Live, True);

            L.Evaluate
              (Live, Under.Ready, 3, Logits, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the device step failed: "
                    & E.Error_Code'Image (Status.Code));

            Spent := L.Time_Spent (Live);

            --  Something was charged: a budget that measured nothing would
            --  pass the claim below by measuring nothing.
            declare
               Total : Duration := 0.0;
            begin
               for Phase in L.Phase loop
                  Total := Total + Spent (Phase);
               end loop;

               Assert (Total > 0.0,
                       "the device budget came back empty, so what it "
                       & "charges where cannot be asked");
            end;

            Assert (Spent (L.Fusing) > 0.0,
                    "a device that fuses a layer charged nothing to "
                    & "Fusing, so either it did not fuse or the whole "
                    & "layer is being charged somewhere else again");

            Assert (Spent (L.Attending) = 0.0,
                    "a fused layer was charged to Attending, which is the "
                    & "phase that grows with the context -- a whole layer "
                    & "under that name is what made the budget name "
                    & "attending as the device's largest cost");
         end;

         L.Close (Live);
         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end A_Fused_Layer_Is_Not_Charged_To_Attending;

   -------------------------------------------------
   -- A_Halved_Session_On_The_Device_Reads_The_Copy --
   -------------------------------------------------

   --  A session asking for halves on the device gets the device's halves:
   --  the host's copy of record stays exact, the device attends a token
   --  out of its half-precision copy, and the session says Halved for
   --  it. What it answers is held near what the exact session answers,
   --  not to the bit. And the next session opened exact takes the device
   --  back with it, since the device is told for the process.
   procedure A_Halved_Session_On_The_Device_Reads_The_Copy
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7];

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Format => Tiny_Model.Q8_0);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         Able   : Boolean;
         Awake  : Boolean;

         Exact, Halved : Logit_Vector;
         Worst         : N.Real := 0.0;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device attended out of its copy here");
            B.Free (Image);
            return;
         end if;

         Start (Under, Model_Runner.Backend.Backend_Device, Able);

         if not Able then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device attended out of its copy here");
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         --  Exact first, so the device is known not to be reading the
         --  copy before it is asked to.
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the exact session did not open");
         Assert (L."=" (L.Precision (Live), L.Exact),
                 "an exact session on the device says it is not");
         Assert (not Model_Runner.Backend.Device.Attends_In_Halves,
                 "the device reads its copy for an exact session");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Exact, Status => Status);
            Assert (E.Is_Ok (Status), "the exact evaluation failed");
         end loop;

         L.Close (Live);

         --  Then halves, which the device takes as its own.
         L.Open (Live, Under.Ready, Cache => L.Halved, Status => Status);
         Assert (E.Is_Ok (Status),
                 "the halved session did not open on the device: "
                 & E.Error_Code'Image (Status.Code));

         if not Model_Runner.Backend.Device.Attends_In_Halves then
            --  A device without the half-precision kernels: the session
            --  is exact and says so, and there is nothing more to ask.
            Assert (L."=" (L.Precision (Live), L.Exact),
                    "a session the device could not halve says Halved");
            L.Close (Live);
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         Assert (L."=" (L.Precision (Live), L.Halved),
                 "a session attending out of the copy says it is exact");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Halved, Status => Status);
            Assert (E.Is_Ok (Status), "the halved evaluation failed");
         end loop;

         for Index in Exact'Range loop
            Worst := N.Real'Max (Worst, abs (Exact (Index) - Halved (Index)));
         end loop;

         Assert (Worst < 5.0e-2,
                 "a token attending out of the copy answers"
                 & N.Real'Image (Worst) & " away from the exact session");

         L.Close (Live);

         --  Closing the session leaves the device as it was told: the
         --  device is told for the process, by whichever session opened
         --  last, and by a caller with no session at all.
         Assert (Model_Runner.Backend.Device.Attends_In_Halves,
                 "closing a halved session took the copy away from the "
                 & "device, which is told for the process");
         Model_Runner.Backend.Device.Attend_In_Halves (False);
         Assert (not Model_Runner.Backend.Device.Attends_In_Halves,
                 "the device kept reading its copy after being told not to");
         Model_Runner.Backend.Device.Attend_In_Halves (True);
         Assert (Model_Runner.Backend.Device.Attends_In_Halves,
                 "the device would not read its copy when told to directly");

         --  And an exact session opened after takes the device back.
         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the last exact session did not open");
         Assert (not Model_Runner.Backend.Device.Attends_In_Halves,
                 "the device kept reading its copy for an exact session");
         Assert (L."=" (L.Precision (Live), L.Exact),
                 "an exact session after a halved one says Halved");
         L.Close (Live);

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end A_Halved_Session_On_The_Device_Reads_The_Copy;

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

   --  A hybrid's linear layers keep a state instead of keys and values,
   --  and everything a session does with its context has to hold for it:
   --  a batch says what the tokens one at a time say, a snapshot carries
   --  the state and comes back saying the same, a rewind restores the
   --  state it kept and refuses where it kept none, and a shift is refused
   --  by name. The fixture is Tiny_Model's Qwen35: one linear layer and
   --  one full attention layer with a gate beside each head.
   procedure A_Hybrid_Keeps_Its_State_Through_Everything
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type L.Architecture;

      Image  : B.Byte_Array_Access;
      Prompt : constant Vocab.Token_Array (1 .. 5) := [4, 7, 2, 9, 5];

      Step_By_Step : Logit_Vector := [others => 0.0];
      Batched      : Logit_Vector := [others => 0.0];
      After_One    : Logit_Vector := [others => 0.0];
      After_Many   : Logit_Vector := [others => 0.0];
      Kept         : B.Byte_Array_Access;
      Direct       : Logit_Vector := [others => 0.0];
      Restored     : Logit_Vector := [others => 0.0];
      Rewound      : Logit_Vector := [others => 0.0];

      --  Not the bit: the linear layer runs the same words in both paths,
      --  but a batch's products are a batch's and a token's a token's.
      Near : constant N.Real := 1.0e-4;

      function Worst (A, B : Logit_Vector) return N.Real is
         Most : N.Real := 0.0;
      begin
         for Index in A'Range loop
            Most := N.Real'Max (Most, abs (A (Index) - B (Index)));
         end loop;
         return Most;
      end Worst;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Qwen35);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Status : E.Error_Info;
      begin
         Start (Under);

         declare
            Settings : constant L.Configuration := L.Config (Under.Ready);
         begin
            Assert (Settings.Kind = L.Qwen35, "the fixture is not read as qwen35");
            Assert (L.Hybrid (Settings.Kind), "qwen35 is not a hybrid");
            Assert (L.Linear (Settings, 0) and then not L.Linear (Settings, 1),
                    "the first block is not linear or the second is");
            Assert (L.Key_Width (Settings) = Tiny_Model.Linear_Heads * Tiny_Model.Linear_State
                    and then L.Value_Width (Settings) = L.Key_Width (Settings)
                    and then L.Mix_Width (Settings) = 3 * L.Key_Width (Settings),
                    "the linear layer's widths are not what the fixture wrote");
         end;

         --  One token at a time, then the same tokens in one batch.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the sequential session did not open");
            Assert (L.States_Kept (Live) = 0,
                    "a hybrid session keeps states it was not asked to");

            for Index in Prompt'Range loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Step_By_Step,
                  Status => Status);
               Assert (E.Is_Ok (Status), "sequential evaluation failed");
            end loop;
            L.Evaluate (Live, Under.Ready, 3, After_One, Status => Status);
            Assert (E.Is_Ok (Status), "the continuation failed");

            --  A shift is refused by name: the state has no middle to
            --  take out.
            L.Shift (Live, Under.Ready, Keep => 1, Drop => 2, Status => Status);
            Assert (Status.Code = E.Arch_Unsupported_Feature,
                    "a hybrid session took a shift: "
                    & E.Error_Code'Image (Status.Code));

            --  And a rewind past what it kept, which is nothing, is
            --  refused; to the front it is not, since the front is nought.
            L.Rewind (Live, 3, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "a rewind into an unkept state was taken: "
                    & E.Error_Code'Image (Status.Code));
            L.Rewind (Live, 0, Status);
            Assert (E.Is_Ok (Status), "a rewind to the front was refused");

            L.Close (Live);
         end;

         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the batched session did not open");
            L.Evaluate_Batch
              (Live, Under.Ready, Prompt, Batched, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the batch failed: " & E.Error_Code'Image (Status.Code));
            L.Evaluate (Live, Under.Ready, 3, After_Many, Status => Status);
            Assert (E.Is_Ok (Status), "the continuation after the batch failed");

            --  A snapshot from here, read back below.
            L.Snapshot (Live, Under.Ready, Kept, Status);
            Assert (E.Is_Ok (Status), "the hybrid session did not snapshot");
            L.Evaluate (Live, Under.Ready, 6, Direct, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation after the snapshot failed");
            L.Close (Live);
         end;

         Assert (Worst (Step_By_Step, Batched) <= Near,
                 "a batch says something else than the tokens one at a time:"
                 & N.Real'Image (Worst (Step_By_Step, Batched)));
         Assert (Worst (After_One, After_Many) <= Near,
                 "the state a batch leaves differs from the one the tokens "
                 & "leave:" & N.Real'Image (Worst (After_One, After_Many)));

         --  The snapshot back into a fresh session: the same next answer,
         --  exactly, since the state came back as it was.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the adopting session did not open");
            L.Adopt (Live, Under.Ready, Kept.all, Status);
            Assert (E.Is_Ok (Status),
                    "the hybrid snapshot was not adopted: "
                    & E.Error_Code'Image (Status.Code));
            L.Evaluate (Live, Under.Ready, 6, Restored, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation after adopting failed");
            L.Close (Live);
         end;

         Assert (Worst (Direct, Restored) = 0.0,
                 "a hybrid's state did not survive its snapshot; the "
                 & "logits moved by" & N.Real'Image (Worst (Direct, Restored)));

         --  Kept states: five tokens, back two, forward two again, and
         --  the answer is the one the straight run gave.
         declare
            Live : L.Session;
            Straight : Logit_Vector := [others => 0.0];
         begin
            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the rewinding session did not open");
            L.Keep_States (Live, 3, Status);
            Assert (E.Is_Ok (Status), "the session would not keep states");
            Assert (L.States_Kept (Live) = 3, "the session keeps another count");

            for Index in Prompt'Range loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Straight,
                  Status => Status);
               Assert (E.Is_Ok (Status), "evaluation with kept states failed");
            end loop;

            L.Rewind (Live, 3, Status);
            Assert (E.Is_Ok (Status),
                    "a rewind into the kept states was refused: "
                    & E.Error_Code'Image (Status.Code));
            L.Rewind (Live, 1, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "a rewind past the kept states was taken");

            for Index in 4 .. 5 loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Rewound,
                  Status => Status);
               Assert (E.Is_Ok (Status), "evaluation after the rewind failed");
            end loop;

            Assert (Worst (Straight, Rewound) = 0.0,
                    "the state a rewind restored is not the state that "
                    & "was there; the logits moved by"
                    & N.Real'Image (Worst (Straight, Rewound)));

            L.Close (Live);
         end;
      end;

      B.Free (Kept);
      B.Free (Image);
   end A_Hybrid_Keeps_Its_State_Through_Everything;

   --  The block past a hybrid's stack drafts the next token, and a run
   --  drafting from it says exactly what it says without.
   --
   --  The block is asked directly first: it answers only once the stack
   --  has a state to hand it, with a distribution and a state of its own
   --  that it takes back for one more draft, and it refuses a row of the
   --  wrong width by name. Then the run: at temperature zero a proposal
   --  is either what the stack would have chosen or it is not, and only
   --  the ones that match are kept, so the text is the same text -- and
   --  the round proposed rather than quietly falling back.
   procedure A_Hybrid_Drafts_From_Its_Next_Block
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      Room : constant := 64;

      Image  : B.Byte_Array_Access;
      Prompt : constant Vocab.Token_Array (1 .. 4) := [4, 7, 2, 9];
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Qwen35, Room => Room);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);
         Status : E.Error_Info;
      begin
         Start (Under);

         declare
            Settings : constant L.Configuration := L.Config (Under.Ready);
            Width    : constant N.Element_Count :=
              N.Element_Count (Settings.Embedding);
            Live     : L.Session;
            Logits   : Logit_Vector := [others => 0.0];
            Drafted  : Logit_Vector := [others => 0.0];
            Chained  : Logit_Vector := [others => 0.0];
            Nothing  : N.Real_Array (1 .. 0);
            State    : N.Real_Array (0 .. Width - 1);
            Again    : N.Real_Array (0 .. Width - 1);
            Narrow   : constant N.Real_Array (0 .. Width - 2) := [others => 0.0];
         begin
            Assert (Settings.Next_Layers = 1,
                    "the fixture's block past the stack was not counted");
            Assert (Settings.Layers = Tiny_Model.Layers,
                    "the block past the stack was counted as the stack's");

            L.Open (Live, Under.Ready, Context => Room, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");
            Assert (L.Drafts_Next (Live), "the session does not draft");
            Assert (L.Last_State (Live)'Length = 0,
                    "a session that has evaluated nothing has a last state");

            for Index in Prompt'Range loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Logits, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed");
            end loop;
            Assert (L.Last_State (Live)'Length = Width,
                    "the last state is not Embedding wide");

            L.Draft_Next
              (Live, Under.Ready, 3, L.Last_State (Live), Prompt'Length - 1,
               Drafted, State, Status);
            Assert (E.Is_Ok (Status),
                    "the block did not draft: "
                    & E.Error_Code'Image (Status.Code));
            for Index in Drafted'Range loop
               Assert (Drafted (Index)'Valid, "a drafted logit is not a number");
            end loop;

            --  Chained on its own answer, one position further; and
            --  without a distribution asked for, which is a cache written
            --  and a state handed on.
            L.Draft_Next
              (Live, Under.Ready, 5, State, Prompt'Length, Chained, Again,
               Status);
            Assert (E.Is_Ok (Status), "the block did not draft on its draft");
            L.Draft_Next
              (Live, Under.Ready, 5, State, Prompt'Length, Nothing, Again,
               Status);
            Assert (E.Is_Ok (Status), "a draft without logits was refused");

            L.Draft_Next
              (Live, Under.Ready, 5, Narrow, Prompt'Length, Chained, Again,
               Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "a state of the wrong width was taken");
            L.Draft_Next
              (Live, Under.Ready, 5, State, Room, Chained, Again, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "a position past the context was taken");

            L.Close (Live);
            Assert (not L.Drafts_Next (Live), "a closed session drafts");
         end;

         declare
            procedure Turn
              (From_Next : Boolean;
               Text      : out Model_Runner.Bytes.Byte_Array_Access;
               Length    : out Natural;
               Proposed  : out Natural)
            is
               Live    : L.Session;
               Request : Gen.Request;
               Stop    : Model_Runner.Stops.Set;
               Outcome : Gen.Result;
               Local   : E.Error_Info;
            begin
               L.Open (Live, Under.Ready, Context => Room, Status => Local);
               Assert (E.Is_Ok (Local), "the session did not open");

               Model_Runner.Stops.Open (Stop);
               Request.Max_Tokens := 12;
               Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
               Request.Seed := 7;
               Request.Has_Seed := True;
               Request.Add_Beginning := True;
               Request.Retain_Text := True;
               Request.Draft_Tokens := (if From_Next then 3 else 0);
               Request.Draft_From_Next := From_Next;

               Gen.Generate
                 (Under.Ready, Live, "abab", Request, Stop, null, null,
                  null, null, null, null, Outcome => Outcome);
               Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                       "the run failed: "
                       & E.Error_Code'Image (Outcome.Error.Code));

               Text := Outcome.Text;
               Length := Outcome.Text_Length;
               Proposed := Outcome.Drafted;

               Model_Runner.Stops.Close (Stop);
               L.Close (Live);
            end Turn;

            Plain_Text, Next_Text : Model_Runner.Bytes.Byte_Array_Access;
            Plain_Last, Next_Last : Natural;
            Ignored, Proposed     : Natural;
         begin
            Turn (False, Plain_Text, Plain_Last, Ignored);
            Turn (True, Next_Text, Next_Last, Proposed);

            Assert (Plain_Last > 0, "the plain run produced nothing");
            Assert (Next_Last = Plain_Last,
                    "the drafted run produced" & Natural'Image (Next_Last)
                    & " bytes against" & Natural'Image (Plain_Last));
            Assert (B."/=" (Plain_Text, null)
                      and then B."/=" (Next_Text, null),
                    "a run retained no text");
            Assert (B."=" (Plain_Text.all (1 .. B.Byte_Index (Plain_Last)),
                           Next_Text.all (1 .. B.Byte_Index (Next_Last))),
                    "drafting from the next block produced different text");
            Assert (Proposed > 0,
                    "the run proposed nothing from its next block, so this "
                    & "compares two runs of the same path");

            B.Free (Plain_Text);
            B.Free (Next_Text);
         end;
      end;

      B.Free (Image);
   end A_Hybrid_Drafts_From_Its_Next_Block;

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
         --
         --  One direction, not both. The program may read a format the
         --  shader does not -- MXFP4 arrived that way, and was refused on
         --  the device while it loaded, by name, until the shader grew its
         --  branch. What may not happen is the other direction, and that
         --  is what this asks.
         declare
            Said : constant Model_Runner.Backend.Capabilities :=
              Model_Runner.Backend.Device.Describe;
         begin
            for Format in Model_Runner.GGUF.Tensor_Type loop
               Assert (not Model_Runner.Backend.Supports (Said, Format)
                       or else Model_Runner.GGUF.Is_Supported (Format),
                       "the device backend claims "
                       & Model_Runner.GGUF.Type_Name (Format)
                       & ", which the program does not read");
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

      --  Run twice: once on a model that holds every position for every
      --  layer, and once on one that slides a window and holds neither.
      --  A round's rows are different sessions, so each holds its window
      --  somewhere of its own and a row that read another's cells would be
      --  reading another member's context -- which is what this test is
      --  about, said about a cache that moves.
      procedure Stepped (Window : Natural);

      procedure Stepped (Window : Natural) is
         Image : B.Byte_Array_Access;

         Steps : constant := 4;

         First_Prompt  : constant array (1 .. Steps) of Vocab.Token_Id :=
           [4, 5, 6, 7];
         Second_Prompt : constant array (1 .. Steps) of Vocab.Token_Id :=
           [9, 8, 7, 6];

         type Trail is array (1 .. Steps) of Logit_Vector;
      begin
         Tiny_Model.Build (Image, Window => Window);

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

               Assert (L.Position (One) = Steps
                       and then L.Position (Two) = Steps,
                       "the members of a round did not each advance by one "
                       & "position a step");

               --  And what a round refuses. The rows have to add up to what
               --  the members were given -- one apiece unless a share list
               --  says otherwise -- and a member that is not open cannot be in
               --  one: both are refused by name, because a round that ran
               --  anyway would give somebody another sequence's attention.
               L.Evaluate_Round
                 (Members => [One'Unchecked_Access, Two'Unchecked_Access],
                  Source  => Under.Ready,
                  Tokens  => [1 => First_Prompt (1)],
                  Logits  => Both,
                  Status  => Status);

               Assert (Status.Code = E.Tensor_Shape_Mismatch,
                       "a round with fewer tokens than rows was not "
                       & "refused as a shape: "
                       & E.Error_Code'Image (Status.Code));

               --  And a share list that does not name every member.
               L.Evaluate_Round
                 (Members => [One'Unchecked_Access, Two'Unchecked_Access],
                  Source  => Under.Ready,
                  Tokens  => [First_Prompt (1), Second_Prompt (1)],
                  Logits  => Both,
                  Shares  => [1 => 2],
                  Status  => Status);

               Assert (Status.Code = E.Tensor_Shape_Mismatch,
                       "a round whose shares name fewer members than it has "
                       & "was not refused as a shape: "
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
      end Stepped;
   begin
      Stepped (0);
      Stepped (3);
   end Round_Members_Get_What_They_Would_Alone;

   --  A server gives each member what it would have got alone.
   --
   --  The round primitive is held bit for bit by the test above. What this
   --  holds is the policy over it: that a member's own sampler, its own
   --  stop and its own limit are its own, that a member that stops leaves
   --  without disturbing the rest, and that the tokens handed back are the
   --  ones that member would have generated by itself.
   --
   --  Greedy, so "what it would have got alone" is a text and not a
   --  distribution: the same prompt through the same sampler is the same
   --  tokens, and two members with different prompts that produced the same
   --  tokens would be a collision this could not see -- which is why the
   --  two prompts are checked to differ first.
   procedure Served_Members_Get_What_They_Would_Alone
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;

      Steps : constant := 5;

      First_Prompt  : constant Vocab.Token_Array (1 .. 3) := [4, 5, 6];
      Second_Prompt : constant Vocab.Token_Array (1 .. 3) := [9, 8, 7];

      type Trail is array (1 .. Steps) of Vocab.Token_Id;

      --  What a member would say on its own, greedily, from a prompt.
      procedure Said_Alone
        (Under  : in out L.Model'Class;
         Prompt : Vocab.Token_Array;
         Into   : out Trail;
         Status : out E.Error_Info)
      is
         Live  : L.Session;
         Row   : Logit_Vector := [others => 0.0];
         Token : Vocab.Token_Id;
      begin
         Into := [others => Vocab.No_Token];

         L.Open (Live, Under, Status => Status);
         if E.Is_Error (Status) then
            return;
         end if;

         L.Evaluate_Batch (Live, Under, Prompt, Row, Status => Status);

         for Step in Trail'Range loop
            exit when E.Is_Error (Status);

            Token := Vocab.Token_Id (Best_Of (Row));
            Into (Step) := Token;
            L.Evaluate (Live, Under, Token, Row, Status => Status);
         end loop;

         L.Close (Live);
      end Said_Alone;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);

         Alone_First, Alone_Second : Trail := [others => Vocab.No_Token];
         Status : E.Error_Info;
      begin
         Start (Under);

         Said_Alone (Under.Ready, First_Prompt, Alone_First, Status);
         Assert (E.Is_Ok (Status), "the first sequence would not run alone");

         Said_Alone (Under.Ready, Second_Prompt, Alone_Second, Status);
         Assert (E.Is_Ok (Status), "the second sequence would not run alone");

         --  The two must differ, or the comparison below would hold however
         --  badly the rows collided.
         Assert (Alone_First /= Alone_Second,
                 "the two prompts produce the same tokens, so this fixture "
                 & "cannot tell a collision from a coincidence");

         declare
            Serve : Model_Runner.Serving.Server (Capacity => 4);

            use type Model_Runner.Serving.Member_Id;
            use type Model_Runner.Serving.Ending;

            One, Two : Model_Runner.Serving.Member_Id;

            --  The first member is held to a limit and the second to a
            --  stop -- the token the first one said last -- so that the two
            --  ways of ending are both exercised and neither member's end
            --  is the other's.
            First_Terms : Model_Runner.Serving.Terms;
            Then_Terms  : Model_Runner.Serving.Terms;
         begin
            --  Greedy and unpenalized, so that "what it would have got
            --  alone" is the argmax the comparison above took. The sampler's
            --  own defaults are a temperature and a repetition penalty,
            --  which are the right defaults for a caller and the wrong ones
            --  for a test that compares two runs token for token.
            First_Terms.Sampling.Temperature := 0.0;
            First_Terms.Sampling.Repeat_Penalty := 1.0;
            First_Terms.Limit := Steps;

            Then_Terms.Sampling := First_Terms.Sampling;
            Then_Terms.Limit := Steps;

            Model_Runner.Serving.Open
              (Serve, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the server did not open: "
                    & E.Error_Code'Image (Status.Code));

            Model_Runner.Serving.Admit
              (Serve, First_Prompt, First_Terms, One, Status);
            Assert (E.Is_Ok (Status) and then One /= 0,
                    "the first member was not admitted: "
                    & E.Error_Code'Image (Status.Code));

            Model_Runner.Serving.Admit
              (Serve, Second_Prompt, Then_Terms, Two, Status);
            Assert (E.Is_Ok (Status) and then Two /= 0,
                    "the second member was not admitted: "
                    & E.Error_Code'Image (Status.Code));

            Assert (Model_Runner.Serving.Serving (Serve) = 2,
                    "the server is not serving the two members admitted");

            while Model_Runner.Serving.Serving (Serve) > 0 loop
               Model_Runner.Serving.Step (Serve, Status => Status);
               Assert (E.Is_Ok (Status),
                       "a round refused: "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            --  One round a token: the first of them is the one that reads
            --  both prompts, which are rows of it like any other, and the
            --  token each member says comes out of that same pass.
            Assert (Model_Runner.Serving.Rounds (Serve) = Steps,
                    "a server of two members held to five tokens made"
                    & Integer'Image (Model_Runner.Serving.Rounds (Serve))
                    & " rounds rather than five");

            Assert (Model_Runner.Serving.Gathered (Serve) = 2,
                    "the last round did not gather both members");

            Assert (Model_Runner.Serving.Produced (Serve) = 2 * Steps,
                    "the server did not produce a token a member a round");

            for Member in 1 .. 2 loop
               declare
                  Who : constant Model_Runner.Serving.Member_Id :=
                    (if Member = 1 then One else Two);

                  Wanted : constant Trail :=
                    (if Member = 1 then Alone_First else Alone_Second);

                  Got  : Vocab.Token_Array (1 .. Steps);
                  Last : Natural;
                  Done : Boolean;
               begin
                  Model_Runner.Serving.Take (Serve, Who, Got, Last, Done);

                  Assert (Last = Steps,
                          "a member handed back" & Integer'Image (Last)
                          & " tokens rather than five");
                  Assert (Done, "a member that reached its limit is not done");
                  Assert
                    (Model_Runner.Serving.Ended (Serve, Who)
                       = Model_Runner.Serving.Reached_Its_Limit,
                     "a member that reached its limit says otherwise");

                  for Step in Trail'Range loop
                     Assert (Got (Step) = Wanted (Step),
                             "member" & Integer'Image (Member)
                             & " said a different token at step"
                             & Integer'Image (Step)
                             & " than it would have said alone");
                  end loop;

                  --  And its room comes back, which is what lets a server
                  --  outlive the callers it was opened for.
                  Model_Runner.Serving.Retire (Serve, Who);
               end;
            end loop;

            declare
               Again  : Model_Runner.Serving.Member_Id;
               Retook : E.Error_Info;
            begin
               Model_Runner.Serving.Admit
                 (Serve, First_Prompt, First_Terms, Again, Retook);

               Assert (E.Is_Ok (Retook) and then Again /= 0,
                       "a retired member's room was not taken again: "
                       & E.Error_Code'Image (Retook.Code));

               --  And a full server says so by name rather than by
               --  refusing to make progress: a caller told the room is
               --  gone can wait, and one told nothing cannot.
               for Seat in 2 .. 4 loop
                  Model_Runner.Serving.Admit
                    (Serve, First_Prompt, First_Terms, Again, Retook);
                  Assert (E.Is_Ok (Retook),
                          "a seat that was free would not take a caller: "
                          & E.Error_Code'Image (Retook.Code));
               end loop;

               Model_Runner.Serving.Admit
                 (Serve, First_Prompt, First_Terms, Again, Retook);

               Assert (Retook.Code = E.Generation_Batch_Too_Large
                         and then Again = 0,
                       "a full server did not refuse a fifth caller by "
                       & "name: " & E.Error_Code'Image (Retook.Code));
            end;

            Model_Runner.Serving.Close (Serve);
         end;

         L.Close (Under.Ready, Status);
         Assert (E.Is_Ok (Status),
                 "the model would not close after serving: "
                 & E.Error_Code'Image (Status.Code));
      end;

      B.Free (Image);
   end Served_Members_Get_What_They_Would_Alone;

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
   --  The lookup proposes what followed this phrase the last time it was
   --  said, and proposes nothing where nothing did.
   --
   --  A search over an array, which is why it is a package of its own and
   --  checked here rather than only through a run: what a run can show is
   --  that the text came out the same, and the text comes out the same when
   --  the lookup proposes nothing at all.
   procedure The_Lookup_Proposes_What_Followed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Look renames Model_Runner.Lookup;

      Into  : Vocab.Token_Array (1 .. 4);
      Count : Natural;
   begin
      --  "a b c d a b" -- the last two are "a b", which occurred at the
      --  front and was followed by "c d a b". All four, and running back
      --  into the phrase itself is the point rather than an oversight: a
      --  passage that has begun to repeat is a passage that will go on
      --  repeating, and clamping the proposal at the match would give up
      --  exactly the case this is for.
      Look.Propose ([1, 2, 3, 4, 1, 2], Into, Count);
      Assert (Count = 4,
              "the lookup proposed" & Natural'Image (Count)
              & " tokens where four followed the phrase");
      Assert (Into (1) = 3 and then Into (2) = 4
              and then Into (3) = 1 and then Into (4) = 2,
              "the lookup proposed tokens that did not follow the phrase");

      --  The most recent occurrence, not the first. "a b x, a b y, a b" has
      --  to propose y: a phrase said twice is likelier to go on the way it
      --  went last time, and that is the rule the figures were measured
      --  under.
      Look.Propose ([1, 2, 8, 1, 2, 9, 1, 2], Into, Count);
      Assert (Count > 0 and then Into (1) = 9,
              "the lookup proposed what followed the phrase the first time "
              & "rather than the last");

      --  Nothing to match against.
      Look.Propose ([1, 2, 3], Into, Count);
      Assert (Count = 0,
              "the lookup proposed" & Natural'Image (Count)
              & " tokens where the phrase had never been said before");

      --  Shorter than a key and a match.
      Look.Propose ([1, 2], Into, Count);
      Assert (Count = 0, "the lookup proposed from a history of two");
      Look.Propose ([1 .. 0 => 1], Into, Count);
      Assert (Count = 0, "the lookup proposed from an empty history");

      --  Bounded by the room it is given, not by what it found.
      declare
         Narrow : Vocab.Token_Array (1 .. 2);
      begin
         Look.Propose ([1, 2, 3, 4, 5, 6, 7, 1, 2], Narrow, Count);
         Assert (Count = 2 and then Narrow (1) = 3 and then Narrow (2) = 4,
                 "the lookup overran the room it was given");
      end;

      --  A longer key is a narrower question, and this history answers the
      --  short one and not the long one: "b c" occurred before, "a b c"
      --  did not.
      Look.Propose ([9, 2, 3, 7, 1, 2, 3], Into, Count, Key => 2);
      Assert (Count > 0 and then Into (1) = 7,
              "a key of two did not find the pair that had occurred");
      Look.Propose ([9, 2, 3, 7, 1, 2, 3], Into, Count, Key => 3);
      Assert (Count = 0,
              "a key of three found a triple that had not occurred");
   end The_Lookup_Proposes_What_Followed;

   --  A run drafting from its own context says exactly what it says
   --  without drafting.
   --
   --  The same claim the draft-model path makes and for the same reason:
   --  at temperature zero a proposal is either what the target would have
   --  chosen or it is not, and only the ones that match are kept. What is
   --  different is that there is no second model to be wrong -- the
   --  proposals come out of the text, so a fault here shows up as the
   --  target being asked to check a phrase that was never said.
   --
   --  The prompt repeats on purpose. A lookup over a context with nothing
   --  said twice proposes nothing, and a run that proposes nothing is the
   --  run without drafting compared against itself.
   procedure Lookup_Drafting_Produces_The_Same_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      --  Room for the prompt, the tokens asked for and a batch of
      --  proposals, which the fixture's own sixteen is not.
      Room : constant := 64;

      Image : B.Byte_Array_Access;

      Prompt : constant String := "abababab";
   begin
      Tiny_Model.Build (Image, Room => Room);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         procedure Turn
           (With_Lookup : Boolean;
            Text        : out Model_Runner.Bytes.Byte_Array_Access;
            Length      : out Natural;
            Proposed    : out Natural;
            Accepted    : out Natural)
         is
            Live    : L.Session;
            Request : Gen.Request;
            Stop    : Model_Runner.Stops.Set;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
         begin
            L.Open (Live, Under.Ready, Context => Room, Status => Local);
            Assert (E.Is_Ok (Local), "the session did not open");

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 12;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 7;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;
            Request.Retain_Text := True;
            Request.Draft_Tokens := (if With_Lookup then 4 else 0);
            Request.Draft_From_Context := With_Lookup;

            Gen.Generate
              (Under.Ready, Live, Prompt, Request, Stop, null, null,
               null, null, null, null, Outcome => Outcome);

            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Text := Outcome.Text;
            Length := Outcome.Text_Length;
            Proposed := Outcome.Drafted;
            Accepted := Outcome.Accepted;

            Model_Runner.Stops.Close (Stop);
            L.Close (Live);
         end Turn;

         Plain_Text, Look_Text : Model_Runner.Bytes.Byte_Array_Access;
         Plain_Last, Look_Last : Natural;
         Ignored_A, Ignored_B  : Natural;
         Proposed, Accepted    : Natural;
      begin
         Start (Under);

         Turn (False, Plain_Text, Plain_Last, Ignored_A, Ignored_B);
         Turn (True, Look_Text, Look_Last, Proposed, Accepted);

         Assert (Plain_Last > 0, "the plain run produced nothing");
         Assert (Look_Last = Plain_Last,
                 "the drafted run produced" & Natural'Image (Look_Last)
                 & " bytes against" & Natural'Image (Plain_Last));

         Assert (B."/=" (Plain_Text, null)
                   and then B."/=" (Look_Text, null),
                 "a run retained no text");
         Assert (B."=" (Plain_Text.all (1 .. B.Byte_Index (Plain_Last)),
                        Look_Text.all (1 .. B.Byte_Index (Look_Last))),
                 "drafting from the context produced different text");

         --  And the path was taken, rather than the run quietly falling
         --  back to one token at a time.
         Assert (Proposed > 0,
                 "the run proposed nothing from a context that repeats, so "
                 & "this compares two runs of the same path");
         --  And most of them were right, which is the part the same text
         --  cannot show. A proposal is checked either way, so a lookup that
         --  proposes nonsense produces the same text and costs passes to do
         --  it: the fault this holds is the key not ending at the token the
         --  round is already certain of, which proposes what follows the
         --  phrase before this one. On a prompt repeating with period two
         --  every proposal is right; with the key one short, one in five
         --  is.
         Assert (Accepted * 2 >= Proposed,
                 "only" & Natural'Image (Accepted) & " of"
                 & Natural'Image (Proposed) & " proposals were accepted on "
                 & "a context that repeats, so the proposals are for the "
                 & "wrong position");

         B.Free (Plain_Text);
         B.Free (Look_Text);
      end;

      B.Free (Image);
   end Lookup_Drafting_Produces_The_Same_Text;

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

   --  The architecture that attends to nothing, and clamps its gate.
   --
   --  GPT_OSS is the model MXFP4 exists for and the first architecture here
   --  to carry either of two things. A sink is one learned score a head
   --  that joins the softmax's denominator and takes none of the weight, so
   --  a head with nothing worth attending to answers small rather than
   --  answering with whatever is nearest; nothing else in this program adds
   --  to a denominator without adding to a numerator. And its gate is not
   --  the logistic every other architecture here uses: both projections are
   --  held at a limit, the logistic is taken at a steeper slope, and one is
   --  added to the up projection -- so it reaches the second vector and
   --  cannot be an activation followed by a multiply.
   --
   --  Compared against the independent implementation rather than only run,
   --  because a sink that is dropped and a gate that is the ordinary one
   --  both produce a number: the engine would answer, and answer wrongly,
   --  and only a second implementation of the same two rules says so.
   procedure Sinks_And_A_Clamped_Gate
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      Image  : B.Byte_Array_Access;
      Result : Logit_Vector;
   begin
      Tiny_Model.Build
        (Image, Kind => Tiny_Model.GPT_OSS,
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
            Assert (L."=" (Read.Kind, L.GPT_OSS),
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
                 & "about a gpt-oss model by" & Long_Float'Image (Worst));

         Reference_Transformer.Close (Second);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Sinks_And_A_Clamped_Gate;

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

   --  A window that slides is the same window.
   --
   --  The test above holds a window that narrows what a position reads. This
   --  one holds what the cache does about it: a layer that slides a window
   --  is given the window and a batch rather than the whole context, and
   --  when a run passes the end of that it moves what the window still needs
   --  down to the front and carries on. Nothing else in the engine is told
   --  -- a position is asked for by where it sits, not by what it is -- and
   --  the claim is that the answer does not know either.
   --
   --  So the run has to be long enough to slide, which is why this one is
   --  five hundred and sixty positions where the test above is eight: a
   --  layer holds the window and a batch, a batch is five hundred and
   --  twelve, and nothing moves until a position passes that. Held against
   --  the implementation written from the description, as the window itself
   --  is, because an engine compared only with itself would agree with its
   --  own mistake.
   --
   --  And the memory is the point of it, so the plan is asked too: a
   --  context this model can only read three positions back through must
   --  cost less than one that holds every position for every layer.
   procedure A_Window_That_Slides_Answers_The_Same
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      use type Model_Runner.Memory.U64;

      --  Past the window and a batch, so that every layer has slid at least
      --  once by the end and the last position reads across a move.
      --  Long enough to slide, and no longer. A layer holds the window and
      --  a batch, so nothing moves until a position passes five hundred and
      --  fifteen; the last position of this run reads across the rows that
      --  moved, which is the part a run that stopped later would not touch
      --  -- a window of three reaches three positions back, and forty of
      --  them later there is nothing of the move left to be wrong about.
      Room   : constant := 600;
      Length : constant := 518;

      Prompt : Vocab.Token_Array (1 .. Length);

      Image  : B.Byte_Array_Access;
      Engine : Logit_Vector;
      Wanted : Reference_Transformer.Real_Vector
        (0 .. Tiny_Model.Vocabulary - 1);
      Made   : Boolean := False;
      Worst  : Long_Float := 0.0;
   begin
      --  Tokens that do not repeat with the window's period, so that a
      --  position reading the wrong three neighbours answers differently.
      for Index in Prompt'Range loop
         Prompt (Index) :=
           Vocab.Token_Id (4 + ((Index - 1) * 7 + Index / 13) mod 5);
      end loop;

      Tiny_Model.Build (Image, Window => 3, Room => Room);

      --  What the engine says, on a cache that slides.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;

         Whole  : Model_Runner.Memory.Session_Plan;
         Narrow : Model_Runner.Memory.Session_Plan;
      begin
         Start (Under);

         --  What it costs, before anything is opened. A context short
         --  enough that the window and a batch cover it holds every
         --  position of every layer, as it always did; one longer than that
         --  holds the window and the batch, and costs less.
         L.Plan_Session (Under.Ready, 64, Narrow, Status);
         Assert (E.Is_Ok (Status), "the short plan failed");
         L.Plan_Session (Under.Ready, Room, Whole, Status);
         Assert (E.Is_Ok (Status), "the long plan failed");

         Assert (Whole.KV_Cache_Bytes < Narrow.KV_Cache_Bytes * (Room / 64),
                 "a context nine times longer cost nine times the cache, so "
                 & "the window bought nothing:"
                 & Model_Runner.Memory.U64'Image (Whole.KV_Cache_Bytes)
                 & " against"
                 & Model_Runner.Memory.U64'Image (Narrow.KV_Cache_Bytes));

         L.Open (Live, Under.Ready, Context => Room, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Engine, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed: " & E.Error_Code'Image (Status.Code));
         end loop;

         L.Close (Live);
      end;

      --  And what the independent implementation says.
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

         Reference_Transformer.Run (Second, Tokens, Wanted, Made);
         Assert (Made, "the reference produced no logits");

         Reference_Transformer.Close (Second);
         Containers.Close (Parsed);
      end;

      B.Free (Image);

      for Index in Wanted'Range loop
         Worst := Long_Float'Max
           (Worst,
            abs (Long_Float
                   (Engine (Model_Runner.Numerics.Element_Count (Index)))
                 - Wanted (Index)));
      end loop;

      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree about "
              & "a window that has slid, by" & Long_Float'Image (Worst));
   end A_Window_That_Slides_Answers_The_Same;

   --  A shift on a cache that has slid renumbers what the layer holds,
   --  and holds nothing it should not.
   --
   --  THIS RAISED. Shift keeps the first Keep positions and moves the rest
   --  down, and it found both ends through Cell_Of -- a position's distance
   --  from the lowest one its layer still holds. On a layer that has slid,
   --  the positions a shift promises to keep are the first ones the window
   --  dropped, so that distance went below zero and the shift raised rather
   --  than shifting. Every architecture that slides, any context long
   --  enough to have slid: which is every context the window was built for.
   --
   --  What a shift means to such a layer is only a renumbering. It holds
   --  the newest positions and those are exactly the ones that survive, so
   --  each key is turned back and stays in the cell it is in, and the
   --  layer's origin moves by Drop. Nothing is copied.
   --
   --  HOW THIS CHECKS THAT THE RENUMBERING IS RIGHT rather than merely
   --  survivable. Every layer of this fixture slides and there are two of
   --  them, so a window of three reaches at most four positions back
   --  through the pair: a logit at position P is decided by the tokens at
   --  P - 4 .. P. Twenty positions after the shift, nothing before it can
   --  reach the answer. So the shifted run and a run that never had the
   --  dropped tokens at all must agree TO THE BIT, and an origin off by
   --  Drop makes the shifted one read the wrong three neighbours and
   --  answer differently.
   --  Rewinding and reading the same token again answers what it answered
   --  the first time, to the bit.
   --
   --  This is the whole of what a served caller keeping its predecessor's
   --  prompt rests on: the positions it keeps were not touched, so reading
   --  the one position it does not have has to give what reading it the
   --  first time gave. Nothing here is about a window or a shift -- it is
   --  the plain claim that a rewind leaves the cache alone.
   --  A caller keeps what its prompt has in common with the one its seat
   --  last held, and keeps exactly that much.
   --
   --  What a fault here looks like is a caller answering out of somebody
   --  else's context, which reads as a plausible wrong answer and not as an
   --  error, so what is checked is the count itself: how many tokens were
   --  kept, against what the two prompts actually share. Four cases, and
   --  each of them is a way to get that wrong -- nothing in common, some of
   --  it in common, all of it in common, and the reuse switched off.
   --
   --  THE CAP AT ONE SHORT OF THE PROMPT is the one worth naming. A caller
   --  whose whole prompt was kept would have nothing left to read and so no
   --  distribution to sample its first token from; it has to read its last
   --  token whatever else it keeps.
   procedure A_Seat_Keeps_What_Two_Prompts_Share
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      package Serve_It renames Model_Runner.Serving;

      use type Serve_It.Member_Id;

      Steps : constant := 3;

      Image : B.Byte_Array_Access;

      First  : constant Vocab.Token_Array := [4, 5, 6, 7, 8];
      Same   : constant Vocab.Token_Array := [4, 5, 6, 7, 8];
      Partly : constant Vocab.Token_Array := [4, 5, 6, 9, 10];
      Apart  : constant Vocab.Token_Array := [11, 12, 13, 14, 15];

      --  What each of them should keep of the one before it. The first has
      --  nothing to keep; the second shares its whole prompt and is capped
      --  one short of it; the third shares three; the fourth shares none.
      procedure Runs (Reuse : Boolean; Wanted : Natural);

      procedure Runs (Reuse : Boolean; Wanted : Natural) is
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Status : E.Error_Info;

         Server : Serve_It.Server (Capacity => 1);
         Terms  : Serve_It.Terms;

         procedure Caller (Prompt : Vocab.Token_Array);

         procedure Caller (Prompt : Vocab.Token_Array) is
            Who : Serve_It.Member_Id;
            Got : Vocab.Token_Array (1 .. Steps);
            Last : Natural;
            Done : Boolean;
         begin
            Serve_It.Admit (Server, Prompt, Terms, Who, Status);
            Assert (E.Is_Ok (Status) and then Who /= 0,
                    "a caller was not admitted: "
                    & E.Error_Code'Image (Status.Code));

            while Serve_It.Serving (Server) > 0 loop
               Serve_It.Step (Server, Status => Status);
               Assert (E.Is_Ok (Status),
                       "a round refused: "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            Serve_It.Take (Server, Who, Got, Last, Done);
            Assert (Last = Steps,
                    "a caller handed back" & Natural'Image (Last)
                    & " tokens rather than" & Natural'Image (Steps));
            Serve_It.Retire (Server, Who);
         end Caller;
      begin
         Terms.Sampling.Temperature := 0.0;
         Terms.Sampling.Repeat_Penalty := 1.0;
         Terms.Limit := Steps;

         Start (Under);

         Serve_It.Open
           (Server, Under.Ready, Reuse => Reuse, Status => Status);
         Assert (E.Is_Ok (Status),
                 "the server did not open: "
                 & E.Error_Code'Image (Status.Code));

         Caller (First);
         Assert (Serve_It.Kept (Server) = 0,
                 "the first caller kept"
                 & Natural'Image (Serve_It.Kept (Server))
                 & " tokens of a seat that had held nobody");

         Caller (Same);
         Caller (Partly);
         Caller (Apart);

         Assert (Serve_It.Kept (Server) = Wanted,
                 "four callers kept"
                 & Natural'Image (Serve_It.Kept (Server))
                 & " prompt tokens between them where"
                 & Natural'Image (Wanted) & " is what they share");

         Serve_It.Close (Server);
      end Runs;
   begin
      Tiny_Model.Build (Image);

      --  Four in a row through one seat. The second shares all five and is
      --  capped at four; the third shares three of the second's five, which
      --  are 4, 5 and 6; the fourth shares none. Four and three is seven.
      Runs (Reuse => True, Wanted => 7);

      --  And none of it when the reuse is off, which is what a caller who
      --  would rather a seat forgot the last one asks for.
      Runs (Reuse => False, Wanted => 0);

      B.Free (Image);

      --  AND THE FLOOR A SLIDING WINDOW PUTS UNDER IT. A layer that has
      --  slid holds the newest positions and no others, so a caller sharing
      --  only the first few tokens of a long one cannot keep them: they are
      --  what the slide dropped. Keeping them would ask the layer to attend
      --  over keys that are gone, which is the fault Reusable_From exists
      --  to refuse -- and refusing it is a slower answer and not a wrong
      --  one.
      declare
         package Serve_It renames Model_Runner.Serving;

         Room   : constant := 600;
         Length : constant := 518;

         Long_One : Vocab.Token_Array (1 .. Length);
         Short_One : Vocab.Token_Array (1 .. 8);

         Windowed : B.Byte_Array_Access;
      begin
         for Index in Long_One'Range loop
            Long_One (Index) :=
              Vocab.Token_Id (4 + ((Index - 1) * 7 + Index / 13) mod 5);
         end loop;

         --  Sharing its first few tokens and nothing else.
         Short_One := Long_One (1 .. Short_One'Length);

         Tiny_Model.Build (Windowed, Window => 3, Room => Room);

         declare
            Held   : aliased constant B.Byte_Array := Windowed.all;
            Under  : Harness (Held'Access);
            Status : E.Error_Info;

            Server : Serve_It.Server (Capacity => 1);
            Terms  : Serve_It.Terms;

            Who  : Serve_It.Member_Id;
            Got  : Vocab.Token_Array (1 .. 2);
            Last : Natural;
            Done : Boolean;
         begin
            Terms.Sampling.Temperature := 0.0;
            Terms.Sampling.Repeat_Penalty := 1.0;
            Terms.Limit := 2;

            Start (Under);

            Serve_It.Open
              (Server, Under.Ready, Context => Room, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the windowed server did not open: "
                    & E.Error_Code'Image (Status.Code));

            for Round in 1 .. 2 loop
               declare
                  Prompt : constant Vocab.Token_Array :=
                    (if Round = 1 then Long_One
                     else Vocab.Token_Array (Short_One));
               begin
                  Serve_It.Admit (Server, Prompt, Terms, Who, Status);
                  Assert (E.Is_Ok (Status) and then Who /= 0,
                          "a caller was not admitted to the windowed seat: "
                          & E.Error_Code'Image (Status.Code));

                  while Serve_It.Serving (Server) > 0 loop
                     Serve_It.Step (Server, Status => Status);
                     Assert (E.Is_Ok (Status),
                             "a windowed round refused: "
                             & E.Error_Code'Image (Status.Code));
                  end loop;

                  Serve_It.Take (Server, Who, Got, Last, Done);
                  Serve_It.Retire (Server, Who);
               end;
            end loop;

            Assert (Serve_It.Kept (Server) = 0,
                    "a caller sharing eight tokens with a five-hundred-token "
                    & "one kept" & Natural'Image (Serve_It.Kept (Server))
                    & " of them, which a slid window no longer holds");

            Serve_It.Close (Server);
         end;

         B.Free (Windowed);
      end;
   end A_Seat_Keeps_What_Two_Prompts_Share;

   --  A session tells a watcher which matrix every product reads, and
   --  answers exactly what it answers with nobody watching.
   --
   --  The seam exists because only the engine knows what it is about to
   --  multiply by: a view carries an address and a length and no name, and
   --  a name is what an importance matrix is keyed by. What has to be true
   --  of it is two things -- that the names are the file's own names, and
   --  that being watched changes nothing -- and the second is the one worth
   --  a test, because a seam that perturbed the arithmetic would produce a
   --  matrix about a model nobody runs.
   procedure A_Watcher_Is_Told_The_Names_And_Changes_Nothing
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Room   : constant := 64;
      Length : constant := 6;

      Prompt : Vocab.Token_Array (1 .. Length);
      Image  : B.Byte_Array_Access;

      Most_Names : constant := 64;

      --  A watcher that writes down what it was told and nothing else.
      type Listener is limited new L.Watcher with record
         Names : Model_Runner.Text.Bounded_List (1 .. Most_Names) :=
           [others => Model_Runner.Text.Empty];
         Up    : Natural := 0;
         Calls : Natural := 0;
         Rows  : Natural := 0;
      end record;

      overriding procedure Note
        (Item   : in out Listener;
         Which  : String;
         Values : Model_Runner.Numerics.Real_Array;
         Rows   : Model_Runner.Numerics.Element_Count);

      overriding procedure Note
        (Item   : in out Listener;
         Which  : String;
         Values : Model_Runner.Numerics.Real_Array;
         Rows   : Model_Runner.Numerics.Element_Count)
      is
         Seen : Boolean := False;
      begin
         Item.Calls := Item.Calls + 1;
         Item.Rows := Item.Rows + Natural (Rows);

         if Values'Length = 0 then
            return;
         end if;

         for Index in 1 .. Item.Up loop
            Seen := Seen
              or else Model_Runner.Text.To_String (Item.Names (Index)) = Which;
         end loop;

         if not Seen and then Item.Up < Most_Names then
            Item.Up := Item.Up + 1;
            Item.Names (Item.Up) := Model_Runner.Text.To_Bounded (Which);
         end if;
      end Note;

      Quiet, Watched : Logit_Vector := [others => 0.0];
      Heard : aliased Listener;
   begin
      for Index in Prompt'Range loop
         Prompt (Index) := Vocab.Token_Id (4 + (Index * 3) mod 5);
      end loop;

      Tiny_Model.Build (Image, Room => Room);

      for Listening in Boolean'Range loop
         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
         begin
            Start (Under);

            L.Open (Live, Under.Ready, Context => Room, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            if Listening then
               L.Watch (Live, Heard'Unchecked_Access);
            end if;

            for Token of Prompt loop
               declare
                  Row : Logit_Vector := [others => 0.0];
               begin
                  L.Evaluate
                    (Live, Under.Ready, Token, Row, Status => Status);
                  Assert (E.Is_Ok (Status), "evaluation failed");

                  if Listening then
                     Watched := Row;
                  else
                     Quiet := Row;
                  end if;
               end;
            end loop;

            L.Watch (Live, null);
            L.Close (Live);
         end;
      end loop;

      B.Free (Image);

      --  It was told something, and the something is a matrix of this
      --  model rather than a name of its own invention.
      Assert (Heard.Calls > 0,
              "a watched run reported no products at all");
      Assert (Heard.Up > 0, "a watched run named no matrices");

      declare
         Found : Boolean := False;
      begin
         for Index in 1 .. Heard.Up loop
            Found := Found
              or else Model_Runner.Text.To_String (Heard.Names (Index))
                      = "blk.0.attn_q.weight";
         end loop;

         Assert (Found,
                 "a watched run never named blk.0.attn_q.weight, which every "
                 & "token of this architecture multiplies by");
      end;

      --  A product a token, at least, for each matrix it named.
      Assert (Heard.Rows >= Heard.Up * Length,
              "a watched run reported" & Natural'Image (Heard.Rows)
              & " rows over" & Natural'Image (Heard.Up) & " matrices and"
              & Natural'Image (Length) & " tokens, which is fewer than one "
              & "row a matrix a token");

      --  And the arithmetic is the arithmetic.
      Assert (Model_Runner.Numerics."=" (Quiet, Watched),
              "a watched run answered differently from an unwatched one, so "
              & "the seam is not free");
   end A_Watcher_Is_Told_The_Names_And_Changes_Nothing;

   procedure Reading_Again_After_A_Rewind_Answers_The_Same
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Room   : constant := 64;
      Length : constant := 12;

      Prompt : Vocab.Token_Array (1 .. Length);
      Image  : B.Byte_Array_Access;

      First, Again : Logit_Vector := [others => 0.0];
      Apart : Long_Float := 0.0;
   begin
      for Index in Prompt'Range loop
         Prompt (Index) := Vocab.Token_Id (4 + (Index * 3) mod 5);
      end loop;

      Tiny_Model.Build (Image, Room => Room);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
      begin
         Start (Under);

         L.Open (Live, Under.Ready, Context => Room, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, First, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");
         end loop;

         L.Rewind (Live, Length - 1, Status);
         Assert (E.Is_Ok (Status),
                 "the rewind was refused: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Position (Live) = Length - 1,
                 "the rewind left" & Natural'Image (L.Position (Live))
                 & " positions, not" & Natural'Image (Length - 1));

         --  And what it kept is what it had: every position below the one
         --  rewound past still reads as the token that was written there.
         for Index in 0 .. Length - 2 loop
            Assert (L.Committed_Token (Live, Index)
                      = Prompt (Prompt'First + Index),
                    "the rewind changed the token at position"
                    & Natural'Image (Index));
         end loop;

         L.Evaluate
           (Live, Under.Ready, Prompt (Prompt'Last), Again,
            Status => Status);
         Assert (E.Is_Ok (Status), "the second reading failed");

         L.Close (Live);
      end;

      B.Free (Image);

      for Index in First'Range loop
         Apart := Long_Float'Max
           (Apart, abs (Long_Float (First (Index) - Again (Index))));
      end loop;

      Assert (Apart = 0.0,
              "reading a token again after a rewind answered differently, "
              & "by" & Long_Float'Image (Apart)
              & " -- what a rewind kept is not what it had");
   end Reading_Again_After_A_Rewind_Answers_The_Same;

   procedure A_Shift_On_A_Window_Renumbers_What_It_Holds
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      --  Past the window and a batch, so that every layer has slid before
      --  the shift is asked for.
      Room   : constant := 600;
      Length : constant := 518;

      Keep   : constant := 0;
      Drop   : constant := 100;

      --  Longer than the four positions a two-layer window of three can
      --  reach back through, by enough that the margin is not the point.
      Tail   : constant := 20;

      Prompt : Vocab.Token_Array (1 .. Length);
      After  : Vocab.Token_Array (1 .. Tail);

      Image  : B.Byte_Array_Access;

      procedure On (Backend : Model_Runner.Backend.Backend_Kind);

      --  The same question of whichever backend will answer it. The device
      --  keeps its own copy of the cache and a shift edits the host's, so
      --  the answer here is a different claim on each: that the renumbering
      --  is right, and that what it renumbered reached the device.
      procedure On (Backend : Model_Runner.Backend.Backend_Kind) is
         Shifted, Fresh : Logit_Vector := [others => 0.0];

         --  And the first token after the shift, whose window still reaches
         --  back into what was kept: what the turn-back is checked by.
         First_Shifted, First_Fresh : Logit_Vector := [others => 0.0];

         Apart, Near : Long_Float := 0.0;

         Where : constant String :=
           " on " & Model_Runner.Text.To_Lower
                      (Model_Runner.Backend.Backend_Kind'Image (Backend));
      begin
         --  What the engine says after a shift on a cache that has slid.
         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
            Able   : Boolean;
         begin
            Start (Under, Backend, Able);

            if not Able then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "note: no device shifted a window here");
               return;
            end if;

            L.Open (Live, Under.Ready, Context => Room, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open" & Where);

            for Token of Prompt loop
               L.Evaluate
                 (Live, Under.Ready, Token, Shifted, Status => Status);
               Assert (E.Is_Ok (Status),
                       "evaluation failed" & Where & ": "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            L.Shift (Live, Under.Ready, Keep, Drop, Status);
            Assert (E.Is_Ok (Status),
                    "a shift on a cache that has slid was refused" & Where
                    & ": " & E.Error_Code'Image (Status.Code));
            Assert (L.Position (Live) = Length - Drop,
                    "the shift left" & Natural'Image (L.Position (Live))
                    & " positions, not" & Natural'Image (Length - Drop)
                    & Where);

            for Index in After'Range loop
               L.Evaluate
                 (Live, Under.Ready, After (Index), Shifted,
                  Status => Status);
               Assert (E.Is_Ok (Status),
                       "the continuation after a shift failed" & Where);

               if Index = After'First then
                  First_Shifted := Shifted;
               end if;
            end loop;

            L.Close (Live);
         end;

         --  And what it says having never read the dropped tokens.
         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
            Able   : Boolean;
         begin
            Start (Under, Backend, Able);
            Assert (Able, "the second model was refused" & Where);

            L.Open (Live, Under.Ready, Context => Room, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the second session did not open" & Where);

            for Index in Drop + 1 .. Length loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Fresh,
                  Status => Status);
               Assert (E.Is_Ok (Status), "the retained prompt failed" & Where);
            end loop;

            for Index in After'Range loop
               L.Evaluate
                 (Live, Under.Ready, After (Index), Fresh, Status => Status);
               Assert (E.Is_Ok (Status),
                       "the second continuation failed" & Where);

               if Index = After'First then
                  First_Fresh := Fresh;
               end if;
            end loop;

            L.Close (Live);
         end;

         for Index in Fresh'Range loop
            Apart := Long_Float'Max
              (Apart, abs (Long_Float (Shifted (Index) - Fresh (Index))));
            Near := Long_Float'Max
              (Near,
               abs (Long_Float (First_Shifted (Index) - First_Fresh (Index))));
         end loop;

         --  The token right after the shift, which the retained keys decide.
         --  Near rather than equal: those keys were turned for the positions
         --  they were written at and turned back again, where the second
         --  session's were turned once, and two rotations that compose to
         --  the same angle do not compose to the same bits. A key that was
         --  not turned back at all is a hundred positions out and nowhere
         --  near.
         Assert (Near < 1.0E-3,
                 "the token after a shift on a window disagrees with a run "
                 & "that never read what was dropped, by"
                 & Long_Float'Image (Near) & Where
                 & " -- the keys the window still holds were not renumbered");

         Assert (Apart < 1.0E-4,
                 "a shifted window answers differently from a run that never "
                 & "read what it dropped, by" & Long_Float'Image (Apart)
                 & Where
                 & " -- the renumbering left the layer reading the wrong "
                 & "positions");
      end On;
   begin
      for Index in Prompt'Range loop
         Prompt (Index) :=
           Vocab.Token_Id (4 + ((Index - 1) * 7 + Index / 13) mod 5);
      end loop;

      for Index in After'Range loop
         After (Index) := Vocab.Token_Id (4 + (Index * 3) mod 5);
      end loop;

      Tiny_Model.Build (Image, Window => 3, Room => Room);

      On (Model_Runner.Backend.Backend_CPU);

      declare
         Ready : Boolean;
      begin
         Model_Runner.Backend.Device.Close;
         Model_Runner.Backend.Device.Open (Ready);

         if Ready then
            On (Model_Runner.Backend.Backend_Device);
            Model_Runner.Backend.Device.Close;
         else
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device shifted a window here");
         end if;
      end;

      B.Free (Image);
   end A_Shift_On_A_Window_Renumbers_What_It_Holds;

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

   ------------------------------------------------
   -- A_Rotation_Stretches_When_A_Caller_Asks_It --
   ------------------------------------------------

   --  A model may be run past the context it was trained on, when the
   --  caller stretches the rotation for it.
   --
   --  The engine has stretched rotations since it first read a file that
   --  asked for one: `rope.scaling.type`, the factor, the band and the
   --  attenuation are all read and all run. What it would not do is let the
   --  person running the model ask for the same thing -- so a file whose
   --  author wrote the keys reached past its trained length and a file
   --  whose author did not could not be made to, which is a decision the
   --  file was making on the reader's behalf.
   --
   --  What is asserted here is the rule and not the quality: that a request
   --  reaches the configuration, that it opens a session the file's own
   --  settings would refuse, that asking for the rotation as trained
   --  refuses again, and that a model with no rotation to stretch says so.
   --  Whether the answers past the trained length are worth having is a
   --  measurement, and `### Past the context it was trained on` has it.
   procedure A_Rotation_Stretches_When_A_Caller_Asks_It
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package K renames Model_Runner.Kernels;

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);

         --  Twice what the fixture declares, which is what a caller who
         --  wants twice the context asks for.
         Twice : constant Positive := 2 * Tiny_Model.Context;

         Opened : E.Error_Info;
      begin
         Containers.Reader.Parse
           (Under.Parsed, Under.Source, Status => Opened);
         Assert (E.Is_Ok (Opened), "the fixture did not parse");

         --  Unasked, the file decides and the rule is the one it always
         --  was: a context past the trained length is refused.
         declare
            Plain  : L.Model;
            Live   : L.Session;
            Status : E.Error_Info;
            Ignored : E.Error_Info;
         begin
            L.Prepare
              (Plain, Under.Parsed, Under.Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture would not prepare");
            Assert (not L.Config (Plain).Stretched,
                    "a model nobody stretched says it was stretched");

            L.Open (Live, Plain, Context => Twice, Status => Status);
            Assert (Status.Code = E.Arch_Context_Too_Large,
                    "a context past the trained length was taken on an "
                    & "unstretched model, with "
                    & E.Error_Code'Image (Status.Code));

            L.Close (Plain, Ignored);
         end;

         --  Asked for, the same context opens, and the configuration holds
         --  the reciprocal of the factor -- which is what a file states and
         --  what the arithmetic multiplies by.
         declare
            Wider  : L.Model;
            Live   : L.Session;
            Status : E.Error_Info;
            Ignored : E.Error_Info;
         begin
            L.Prepare
              (Wider, Under.Parsed, Under.Source, Status => Status,
               Stretch =>
                 (Kind => L.Linear_Stretch, Factor => 2.0, others => <>));
            Assert (E.Is_Ok (Status),
                    "a stretched model would not prepare: "
                    & E.Error_Code'Image (Status.Code));

            Assert (L.Config (Wider).Stretched,
                    "a model stretched by request does not say so");
            Assert (K."=" (L.Config (Wider).Scaling.Kind, K.Linear),
                    "the linear stretch was asked for and not taken");
            Assert (L.Config (Wider).Scaling.Frequency = 0.5,
                    "a factor of two became a frequency of"
                    & N.Wide_Real'Image (L.Config (Wider).Scaling.Frequency)
                    & " where 0.5 is its reciprocal");
            Assert (L.Config (Wider).Trained_Context = Tiny_Model.Context,
                    "the trained context was not kept beside the stretch");

            L.Open (Live, Wider, Context => Twice, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a stretched model refused a context it was stretched "
                    & "for: " & E.Error_Code'Image (Status.Code));
            L.Close (Live);
            L.Close (Wider, Ignored);
         end;

         --  A caller who asks for the rotation as trained is asking for the
         --  rule back, and gets it -- which is what distinguishes "say
         --  nothing" from "say none".
         declare
            Kept   : L.Model;
            Live   : L.Session;
            Status : E.Error_Info;
            Ignored : E.Error_Info;
         begin
            L.Prepare
              (Kept, Under.Parsed, Under.Source, Status => Status,
               Stretch => (Kind => L.As_Trained, others => <>));
            Assert (E.Is_Ok (Status), "the fixture would not prepare");
            Assert (not L.Config (Kept).Stretched,
                    "a rotation asked for as trained counts as stretched");

            L.Open (Live, Kept, Context => Twice, Status => Status);
            Assert (Status.Code = E.Arch_Context_Too_Large,
                    "the rotation as trained was asked for and the trained "
                    & "context was exceeded anyway");

            L.Close (Kept, Ignored);
         end;

         --  And the numbers a caller does not name are the file's own. A
         --  yarn stretch asked for with a factor alone keeps the band the
         --  author tuned, and takes the trained context as what it was
         --  trained on because the file says so.
         declare
            Yarned : L.Model;
            Status : E.Error_Info;
            Ignored : E.Error_Info;
         begin
            L.Prepare
              (Yarned, Under.Parsed, Under.Source, Status => Status,
               Stretch =>
                 (Kind => L.Yarn_Stretch, Factor => 4.0, others => <>));
            Assert (E.Is_Ok (Status), "a yarn stretch would not prepare");
            Assert (K."=" (L.Config (Yarned).Scaling.Kind, K.Yarn),
                    "yarn was asked for and not taken");
            Assert (L.Config (Yarned).Scaling.Original = Tiny_Model.Context,
                    "yarn asked for without a trained context took"
                    & Natural'Image (L.Config (Yarned).Scaling.Original)
                    & " where the file says" & Natural'Image
                        (Tiny_Model.Context));
            Assert (L.Config (Yarned).Scaling.Beta_Fast = 32.0,
                    "a band nobody named was not left as it was");

            L.Close (Yarned, Ignored);
         end;
      end;

      B.Free (Image);

      --  A model that turns nothing cannot be stretched, and says which
      --  model rather than which key. Bert learns a row a position and
      --  holds as many rows as it was trained with: there is no angle to
      --  turn by a different amount.
      declare
         Learned : B.Byte_Array_Access;
      begin
         Tiny_Model.Build (Learned, Kind => Tiny_Model.Bert);

         declare
            Held  : aliased constant B.Byte_Array := Learned.all;
            Under : Harness (Held'Access);
            Ready : L.Model;
            Status : E.Error_Info;
            Ignored : E.Error_Info;
         begin
            Containers.Reader.Parse
              (Under.Parsed, Under.Source, Status => Status);
            Assert (E.Is_Ok (Status), "the bert fixture did not parse");

            L.Prepare
              (Ready, Under.Parsed, Under.Source, Status => Status,
               Stretch =>
                 (Kind => L.Linear_Stretch, Factor => 2.0, others => <>));
            Assert (Status.Code = E.Arch_Rotation_Not_Stretchable,
                    "a model that turns nothing was stretched anyway, with "
                    & E.Error_Code'Image (Status.Code));

            L.Close (Ready, Ignored);
         end;

         B.Free (Learned);
      end;
   end A_Rotation_Stretches_When_A_Caller_Asks_It;

   ---------------------------------------------------
   -- A_Batched_Mixture_Agrees_With_One_At_A_Time --
   ---------------------------------------------------

   --  A batch's mixture, gathered by expert, answers what the positions
   --  answer one at a time.
   --
   --  A batch has no one matrix to multiply the whole of it by, so the
   --  mixture ran a position at a time however many were handed in, and an
   --  expert chosen by seven positions of a hundred and ten had its
   --  matrices read seven times. Gathered the other way round -- by expert,
   --  with every position that chose one multiplied at once -- each is read
   --  once, which is worth 1.6 times on a prompt.
   --
   --  What it must not change is the answer, and it does not have to: the
   --  products are the same products, and each expert's answer is kept in
   --  the place its position and its rank name so that the sums are added
   --  best-expert-first as they always were.
   --
   --  THIS IS HERE BECAUSE NOTHING ELSE HOLDS IT. The fixture comparison
   --  runs a mixture on the processor and against the reference, batched
   --  and a token at a time, and it runs the device -- but not a mixture
   --  batched on the device, which is the one arrangement the gathering
   --  changes. Dropping the share from the sum was caught by nothing: 0
   --  failures, 41,780 conformance sequences, 0 outside tolerance.
   procedure A_Batched_Mixture_Agrees_With_One_At_A_Time
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Device renames Model_Runner.Backend.Device;

      Image : B.Byte_Array_Access;
      Ready : Boolean;

      Tokens : constant Vocab.Token_Array := [3, 4, 5, 6, 7, 8];
   begin
      Device.Close;
      Device.Open (Ready);

      if not Ready then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "note: no device gathered a mixture here");
         return;
      end if;

      --  A mixture wide enough that its experts are chosen apart: with four
      --  experts and two used, six positions spread over them is what makes
      --  the gathering do something rather than hand every expert the whole
      --  batch.
      Tiny_Model.Build
        (Image, Kind => Tiny_Model.Qwen3_MoE,
         Experts => 4, Experts_Used => 2);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Able  : Boolean;

         Status : E.Error_Info;
         Ignored : E.Error_Info;
      begin
         Start (Under, Model_Runner.Backend.Backend_Device, Able);

         if not Able then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device took the mixture fixture");
            Device.Close;
            B.Free (Image);
            return;
         end if;

         declare
            Settings : constant L.Configuration := L.Config (Under.Ready);

            One_By_One, All_At_Once, Whole : N.Real_Array
              (0 .. N.Element_Count (Settings.Vocabulary) - 1);

            Apart : N.Real := 0.0;
            Drift : N.Real := 0.0;
         begin
            Assert (Settings.Experts > 0,
                    "the fixture asked for a mixture and has none");

            --  A position at a time through the batched evaluator, which
            --  is the road a token took before the device took a mixture
            --  layer whole: the router's product and the choosing on the
            --  device, the chosen experts gathered, the shares and the sum
            --  on the host in rank order. Six batches of one.
            declare
               Live : L.Session;
            begin
               L.Open (Live, Under.Ready, Status => Status);
               Assert (E.Is_Ok (Status), "the stepped session would not open");

               for Index in Tokens'Range loop
                  L.Evaluate_Batch
                    (Live, Under.Ready, Tokens (Index .. Index), One_By_One,
                     Status => Status);
                  Assert (E.Is_Ok (Status),
                          "a stepped position failed: "
                          & E.Error_Code'Image (Status.Code));
               end loop;

               L.Close (Live);
            end;

            --  And the same positions as one batch, which on a device takes
            --  the gathered path.
            declare
               Live : L.Session;
            begin
               L.Open (Live, Under.Ready, Status => Status);
               Assert (E.Is_Ok (Status), "the batched session would not open");

               L.Evaluate_Batch
                 (Live, Under.Ready, Tokens, All_At_Once, Status => Status);
               Assert (E.Is_Ok (Status),
                       "the batch failed: "
                       & E.Error_Code'Image (Status.Code));

               L.Close (Live);
            end;

            --  And a token at a time, which on a device that holds the
            --  stacks is the whole layer as one sequence: the head
            --  normalizations, the routing, the gathered experts and the
            --  weighted sum all on the device. Its normalizations sum in
            --  binary32 where the host's sum in binary64, so it is held
            --  close rather than to the bit -- what the bound catches is a
            --  wrong expert, a wrong share or a dropped residual, each of
            --  which moves a logit by far more than a last bit.
            declare
               Live : L.Session;
            begin
               L.Open (Live, Under.Ready, Status => Status);
               Assert (E.Is_Ok (Status), "the token session would not open");

               for Index in Tokens'Range loop
                  L.Evaluate
                    (Live, Under.Ready, Tokens (Index), Whole,
                     Status => Status);
                  Assert (E.Is_Ok (Status),
                          "a token failed: "
                          & E.Error_Code'Image (Status.Code));
               end loop;

               L.Close (Live);
            end;

            for Index in One_By_One'Range loop
               Apart := N.Real'Max
                 (Apart, abs (One_By_One (Index) - All_At_Once (Index)));
               Drift := N.Real'Max
                 (Drift, abs (Whole (Index) - All_At_Once (Index)));
            end loop;

            --  The same products in the same order, so the same bits. A
            --  tolerance here would let the gathering associate the sum
            --  differently and say nothing, which is the whole of what
            --  keeping each expert's answer by rank is for.
            Assert (Apart = 0.0,
                    "a batch gathered by expert answers"
                    & N.Real'Image (Apart)
                    & " away from the same positions one at a time, where "
                    & "the products are the same products in the same order");

            Assert (Drift < 1.0E-4,
                    "a mixture layer taken whole on the device answers"
                    & N.Real'Image (Drift)
                    & " away from the same positions batched");
         end;

         L.Close (Under.Ready, Ignored);
      end;

      Device.Close;
      B.Free (Image);
   end A_Batched_Mixture_Agrees_With_One_At_A_Time;

   -----------------------------------------------
   -- A_Budget_Too_Small_Answers_What_A_Large_One_Does --
   -----------------------------------------------

   --  A model larger than the device's budget answers what it answers when
   --  the whole of it fits.
   --
   --  Above the budget, every matrix taken means one given back, and a
   --  buffer given back is now kept rather than given up: a mixture's
   --  expert matrices are all one size, so the next matrix taken is the
   --  right shape for it and the driver is asked once instead of four
   --  hundred times a generated token. That is worth 1.35 times on a
   --  mixture that does not fit.
   --
   --  What it must not change is the answer. A reused buffer is a buffer
   --  something else has written to, so a matrix uploaded into one and read
   --  short would read the last matrix's weights -- which is the same
   --  failure the shape checks beside the key were added for, arriving by a
   --  different route.
   --
   --  The fixture fits any real budget, so the budget is made small enough
   --  that it does not: what is being exercised is the giving back and the
   --  taking again, not the size of anything.
   procedure A_Budget_Too_Small_Answers_What_A_Large_One_Does
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Device renames Model_Runner.Backend.Device;

      Image : B.Byte_Array_Access;

      Tokens : constant Vocab.Token_Array := [3, 4, 5, 6];

      --  What the model says with the device opened at a given budget.
      procedure Said
        (Budget : Interfaces.Unsigned_64;
         Into   : out N.Real_Array;
         Ran    : out Boolean)
      is
         Ready  : Boolean;
         Status : E.Error_Info;
         Able   : Boolean;
      begin
         Ran := False;
         Into := [others => 0.0];

         Device.Close;
         Device.Open (Ready, Budget => Budget);

         if not Ready then
            return;
         end if;

         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Live  : L.Session;
            Ignored : E.Error_Info;
         begin
            Containers.Reader.Parse
              (Under.Parsed, Under.Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            --  Prepared knowing it does not fit, which is the whole point:
            --  a model larger than the budget runs by giving a matrix back
            --  for every matrix it takes, and refusing it would leave that
            --  loop untested.
            L.Prepare
              (Under.Ready, Under.Parsed, Under.Source,
               Backend => Model_Runner.Backend.Backend_Device,
               Fit_Required => False, Status => Status);

            Able := E.Is_Ok (Status);

            if not Able then
               Device.Close;
               return;
            end if;

            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session would not open");

            for Index in Tokens'Range loop
               L.Evaluate
                 (Live, Under.Ready, Tokens (Index), Into, Status => Status);
               Assert (E.Is_Ok (Status),
                       "a position failed at a budget of"
                       & Interfaces.Unsigned_64'Image (Budget) & ": "
                       & E.Error_Code'Image (Status.Code));
            end loop;

            L.Close (Live);
            L.Close (Under.Ready, Ignored);
         end;

         Device.Close;
         Ran := True;
      end Said;

   begin
      Tiny_Model.Build (Image, Format => Tiny_Model.Q8_0);

      declare
         Wide : constant N.Element_Count :=
           N.Element_Count (Tiny_Model.Vocabulary);

         Plenty, Pinched : N.Real_Array (0 .. Wide - 1);

         Ran_One, Ran_Two : Boolean;

         Apart : N.Real := 0.0;
      begin
         --  Whatever the device offers, which for this fixture is room for
         --  every matrix at once.
         Said (0, Plenty, Ran_One);

         if not Ran_One then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device held the fixture here");
            B.Free (Image);
            return;
         end if;

         --  And a budget too small for it, which makes every matrix taken
         --  cost one given back.
         Said (Interfaces.Unsigned_64 (16 * 1024), Pinched, Ran_Two);
         Assert (Ran_Two, "the device would not open at a small budget");

         for Index in Plenty'Range loop
            Apart := N.Real'Max (Apart, abs (Plenty (Index) - Pinched (Index)));
         end loop;

         --  The same weights read the same way, so the same bits. A
         --  tolerance would let a reused buffer hand back the last
         --  matrix's weights in the elements a short read did not cover.
         Assert (Apart = 0.0,
                 "a model that does not fit answers" & N.Real'Image (Apart)
                 & " away from the same model when it does, so a buffer "
                 & "given back and taken again is not what it was");
      end;

      B.Free (Image);
   end A_Budget_Too_Small_Answers_What_A_Large_One_Does;

   ------------------------------------------------
   -- What_A_Token_Reads_Decides_Whether_It_Fits --
   ------------------------------------------------

   --  A model is refused for not fitting on what a token reads, not on what
   --  the model holds.
   --
   --  The refusal exists because a model larger than the device's share
   --  runs by giving a matrix back for every matrix it takes, and that used
   --  to be slower than the processor -- TinyLlama-1.1B at a fraction of
   --  its weights reads 5.3 tokens a second on this part against 39.4 on
   --  the processor, which is the seven and a half times the refusal was
   --  written for and still is.
   --
   --  A MIXTURE IS THE OTHER CASE. Its token reads its dense half and one
   --  expert of eight, so a shortfall is uploaded a fraction as often, and
   --  Qwen3-30B-A3B -- 11.26 GB against the 8.47 this part offers -- reads
   --  11.5 tokens a second on the device against 2.9 on the processor.
   --  Refused, that is four times the speed thrown away on reasoning that
   --  belongs to the other kind of model.
   --
   --  Both halves are held here, each against half of its own weights, so
   --  that neither passes by being smaller than the other.
   procedure What_A_Token_Reads_Decides_Whether_It_Fits
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Device renames Model_Runner.Backend.Device;
      package Mem renames Model_Runner.Memory;

      use type Interfaces.Unsigned_64;

      --  Prepare a fixture at a device budget, and say what happened and
      --  what its weights came to.
      procedure Try
        (Image  : B.Byte_Array_Access;
         Budget : Interfaces.Unsigned_64;
         Weighs : out Interfaces.Unsigned_64;
         Took   : out Boolean;
         Absent : out Boolean)
      is
         Ready : Boolean;
         Status : E.Error_Info;
      begin
         Weighs := 0;
         Took := False;
         Absent := False;

         Device.Close;
         Device.Open (Ready, Budget => Budget);

         if not Ready then
            Absent := True;
            return;
         end if;

         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ignored : E.Error_Info;
         begin
            Containers.Reader.Parse
              (Under.Parsed, Under.Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            L.Prepare
              (Under.Ready, Under.Parsed, Under.Source,
               Backend => Model_Runner.Backend.Backend_Device,
               Status => Status);

            Took := E.Is_Ok (Status);

            if Took then
               Weighs :=
                 L.Accounting (Under.Ready).By_Category (Mem.Model_Weights);
            else
               Assert (Status.Code = E.Memory_Limit_Exceeded,
                       "a model that does not fit was refused with "
                       & E.Error_Code'Image (Status.Code));
            end if;

            L.Close (Under.Ready, Ignored);
         end;

         Device.Close;
      end Try;

      Mixed, Dense : B.Byte_Array_Access;
   begin
      --  Eight experts of which one runs, so a token reads about a fifth of
      --  what the model holds and the two cases are far apart.
      Tiny_Model.Build (Mixed, Kind => Tiny_Model.Qwen3_MoE,
                        Experts => 8, Experts_Used => 1);
      Tiny_Model.Build (Dense, Kind => Tiny_Model.Qwen3);

      declare
         Weighs : Interfaces.Unsigned_64;
         Took, Absent : Boolean;
      begin
         --  What each holds, taken at a budget nothing could exceed.
         Try (Mixed, 0, Weighs, Took, Absent);

         if Absent then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device weighed a model here");
            B.Free (Mixed);
            B.Free (Dense);
            return;
         end if;

         Assert (Took, "the mixture would not prepare at all");
         Assert (Weighs > 0, "a prepared model weighs nothing");

         --  Half of its own weights: a token reads about a fifth, so it
         --  fits and is taken.
         declare
            Whole : constant Interfaces.Unsigned_64 := Weighs;
            Again : Interfaces.Unsigned_64;
         begin
            Try (Mixed, Whole / 2, Again, Took, Absent);
            Assert (Took,
                    "a mixture whose token reads a fifth of it was refused "
                    & "at half its weights, which is the rule for a model "
                    & "that reads all of itself every token");
         end;

         --  And the dense model against half of its own, which its token
         --  reads all of.
         Try (Dense, 0, Weighs, Took, Absent);
         Assert (Took, "the dense fixture would not prepare at all");

         declare
            Whole : constant Interfaces.Unsigned_64 := Weighs;
            Again : Interfaces.Unsigned_64;
         begin
            Try (Dense, Whole / 2, Again, Took, Absent);
            Assert (not Took,
                    "a model that reads all of itself every token was taken "
                    & "at half its weights, where it runs seven times "
                    & "slower than the processor");
         end;
      end;

      B.Free (Mixed);
      B.Free (Dense);
   end What_A_Token_Reads_Decides_Whether_It_Fits;

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
        (T, A_Seat_Keeps_What_Two_Prompts_Share'Access,
         "a served caller keeps what its prompt shares with the one "
         & "its seat last held, and exactly that much");
      Register_Routine
        (T, A_Watcher_Is_Told_The_Names_And_Changes_Nothing'Access,
         "a watcher is told which matrix every product reads, and the "
         & "run answers what it answers unwatched");
      Register_Routine
        (T, Reading_Again_After_A_Rewind_Answers_The_Same'Access,
         "rewinding and reading the same token again answers what it "
         & "answered the first time");
      Register_Routine
        (T, A_Shift_On_A_Window_Renumbers_What_It_Holds'Access,
         "a shift on a cache that has slid renumbers what the layer "
         & "holds");
      Register_Routine
        (T, A_Window_That_Slides_Answers_The_Same'Access,
         "a window that has slid answers what the independent "
         & "implementation answers, and costs less than the whole context");
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
        (T, Sinks_And_A_Clamped_Gate'Access,
         "an attention sink and a clamped gate agree with the independent "
         & "implementation of both");
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
        (T, A_Hybrid_Keeps_Its_State_Through_Everything'Access,
         "a hybrid's linear state holds through a batch, a snapshot, a "
         & "kept rewind and a refused shift");
      Register_Routine
        (T, A_Hybrid_Drafts_From_Its_Next_Block'Access,
         "the block past a hybrid's stack drafts, chains on its draft, "
         & "refuses a wrong width, and a run drafting from it says the "
         & "same text");
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
        (T, The_Lookup_Proposes_What_Followed'Access,
         "the lookup proposes what followed the phrase the last time "
         & "it was said");
      Register_Routine
        (T, Lookup_Drafting_Produces_The_Same_Text'Access,
         "a run drafting from its own context says what it says "
         & "without drafting");
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
        (T, Served_Members_Get_What_They_Would_Alone'Access,
         "a server gives each member the tokens it would have generated on "
         & "its own, and retires it on its own stop");
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
      Register_Routine
        (T, A_Fused_Layer_Is_Not_Charged_To_Attending'Access,
         "a layer that went over to the device as one sequence is charged "
         & "to fusing and not to attending");
      Register_Routine
        (T, A_Halved_Session_On_The_Device_Reads_The_Copy'Access,
         "a session asking for halves on the device attends out of the "
         & "device's half-precision copy and says so");
      Register_Routine
        (T, What_A_Token_Reads_Decides_Whether_It_Fits'Access,
         "a model is refused for not fitting on what a token reads and not "
         & "on what it holds, so a mixture is taken where a dense model is "
         & "refused");
      Register_Routine
        (T, A_Budget_Too_Small_Answers_What_A_Large_One_Does'Access,
         "a model larger than the device's budget answers what it answers "
         & "when the whole of it fits");
      Register_Routine
        (T, A_Batched_Mixture_Agrees_With_One_At_A_Time'Access,
         "a batch's mixture gathered by expert answers what the same "
         & "positions answer one at a time, to the bit");
      Register_Routine
        (T, A_Rotation_Stretches_When_A_Caller_Asks_It'Access,
         "a caller may stretch the rotation the file did not, and only a "
         & "model stretched for it reaches past its trained context");
   end Register_Tests;

end Tests.Inference_Cases;
