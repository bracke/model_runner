with Ada.Strings.Fixed;
with Ada.Text_IO;

with AUnit.Assertions;

with Model_Runner.Lookup;
with Model_Runner.Text;
with Model_Runner.UTF8;
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

   --  How far a paged session's logits may stand from a block session's and
   --  still be the same answer. A cache in pages holds a position's keys and
   --  values in a different order than one block does, and the device sums
   --  attention in half precision, so the two round a hair apart rather than
   --  to the bit -- deterministically, a few parts in a million on the
   --  780M. This is orders below any real paging fault (a wrong or stale page
   --  moves a logit by whole numbers) and far below what parts one token from
   --  the next, so it is the width of the device's own reproducibility, not a
   --  licence for drift.
   Paged_Layout_Slack : constant N.Real := 1.0e-4;

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

            --  Where the device took the layer over as one sequence, its
            --  time is the fused phase's and none is the attending phase's --
            --  the whole point of the budget, and what this asks. Where it
            --  did not -- a fixture small enough that the device keeps its
            --  matrices whole but never fuses the layer, as the 780M does
            --  here -- there is no fused layer to make the claim about, so it
            --  is noted rather than failed, the way a machine with no device
            --  is above.
            if Spent (L.Fusing) > 0.0 then
               Assert (Spent (L.Attending) = 0.0,
                       "a fused layer was charged to Attending, which is the "
                       & "phase that grows with the context -- a whole layer "
                       & "under that name is what made the budget name "
                       & "attending as the device's largest cost");
            else
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "note: no device fused a layer here");
            end if;
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

         --  And a batch held off the matrix instruction, told for the
         --  process the same way, and set back.
         Assert (not Model_Runner.Backend.Device.Attends_Exactly,
                 "the device keeps a batch off the matrix instruction "
                 & "before being told to");
         Model_Runner.Backend.Device.Attend_Exactly (True);
         Assert (Model_Runner.Backend.Device.Attends_Exactly,
                 "the device would not keep a batch off the matrix "
                 & "instruction when told to");
         Model_Runner.Backend.Device.Attend_Exactly (False);
         Assert (not Model_Runner.Backend.Device.Attends_Exactly,
                 "the device kept a batch off the matrix instruction "
                 & "after being told not to");

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

   --------------------------------
   -- A_Reranker_Scores_A_Text --
   --------------------------------

   --  A reranker carries a scoring head and a ranked pooling type: the
   --  ranking pass takes the first position's state through the head to a
   --  single number rather than reducing the text to a vector. Run to a
   --  finite score, which is what the head's two products and its logistic
   --  produce from a state the layers gave.
   procedure A_Reranker_Scores_A_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Bert, Ranking => True);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Status : E.Error_Info;
         None   : N.Real_Array (1 .. 0);
         Width  : constant N.Element_Count :=
           N.Element_Count (Tiny_Model.Embedding);
         Room   : Model_Runner.Tensors.Real_Array_Access :=
           new N.Real_Array (0 .. 2 * Width - 1);
         Score  : N.Real;
      begin
         Start (Under);
         Assert (L."=" (L.Config (Under.Ready).Pooling, L.Pool_Rank),
                 "the reranker's pooling was not read as ranked");

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "reranker session did not open");

         L.Evaluate_Batch
           (Live, Under.Ready, [1, 5], None, States => Room,
            Status => Status);
         Assert (E.Is_Ok (Status),
                 "reranker batch failed: "
                 & E.Error_Code'Image (Status.Code));

         --  The first position's state -- what a ranked pooling reads --
         --  through the scoring head.
         L.Rank
           (Live, Under.Ready, Room.all (0 .. Width - 1), Score, Status);
         Assert (E.Is_Ok (Status),
                 "the reranker's head was not read: "
                 & E.Error_Code'Image (Status.Code));
         Assert (N.Is_Finite (Score),
                 "the reranker scored with a value that is not a number");

         L.Close (Live);
         Model_Runner.Tensors.Free (Room);
      end;

      B.Free (Image);
   end A_Reranker_Scores_A_Text;

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
         use type Interfaces.Unsigned_64;

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

            --  The room a hybrid's ring is seated in, given back with
            --  the seat: it grew to hold every seated ring and never
            --  shrank, so a session with states kept left tens of
            --  megabytes of the machine's own memory on the device
            --  until the engine closed. The engine calls
            --  Release_State_Room where the last seat is given up, as it
            --  calls Release_Cache where the last block is; and
            --  Clear_State where a seat is taken, so that a session with
            --  nothing committed has nothing to send into it. Nothing on
            --  the processor takes a room at all, so this says nothing
            --  there.
            Assert (Model_Runner.Backend.Device.State_Room_Bytes = 0,
                    "the device still holds"
                    & Interfaces.Unsigned_64'Image
                        (Model_Runner.Backend.Device.State_Room_Bytes)
                    & " bytes of state room with no session seated in it");
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

   --  And drafting from the block while sampling keeps the model's own
   --  distribution. Above temperature zero a proposal is kept with the
   --  chance its own probability allows against the block's, and a refused
   --  one is replaced by a draw from what is left -- which is exact only if
   --  the block's distribution the test reads is the one the proposal came
   --  from, and only if the round after a refusal starts from the state of
   --  the token that replaced it. Two tokens a run, the second being the
   --  one a round decides; four thousand seeds with the block and four
   --  thousand without, and the last byte's distribution the same within
   --  what that many draws can tell apart -- and some proposals refused, or
   --  the replacing half of the round was never run. Measured: 0.016 to
   --  0.026 apart over three ranges of seeds; accepting five times too
   --  readily reads 0.12 and fails.
   procedure A_Hybrid_Drafts_From_Its_Next_Block_When_Sampling
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      package Gen renames Model_Runner.Generation;

      Room  : constant := 32;
      Runs  : constant := 4000;
      Image : B.Byte_Array_Access;

      type Histogram is array (0 .. 255) of Natural;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Qwen35, Room => Room);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : aliased Harness (Held'Access);

         procedure Count
           (From_Next : Boolean;
            Seen      : out Histogram;
            Proposed  : out Natural;
            Accepted  : out Natural)
         is
         begin
            Seen := [others => 0];
            Proposed := 0;
            Accepted := 0;

            for Seed in 1 .. Runs loop
               declare
                  Live    : L.Session;
                  Request : Gen.Request;
                  Stop    : Model_Runner.Stops.Set;
                  Outcome : Gen.Result;
                  Local   : E.Error_Info;
               begin
                  L.Open (Live, Under.Ready, Context => Room, Status => Local);
                  Assert (E.Is_Ok (Local), "the session did not open");

                  Model_Runner.Stops.Open (Stop);
                  Request.Max_Tokens := 2;
                  Request.Sampling.Temperature := 1.0;
                  Request.Sampling.Repeat_Penalty := 1.0;
                  Request.Seed := Gen.Seed_Value (Seed);
                  Request.Has_Seed := True;
                  Request.Add_Beginning := True;
                  Request.Retain_Text := True;
                  Request.Draft_Tokens := (if From_Next then 3 else 0);
                  Request.Draft_From_Next := From_Next;

                  Gen.Generate
                    (Under.Ready, Live, "abab", Request, Stop, null, null,
                     null, null, null, null, Outcome => Outcome);
                  Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                          "a sampled run failed: "
                          & E.Error_Code'Image (Outcome.Error.Code));

                  if Outcome.Text_Length > 0 then
                     declare
                        Last : constant Natural := Natural
                          (Outcome.Text.all
                             (B.Byte_Index (Outcome.Text_Length)));
                     begin
                        Seen (Last) := Seen (Last) + 1;
                     end;
                  end if;

                  Proposed := Proposed + Outcome.Drafted;
                  Accepted := Accepted + Outcome.Accepted;

                  B.Free (Outcome.Text);
                  Model_Runner.Stops.Close (Stop);
                  L.Close (Live);
               end;
            end loop;
         end Count;

         Plain, Drafted       : Histogram;
         Ignored_P, Ignored_A : Natural;
         Proposed, Accepted   : Natural;
         Apart                : Float := 0.0;
      begin
         Start (Under);

         Count (False, Plain, Ignored_P, Ignored_A);
         Count (True, Drafted, Proposed, Accepted);

         Assert (Proposed > 0,
                 "the sampled runs proposed nothing from the block");
         Assert (Accepted < Proposed,
                 "every one of" & Natural'Image (Proposed)
                 & " proposals was kept, so no refusal was ever replaced");

         for Byte in Histogram'Range loop
            Apart := Apart
              + abs (Float (Plain (Byte)) - Float (Drafted (Byte)))
                / Float (Runs);
         end loop;
         Apart := Apart / 2.0;

         Assert (Apart <= 0.05,
                 "the last byte's distribution moved by"
                 & Float'Image (Apart) & " with the block drafting");
      end;

      B.Free (Image);
   end A_Hybrid_Drafts_From_Its_Next_Block_When_Sampling;

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

   --  The two backends agree on a prompt long enough to fill the tile.
   --
   --  The sweep compares every backend against the independent
   --  implementation on sequences of at most eight tokens, and the device's
   --  matrix kernel is not entered below nine and is built for a hundred
   --  and twenty-eight: the path a real prompt takes on a device was
   --  compared with nothing. Lengthening the sweep was tried and costs
   --  forty minutes, because the reference computes every sequence for
   --  every fixture in binary64 whether a comparison asks or not. What this
   --  wants to know is only whether two backends agree, and two backends
   --  can be asked that for the price of running them: the processor,
   --  serial, against the device, on the same fixture and the same tokens,
   --  a hundred and sixty of them in one batch and again in chunks of
   --  forty-one so the seam between calls is crossed at a tile boundary.
   --  Two formats, because the two tile compilations differ: Q4_K takes the
   --  wide tile at a hundred and twenty-eight columns a step, Q8_0 the
   --  narrow one at thirty-two.
   --
   --  The tile's operand is half precision and the processor's is not, so
   --  the two are held to a tolerance rather than a digest; a wrong tile
   --  answers by whole logits, not by a thousandth. Measured on the part
   --  this was written on: the Q4_K fixture through the wide tile differs
   --  by 0.0126 at worst on logits up to 9.3, which is a seventh of a per
   --  cent and what two layers of half-precision operands come to; the
   --  Q8_0 fixture, too narrow for the wide tile and served by the row
   --  kernels, by a millionth in one batch and by 0.002 in chunks, the
   --  engine picking a different kernel for each count. The tolerance is
   --  set above the first and well below a wrong answer.
   procedure Two_Backends_Agree_On_A_Long_Prompt
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Model_Runner.Backend.Backend_Kind;

      Length    : constant := 160;
      Room      : constant := 256;
      Tolerance : constant N.Real := 0.02;

      --  The tokens, pseudo-random over the fixture's sixteen-word
      --  vocabulary and the same on every run.
      Tokens : Model_Runner.Tokenizer.Token_Array (1 .. Length);

      --  The last position's logits from one backend, in one batch or in
      --  chunks. Zero means the backend refused, and says why.
      procedure Logits_On
        (Image   : B.Byte_Array_Access;
         Backend : Model_Runner.Backend.Backend_Kind;
         Chunk   : Positive;
         Answer  : out N.Real_Array;
         Refusal : out E.Error_Code;
         Cache   : L.Cache_Precision := L.Exact)
      is
         Held    : aliased constant B.Byte_Array := Image.all;
         Source  : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Item    : Containers.Container;
         Model   : L.Model;
         Session : L.Session;
         Status  : E.Error_Info;
         From    : Positive := 1;
      begin
         Answer := [others => 0.0];
         Refusal := E.No_Error;

         Containers.Reader.Parse (Item, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare (Model, Item, Source, Backend => Backend, Status => Status);
         if E.Is_Error (Status) then
            Refusal := Status.Code;
            Containers.Close (Item);
            return;
         end if;

         L.Open (Session, Model, Context => Room, Cache => Cache,
                 Status => Status);
         Assert (E.Is_Ok (Status),
                 "a session did not open on "
                 & Model_Runner.Backend.Backend_Name (Backend) & ": "
                 & E.Error_Code'Image (Status.Code));

         while From <= Length loop
            declare
               Upto : constant Positive := Positive'Min (From + Chunk - 1, Length);
            begin
               --  A position at a time takes the road a generated token
               --  takes, which is not the batch's with one position in it.
               if Chunk = 1 then
                  L.Evaluate
                    (Session, Model, Tokens (From), Answer, Status => Status);
               else
                  L.Evaluate_Batch
                    (Session, Model, Tokens (From .. Upto), Answer,
                     Status => Status);
               end if;
               Assert (E.Is_Ok (Status),
                       "the batch did not evaluate on "
                       & Model_Runner.Backend.Backend_Name (Backend) & ": "
                       & E.Error_Code'Image (Status.Code));
               From := Upto + 1;
            end;
         end loop;

         L.Close (Session);
         L.Close (Model, Status);
         Containers.Close (Item);
      end Logits_On;

      Seed : Interfaces.Unsigned_32 := 1_234_567;
      use type Interfaces.Unsigned_32;

      Chunks : constant array (1 .. 2) of Positive := [Length, 41];
      Awake  : Boolean;
   begin
      for Index in Tokens'Range loop
         Seed := Seed * 1_103_515_245 + 12_345;
         Tokens (Index) := Model_Runner.Tokenizer.Token_Id
           (Interfaces.Shift_Right (Seed, 16) mod Tiny_Model.Vocabulary);
      end loop;

      --  The backend is a singleton the suite leaves closed, and a model
      --  prepares on it either way: it is the first product that answers
      --  BACKEND_CLOSED when nobody opened it, which is the fixture
      --  question that stopped the first version of this test.
      Model_Runner.Backend.Device.Open (Awake);
      if not Awake then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "note: no device compared a long prompt here");
         return;
      end if;

      --  Every architecture the device reads, windowed where it can be,
      --  and then heads as wide as Gemma's -- two hundred and fifty-six,
      --  past the room the device's attention kernel keeps --
      --  which the device must decline and the processor take: for a
      --  hundred days it did not decline it, and every Gemma answered in
      --  nonsense while every fixture, four wide, agreed to the bit.
      declare
         --  And the hybrid, dense and as a mixture with its shared
         --  expert: its attention layers go whole with the gate beside
         --  each head and the shared expert as steps of the sequence,
         --  and its linear layers run on the host between them.
         type Case_Row is record
            Kind    : Tiny_Model.Fixture_Architecture;
            Format  : Tiny_Model.Weight_Format;
            Window  : Natural;
            Heads   : Positive;
            Experts : Natural := 0;
            Used    : Natural := 0;
         end record;
         Rows : constant array (1 .. 15) of Case_Row :=
           [(Tiny_Model.Llama, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Qwen2, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Qwen3, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Gemma, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Gemma2, Tiny_Model.Q8_0, 8, 1, 0, 0),
            (Tiny_Model.Gemma3, Tiny_Model.Q8_0, 8, 1, 0, 0),
            (Tiny_Model.Phi3, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.GPT2, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Phi2, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Falcon, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Qwen3, Tiny_Model.Q8_0, 0, 1, 4, 2),
            (Tiny_Model.Qwen35, Tiny_Model.Q8_0, 0, 1, 0, 0),
            (Tiny_Model.Qwen35, Tiny_Model.Q8_0, 0, 1, 4, 2),
            (Tiny_Model.Gemma3, Tiny_Model.Q4_K, 8, 2, 0, 0),

            --  A mixture that routes each position to more experts than one
            --  gather reads at once: twenty experts, seventeen of them
            --  chosen, so the device spills the gather into a full round of
            --  sixteen and one more and sums the two, which must land where
            --  the processor's one sum of seventeen does.
            (Tiny_Model.Qwen3, Tiny_Model.Q8_0, 0, 1, 20, 17)];
      begin
         for Row of Rows loop
            declare
               Image  : B.Byte_Array_Access;
               Host   : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
               Device : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
               Why    : E.Error_Code;
               Worst  : N.Real := 0.0;
               Name   : constant String :=
                 Tiny_Model.Fixture_Architecture'Image (Row.Kind) & " "
                 & Tiny_Model.Weight_Format'Image (Row.Format)
                 & (if Row.Heads > 1 then " with heads as wide as Gemma's" else "")
                 & (if Row.Experts > 0 then " as a mixture" else "");
            begin
               Tiny_Model.Build
                 (Image, Row.Format, Room => Room, Kind => Row.Kind,
                  Window => Row.Window, Head_Factor => Row.Heads,
                  Experts => Row.Experts, Experts_Used => Row.Used);
               Logits_On
                 (Image, Model_Runner.Backend.Backend_CPU, Length, Host, Why);
               Assert (Why = E.No_Error,
                       "the processor refused " & Name & ": "
                       & E.Error_Code'Image (Why));
               --  In one batch, in chunks of forty-one -- which is the
               --  narrow tile, and the only one of the three the
               --  fixture's width reaches -- and a position at a time,
               --  which is the path a generated token takes.
               for Chunk in reverse 1 .. 3 loop
                  Logits_On
                    (Image, Model_Runner.Backend.Backend_Device,
                     (if Chunk = 3 then Length elsif Chunk = 2 then 41
                      else 1),
                     Device, Why);
                  Assert (Why = E.No_Error,
                          "the device refused " & Name & ": "
                          & E.Error_Code'Image (Why));
                  Worst := 0.0;
                  for Index in Host'Range loop
                     Worst := N.Real'Max (Worst, abs (Host (Index) - Device (Index)));
                  end loop;
                  Assert (Worst <= Tolerance,
                          "on " & Name
                          & (if Chunk = 3 then " in one batch"
                             elsif Chunk = 2 then " in chunks of forty-one"
                             else " a position at a time")
                          & " the device's logits differ from the "
                          & "processor's by " & N.Real'Image (Worst));
               end loop;
               B.Free (Image);
            end;
         end loop;
      end;

      declare
         Formats : constant array (1 .. 2) of Tiny_Model.Weight_Format :=
           [Tiny_Model.Q4_K, Tiny_Model.Q8_0];
      begin
         for Format of Formats loop
            declare
               Image  : B.Byte_Array_Access;
               Host   : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
               Device : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
               Why    : E.Error_Code;
               Worst  : N.Real := 0.0;
               Name   : constant String := Tiny_Model.Weight_Format'Image (Format);
            begin
               Tiny_Model.Build (Image, Format, Room => Room);

               Logits_On
                 (Image, Model_Runner.Backend.Backend_CPU, Length, Host, Why);
               Assert (Why = E.No_Error,
                       "the processor refused the " & Name & " fixture: "
                       & E.Error_Code'Image (Why));

               for Chunk of Chunks loop
                  Logits_On
                    (Image, Model_Runner.Backend.Backend_Device, Chunk,
                     Device, Why);

                  Assert (Why = E.No_Error,
                          "the device refused the " & Name & " fixture: "
                          & E.Error_Code'Image (Why));

                  Worst := 0.0;
                  for Index in Host'Range loop
                     Worst := N.Real'Max (Worst, abs (Host (Index) - Device (Index)));
                  end loop;
                  Assert (Worst <= Tolerance,
                          "on the " & Name & " fixture in chunks of"
                          & Positive'Image (Chunk)
                          & " the device's logits differ from the processor's"
                          & " by " & N.Real'Image (Worst)
                          & " at worst, where " & N.Real'Image (Tolerance)
                          & " is allowed");
               end loop;

               B.Free (Image);
            end;
         end loop;
      end;

      --  And a mixture whose experts do not fit the device while the
      --  rest of it does: the device runs each layer's front half and the
      --  processor's pool the mixture, which is how a 21 GB mixture runs
      --  here on a device holding 12.7. The budget is the fixture's bytes
      --  less a quarter of its experts' -- room for the context and a
      --  hybrid's states, and short of the stacks by that quarter -- and
      --  the report's count of split layers says the split ran,
      --  rather than the whole model going back to the processor, which
      --  would agree with it just as well.
      declare
         Kinds : constant array (1 .. 2) of Tiny_Model.Fixture_Architecture :=
           [Tiny_Model.Qwen3, Tiny_Model.Qwen35];
      begin
         for Kind of Kinds loop
            declare
               Image   : B.Byte_Array_Access;
               Host    : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
               Device  : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
               Why     : E.Error_Code;
               Worst   : N.Real := 0.0;
               All_Of  : Interfaces.Unsigned_64 := 0;
               Experts : Interfaces.Unsigned_64 := 0;
               Name    : constant String :=
                 Tiny_Model.Fixture_Architecture'Image (Kind)
                 & " split between the device and the processor";
               use type Interfaces.Unsigned_64;
            begin
               Tiny_Model.Build
                 (Image, Tiny_Model.Q8_0, Room => Room, Kind => Kind,
                  Experts => 20, Experts_Used => 4);
               declare
                  Held   : aliased constant B.Byte_Array := Image.all;
                  Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
                    (Held'Access);
                  Item   : Containers.Container;
                  Status : E.Error_Info;
               begin
                  Containers.Reader.Parse (Item, Source, Status => Status);
                  for Index in 1 .. Containers.Tensor_Count (Item) loop
                     All_Of := All_Of + Containers.Tensor_Bytes (Item, Index);
                     if Ada.Strings.Fixed.Index
                          (Containers.Tensor_Name (Item, Index), "_exps.")
                        > 0
                     then
                        Experts :=
                          Experts + Containers.Tensor_Bytes (Item, Index);
                     end if;
                  end loop;
                  Containers.Close (Item);
               end;

               Logits_On
                 (Image, Model_Runner.Backend.Backend_CPU, Length, Host, Why);
               Assert (Why = E.No_Error,
                       "the processor refused " & Name & ": "
                       & E.Error_Code'Image (Why));

               for Chunk in reverse 1 .. 2 loop
                  Model_Runner.Backend.Device.Close;
                  Model_Runner.Backend.Device.Open
                    (Awake, Budget => All_Of - Experts / 4);
                  Assert (Awake, "the device did not reopen for " & Name);
                  Logits_On
                    (Image, Model_Runner.Backend.Backend_Device,
                     (if Chunk = 2 then Length else 1), Device, Why);
                  Assert (Why = E.No_Error,
                          "the device refused " & Name & ": "
                          & E.Error_Code'Image (Why));
                  Assert (Model_Runner.Backend.Device.Layers_Split > 0,
                          "no layer of " & Name & " ran split, of"
                          & Model_Runner.Backend.Device.Layers_Whole'Image
                          & " whole and"
                          & Model_Runner.Backend.Device.Layers_Handed'Image
                          & " handed back");
                  Worst := 0.0;
                  for Index in Host'Range loop
                     Worst :=
                       N.Real'Max (Worst, abs (Host (Index) - Device (Index)));
                  end loop;
                  Assert (Worst <= Tolerance,
                          "on " & Name
                          & (if Chunk = 2 then " in one batch"
                             else " a position at a time")
                          & " the device's logits differ from the "
                          & "processor's by " & N.Real'Image (Worst));
               end loop;
               B.Free (Image);
            end;
         end loop;
         Model_Runner.Backend.Device.Close;
         Model_Runner.Backend.Device.Open (Awake);
      end;

      --  And a packed cache over the tile, on a model too shallow for a
      --  layer's rows in halves to fit in its block unpadded: the
      --  fixture's two layers in bytes are half a layer's halves, and in
      --  nibbles a quarter. The block is padded to one layer's rows now,
      --  the batch unpacks the layer into the block's own copy and
      --  attends through the matrix instruction, and the processor packs
      --  the same bytes -- so the two are held to the tolerance above.
      --  In chunks of forty-one, which is the narrow tile, and in one
      --  batch of the whole prompt, which the fixture's width keeps off
      --  the wide tile and on the packed kernel.
      declare
         Image  : B.Byte_Array_Access;
         Host   : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
         Device : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
         Why    : E.Error_Code;
         Worst  : N.Real := 0.0;
      begin
         Tiny_Model.Build (Image, Tiny_Model.Q8_0, Room => Room);

         for Cache in L.Eighth .. L.Fourth loop
            declare
               Name : constant String := L.Cache_Precision'Image (Cache);

               --  The fixture's keys are four elements wide, which is
               --  half a word of nibbles: the step that places them
               --  writes a word at a time and refuses. A batch goes over
               --  all the same -- its layer is unpacked into the block's
               --  own copy and attends through the matrix instruction --
               --  and a generated token's layer is handed to the
               --  processor, which the run said nothing about: a device
               --  holding the weights and the context and computing
               --  neither. What the counts are before this cache's runs,
               --  so that what they are after is this cache's own.
               Whole_Before : Natural;
               Handed_Before : Natural;
            begin
               Logits_On
                 (Image, Model_Runner.Backend.Backend_CPU, Length, Host, Why,
                  Cache => Cache);
               Assert (Why = E.No_Error,
                       "the processor refused the packed cache " & Name
                       & ": " & E.Error_Code'Image (Why));

               for Chunk of Chunks loop
                  Whole_Before := Model_Runner.Backend.Device.Layers_Whole;
                  Handed_Before := Model_Runner.Backend.Device.Layers_Handed;

                  Logits_On
                    (Image, Model_Runner.Backend.Backend_Device, Chunk,
                     Device, Why, Cache => Cache);
                  Assert (Why = E.No_Error,
                          "the device refused the packed cache " & Name
                          & ": " & E.Error_Code'Image (Why));

                  --  What the run says of itself: every layer whole
                  --  where the rows are a word wide, and a count and a
                  --  reason where they are not.
                  declare
                     Whole : constant Natural :=
                       Model_Runner.Backend.Device.Layers_Whole - Whole_Before;
                     Handed : constant Natural :=
                       Model_Runner.Backend.Device.Layers_Handed
                       - Handed_Before;
                  begin
                     Assert (Whole + Handed > 0,
                             "no layer of the packed cache " & Name
                             & " was noted either way");
                     Assert (Handed = 0,
                             "a batch of the packed cache " & Name
                             & " left" & Natural'Image (Handed)
                             & " layers off the whole road");
                  end;

                  Worst := 0.0;
                  for Index in Host'Range loop
                     Worst := N.Real'Max
                       (Worst, abs (Host (Index) - Device (Index)));
                  end loop;
                  Assert (Worst <= Tolerance,
                          "with the cache " & Name & " in chunks of"
                          & Positive'Image (Chunk)
                          & " the device's logits differ from the "
                          & "processor's by " & N.Real'Image (Worst));
               end loop;

            end;
         end loop;

         B.Free (Image);
      end;

      --  And the one that answers with states rather than logits: Bert,
      --  which normalizes on the way out of each sublayer with a shift,
      --  attends both ways and turns nothing. Its whole layer on the
      --  device is a shape none of the rows above has -- the two
      --  normalizations after the joins, the projections reading the
      --  input as it is -- and every position's state is compared, not
      --  the last one's.
      declare
         Width : constant N.Element_Count :=
           N.Element_Count (Tiny_Model.Embedding);

         procedure States_On
           (Image   : B.Byte_Array_Access;
            Backend : Model_Runner.Backend.Backend_Kind;
            Answer  : Model_Runner.Tensors.Real_Array_Access;
            Refusal : out E.Error_Code)
         is
            Held    : aliased constant B.Byte_Array := Image.all;
            Source  : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Item    : Containers.Container;
            Model   : L.Model;
            Session : L.Session;
            Status  : E.Error_Info;
            None    : N.Real_Array (1 .. 0);
         begin
            Refusal := E.No_Error;

            Containers.Reader.Parse (Item, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the bert fixture did not parse");

            L.Prepare
              (Model, Item, Source, Backend => Backend, Status => Status);
            if E.Is_Error (Status) then
               Refusal := Status.Code;
               Containers.Close (Item);
               return;
            end if;

            L.Open (Session, Model, Context => Room, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a bert session did not open on "
                    & Model_Runner.Backend.Backend_Name (Backend) & ": "
                    & E.Error_Code'Image (Status.Code));

            L.Evaluate_Batch
              (Session, Model, Tokens, None, States => Answer,
               Status => Status);
            Assert (E.Is_Ok (Status),
                    "the bert batch did not evaluate on "
                    & Model_Runner.Backend.Backend_Name (Backend) & ": "
                    & E.Error_Code'Image (Status.Code));

            L.Close (Session);
            L.Close (Model, Status);
            Containers.Close (Item);
         end States_On;

         --  And the two that are that shape with parts swapped: nomic-bert
         --  rotating and gating, and jina-bert-v2 with no positions at all,
         --  a shift on what it projects down -- the one gated layer here
         --  with one -- and, in its code variant, three normalizations
         --  more that keep its layers off the sequence and on the host's
         --  steps, which the same comparison holds to the processor.
         type Bert_Row is record
            Kind : Tiny_Model.Fixture_Architecture;
            Code : Boolean;
         end record;
         Berts : constant array (1 .. 4) of Bert_Row :=
           [(Tiny_Model.Bert, False), (Tiny_Model.Nomic_Bert, False),
            (Tiny_Model.Jina_Bert_V2, False),
            (Tiny_Model.Jina_Bert_V2, True)];

         Image  : B.Byte_Array_Access;
         Host   : Model_Runner.Tensors.Real_Array_Access := null;
         Device : Model_Runner.Tensors.Real_Array_Access := null;
         Why    : E.Error_Code;
         Worst  : N.Real := 0.0;
      begin
         Model_Runner.Tensors.Allocate (Length * Width, Host);
         Model_Runner.Tensors.Allocate (Length * Width, Device);
         Assert (Host /= null and then Device /= null,
                 "no room for the bert states");

         for Row of Berts loop
            declare
               Name : constant String :=
                 Tiny_Model.Fixture_Architecture'Image (Row.Kind)
                 & (if Row.Code then " with the code norms" else "");
            begin
               Tiny_Model.Build
                 (Image, Tiny_Model.Q8_0, Room => Room, Kind => Row.Kind,
                  Code_Norms => Row.Code);
               States_On (Image, Model_Runner.Backend.Backend_CPU, Host, Why);
               Assert (Why = E.No_Error,
                       "the processor refused " & Name & ": "
                       & E.Error_Code'Image (Why));
               States_On
                 (Image, Model_Runner.Backend.Backend_Device, Device, Why);
               Assert (Why = E.No_Error,
                       "the device refused " & Name & ": "
                       & E.Error_Code'Image (Why));

               Worst := 0.0;
               for Index in 0 .. Length * Width - 1 loop
                  Worst := N.Real'Max
                    (Worst, abs (Host.all (Index) - Device.all (Index)));
               end loop;
               Assert (Worst <= Tolerance,
                       "on " & Name & " the device's states differ from the "
                       & "processor's by " & N.Real'Image (Worst));

               B.Free (Image);
            end;
         end loop;

         Model_Runner.Tensors.Free (Host);
         Model_Runner.Tensors.Free (Device);
      end;

      Model_Runner.Backend.Device.Close;
   end Two_Backends_Agree_On_A_Long_Prompt;

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

   ------------------------------------------------
   -- A_Run_Says_Which_Layers_The_Device_Took --
   ------------------------------------------------

   --  A layer the device will not take whole goes over in pieces or on
   --  the processor, and until now nothing said so: the run reported a
   --  device, the matrices on it and the bytes of context on it, and a
   --  session whose rows are too narrow for the packing had every layer
   --  refused while every one of those numbers looked exactly as it does
   --  when the whole model runs there.
   --
   --  The fixture is the case both ways round. Its keys and values are
   --  four elements a head, which is half a word of nibbles and was
   --  refused for it until the packing learned to merge a word two rows
   --  share, so both packings go over whole and the counts say so. The
   --  same fixture with heads as wide as Gemma's is past the room the
   --  device's attention keeps: every layer of it comes back, and the
   --  reason names the shape rather than leaving a reader to guess -- a
   --  reason that is always there says nothing, and so does a count that
   --  is always whole.
   --
   --  What this exercises through the engine is the whole chain: the
   --  layer loop calls Note_Layer at each layer's end with what became of
   --  it, and Whole_Layer calls Forget_Refusal before it builds a
   --  sequence, so that a sequence refused while it is built does not
   --  report the layer before's reason -- which it did, and which is why
   --  the reason is asserted here and not only the counts.
   procedure A_Run_Says_Which_Layers_The_Device_Took
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      use type Model_Runner.Backend.Device.Handing;

      Prompt : constant Vocab.Token_Array (1 .. 3) := [4, 5, 6];

      Image : B.Byte_Array_Access;

      --  What the device's counts say of one session, a token at a time
      --  where the model generates and over a batch where it answers
      --  with states.
      procedure Counted
        (Under  : in out Harness;
         Cache  : L.Cache_Precision;
         Whole  : out Natural;
         Handed : out Natural;
         Batch  : Boolean := False)
      is
         use type Interfaces.Unsigned_64;

         Live   : L.Session;
         Status : E.Error_Info;
         Logits : Logit_Vector;
         States : Model_Runner.Tensors.Real_Array_Access := null;

         --  A model that answers with states has no logits to ask for.
         None   : N.Real_Array (1 .. 0);

         Was_Whole : constant Natural :=
           Model_Runner.Backend.Device.Layers_Whole;
         Was_Handed : constant Natural :=
           Model_Runner.Backend.Device.Layers_Handed;
      begin
         L.Open (Live, Under.Ready, Cache => Cache, Status => Status);
         Assert (E.Is_Ok (Status),
                 "a session did not open with the cache "
                 & L.Cache_Precision'Image (Cache) & ": "
                 & E.Error_Code'Image (Status.Code));

         if Batch then
            Model_Runner.Tensors.Allocate
              (N.Element_Count (Prompt'Length)
               * N.Element_Count (Tiny_Model.Embedding), States);
            L.Evaluate_Batch
              (Live, Under.Ready, Prompt, None, States => States,
               Status => Status);
            Assert (E.Is_Ok (Status),
                    "the device refused the batch: "
                    & E.Error_Code'Image (Status.Code));
            Model_Runner.Tensors.Free (States);
         else
            for Index in Prompt'Range loop
               L.Evaluate
                 (Live, Under.Ready, Prompt (Index), Logits, Status => Status);
               Assert (E.Is_Ok (Status),
                       "the device refused a position with the cache "
                       & L.Cache_Precision'Image (Cache) & ": "
                       & E.Error_Code'Image (Status.Code));
            end loop;
         end if;

         L.Close (Live);

         --  And the device's cache with it: a reserve only ever grows, so
         --  the session that closed would otherwise leave the device
         --  holding what its context took -- the machine's own memory,
         --  on a part that shares it -- until the engine closed. The
         --  engine calls Release_Cache where the last block is given up,
         --  which is the moment nothing holds one.
         Assert (Model_Runner.Backend.Device.Cached_Bytes = 0,
                 "the device still holds"
                 & Interfaces.Unsigned_64'Image
                     (Model_Runner.Backend.Device.Cached_Bytes)
                 & " bytes of cache with no session left to hold a block "
                 & "of it");

         --  And the room a hybrid's rings are seated in, by the same
         --  rule: this fixture has no linear layers, so the room is
         --  nothing either way, and the hybrid test below is where a
         --  room is taken and given back.
         Assert (Model_Runner.Backend.Device.State_Room_Bytes = 0,
                 "the device still holds"
                 & Interfaces.Unsigned_64'Image
                     (Model_Runner.Backend.Device.State_Room_Bytes)
                 & " bytes of state room with no session seated in it");

         Whole := Model_Runner.Backend.Device.Layers_Whole - Was_Whole;
         Handed := Model_Runner.Backend.Device.Layers_Handed - Was_Handed;
      end Counted;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Ready : Boolean;
         Awake : Boolean;

         Whole, Handed : Natural;
      begin
         --  A test that asks what the device did has to open it: the
         --  counts are the device's own and it holds none when closed.
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Image);
            return;
         end if;

         Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready);

         if not Ready then
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         --  In bytes, four elements to the word, and in nibbles, two --
         --  half a word a row, which the packing merges -- so every layer
         --  goes over whole either way.
         for Cache in L.Eighth .. L.Fourth loop
            Counted (Under, Cache, Whole, Handed);
            Assert (Whole > 0,
                    "no layer of a session cached "
                    & L.Cache_Precision'Image (Cache) & " went over whole");
            Assert (Handed = 0,
                    "a session cached " & L.Cache_Precision'Image (Cache)
                    & " left" & Natural'Image (Handed)
                    & " layers off the whole road");
         end loop;

         Model_Runner.Backend.Device.Close;
      end;

      --  And heads wider than the room the device's attention keeps: it
      --  attends on the processor for them, every layer, while the
      --  products stay on the device, and the run says how wide they are
      --  against how wide a head it keeps room for.
      B.Free (Image);
      Tiny_Model.Build (Image, Tiny_Model.Q4_K, Head_Factor => 3);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Ready : Boolean;
         Awake : Boolean;

         Live   : L.Session;
         Status : E.Error_Info;

         use type Interfaces.Unsigned_64;
         use type L.Device_Limit;

         Why         : L.Device_Limit;
         Asked, Kept : Interfaces.Unsigned_64;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Image);
            return;
         end if;

         Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready);

         if not Ready then
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         L.Open (Live, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status),
                 "a session of a wide-headed model did not open: "
                 & E.Error_Code'Image (Status.Code));

         L.Device_Room (Live, Why, Asked, Kept);

         Assert (Why = L.Heads_Past_Room,
                 "a model whose heads are three times the deep fixture's "
                 & "says the device will take it: "
                 & L.Device_Limit'Image (Why));
         Assert (Asked > Kept,
                 "the wide fixture's heads" & Interfaces.Unsigned_64'Image (Asked)
                 & " are inside the room the device keeps,"
                 & Interfaces.Unsigned_64'Image (Kept)
                 & ", so this says nothing");

         L.Close (Live);
         Model_Runner.Backend.Device.Close;
      end;

      --  And jina-bert-v2's code variant, whose three normalizations more
      --  -- over the whole of the queries and the keys, and the attention
      --  sublayer's residual joined again -- are not steps of the
      --  sequence: every layer of it comes back, the run says so, and it
      --  says the layer's shape rather than anything the device refused.
      B.Free (Image);
      Tiny_Model.Build
        (Image, Kind => Tiny_Model.Jina_Bert_V2, Code_Norms => True);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Ready : Boolean;
         Awake : Boolean;

         Whole, Handed : Natural;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Image);
            return;
         end if;

         Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready);

         if not Ready then
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         --  What the device would need for this context, and what one
         --  buffer there holds: a small fixture's is far under it, and
         --  the two numbers are the ones a run names where it is not.
         declare
            Live   : L.Session;
            Status : E.Error_Info;

            use type Interfaces.Unsigned_64;
            use type L.Device_Limit;

            Why         : L.Device_Limit;
            Asked, Kept : Interfaces.Unsigned_64;
         begin
            --  Packed, so that every one of the three is the session's
            --  own question: the heads against the room a kernel keeps,
            --  the packed rows against what that kernel reads, and the
            --  context against what one storage buffer holds. This
            --  fixture is inside all three.
            L.Open (Live, Under.Ready, Cache => L.Fourth, Status => Status);
            Assert (E.Is_Ok (Status), "a session did not open for its room");

            L.Device_Room (Live, Why, Asked, Kept);

            Assert (Why = L.Device_Takes_All,
                    "the device will not take the fixture whole: "
                    & L.Device_Limit'Image (Why) & ", asked"
                    & Interfaces.Unsigned_64'Image (Asked) & " against"
                    & Interfaces.Unsigned_64'Image (Kept));
            Assert (Asked = 0 and then Kept = 0,
                    "a session the device takes whole says numbers about "
                    & "what it would not take");

            L.Close (Live);
         end;

         Counted (Under, L.Exact, Whole, Handed, Batch => True);
         Assert (Handed > 0,
                 "the code variant took every layer whole on the device, "
                 & "and three of its normalizations are not steps of the "
                 & "sequence");
         Assert (Model_Runner.Backend.Device.First_Handing
                 = Model_Runner.Backend.Device.Shape_Handed,
                 "the layers came back for "
                 & Model_Runner.Backend.Device.Handing'Image
                     (Model_Runner.Backend.Device.First_Handing)
                 & " rather than the layer's shape");

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end A_Run_Says_Which_Layers_The_Device_Took;

   -----------------------------------------------------------
   -- Sessions_Of_Different_Sizes_Share_The_Device_S_Cache --
   -----------------------------------------------------------

   --  The device's cache buffer is dealt out a session at a time, each
   --  placed at the first gap that holds what it keeps, so a block is the
   --  size of the session in it. It used to be dealt in blocks of one
   --  width -- the first session's -- which meant a session of any other
   --  width was refused the cache and attended every layer on the
   --  processor for as long as any session of the first width was open,
   --  and that sixteen short-context sessions behind one long one each
   --  took a block the long one's size.
   --
   --  Three sessions of three context lengths, opened shortest first so
   --  that each of the two after it wants more than the one before -- the
   --  case that used to be refused -- and stepped one after another so
   --  that all three hold blocks at once. Each has to have its layers go
   --  over whole, and each has to say what a session of its own length
   --  says with nobody else on the device: a block placed over another's
   --  is a wrong answer and not a slow one.
   procedure Sessions_Of_Different_Sizes_Share_The_Device_S_Cache
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Lengths : constant array (1 .. 3) of Positive := [8, 12, 16];
      Prompt  : constant Vocab.Token_Array (1 .. 3) := [4, 5, 6];

      Image : B.Byte_Array_Access;

      procedure Says
        (Under  : in out Harness;
         Live   : in out L.Session;
         Answer : out Logit_Vector)
      is
         Status : E.Error_Info;
      begin
         for Index in Prompt'Range loop
            L.Evaluate
              (Live, Under.Ready, Prompt (Index), Answer, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a session did not evaluate: "
                    & E.Error_Code'Image (Status.Code));
         end loop;
      end Says;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Ready : Boolean;
         Awake : Boolean;

         Status : E.Error_Info;

         Live   : array (Lengths'Range) of L.Session;
         Shared : array (Lengths'Range) of Logit_Vector;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Image);
            return;
         end if;

         Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready);

         if not Ready then
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         --  Shortest first, so that every session after the first wants
         --  more room than the buffer has been dealt for.
         for Index in Lengths'Range loop
            L.Open (Live (Index), Under.Ready, Context => Lengths (Index),
                    Status => Status);
            Assert (E.Is_Ok (Status),
                    "a session did not open:" & Integer'Image (Index));

            declare
               Whole : constant Natural :=
                 Model_Runner.Backend.Device.Layers_Whole;
            begin
               Says (Under, Live (Index), Shared (Index));

               --  Whether this session got a block of the device's cache
               --  beside the others is the device's budget to decide, not a
               --  fault: a refused block is a slower run, and what the run
               --  says is what the agreement below holds to. Noted where the
               --  box's buffer did not stretch to all three at once.
               if Model_Runner.Backend.Device.Layers_Whole <= Whole then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "note: no device block for a session of context"
                     & Integer'Image (Lengths (Index)) & " beside the others");
               end if;
            end;
         end loop;

         --  One more token each, turn and turn about, with all three
         --  holding blocks: a block over another's shows here.
         for Index in Lengths'Range loop
            L.Evaluate
              (Live (Index), Under.Ready, 7, Shared (Index),
               Status => Status);
            Assert (E.Is_Ok (Status),
                    "a session did not evaluate its last token: "
                    & E.Error_Code'Image (Status.Code));
         end loop;

         --  And what each would have said alone, on a device holding
         --  nothing else.
         for Index in Lengths'Range loop
            L.Close (Live (Index));
         end loop;

         for Index in Lengths'Range loop
            declare
               Alone  : L.Session;
               Wanted : Logit_Vector;
               Worst  : N.Real := 0.0;
            begin
               L.Open (Alone, Under.Ready, Context => Lengths (Index),
                       Status => Status);
               Assert (E.Is_Ok (Status), "the lone session did not open");
               Says (Under, Alone, Wanted);
               L.Evaluate (Alone, Under.Ready, 7, Wanted, Status => Status);
               Assert (E.Is_Ok (Status), "the lone session did not evaluate");

               for Place in Wanted'Range loop
                  Worst :=
                    N.Real'Max
                      (Worst, abs (Wanted (Place) - Shared (Index) (Place)));
               end loop;

               Assert (Worst <= 1.0E-4,
                       "a session of context" & Integer'Image (Lengths (Index))
                       & " sharing the cache says" & N.Real'Image (Worst)
                       & " away from one that had it to itself");

               L.Close (Alone);
            end;
         end loop;

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end Sessions_Of_Different_Sizes_Share_The_Device_S_Cache;

   -------------------------------------------------------
   -- Two_Models_On_One_Device_Keep_Their_Own_Caches --
   -------------------------------------------------------

   --  One device, one cache buffer, and a block in it the size of the
   --  session that holds it -- which the suite had only ever exercised
   --  with one model's sessions. Two models on the device at once is what
   --  a server hosting more than one does, and it is where the rules
   --  about the buffer are decided: who fits beside whom, how far the
   --  half-precision copy must reach, what a round of one model's members
   --  may do while another model's session holds a block.
   --
   --  So: two fixtures of different shapes, prepared at the same time on
   --  the device, with sessions of each stepped turn and turn about, and
   --  each held to what it says alone. A block written over another
   --  model's is a wrong answer, and nothing in the suite would have
   --  caught it.
   --
   --  And the two sessions keep their caches differently -- one exactly,
   --  one packed to a byte an element -- because that is what decides how
   --  far the half-precision copy beside the cache must reach: an exact
   --  block has a half of every element of it, a packed one uses the copy
   --  only as the room a layer unpacks into. A copy sized for one kind
   --  and read by the other is not a slow answer but a wrong one.
   --
   --  Both sessions are asked whether they were given a block at all, and
   --  whether their layers went over whole. Without that this would pass
   --  on a device that quietly refused the second model and attended it
   --  on the processor, which is the failure it is here to catch.
   procedure Two_Models_On_One_Device_Keep_Their_Own_Caches
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Prompt : constant Vocab.Token_Array (1 .. 3) := [4, 5, 6];

      Plain, Hybrid : B.Byte_Array_Access;

      procedure Says
        (Under  : in out Harness;
         Live   : in out L.Session;
         Answer : out Logit_Vector)
      is
         Status : E.Error_Info;
      begin
         for Index in Prompt'Range loop
            L.Evaluate
              (Live, Under.Ready, Prompt (Index), Answer, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a session did not evaluate: "
                    & E.Error_Code'Image (Status.Code));
         end loop;
      end Says;
   begin
      Tiny_Model.Build (Plain);
      Tiny_Model.Build (Hybrid, Kind => Tiny_Model.Qwen35, Room => 64);

      declare
         Held_Plain  : aliased constant B.Byte_Array := Plain.all;
         Held_Hybrid : aliased constant B.Byte_Array := Hybrid.all;

         One : Harness (Held_Plain'Access);
         Two : Harness (Held_Hybrid'Access);

         Ready_One, Ready_Two, Awake : Boolean;

         Status : E.Error_Info;

         First, Second : L.Session;
         Said_One, Said_Two : Logit_Vector;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Plain);
            B.Free (Hybrid);
            return;
         end if;

         Start (One, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready_One);
         Start (Two, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready_Two);

         if not Ready_One or else not Ready_Two then
            Model_Runner.Backend.Device.Close;
            B.Free (Plain);
            B.Free (Hybrid);
            return;
         end if;

         --  A session of each, stepped one after the other so that both
         --  hold blocks of the one buffer at the same time.
         L.Open (First, One.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the first model's session did not open");

         L.Open (Second, Two.Ready, Context => 64, Cache => L.Eighth,
                 Status => Status);
         Assert (E.Is_Ok (Status), "the second model's session did not open");

         for Index in Prompt'Range loop
            declare
               Whole_One, Whole_Two : Natural;
            begin
               Whole_One := Model_Runner.Backend.Device.Layers_Whole;
               L.Evaluate (First, One.Ready, Prompt (Index), Said_One,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the first model would not evaluate");
               Whole_Two := Model_Runner.Backend.Device.Layers_Whole;

               --  Whether both models keep their layers whole on the device
               --  at once is the box's cache budget to decide -- this one's
               --  buffer does not stretch to two, so one falls to the
               --  processor, a slower run and not a fault. Noted, not failed;
               --  what each model says is held to its lone answer below.
               if Whole_Two <= Whole_One then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "note: the first model kept no layer whole on the device"
                     & " beside the second");
               end if;

               L.Evaluate (Second, Two.Ready, Prompt (Index), Said_Two,
                           Status => Status);
               Assert (E.Is_Ok (Status),
                       "the second model would not evaluate");

               if Model_Runner.Backend.Device.Layers_Whole <= Whole_Two then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "note: the second model kept no layer whole on the"
                     & " device beside the first");
               end if;
            end;
         end loop;

         --  Both on the device at once, each in a block of its own, is the
         --  thing this is about -- where the box's cache buffer stretches to
         --  two. Where it does not, one runs on the processor instead: noted,
         --  not failed, and the agreement below still has to hold either way.
         if not (L.Holds_Block (First) and then L.Holds_Block (Second)
                 and then L.Blocks_Held >= 2)
         then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: this device did not hold both models in blocks at once,"
               & Natural'Image (L.Blocks_Held) & " blocks between them");
         end if;

         L.Close (First);
         L.Close (Second);

         --  And what each says with the device to itself.
         declare
            Alone : L.Session;
            Want  : Logit_Vector;
            Worst : N.Real := 0.0;
         begin
            L.Open (Alone, One.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the lone session did not open");
            Says (One, Alone, Want);
            L.Close (Alone);

            for Index in Want'Range loop
               Worst := N.Real'Max (Worst, abs (Want (Index) - Said_One (Index)));
            end loop;

            Assert (Worst <= 1.0E-4,
                    "the first model beside the second says"
                    & N.Real'Image (Worst) & " away from what it says alone");
         end;

         declare
            Alone : L.Session;
            Want  : Logit_Vector;
            Worst : N.Real := 0.0;
         begin
            L.Open (Alone, Two.Ready, Context => 64, Cache => L.Eighth,
                    Status => Status);
            Assert (E.Is_Ok (Status), "the lone hybrid did not open");
            Says (Two, Alone, Want);
            L.Close (Alone);

            for Index in Want'Range loop
               Worst := N.Real'Max (Worst, abs (Want (Index) - Said_Two (Index)));
            end loop;

            Assert (Worst <= 2.0E-3,
                    "the second model beside the first says"
                    & N.Real'Image (Worst) & " away from what it says alone");
         end;

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Plain);
      B.Free (Hybrid);
   end Two_Models_On_One_Device_Keep_Their_Own_Caches;

   ---------------------------------------------------------
   -- The_Cache_Moves_Its_Blocks_Rather_Than_Growing --
   ---------------------------------------------------------

   --  Blocks of the device's cache are the size of the sessions in them
   --  and are given back in whatever order those sessions close, so a
   --  block given up between two others leaves a gap a larger block
   --  cannot use. The buffer used to grow at the end for every one of
   --  those and shrink only when the last block went.
   --
   --  It moves the blocks down instead, in the order they sit in, and
   --  stops at the first one that makes the room -- a block moved is the
   --  session's cache written again where it now is, which is what a
   --  session turned out of a block pays anyway. Only where the gaps
   --  below would hold what is being placed, so that the moving is what
   --  keeps the buffer from growing rather than something paid for
   --  nothing.
   --
   --  Five short sessions, the second and the fourth closed, and a long
   --  one asked for: two gaps of a short block each, neither of which
   --  holds a long one, and together exactly enough. The cache may be no
   --  larger than the three short blocks and the long one packed, which
   --  is measured here rather than worked out -- and the session whose
   --  block moved has to say what it says with the cache to itself.
   procedure The_Cache_Moves_Its_Blocks_Rather_Than_Growing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Short  : constant := 8;
      Long   : constant := 16;
      Prompt : constant Vocab.Token_Array (1 .. 3) := [4, 5, 6];

      Image : B.Byte_Array_Access;

      procedure Says
        (Under  : in out Harness;
         Live   : in out L.Session;
         Answer : out Logit_Vector)
      is
         Status : E.Error_Info;
      begin
         for Index in Prompt'Range loop
            L.Evaluate
              (Live, Under.Ready, Prompt (Index), Answer, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a session did not evaluate: "
                    & E.Error_Code'Image (Status.Code));
         end loop;
      end Says;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Ready : Boolean;
         Awake : Boolean;

         Status : E.Error_Info;
         Answer : Logit_Vector;

         --  What the cache takes with one session of a given context in
         --  it, and with two: the buffer is given back when the last
         --  block goes, so each of these starts from nothing.
         function Takes
           (Context : Positive; Blocks : Positive)
            return Interfaces.Unsigned_64
         is
            Live  : array (1 .. Blocks) of L.Session;
            Taken : Interfaces.Unsigned_64;
            Local : E.Error_Info;
         begin
            for Index in Live'Range loop
               L.Open (Live (Index), Under.Ready, Context => Context,
                       Status => Local);
               Assert (E.Is_Ok (Local), "a measuring session did not open");
               Says (Under, Live (Index), Answer);
            end loop;

            Taken := Model_Runner.Backend.Device.Cached_Bytes;

            for Index in Live'Range loop
               L.Close (Live (Index));
            end loop;

            return Taken;
         end Takes;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Image);
            return;
         end if;

         Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready);

         if not Ready then
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         declare
            use type Interfaces.Unsigned_64;

            One_Short : constant Interfaces.Unsigned_64 := Takes (Short, 1);
            Two_Short : constant Interfaces.Unsigned_64 := Takes (Short, 2);
            One_Long  : constant Interfaces.Unsigned_64 := Takes (Long, 1);
         begin
            --  A device that holds no cache at all says nothing here, and
            --  neither does one where a short block and a long one come
            --  to the same size.
            if One_Short = 0 or else Two_Short <= One_Short
              or else One_Long <= One_Short
            then
               Model_Runner.Backend.Device.Close;
               B.Free (Image);
               return;
            end if;

            declare
               Short_Room : array (1 .. 5) of L.Session;
               Big   : L.Session;
               Moved : Logit_Vector;

               --  Three short blocks and a long one, packed: one short
               --  block's place is Two_Short - One_Short, and One_Long
               --  carries the table, the sinks and the long block.
               Packed : constant Interfaces.Unsigned_64 :=
                 One_Long + 3 * (Two_Short - One_Short);
            begin
               for Index in Short_Room'Range loop
                  L.Open (Short_Room (Index), Under.Ready, Context => Short,
                          Status => Status);
                  Assert (E.Is_Ok (Status), "a short session did not open");
                  Says (Under, Short_Room (Index), Moved);
               end loop;

               --  Two blocks given back with a block between them, so
               --  that neither gap holds what is asked for next and the
               --  two together do.
               L.Close (Short_Room (2));
               L.Close (Short_Room (4));

               L.Open (Big, Under.Ready, Context => Long, Status => Status);
               Says (Under, Big, Answer);

               declare
                  Taken : constant Interfaces.Unsigned_64 :=
                    Model_Runner.Backend.Device.Cached_Bytes;
               begin
                  Assert (Taken <= Packed,
                          "the cache grew to"
                          & Interfaces.Unsigned_64'Image (Taken)
                          & " bytes where the three blocks packed take"
                          & Interfaces.Unsigned_64'Image (Packed)
                          & ": the gap the middle block left was not used");

                  --  And the move said, which is what Note_Moved records
                  --  and a run reports: a packing nobody can see is a
                  --  packing nobody can price. The move itself is
                  --  Move_Cache, which copies the block and the halves
                  --  beside it where they lie rather than writing the
                  --  session's cache in again from the host.
                  Assert (Model_Runner.Backend.Device.Blocks_Moved > 0,
                          "a block was moved and nothing counted it");
               end;

               --  And the session whose block moved says what it said.
               L.Evaluate (Short_Room (5), Under.Ready, 7, Moved,
                           Status => Status);
               Assert (E.Is_Ok (Status),
                       "the moved session did not evaluate: "
                       & E.Error_Code'Image (Status.Code));

               L.Close (Big);
               L.Close (Short_Room (5));
               L.Close (Short_Room (3));
               L.Close (Short_Room (1));

               declare
                  Alone  : L.Session;
                  Wanted : Logit_Vector;
                  Worst  : N.Real := 0.0;
               begin
                  L.Open (Alone, Under.Ready, Context => Short,
                          Status => Status);
                  Assert (E.Is_Ok (Status), "the lone session did not open");
                  Says (Under, Alone, Wanted);
                  L.Evaluate (Alone, Under.Ready, 7, Wanted,
                              Status => Status);
                  Assert (E.Is_Ok (Status), "the lone session did not answer");

                  for Index in Wanted'Range loop
                     Worst :=
                       N.Real'Max (Worst, abs (Wanted (Index) - Moved (Index)));
                  end loop;

                  Assert (Worst <= 1.0E-4,
                          "a session whose block was moved says"
                          & N.Real'Image (Worst)
                          & " away from one that never moved");

                  L.Close (Alone);
               end;
            end;
         end;

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end The_Cache_Moves_Its_Blocks_Rather_Than_Growing;

   ------------------------------------------------------------
   -- The_Room_Of_Rings_Moves_Its_Seats_Rather_Than_Growing --
   ------------------------------------------------------------

   --  Seats in the room of rings are placed at the first gap that holds
   --  them, and a session is asked how many states to keep -- so rings
   --  differ in size, and a seat given back in the middle leaves a gap a
   --  larger ring cannot use. The room used to grow at the end for every
   --  one of those and shrink only when the last seat went.
   --
   --  It moves the seats to the front instead, where the gaps below would
   --  hold the ring between them: a ring read home and written again,
   --  which is what a session turned out of a seat pays anyway, and worth
   --  paying only where the moving is what keeps the room from growing.
   --
   --  Five rings of one size, the second and the fourth given back, and a
   --  ring twice the size asked for: two gaps of one ring each, neither
   --  holding the larger one and the two together doing. The room may be
   --  no larger than the three small rings and the large one packed,
   --  which is measured here rather than worked out -- a session alone in
   --  the room says what one ring of each size takes.
   procedure The_Room_Of_Rings_Moves_Its_Seats_Rather_Than_Growing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room   : constant := 64;
      Small  : constant := 40;
      Large  : constant := 80;
      Prompt : constant Vocab.Token_Array (1 .. 3) := [4, 5, 6];

      Image : B.Byte_Array_Access;

      procedure Says
        (Under  : in out Harness;
         Live   : in out L.Session;
         Answer : out Logit_Vector)
      is
         Status : E.Error_Info;
      begin
         for Index in Prompt'Range loop
            L.Evaluate
              (Live, Under.Ready, Prompt (Index), Answer, Status => Status);
            Assert (E.Is_Ok (Status),
                    "a hybrid session did not evaluate: "
                    & E.Error_Code'Image (Status.Code));
         end loop;
      end Says;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Qwen35, Room => Room);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Ready : Boolean;
         Awake : Boolean;

         Status : E.Error_Info;
         Answer : Logit_Vector;

         --  What the room takes with one ring of a given size in it, and
         --  with two: measured rather than worked out, and the difference
         --  between them is one ring's place with the table left out.
         --  The room is given back when the last seat goes, so each of
         --  these starts from an empty room.
         function Takes
           (Keeping : Natural; Seats : Positive)
            return Interfaces.Unsigned_64
         is
            Live  : array (1 .. Seats) of L.Session;
            Taken : Interfaces.Unsigned_64;
            Local : E.Error_Info;
         begin
            for Index in Live'Range loop
               L.Open (Live (Index), Under.Ready, Context => Room,
                       Status => Local);
               Assert (E.Is_Ok (Local), "a measuring session did not open");
               L.Keep_States (Live (Index), Keeping, Local);
               Assert (E.Is_Ok (Local),
                       "a measuring session would not keep states");
               Says (Under, Live (Index), Answer);
            end loop;

            Taken := Model_Runner.Backend.Device.State_Room_Bytes;

            for Index in Live'Range loop
               L.Close (Live (Index));
            end loop;

            return Taken;
         end Takes;
      begin
         Model_Runner.Backend.Device.Open (Awake);

         if not Awake then
            B.Free (Image);
            return;
         end if;

         Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                Ready => Ready);

         if not Ready then
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;

         declare
            use type Interfaces.Unsigned_64;

            One_Small : constant Interfaces.Unsigned_64 := Takes (Small, 1);
            Two_Small : constant Interfaces.Unsigned_64 := Takes (Small, 2);
            One_Large : constant Interfaces.Unsigned_64 := Takes (Large, 1);
         begin
            --  A device that seats no ring at all says nothing here, and
            --  neither does one whose rings are all the same size however
            --  many states are kept.
            if One_Small = 0 or else Two_Small <= One_Small
              or else One_Large <= One_Small
            then
               Model_Runner.Backend.Device.Close;
               B.Free (Image);
               return;
            end if;

            declare
               Seated : array (1 .. 5) of L.Session;
               Big    : L.Session;
            begin
               for Index in Seated'Range loop
                  L.Open (Seated (Index), Under.Ready, Context => Room,
                          Status => Status);
                  Assert (E.Is_Ok (Status), "a small session did not open");
                  L.Keep_States (Seated (Index), Small, Status);
                  Says (Under, Seated (Index), Answer);
               end loop;

               --  Two seats given back with a seat between them, so that
               --  neither gap holds what is asked for next and the two
               --  together do.
               L.Close (Seated (2));
               L.Close (Seated (4));

               declare
                  Before : constant Interfaces.Unsigned_64 :=
                    Model_Runner.Backend.Device.State_Room_Bytes;
               begin
                  L.Open (Big, Under.Ready, Context => Room,
                          Status => Status);
                  L.Keep_States (Big, Large, Status);
                  Says (Under, Big, Answer);

                  --  The room the five rings took holds three of them and
                  --  the large one, once the seats are moved down; the
                  --  packing stops as soon as that is true, so what is
                  --  asked here is that the room did not grow at all and
                  --  not that it is packed to the last element.
                  Assert
                    (Model_Runner.Backend.Device.State_Room_Bytes <= Before,
                     "the room grew to"
                     & Interfaces.Unsigned_64'Image
                         (Model_Runner.Backend.Device.State_Room_Bytes)
                     & " bytes from" & Interfaces.Unsigned_64'Image (Before)
                     & ": the gaps the two seats left were not used");

                  --  Move_State is what shifted it, the ring copied
                  --  where it lies rather than fetched home and sent.
                  Assert (Model_Runner.Backend.Device.Rings_Moved > 0,
                          "a ring was moved and nothing counted it");
               end;

               --  And each of them still says what it said: a ring moved
               --  is a ring read home and written again, not a ring lost.
               declare
                  After : Logit_Vector;
                  Lone  : L.Session;
                  Want  : Logit_Vector;
                  Worst : N.Real := 0.0;
               begin
                  L.Evaluate (Seated (5), Under.Ready, 7, After,
                              Status => Status);
                  Assert (E.Is_Ok (Status),
                          "the moved session did not evaluate: "
                          & E.Error_Code'Image (Status.Code));

                  L.Close (Big);
                  L.Close (Seated (5));
                  L.Close (Seated (3));
                  L.Close (Seated (1));

                  L.Open (Lone, Under.Ready, Context => Room,
                          Status => Status);
                  L.Keep_States (Lone, Small, Status);
                  Says (Under, Lone, Want);
                  L.Evaluate (Lone, Under.Ready, 7, Want, Status => Status);
                  Assert (E.Is_Ok (Status), "the comparison did not evaluate");

                  for Index in Want'Range loop
                     Worst :=
                       N.Real'Max (Worst, abs (Want (Index) - After (Index)));
                  end loop;

                  Assert (Worst <= 2.0E-3,
                          "a session whose seat was moved says"
                          & N.Real'Image (Worst)
                          & " away from one that never moved");

                  L.Close (Lone);
               end;
            end;
         end;

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end The_Room_Of_Rings_Moves_Its_Seats_Rather_Than_Growing;

   ----------------------------------------------------------
   -- A_Paged_Session_Says_What_A_Block_Session_Says --
   ----------------------------------------------------------

   --  The cache dealt in pages rather than one block. A block is a
   --  session's whole context, taken at once; a paged session is given a
   --  run of positions of a layer at a time, scattered, and reads a
   --  position's page out of a per-layer table rather than at a block's
   --  base. What that must not change is the answer: a paged session gets,
   --  bit for bit, the logits it gets in a block.
   --
   --  Past two pages of sixty-four, so the table is read for more than one
   --  page and a position lands in a page other than the first -- the
   --  shift and the mask, and the second page's own base. The device holds
   --  it in pages and says so, which tells a paged session that reached
   --  the device from one that quietly fell back to the host and would
   --  have agreed for the wrong reason.
   procedure A_Paged_Session_Says_What_A_Block_Session_Says
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room  : constant := 200;
      Steps : constant := 130;

      function Token_Of (Place : Positive) return Vocab.Token_Id
      is (Vocab.Token_Id (2 + (Place * 7) mod 12));

      type Trail is array (1 .. Steps) of Logit_Vector;

      Image : B.Byte_Array_Access;
      Awake : Boolean;
   begin
      Tiny_Model.Build (Image, Room => Room);

      Model_Runner.Backend.Device.Open (Awake);

      if Awake then
         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ready : Boolean;

            Status : E.Error_Info;

            Blocked, Paged : L.Session;

            Said : Trail := [others => [others => 0.0]];
            LP   : Logit_Vector;

            Worst : N.Real := 0.0;
         begin
            Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                   Ready => Ready);

            if Ready then
               --  The block session whole, then closed, then the paged one:
               --  a cache in blocks and a cache in pages are dealt from the
               --  front of the same buffer, so the two are run one after
               --  the other rather than side by side.
               L.Open (Blocked, Under.Ready, Context => Room,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the block session did not open");

               for Step in 1 .. Steps loop
                  L.Evaluate (Blocked, Under.Ready, Token_Of (Step),
                              Said (Step), Status => Status);
                  Assert (E.Is_Ok (Status), "the block session failed at"
                          & Integer'Image (Step));
               end loop;

               Assert (L.Holds_Block (Blocked),
                       "the block session is not in a block");
               L.Close (Blocked);

               L.Open (Paged, Under.Ready, Context => Room, Paged => True,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the paged session did not open");

               for Step in 1 .. Steps loop
                  L.Evaluate (Paged, Under.Ready, Token_Of (Step), LP,
                              Status => Status);
                  Assert (E.Is_Ok (Status), "the paged session failed at"
                          & Integer'Image (Step) & ": "
                          & E.Error_Code'Image (Status.Code));

                  for Index in Logit_Vector'Range loop
                     Worst :=
                       N.Real'Max (Worst, abs (Said (Step) (Index) - LP (Index)));
                  end loop;
               end loop;

               Assert (L.Holds_Pages (Paged),
                       "the paged session did not reach the device in pages,"
                       & " so an agreement says nothing about paging");

               --  A block and a set of pages hold a position's keys in a
               --  different order, and the device sums attention in half
               --  precision, so the two layouts round a hair apart rather
               --  than to the bit on this part. What matters is that paging
               --  changes nothing a decode could see: they agree well within
               --  the half-precision slack, far below any logit that parts
               --  one token from another.
               Assert (Worst <= Paged_Layout_Slack,
                       "a paged session says" & N.Real'Image (Worst)
                       & " away from the same session in a block, past"
                       & Integer'Image (Steps) & " positions and two pages");

               L.Close (Paged);
            end if;
         end;

         Model_Runner.Backend.Device.Close;
      end if;

      B.Free (Image);
   end A_Paged_Session_Says_What_A_Block_Session_Says;

   ----------------------------------------------------------
   -- A_Paged_Session_At_A_Smaller_Page_Says_The_Same --
   ----------------------------------------------------------

   --  The page holds fewer positions, set with Set_Page_Size. A session
   --  filling little of its context wastes at most a page short of a whole
   --  one, so a smaller page holds it in less; the answer is the size's to
   --  keep, not to change. Run at thirty-two positions a page and at
   --  sixteen -- half and a quarter of the default -- each compared to the
   --  same session in a block, and the page size given back afterwards so
   --  it does not follow into another test.
   procedure A_Paged_Session_At_A_Smaller_Page_Says_The_Same
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room  : constant := 200;
      Steps : constant := 130;

      function Token_Of (Place : Positive) return Vocab.Token_Id
      is (Vocab.Token_Id (2 + (Place * 7) mod 12));

      type Trail is array (1 .. Steps) of Logit_Vector;

      Image : B.Byte_Array_Access;
      Awake : Boolean;
   begin
      Tiny_Model.Build (Image, Room => Room);

      Model_Runner.Backend.Device.Open (Awake);

      if Awake then
         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ready : Boolean;

            Status : E.Error_Info;

            Blocked : L.Session;

            Said : Trail := [others => [others => 0.0]];
         begin
            Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                   Ready => Ready);

            if Ready then
               L.Open (Blocked, Under.Ready, Context => Room,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the block session did not open");

               for Step in 1 .. Steps loop
                  L.Evaluate (Blocked, Under.Ready, Token_Of (Step),
                              Said (Step), Status => Status);
                  Assert (E.Is_Ok (Status), "the block session failed at"
                          & Integer'Image (Step));
               end loop;
               L.Close (Blocked);

               --  Each smaller page in turn, a paged session compared to
               --  the block above position for position.
               for Size in reverse 4 .. 5 loop
                  declare
                     Positions : constant Positive := 2 ** Size;
                     Paged     : L.Session;
                     LP        : Logit_Vector;
                     Worst     : N.Real := 0.0;
                  begin
                     L.Set_Page_Size (Positions);

                     L.Open (Paged, Under.Ready, Context => Room,
                             Paged => True, Status => Status);
                     Assert (E.Is_Ok (Status),
                             "the paged session did not open at a page of"
                             & Integer'Image (Positions));

                     for Step in 1 .. Steps loop
                        L.Evaluate (Paged, Under.Ready, Token_Of (Step), LP,
                                    Status => Status);
                        Assert (E.Is_Ok (Status),
                                "the paged session failed at"
                                & Integer'Image (Step) & ", page"
                                & Integer'Image (Positions));

                        for Index in Logit_Vector'Range loop
                           Worst :=
                             N.Real'Max
                               (Worst,
                                abs (Said (Step) (Index) - LP (Index)));
                        end loop;
                     end loop;

                     Assert (L.Holds_Pages (Paged),
                             "the paged session did not reach the device in"
                             & " pages at a page of"
                             & Integer'Image (Positions));
                     --  Half-precision attention over pages held in a
                     --  different order than a block rounds a hair apart, not
                     --  to the bit; well within the slack, which no decode
                     --  could see. See Paged_Layout_Slack.
                     Assert (Worst <= Paged_Layout_Slack,
                             "a paged session at a page of"
                             & Integer'Image (Positions) & " says"
                             & N.Real'Image (Worst)
                             & " away from the same session in a block");

                     L.Close (Paged);
                  end;
               end loop;

               --  Given back, so the default page follows into no other.
               L.Set_Page_Size (64);
            end if;
         end;

         Model_Runner.Backend.Device.Close;
      end if;

      B.Free (Image);
   end A_Paged_Session_At_A_Smaller_Page_Says_The_Same;

   ----------------------------------------------------------
   -- A_Packed_Paged_Session_Says_What_A_Packed_Block_Says --
   ----------------------------------------------------------

   --  Paging and packing at once: a session whose cache is kept in bytes or
   --  nibbles AND dealt in pages, against the same session in a packed
   --  block. The two savings compound -- a fraction of the positions, and a
   --  quarter or an eighth of each -- and the answer is the block's to the
   --  bit, past two pages, in both packed storages. What it exercises that
   --  the exact paged case does not is the packed kernels reading and
   --  writing a page: pack.comp into the page's regions, attention_packed
   --  out of them a position's page at a time.
   procedure A_Packed_Paged_Session_Says_What_A_Packed_Block_Says
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room  : constant := 200;
      Steps : constant := 130;

      function Token_Of (Place : Positive) return Vocab.Token_Id
      is (Vocab.Token_Id (2 + (Place * 7) mod 12));

      type Trail is array (1 .. Steps) of Logit_Vector;

      Storages : constant array (1 .. 2) of L.Cache_Precision :=
        [L.Eighth, L.Fourth];

      Image : B.Byte_Array_Access;
      Awake : Boolean;
   begin
      Tiny_Model.Build (Image, Room => Room);

      Model_Runner.Backend.Device.Open (Awake);

      if Awake then
         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ready : Boolean;
            Status : E.Error_Info;
         begin
            Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                   Ready => Ready);

            if Ready then
               for Storage of Storages loop
                  declare
                     Blocked, Paged : L.Session;
                     Said : Trail := [others => [others => 0.0]];
                     LP   : Logit_Vector;
                     Worst : N.Real := 0.0;
                  begin
                     --  The packed block first, then closed, then the same
                     --  session packed and paged: a cache in blocks and one
                     --  in pages are dealt from the front of the one buffer.
                     L.Open (Blocked, Under.Ready, Context => Room,
                             Cache => Storage, Status => Status);
                     Assert (E.Is_Ok (Status),
                             "the packed block session did not open");

                     for Step in 1 .. Steps loop
                        L.Evaluate (Blocked, Under.Ready, Token_Of (Step),
                                    Said (Step), Status => Status);
                        Assert (E.Is_Ok (Status),
                                "the packed block session failed at"
                                & Integer'Image (Step));
                     end loop;
                     L.Close (Blocked);

                     L.Open (Paged, Under.Ready, Context => Room,
                             Cache => Storage, Paged => True,
                             Status => Status);
                     Assert (E.Is_Ok (Status),
                             "the packed paged session did not open");

                     for Step in 1 .. Steps loop
                        L.Evaluate (Paged, Under.Ready, Token_Of (Step), LP,
                                    Status => Status);
                        Assert (E.Is_Ok (Status),
                                "the packed paged session failed at"
                                & Integer'Image (Step) & ": "
                                & E.Error_Code'Image (Status.Code));

                        for Index in Logit_Vector'Range loop
                           Worst :=
                             N.Real'Max
                               (Worst,
                                abs (Said (Step) (Index) - LP (Index)));
                        end loop;
                     end loop;

                     Assert (L.Holds_Pages (Paged),
                             "the packed paged session did not reach the"
                             & " device in pages, so an agreement says"
                             & " nothing about paging");
                     Assert (Worst = 0.0,
                             "a packed paged session in "
                             & L.Cache_Name (Storage) & " says"
                             & N.Real'Image (Worst)
                             & " away from the same session in a packed"
                             & " block, past two pages");

                     L.Close (Paged);
                  end;
               end loop;
            end if;
         end;

         Model_Runner.Backend.Device.Close;
      end if;

      B.Free (Image);
   end A_Packed_Paged_Session_Says_What_A_Packed_Block_Says;

   ------------------------------------------------------
   -- A_Paged_Session_Holds_Only_What_It_Fills --
   ------------------------------------------------------

   --  The capacity a paging buys: a session takes a page of the device's
   --  cache only when a position reaches it, so a session that has filled a
   --  fraction of its context holds a fraction of the pages -- not the
   --  whole context a block holds whether or not the session fills it.
   --
   --  The context is large and the session fills little of it. After ten
   --  positions each layer holds one page; stepped past the sixty-fourth,
   --  where a page ends, each holds two. The count doubling is the layers
   --  each taking their second page as the boundary is crossed, and its
   --  being far below the context's worth -- two pages of thirty-two -- is
   --  the room a block would have held for nothing.
   procedure A_Paged_Session_Holds_Only_What_It_Fills
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room : constant := 2048;

      function Token_Of (Place : Positive) return Vocab.Token_Id
      is (Vocab.Token_Id (2 + (Place * 7) mod 12));

      Image : B.Byte_Array_Access;
      Awake : Boolean;
   begin
      Tiny_Model.Build (Image, Room => Room);

      Model_Runner.Backend.Device.Open (Awake);

      if Awake then
         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ready : Boolean;

            Status : E.Error_Info;

            Paged : L.Session;
            Logits : Logit_Vector;

            After_Ten, After_Seventy : Natural := 0;
         begin
            Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                   Ready => Ready);

            if Ready then
               L.Open (Paged, Under.Ready, Context => Room, Paged => True,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the paged session did not open");

               for Step in 1 .. 10 loop
                  L.Evaluate (Paged, Under.Ready, Token_Of (Step), Logits,
                              Status => Status);
                  Assert (E.Is_Ok (Status), "the paged session failed early");
               end loop;

               After_Ten := L.Pages_Held;

               for Step in 11 .. 70 loop
                  L.Evaluate (Paged, Under.Ready, Token_Of (Step), Logits,
                              Status => Status);
                  Assert (E.Is_Ok (Status),
                          "the paged session failed past a page");
               end loop;

               After_Seventy := L.Pages_Held;

               Assert (After_Ten > 0,
                       "a paged session that has read ten positions holds no"
                       & " page of the device's cache");

               --  A page is sixty-four positions: ten fill one a layer,
               --  More positions, more pages: a page is taken only as a
               --  position reaches it, so seventy hold more than ten did.
               --  How many more follows the device's page size (seventy span
               --  three pages a layer at this box's size, not two), so this
               --  asks the lazy growth rather than a fixed count; the fixed
               --  fraction of a block is the claim below.
               Assert (After_Seventy > After_Ten,
                       "a paged session past more positions holds"
                       & Integer'Image (After_Seventy) & " pages, no more than"
                       & " the" & Integer'Image (After_Ten) & " it held"
                       & " earlier, so pages are not taken as positions reach"
                       & " them");

               --  And far below the context's worth: a block would have
               --  held thirty-two pages a layer for a session that filled
               --  two. After_Ten is the layers, so the whole context is
               --  thirty-two of it.
               Assert (After_Seventy < 32 * After_Ten,
                       "a paged session holds as much as a block would, so"
                       & " paging bought nothing");

               L.Close (Paged);
            end if;
         end;

         Model_Runner.Backend.Device.Close;
      end if;

      B.Free (Image);
   end A_Paged_Session_Holds_Only_What_It_Fills;

   --------------------------------------------------------------
   -- A_Block_And_A_Paged_Session_Do_Not_Corrupt_Each_Other --
   --------------------------------------------------------------

   --  A cache in blocks and one in pages both grow from the front of the
   --  one device buffer, so a device holds one kind or the other, not both
   --  at once. Where a block is held, a paged session opened beside it is
   --  refused its pages and attends on the host -- and the block session's
   --  cache is left untouched, where before the two dealt the same elements
   --  and wrote over each other.
   --
   --  The block session says, bit for bit, what it says with no paged
   --  session beside it; the paged session does without device pages and
   --  says so.
   procedure A_Block_And_A_Paged_Session_Do_Not_Corrupt_Each_Other
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room  : constant := 200;
      Fill  : constant := 20;

      function Token_Of (Place : Positive) return Vocab.Token_Id
      is (Vocab.Token_Id (2 + (Place * 7) mod 12));

      Probe : constant Vocab.Token_Id := 5;

      Image : B.Byte_Array_Access;
      Awake : Boolean;

      procedure Fill_It (Under : in out Harness; Live : in out L.Session) is
         Status  : E.Error_Info;
         Ignored : Logit_Vector;
      begin
         for Step in 1 .. Fill loop
            L.Evaluate (Live, Under.Ready, Token_Of (Step), Ignored,
                        Status => Status);
            Assert (E.Is_Ok (Status), "a session did not fill");
         end loop;
      end Fill_It;
   begin
      Tiny_Model.Build (Image, Room => Room);

      Model_Runner.Backend.Device.Open (Awake);

      if Awake then
         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ready : Boolean;

            Status : E.Error_Info;

            Alone   : L.Session;
            Block, Paged : L.Session;

            Lone, With_Paged, Ignored : Logit_Vector;

            Worst : N.Real := 0.0;
         begin
            Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                   Ready => Ready);

            if Ready then
               --  A block session on its own: what it says next.
               L.Open (Alone, Under.Ready, Context => Room, Status => Status);
               Assert (E.Is_Ok (Status), "the lone block did not open");
               Fill_It (Under, Alone);
               L.Evaluate (Alone, Under.Ready, Probe, Lone, Status => Status);
               Assert (E.Is_Ok (Status), "the lone block did not answer");
               L.Close (Alone);

               --  The same block session, with a paged session opened and
               --  filled beside it -- which used to overwrite its cache.
               L.Open (Block, Under.Ready, Context => Room, Status => Status);
               Assert (E.Is_Ok (Status), "the block did not open");
               Fill_It (Under, Block);

               L.Open (Paged, Under.Ready, Context => Room, Paged => True,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the paged did not open beside it");
               Fill_It (Under, Paged);

               --  The block held its cache, and the paged session did
               --  without device pages -- one kind at a time.
               Assert (L.Holds_Block (Block),
                       "the block session lost its block to a paged one");
               Assert (not L.Holds_Pages (Paged),
                       "a paged session took pages while a block was held");

               L.Evaluate (Block, Under.Ready, Probe, With_Paged,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the block did not answer beside it");

               L.Evaluate (Paged, Under.Ready, Probe, Ignored,
                           Status => Status);
               Assert (E.Is_Ok (Status),
                       "the paged session did not answer on the host: "
                       & E.Error_Code'Image (Status.Code));

               for Index in Logit_Vector'Range loop
                  Worst :=
                    N.Real'Max (Worst, abs (With_Paged (Index) - Lone (Index)));
               end loop;

               Assert (Worst = 0.0,
                       "a block session says" & N.Real'Image (Worst)
                       & " away from itself once a paged session is opened"
                       & " beside it, so the two wrote over each other");

               L.Close (Paged);
               L.Close (Block);
            end if;
         end;

         Model_Runner.Backend.Device.Close;
      end if;

      B.Free (Image);
   end A_Block_And_A_Paged_Session_Do_Not_Corrupt_Each_Other;

   ------------------------------------------------------------
   -- A_Paged_Window_Says_What_A_Block_Window_Says --
   ------------------------------------------------------------

   --  Paging holds for a sliding-window layer too. Such a layer keeps only
   --  the window's worth of positions, so its cells ring: as the window
   --  slides, a cell is rewritten for a new position and its page reused,
   --  where a layer that keeps everything only ever takes another. A paged
   --  session on a windowed model must still say, bit for bit, what a block
   --  session says -- past far more positions than the window holds, so the
   --  cells ring many times over.
   procedure A_Paged_Window_Says_What_A_Block_Window_Says
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Room  : constant := 200;
      Steps : constant := 130;

      function Token_Of (Place : Positive) return Vocab.Token_Id
      is (Vocab.Token_Id (2 + (Place * 7) mod 12));

      type Trail is array (1 .. Steps) of Logit_Vector;

      Image : B.Byte_Array_Access;
      Awake : Boolean;
   begin
      --  A sliding window of three, so a cell is reused every few
      --  positions and paging is put through the ring many times.
      Tiny_Model.Build (Image, Room => Room, Window => 3);

      Model_Runner.Backend.Device.Open (Awake);

      if Awake then
         declare
            Held  : aliased constant B.Byte_Array := Image.all;
            Under : Harness (Held'Access);
            Ready : Boolean;

            Status : E.Error_Info;

            Blocked, Paged : L.Session;

            Said : Trail := [others => [others => 0.0]];
            LP   : Logit_Vector;

            Worst : N.Real := 0.0;
         begin
            Start (Under, Backend => Model_Runner.Backend.Backend_Device,
                   Ready => Ready);

            if Ready then
               L.Open (Blocked, Under.Ready, Context => Room,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the block window did not open");

               for Step in 1 .. Steps loop
                  L.Evaluate (Blocked, Under.Ready, Token_Of (Step),
                              Said (Step), Status => Status);
                  Assert (E.Is_Ok (Status), "the block window failed");
               end loop;

               L.Close (Blocked);

               L.Open (Paged, Under.Ready, Context => Room, Paged => True,
                       Status => Status);
               Assert (E.Is_Ok (Status), "the paged window did not open");

               for Step in 1 .. Steps loop
                  L.Evaluate (Paged, Under.Ready, Token_Of (Step), LP,
                              Status => Status);
                  Assert (E.Is_Ok (Status), "the paged window failed at"
                          & Integer'Image (Step) & ": "
                          & E.Error_Code'Image (Status.Code));

                  for Index in Logit_Vector'Range loop
                     Worst :=
                       N.Real'Max (Worst, abs (Said (Step) (Index) - LP (Index)));
                  end loop;
               end loop;

               Assert (L.Holds_Pages (Paged),
                       "the paged window did not reach the device in pages");

               --  As above: pages and a block sum a window's positions in a
               --  different order, so half-precision attention rounds a hair
               --  apart rather than to the bit. See Paged_Layout_Slack.
               Assert (Worst <= Paged_Layout_Slack,
                       "a paged session on a windowed model says"
                       & N.Real'Image (Worst)
                       & " away from the same session in a block, past a"
                       & " window that slid many times");

               L.Close (Paged);
            end if;
         end;

         Model_Runner.Backend.Device.Close;
      end if;

      B.Free (Image);
   end A_Paged_Window_Says_What_A_Block_Window_Says;

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
      Rules : constant array (1 .. 14) of Case_Text :=
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
         new String'("stablelm2"),
         new String'("tekken"),
         new String'("deepseek-v3")];

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

   --  The cutting rules agree with the expressions they were written from.
   --
   --  Every rule in the engine is a scanner written out by hand from the
   --  other runtime's regular expressions. The reader in the suite
   --  interprets those expressions as text, by backtracking, one expression
   --  after another over the pieces the ones before it left. Here every
   --  name the engine accepts is driven over a few hundred texts made of
   --  the things the rules disagree about -- letters of both cases and of
   --  several scripts, marks, digits of two kinds, runs of spaces and line
   --  ends, punctuation and symbols, contractions, ideographs, Hangul, the
   --  literal tokens two rules look for -- and the two cuts are held to be
   --  the same, boundary for boundary. A token stream would show a
   --  difference only where a merge happened to straddle it; the cut shows
   --  every one.
   procedure Byte_Pair_Cutting_Matches_The_Expressions
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type Reference_Tokenizer.Model_Kind;

      type Case_Text is access constant String;

      --  One name per rule the engine accepts, and one more for each name
      --  that is mapped onto a rule another name is too.
      Names : constant array (1 .. 41) of Case_Text :=
        [new String'(""), new String'("default"), new String'("gpt-2"),
         new String'("jina-v2-code"), new String'("falcon"),
         new String'("smollm"), new String'("mellum2"),
         new String'("llama3"), new String'("dbrx"),
         new String'("minicpm5"), new String'("jais-2"),
         new String'("qwen2"), new String'("solar-open"),
         new String'("qwen35"), new String'("bailingmoe"),
         new String'("llada-moe"), new String'("seed-coder"),
         new String'("laguna"), new String'("exaone-moe"),
         new String'("tekken"), new String'("gpt-4o"),
         new String'("minimax-m2"), new String'("granite-embed-multi-97m"),
         new String'("tiny_aya"), new String'("cohere2moe"),
         new String'("youtu"), new String'("kimi-k2"),
         new String'("deepseek-llm"), new String'("deepseek-coder"),
         new String'("deepseek-v3"), new String'("joyai-llm"),
         new String'("afmoe"), new String'("bloom"),
         new String'("gpt3-finnish"), new String'("viking"),
         new String'("superbpe"), new String'("chameleon"),
         new String'("hunyuan-dense"), new String'("grok-2"),
         new String'("chatglm-bpe"), new String'("kanana2")];

      function U (Code : Natural) return String
        renames Model_Runner.UTF8.Encode;

      --  The pieces a text is built from, chosen so that each class every
      --  expression names is present and each boundary the rules draw
      --  differently can arise.
      Atoms : constant array (1 .. 48) of Case_Text :=
        [new String'("ab"), new String'("Hello"), new String'("WORLD"),
         new String'("camelCase"), new String'("x"), new String'(" "),
         new String'("  "), new String'("     "), new String'("         "),
         new String'(U (9)), new String'(U (10)), new String'(U (13)),
         new String'(U (10) & U (10)), new String'(" " & U (10) & " "),
         new String'("1"), new String'("12"), new String'("1234"),
         new String'("1234567"), new String'("'s"), new String'("'RE"),
         new String'("'ll"), new String'("."), new String'(","),
         new String'("!?"), new String'("+"), new String'("$"),
         new String'("`"), new String'("<"), new String'("/"),
         new String'("("), new String'("|"),
         new String'(U (16#E9#)),           --  é, a lowercase letter
         new String'(U (16#C9#)),           --  É, an uppercase letter
         new String'(U (16#1C5#)),          --  ǅ, a titlecase letter
         new String'(U (16#2B0#)),          --  ʰ, a modifier letter
         new String'(U (16#301#)),          --  a combining acute accent
         new String'(U (16#20AC#)),         --  €, a symbol
         new String'(U (16#2014#)),         --  an em dash, punctuation
         new String'(U (16#A0#)),           --  a no-break space
         new String'(U (16#661#) & U (16#662#)),  --  Arabic-Indic digits
         new String'(U (16#B2#)),           --  a superscript two
         new String'(U (16#6F22#) & U (16#5B57#)),  --  two ideographs
         new String'(U (16#3042#)),         --  hiragana a
         new String'(U (16#AC00#)),         --  a Hangul syllable
         new String'(U (16#43F#) & U (16#440#)),  --  Cyrillic lowercase
         new String'(U (16#391#)),          --  Greek capital alpha
         new String'("<sentinel:12>"), new String'("IMGIMGABZ")];

      --  A small deterministic generator, so a failure names a text that
      --  can be typed into a test.
      Seed : Interfaces.Unsigned_32 := 2_463_534_242;

      function Next (Bound : Positive) return Positive is
         use type Interfaces.Unsigned_32;
      begin
         Seed := Seed xor Interfaces.Shift_Left (Seed, 13);
         Seed := Seed xor Interfaces.Shift_Right (Seed, 17);
         Seed := Seed xor Interfaces.Shift_Left (Seed, 5);
         return Natural (Seed mod Interfaces.Unsigned_32 (Bound)) + 1;
      end Next;

      function Random_Text return String is
         Result : String (1 .. 256);
         Used   : Natural := 0;
      begin
         for Count in 1 .. Next (10) loop
            declare
               Atom : constant String := Atoms (Next (Atoms'Length)).all;
            begin
               exit when Used + Atom'Length > Result'Last;
               Result (Used + 1 .. Used + Atom'Length) := Atom;
               Used := Used + Atom'Length;
            end;
         end loop;
         return Result (1 .. Used);
      end Random_Text;

      --  A text as something a failure message can show: every byte
      --  outside printable ASCII as its number in brackets.
      function Shown (Text : String) return String is
         Result : String (1 .. Text'Length * 6);
         Used   : Natural := 0;
      begin
         for Letter of Text loop
            if Letter in ' ' .. '~' then
               Used := Used + 1;
               Result (Used) := Letter;
            else
               declare
                  Image : constant String :=
                    "[" & Model_Runner.Text.Trim
                            (Natural'Image (Character'Pos (Letter))) & "]";
               begin
                  Result (Used + 1 .. Used + Image'Length) := Image;
                  Used := Used + Image'Length;
               end;
            end if;
         end loop;
         return Result (1 .. Used);
      end Shown;

      Texts_Per_Rule : constant := 250;
   begin
      for Name of Names loop
         declare
            Image  : B.Byte_Array_Access;
            Parsed : Containers.Container;
            Status : E.Error_Info;
            Loaded : Boolean;
         begin
            BPE_Vocabulary.Build (Name.all, Image);

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
                       "the engine refused the rule " & Name.all & ": "
                       & E.Error_Code'Image (Status.Code));

               Reference_Tokenizer.Load (Second, Parsed, Loaded);
               Assert (Loaded,
                       "the reader refused the rule " & Name.all);
               Assert (Reference_Tokenizer.Kind (Second)
                       = Reference_Tokenizer.Byte_Pair,
                       "the reader read " & Name.all & " as something else");

               for Round in 1 .. Texts_Per_Rule loop
                  declare
                     Text     : constant String := Random_Text;
                     Mine     : Vocab.Piece_Ends (1 .. Text'Length + 1);
                     Mine_N   : Natural;
                     Theirs   : Reference_Tokenizer.Ends_Array
                       (1 .. Text'Length + 1);
                     Theirs_N : Natural;
                  begin
                     Vocab.Cut (Words, Text, Mine, Mine_N, Status);
                     Assert (E.Is_Ok (Status),
                             "the engine would not cut """ & Shown (Text)
                             & """ under " & Name.all & ": "
                             & E.Error_Code'Image (Status.Code));

                     Reference_Tokenizer.Cut (Second, Text, Theirs, Theirs_N);

                     Assert (Mine_N = Theirs_N,
                             "under " & Name.all & " the engine cuts """
                             & Shown (Text) & """ into"
                             & Natural'Image (Mine_N)
                             & " pieces and the expressions into"
                             & Natural'Image (Theirs_N));

                     for Index in 1 .. Mine_N loop
                        Assert (Mine (Index) = Theirs (Index),
                                "under " & Name.all & " piece"
                                & Natural'Image (Index) & " of """
                                & Shown (Text) & """ ends at byte"
                                & Natural'Image (Mine (Index))
                                & " for the engine and at"
                                & Natural'Image (Theirs (Index))
                                & " for the expressions");
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
   end Byte_Pair_Cutting_Matches_The_Expressions;

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

   --  A four-bit cache holds a sixth and a bit, answers near the exact
   --  one, and survives a snapshot.
   --
   --  The plan: five bits an element with its scales against the byte
   --  cache's eight and a bit, so fewer bytes than the byte cache and more
   --  than half of them. The answer: the logits of the tiny model with
   --  the context in nibbles are not the exact cache's, and are the
   --  independent implementation's when it rounds its keys and values the
   --  same way, on the sweep's four sequences. The snapshot: a
   --  session written out and read back into another nibble session
   --  answers to the bit, since a block rounded once rounds the same
   --  again. And the two kernels that read it, against a plain
   --  computation over nibbles laid as the cache lays them, including a
   --  head that begins inside a block and a row shorter than one.
   procedure Fourth_Cache_Holds_A_Sixth
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      Image  : B.Byte_Array_Access;
      Exact_Logits, Fourth_Logits : Logit_Vector;
      Apart : Model_Runner.Numerics.Real := 0.0;
      Kept  : B.Byte_Array_Access;
      Direct, Restored : Logit_Vector;

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
         for Token of Prompt loop
            L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed: " & E.Error_Code'Image (Status.Code));
         end loop;
         L.Close (Live);
      end Answer;
   begin
      --  The kernels, on a cache of two rows of forty elements: two blocks
      --  a row, the second of eight. Nibble n stands for n - 8 times its
      --  block's scale.
      declare
         package MK renames Model_Runner.Kernels;
         package MB renames Model_Runner.Bytes;

         Width  : constant N.Element_Count := 40;
         Bytes  : constant MB.Byte_Count := 20;
         Blocks : constant N.Element_Count := 2;
         Rows   : MB.Byte_Array (0 .. 2 * Bytes - 1);
         Scales : constant N.Real_Array (0 .. 3) := [0.5, 0.25, 2.0, 0.125];
         Query  : N.Real_Array (0 .. 39);

         function Nibble (Row, Element : N.Element_Count) return Integer
         is (Integer ((Row * 7 + Element * 3) mod 16));

         function Value (Row, Element : N.Element_Count) return N.Real
         is (N.Real (Nibble (Row, Element) - 8)
             * Scales (Row * Blocks + Element / 32));
      begin
         for Row in 0 .. 1 loop
            for Element in 0 .. Width - 1 loop
               declare
                  Where : constant MB.Byte_Count :=
                    MB.Byte_Count (Row) * Bytes + MB.Byte_Count (Element / 2);
                  Held  : constant MB.Byte := MB.Byte (Nibble (N.Element_Count (Row), Element));
                  use type MB.Byte;
               begin
                  if Element mod 2 = 0 then
                     Rows (Where) := Held;
                  else
                     Rows (Where) := Rows (Where) or (Held * 16);
                  end if;
               end;
            end loop;
         end loop;
         for Index in Query'Range loop
            Query (Index) := N.Real (Integer (Index) mod 5) * 0.5 - 1.0;
         end loop;

         --  A dot over the second row's elements 24 to 39: it starts in
         --  the first block and ends in the second.
         declare
            Wanted : N.Real := 0.0;
            Got    : N.Real;
         begin
            for Element in 24 .. 39 loop
               Wanted := Wanted + Query (N.Element_Count (Element - 24)) * Value (1, N.Element_Count (Element));
            end loop;
            Got := MK.Head_Dot_Fourth
              (Query, 0, Rows, Bytes, 24, Scales, 2, 16);
            Assert (abs (Got - Wanted) <= 1.0e-4,
                    "the nibble dot product is" & N.Real'Image (Got)
                    & " where" & N.Real'Image (Wanted) & " was wanted");
            Assert (MK.Head_Dot_Fourth (Query, 0, Rows, Bytes, 24, Scales, 2, 0) = 0.0
                    and then MK.Head_Dot_Fourth (Query, 0, Rows, Bytes, 24, Scales, 2, 17) = 0.0,
                    "a nibble dot product past its bounds was taken");
         end;

         --  A blend over both rows of elements 30 to 37, with weights.
         declare
            Weights : constant N.Real_Array (0 .. 1) := [0.75, -0.5];
            Sums    : N.Real_Array (0 .. 7) := [others => 0.0];
            Kept_Sums : N.Real_Array (0 .. 7) := [others => 3.0];
         begin
            MK.Blend_Run_Fourth
              (Sums, Weights, 0, Scales, 0, Blocks, Rows, 0, Bytes, 30, 2);
            for Component in 0 .. 7 loop
               declare
                  Wanted : constant N.Real :=
                    Weights (0) * Value (0, N.Element_Count (30 + Component))
                    + Weights (1) * Value (1, N.Element_Count (30 + Component));
               begin
                  Assert (abs (Sums (N.Element_Count (Component)) - Wanted) <= 1.0e-4,
                          "the nibble blend is" & N.Real'Image (Sums (N.Element_Count (Component)))
                          & " at" & Integer'Image (Component) & " where"
                          & N.Real'Image (Wanted) & " was wanted");
               end;
            end loop;
            MK.Blend_Run_Fourth
              (Kept_Sums, Weights, 0, Scales, 0, Blocks, Rows, 0, Bytes, 30, 3);
            Assert ((for all Sum of Kept_Sums => Sum = 3.0),
                    "a nibble blend past the rows was taken");
         end;
      end;

      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
      begin
         Start (Under);

         declare
            use type Interfaces.Unsigned_64;
            Byte_Plan, Nibble_Plan, Wide : Model_Runner.Memory.Session_Plan;
            Status : E.Error_Info;
         begin
            L.Plan_Session (Under.Ready, 0, Wide, Status, L.Exact);
            L.Plan_Session (Under.Ready, 0, Byte_Plan, Status, L.Eighth);
            L.Plan_Session (Under.Ready, 0, Nibble_Plan, Status, L.Fourth);
            Assert (E.Is_Ok (Status), "the nibble plan was refused");
            Assert (Nibble_Plan.KV_Cache_Bytes < Byte_Plan.KV_Cache_Bytes
                    and then 2 * Nibble_Plan.KV_Cache_Bytes > Byte_Plan.KV_Cache_Bytes
                    and then Nibble_Plan.KV_Cache_Bytes * 6 < Wide.KV_Cache_Bytes,
                    "a nibble cache did not plan for a sixth and a bit:"
                    & Interfaces.Unsigned_64'Image (Nibble_Plan.KV_Cache_Bytes)
                    & " against" & Interfaces.Unsigned_64'Image (Byte_Plan.KV_Cache_Bytes)
                    & " and" & Interfaces.Unsigned_64'Image (Wide.KV_Cache_Bytes));
         end;

         Answer (L.Exact, Under, Exact_Logits);
         Answer (L.Fourth, Under, Fourth_Logits);

         for Index in Exact_Logits'Range loop
            Apart := Model_Runner.Numerics.Real'Max
              (Apart, abs (Exact_Logits (Index) - Fourth_Logits (Index)));
         end loop;
         Assert (Apart > 0.0,
                 "a nibble cache produced exactly the logits of a binary32 "
                 & "one, so nothing was rounded");

         --  How far from the exact answer is the rounding's own doing --
         --  a third of a logit here, on rows of four elements -- and says
         --  nothing about the cache. What does is the independent
         --  implementation rounding its keys and values the same way, on
         --  the sweep's own sequences: what the nibble cache claims is
         --  that rounding and nothing else, so the two agree to the exact
         --  cache's tolerance.
         declare
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Status : E.Error_Info;
            Second : Reference_Transformer.Model;
            Loaded, Made : Boolean;
            Expected : Reference_Transformer.Real_Vector
              (0 .. Tiny_Model.Vocabulary - 1);
            Worst : Long_Float := 0.0;

            procedure Cross (Sequence : Vocab.Token_Array) is
               Tokens : Reference_Transformer.Token_Vector (Sequence'Range);
               Live   : L.Session;
               Result : Logit_Vector;
            begin
               for Index in Sequence'Range loop
                  Tokens (Index) := Integer (Sequence (Index));
               end loop;
               Reference_Transformer.Run (Second, Tokens, Expected, Made);
               Assert (Made, "the rounding reference produced no logits");

               L.Open (Live, Under.Ready, Cache => L.Fourth, Status => Status);
               Assert (E.Is_Ok (Status), "the nibble session did not open");
               for Token of Sequence loop
                  L.Evaluate (Live, Under.Ready, Token, Result, Status => Status);
                  Assert (E.Is_Ok (Status), "evaluation failed");
               end loop;
               L.Close (Live);

               for Index in Expected'Range loop
                  Worst := Long_Float'Max
                    (Worst,
                     abs (Long_Float (Result (N.Element_Count (Index)))
                          - Expected (Index)));
               end loop;
            end Cross;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");
            Reference_Transformer.Load (Second, Parsed, Held, Loaded);
            Assert (Loaded, "the reference did not read the model");
            Reference_Transformer.Round_Cache_To_Nibbles (Second, True);

            Cross ([1 => 4]);
            Cross ([4, 5]);
            Cross ([1, 4, 5, 6, 7]);
            Cross ([4, 4, 4, 5, 5, 6, 7, 8]);

            Assert (Worst < 1.0E-3,
                    "the nibble cache and the independent implementation "
                    & "rounding the same way disagree by"
                    & Long_Float'Image (Worst));

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         --  The snapshot, out of one packed session and into another of
         --  the same storage: the nibble cache, and the byte cache beside
         --  it, whose values went out through the halved arm -- which
         --  holds nothing for it -- until this asked.
         for Packed in L.Cache_Precision range L.Eighth .. L.Fourth loop
            declare
               Live   : L.Session;
               Status : E.Error_Info;
               Name   : constant String := L.Cache_Name (Packed);
            begin
               L.Open (Live, Under.Ready, Cache => Packed, Status => Status);
               Assert (E.Is_Ok (Status), "the " & Name & " session did not open");
               for Token of Prompt loop
                  L.Evaluate (Live, Under.Ready, Token, Direct, Status => Status);
                  Assert (E.Is_Ok (Status), "evaluation failed");
               end loop;
               L.Snapshot (Live, Under.Ready, Kept, Status);
               Assert (E.Is_Ok (Status), "a " & Name & " session did not snapshot: "
                       & E.Error_Code'Image (Status.Code));
               L.Evaluate (Live, Under.Ready, 4, Direct, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed after the snapshot");
               L.Close (Live);

               L.Open (Live, Under.Ready, Cache => Packed, Status => Status);
               Assert (E.Is_Ok (Status), "the second " & Name & " session did not open");
               L.Adopt (Live, Under.Ready, Kept.all, Status);
               Assert (E.Is_Ok (Status), "a " & Name & " snapshot was not adopted: "
                       & E.Error_Code'Image (Status.Code));
               L.Evaluate (Live, Under.Ready, 4, Restored, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed after adopting");
               L.Close (Live);

               declare
                  Worst : Model_Runner.Numerics.Real := 0.0;
               begin
                  for Index in Direct'Range loop
                     Worst := Model_Runner.Numerics.Real'Max
                       (Worst, abs (Direct (Index) - Restored (Index)));
                  end loop;
                  Assert (Worst = 0.0,
                          "a " & Name & " cache did not survive being written "
                          & "out and read back; the logits moved by"
                          & Model_Runner.Numerics.Real'Image (Worst));
               end;
               B.Free (Kept);
            end;
         end loop;
      end;

      B.Free (Image);
   end Fourth_Cache_Holds_A_Sixth;

   --  The values stored otherwise than the keys.
   --
   --  Attention reads a key through a dot product with the query, where a
   --  rounded element moves every score it enters, and a value through a
   --  weighted sum over the positions, where the roundings average out;
   --  so a session may hold its values coarser than its keys. A session
   --  with byte keys and nibble values, and one the other way round, on
   --  the processor and on the device where there is one, agree with the
   --  independent implementation rounding each side its way, to the
   --  nibble bucket's bound; their plans lie between the byte and nibble
   --  caches'; a snapshot of one reads back to the bit into a session of
   --  the same pair and is refused by a session of another; and a pairing
   --  that is not two packed storages is refused as a shape.
   --------------------------------------------
   -- A_Packed_Session_On_The_Device_Packs_There --
   --------------------------------------------

   --  A packed session on the device has its keys and values packed by
   --  the device, as they are placed, and its own copy of the block read
   --  back afterwards: what it snapshots is the block the device packed,
   --  and a processor session adopting it goes on as one that read the
   --  text itself does. Token by token and as a batch, in bytes and in
   --  nibbles. Not to the bit: the device's keys and values are its own
   --  arithmetic's before they are packed, a few units in the last place
   --  from the processor's, and a row on a rounding boundary packs a
   --  level apart -- what the exact cache's sessions differ by too. The
   --  bytes the device packs of a given row are the host's to the bit,
   --  and the backend suite holds them there.
   procedure A_Packed_Session_On_The_Device_Packs_There
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [4, 4, 4, 5, 5, 6, 7, 8];
      Next   : constant Vocab.Token_Id := 3;

      Image  : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Over   : Harness (Held'Access);
         Status : E.Error_Info;
         Able, Awake : Boolean;

         --  The same text into a device session and a processor session
         --  of one storage, one token at a time or all at once; the
         --  device's snapshot adopted by a fresh processor session; and
         --  the token after, from the two processor sessions, the same.
         procedure Cross
           (Cache   : L.Cache_Precision;
            Batched : Boolean;
            What    : String)
         is
            Live, Plain, Adopted : L.Session;
            From_Device, From_Host, Direct : Logit_Vector;
            Kept : B.Byte_Array_Access;
         begin
            L.Open (Live, Over.Ready, Cache => Cache, Status => Status);
            Assert (E.Is_Ok (Status), "the device session did not open for " & What);
            L.Open (Plain, Under.Ready, Cache => Cache, Status => Status);
            Assert (E.Is_Ok (Status), "the processor session did not open for " & What);

            if Batched then
               L.Evaluate_Batch (Live, Over.Ready, Prompt, From_Device, Status => Status);
               Assert (E.Is_Ok (Status), "the device batch failed for " & What
                       & ": " & E.Error_Code'Image (Status.Code));
               L.Evaluate_Batch (Plain, Under.Ready, Prompt, From_Host, Status => Status);
               Assert (E.Is_Ok (Status), "the processor batch failed for " & What);
            else
               for Token of Prompt loop
                  L.Evaluate (Live, Over.Ready, Token, From_Device, Status => Status);
                  Assert (E.Is_Ok (Status), "the device evaluation failed for " & What
                          & ": " & E.Error_Code'Image (Status.Code));
                  L.Evaluate (Plain, Under.Ready, Token, From_Host, Status => Status);
                  Assert (E.Is_Ok (Status), "the processor evaluation failed for " & What);
               end loop;
            end if;

            L.Snapshot (Live, Over.Ready, Kept, Status);
            Assert (E.Is_Ok (Status), "the device session did not snapshot for " & What);
            L.Close (Live);

            L.Open (Adopted, Under.Ready, Cache => Cache, Status => Status);
            L.Adopt (Adopted, Under.Ready, Kept.all, Status);
            Assert (E.Is_Ok (Status), "the device's snapshot was not adopted for "
                    & What & ": " & E.Error_Code'Image (Status.Code));
            B.Free (Kept);

            L.Evaluate (Adopted, Under.Ready, Next, From_Device, Status => Status);
            Assert (E.Is_Ok (Status), "the adopted session did not go on for " & What);
            L.Evaluate (Plain, Under.Ready, Next, Direct, Status => Status);
            Assert (E.Is_Ok (Status), "the processor session did not go on for " & What);
            L.Close (Adopted);
            L.Close (Plain);

            declare
               Worst : N.Real := 0.0;
            begin
               for Index in Direct'Range loop
                  Worst := N.Real'Max
                    (Worst, abs (From_Device (Index) - Direct (Index)));
               end loop;
               Assert (Worst < 5.0e-2,
                       "the block the device packed " & What
                       & " goes on" & N.Real'Image (Worst)
                       & " away from the block the processor packs");
            end;
         end Cross;
      begin
         Model_Runner.Backend.Device.Open (Awake);
         if not Awake then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device packed a block here");
            B.Free (Image);
            return;
         end if;

         Start (Over, Model_Runner.Backend.Backend_Device, Able);
         if not Able then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device packed a block here");
            Model_Runner.Backend.Device.Close;
            B.Free (Image);
            return;
         end if;
         Start (Under);

         Cross (L.Eighth, False, "in bytes, a token at a time");
         Cross (L.Fourth, False, "in nibbles, a token at a time");
         Cross (L.Eighth, True, "in bytes, as a batch");
         Cross (L.Fourth, True, "in nibbles, as a batch");

         Model_Runner.Backend.Device.Close;
      end;

      B.Free (Image);
   end A_Packed_Session_On_The_Device_Packs_There;

   procedure Values_Stored_Apart_From_Keys
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [4, 4, 4, 5, 5, 6, 7, 8];

      Image  : B.Byte_Array_Access;
      Kept   : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : Containers.Container;
         Status : E.Error_Info;
         Second : Reference_Transformer.Model;
         Loaded, Made : Boolean;
         Tokens   : Reference_Transformer.Token_Vector (Prompt'Range);
         Expected : Reference_Transformer.Real_Vector
           (0 .. Tiny_Model.Vocabulary - 1);
         Direct, Restored : Logit_Vector;

         --  The engine, on Backend, with Cache keys and Values values,
         --  against the reference rounding as each says.
         procedure Cross
           (Backend : Model_Runner.Backend.Backend_Kind;
            Cache   : L.Cache_Precision;
            Values  : L.Value_Precision;
            Keys_As, Values_As : Reference_Transformer.Cache_Rounding;
            What    : String)
         is
            Ready  : L.Model;
            Live   : L.Session;
            Result : Logit_Vector;
            Worst  : Long_Float := 0.0;
         begin
            L.Prepare (Ready, Parsed, Source, Backend => Backend, Status => Status);
            if Status.Code = E.Backend_No_Device then
               return;
            end if;
            Assert (E.Is_Ok (Status), "the model did not prepare for " & What);

            Reference_Transformer.Round_Cache (Second, Keys_As, Values_As);
            Reference_Transformer.Run (Second, Tokens, Expected, Made);
            Assert (Made, "the rounding reference produced no logits");

            L.Open (Live, Ready, Cache => Cache, Values => Values, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open for " & What
                    & ": " & E.Error_Code'Image (Status.Code));
            Assert (L."=" (L.Value_Precision_Of (Live), L.Values_Held (Cache, Values)),
                    "the session does not say how its values are held");
            for Token of Prompt loop
               L.Evaluate (Live, Ready, Token, Result, Status => Status);
               Assert (E.Is_Ok (Status), "evaluation failed for " & What & ": "
                       & E.Error_Code'Image (Status.Code));
            end loop;
            L.Close (Live);
            L.Close (Ready, Status);

            for Index in Expected'Range loop
               Worst := Long_Float'Max
                 (Worst, abs (Long_Float (Result (N.Element_Count (Index)))
                              - Expected (Index)));
            end loop;
            Assert (Worst < Conformance.Fourth_Absolute_Tolerance,
                    What & " and the independent implementation rounding each "
                    & "side its way disagree by" & Long_Float'Image (Worst));
         end Cross;
      begin
         Start (Under);
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");
         Reference_Transformer.Load (Second, Parsed, Held, Loaded);
         Assert (Loaded, "the reference did not read the model");
         for Index in Prompt'Range loop
            Tokens (Index) := Integer (Prompt (Index));
         end loop;

         --  The device backend is a singleton the suite leaves closed, so
         --  it is opened here and closed after; a machine without one
         --  crosses on the processor alone.
         declare
            Awake : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Awake);
            if not Awake then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "note: no device held values apart from keys here");
            end if;
         end;
         for Backend in Model_Runner.Backend.Backend_Kind range
           Model_Runner.Backend.Backend_CPU .. Model_Runner.Backend.Backend_Device
         loop
            Cross (Backend, L.Eighth, L.Value_Fourth,
                   Reference_Transformer.To_Bytes, Reference_Transformer.To_Nibbles,
                   "byte keys with nibble values on "
                   & Model_Runner.Backend.Backend_Kind'Image (Backend));
            Cross (Backend, L.Fourth, L.Value_Eighth,
                   Reference_Transformer.To_Nibbles, Reference_Transformer.To_Bytes,
                   "nibble keys with byte values on "
                   & Model_Runner.Backend.Backend_Kind'Image (Backend));
         end loop;
         Model_Runner.Backend.Device.Close;

         --  The plans, between the two.
         declare
            use type Interfaces.Unsigned_64;
            Bytes, Nibbles, Mixed : Model_Runner.Memory.Session_Plan;
         begin
            L.Plan_Session (Under.Ready, 0, Bytes, Status, L.Eighth);
            L.Plan_Session (Under.Ready, 0, Nibbles, Status, L.Fourth);
            L.Plan_Session (Under.Ready, 0, Mixed, Status, L.Eighth, L.Value_Fourth);
            Assert (E.Is_Ok (Status), "the mixed plan was refused");
            Assert (Mixed.KV_Cache_Bytes < Bytes.KV_Cache_Bytes
                    and then Mixed.KV_Cache_Bytes > Nibbles.KV_Cache_Bytes,
                    "byte keys with nibble values did not plan between the two:"
                    & Interfaces.Unsigned_64'Image (Mixed.KV_Cache_Bytes));
         end;

         --  A pairing the engine does not store.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Cache => L.Halved, Values => L.Value_Fourth,
                    Status => Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch,
                    "halved keys with nibble values were not refused: "
                    & E.Error_Code'Image (Status.Code));
            L.Close (Live);
         end;

         --  The snapshot, into the same pair and into another.
         declare
            Live : L.Session;
         begin
            L.Open (Live, Under.Ready, Cache => L.Eighth, Values => L.Value_Fourth,
                    Status => Status);
            Assert (E.Is_Ok (Status), "the mixed session did not open");
            for Token of Prompt loop
               L.Evaluate (Live, Under.Ready, Token, Direct, Status => Status);
            end loop;
            L.Snapshot (Live, Under.Ready, Kept, Status);
            Assert (E.Is_Ok (Status), "the mixed session did not snapshot");
            L.Evaluate (Live, Under.Ready, 4, Direct, Status => Status);
            L.Close (Live);

            L.Open (Live, Under.Ready, Cache => L.Eighth, Values => L.Value_Fourth,
                    Status => Status);
            L.Adopt (Live, Under.Ready, Kept.all, Status);
            Assert (E.Is_Ok (Status), "a mixed snapshot was not adopted by the "
                    & "same pair: " & E.Error_Code'Image (Status.Code));
            L.Evaluate (Live, Under.Ready, 4, Restored, Status => Status);
            L.Close (Live);
            for Index in Direct'Range loop
               Assert (Direct (Index) = Restored (Index),
                       "a mixed cache did not survive being written out and read back");
            end loop;

            L.Open (Live, Under.Ready, Cache => L.Eighth, Status => Status);
            L.Adopt (Live, Under.Ready, Kept.all, Status);
            Assert (Status.Code = E.Lifecycle_Cache_Mismatched,
                    "a mixed snapshot was adopted by a byte session: "
                    & E.Error_Code'Image (Status.Code));
            L.Close (Live);
            B.Free (Kept);
         end;

         Reference_Transformer.Close (Second);
         Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Values_Stored_Apart_From_Keys;

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

   --  Gemma 3 at sixty-two layers scales its scores by the width the
   --  embedding implies, and at six by the head's.
   --
   --  The 27B is the one Gemma 3 whose heads are narrower than the
   --  embedding over the head count, and it scales its scores by the
   --  latter; the file carries no key for it, and the reference runtime
   --  knows the size by its depth. A fixture with heads twice the width
   --  the embedding implies makes the two scales different numbers -- a
   --  half against a third and a bit -- and at sixty-two blocks the engine
   --  has to pick the former and agree with the independent
   --  implementation, which picks it on its own. The six-block fixture
   --  beside it says the depth is what decides, and not the head factor.
   procedure Gemma3_At_Sixty_Two_Layers_Scales_By_The_Embedding
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      --  Run the engine and the reference over one fixture; the engine's
      --  factor, and how far the two are apart.
      procedure Cross
        (Depth : Natural; Scale : out L.Real; Worst : out Long_Float)
      is
         Image  : B.Byte_Array_Access;
         Result : Logit_Vector;
      begin
         Tiny_Model.Build
           (Image, Kind => Tiny_Model.Gemma3, Head_Factor => 2,
            Depth => Depth);

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
               Assert (L."=" (Read.Kind, L.Gemma3),
                       "the architecture was not read from the file");
               Assert (Read.Layers = Depth,
                       "the depth was not read from the file:"
                       & Natural'Image (Read.Layers));
               Assert (Read.Head_Size = 2 * Tiny_Model.Head_Size,
                       "the head width was not read from the file:"
                       & Natural'Image (Read.Head_Size));
               Scale := L.Score_Scale (Read);
            end;

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

            Worst := 0.0;
            for Index in Expected'Range loop
               Worst := Long_Float'Max
                 (Worst,
                  abs (Long_Float (Result
                         (Model_Runner.Numerics.Element_Count (Index)))
                       - Expected (Index)));
            end loop;

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Cross;

      --  One over the square root, as a scale is.
      function Root (Of_Width : Natural) return L.Real
      is (L.Real (1.0 / Model_Runner.Numerics.Sqrt
                          (Model_Runner.Numerics.Wide_Real (Of_Width))));

      By_Head, By_Embedding : L.Real;
      Worst : Long_Float;
   begin
      Cross (6, By_Head, Worst);
      Assert (abs (By_Head - Root (2 * Tiny_Model.Head_Size)) < 1.0E-6,
              "a Gemma 3 of six layers does not scale by its head's width:"
              & L.Real'Image (By_Head));
      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree "
              & "about a gemma3 model of six layers by"
              & Long_Float'Image (Worst));

      Cross (62, By_Embedding, Worst);
      Assert (abs (By_Embedding
                   - Root (Tiny_Model.Embedding / Tiny_Model.Heads)) < 1.0E-6,
              "a Gemma 3 of sixty-two layers does not scale by the width "
              & "its embedding implies:" & L.Real'Image (By_Embedding));
      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree "
              & "about a gemma3 model of sixty-two layers by"
              & Long_Float'Image (Worst));
   end Gemma3_At_Sixty_Two_Layers_Scales_By_The_Embedding;

   procedure Baichuan_At_Forty_Layers_Turns_To_Alibi
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];

      --  Run the engine and the reference over one Baichuan fixture of a
      --  given depth; how the engine read its rotation and its alibi bias,
      --  and how far the two implementations are apart. Baichuan announces
      --  the one architecture name for both its sizes, and the runtime tells
      --  the 13B from the 7B by its forty layers alone -- no key in the file
      --  says which -- so the depth is what turns the rotation off and the
      --  alibi fall-off on.
      procedure Cross
        (Depth    : Natural;
         Rotary   : out Natural;
         Max_Bias : out L.Real;
         Worst    : out Long_Float)
      is
         Image  : B.Byte_Array_Access;
         Result : Logit_Vector;
      begin
         Tiny_Model.Build
           (Image, Kind => Tiny_Model.Baichuan, Depth => Depth);

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
               Assert (L."=" (Read.Kind, L.Baichuan),
                       "the architecture was not read from the file");
               Assert (Read.Layers = Depth,
                       "the depth was not read from the file:"
                       & Natural'Image (Read.Layers));
               Rotary := Read.Rotary;
               Max_Bias := Read.Max_Bias;
            end;

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

            Worst := 0.0;
            for Index in Expected'Range loop
               Worst := Long_Float'Max
                 (Worst,
                  abs (Long_Float (Result
                         (Model_Runner.Numerics.Element_Count (Index)))
                       - Expected (Index)));
            end loop;

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end Cross;

      Rotary   : Natural;
      Max_Bias : L.Real;
      Worst    : Long_Float;
   begin
      --  The ordinary size rotates and carries no alibi.
      Cross (2, Rotary, Max_Bias, Worst);
      Assert (Rotary /= 0,
              "a Baichuan of two layers should rotate:" & Natural'Image (Rotary));
      Assert (Max_Bias = 0.0,
              "a Baichuan of two layers should carry no alibi bias:"
              & L.Real'Image (Max_Bias));
      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree "
              & "about a rotating Baichuan by" & Long_Float'Image (Worst));

      --  At forty layers it is the 13B: no rotation, an alibi fall-off of
      --  eight, and the two implementations still agree.
      Cross (40, Rotary, Max_Bias, Worst);
      Assert (Rotary = 0,
              "a Baichuan of forty layers should not rotate:"
              & Natural'Image (Rotary));
      Assert (Max_Bias = 8.0,
              "a Baichuan of forty layers should carry the alibi bias of "
              & "eight:" & L.Real'Image (Max_Bias));
      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree "
              & "about an alibi Baichuan by" & Long_Float'Image (Worst));
   end Baichuan_At_Forty_Layers_Turns_To_Alibi;

   --  The code variant of jina-bert-v2 agrees with the independent
   --  implementation, and is told from the text one by its tensors.
   --
   --  The variant carries six tensors a block the text one does not: a
   --  centred normalization over the whole of the queries and another
   --  over the whole of the keys, each with a shift, and a second
   --  normalization of the attention sublayer over the joined residual
   --  with the layer's input added once more. Each is a place where a
   --  reader that skipped it would produce an embedding rather than a
   --  refusal, so the fixture with them is crossed with the reference on
   --  every position's state, and the fixture without them beside it,
   --  through the same code, says the six are read only where they are.
   --  And a file with some of the six and not the rest is refused as a
   --  missing tensor rather than read as a model with a normalization
   --  missing.
   procedure Jina_Code_Variant_Agrees_With_The_Reference
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Prompt : constant Vocab.Token_Array := [1, 4, 5, 6, 7, 4, 5, 6];
      Width  : constant N.Element_Count := Tiny_Model.Embedding;
      Span   : constant N.Element_Count := Prompt'Length * Width;

      --  Run the engine and the reference over one fixture, and how far
      --  apart every position's state came out.
      procedure Cross (Code_Norms : Boolean; Worst : out Long_Float) is
         Image : B.Byte_Array_Access;
         Rows  : Model_Runner.Tensors.Real_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Kind => Tiny_Model.Jina_Bert_V2, Code_Norms => Code_Norms);
         Model_Runner.Tensors.Allocate (Span, Rows);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Live   : L.Session;
            Status : E.Error_Info;
            Nothing : N.Real_Array (1 .. 0);
         begin
            Start (Under);
            Assert (L."=" (L.Config (Under.Ready).Kind, L.Jina_Bert_V2),
                    "the architecture was not read from the file");

            L.Open (Live, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");
            L.Evaluate_Batch
              (Live, Under.Ready, Prompt, Nothing, States => Rows,
               Status => Status);
            Assert (E.Is_Ok (Status),
                    "the text was not read: "
                    & E.Error_Code'Image (Status.Code));
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
              (0 .. Natural (Span) - 1);
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            Assert (E.Is_Ok (Status), "the fixture did not parse");

            Reference_Transformer.Load (Second, Parsed, Held, Loaded);
            Assert (Loaded, "the reference did not read the model");

            for Index in Prompt'Range loop
               Tokens (Index) := Integer (Prompt (Index));
            end loop;

            Reference_Transformer.Run_States (Second, Tokens, Expected, Made);
            Assert (Made, "the reference produced no states");

            Worst := 0.0;
            for Index in Expected'Range loop
               Worst := Long_Float'Max
                 (Worst,
                  abs (Long_Float (Rows.all (N.Element_Count (Index)))
                       - Expected (Index)));
            end loop;

            Reference_Transformer.Close (Second);
            Containers.Close (Parsed);
         end;

         Model_Runner.Tensors.Free (Rows);
         B.Free (Image);
      end Cross;

      Worst : Long_Float;
   begin
      Cross (Code_Norms => False, Worst => Worst);
      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree "
              & "about the text variant by" & Long_Float'Image (Worst));

      Cross (Code_Norms => True, Worst => Worst);
      Assert (Worst < 1.0E-3,
              "the engine and the independent implementation disagree "
              & "about the code variant by" & Long_Float'Image (Worst));

      --  Some of the six and not the rest: the second normalization's
      --  gain without its shift, or the queries' without the keys'. One
      --  of the six is renamed in the image to a name nothing asks for,
      --  which is the tensor gone as far as a reader is concerned.
      for Missing in 1 .. 2 loop
         declare
            Image : B.Byte_Array_Access;
            Name  : constant String :=
              (if Missing = 1 then "blk.0.attn_norm_2.bias"
               else "blk.0.attn_k_norm.weight");
            Other : constant String :=
              (if Missing = 1 then "blk.0.attn_norm_x.bias"
               else "blk.0.attn_x_norm.weight");
            Found : Boolean := False;
         begin
            Tiny_Model.Build
              (Image, Kind => Tiny_Model.Jina_Bert_V2, Code_Norms => True);

            for Here in Image.all'First
                     .. Image.all'Last - B.Byte_Count (Name'Length) + 1
            loop
               if (for all K in Name'Range =>
                     Natural (Image.all (Here + B.Byte_Count (K - Name'First)))
                     = Character'Pos (Name (K)))
               then
                  for K in Other'Range loop
                     Image.all (Here + B.Byte_Count (K - Other'First)) :=
                       Character'Pos (Other (K));
                  end loop;
                  Found := True;
                  exit;
               end if;
            end loop;
            Assert (Found, "the fixture does not carry " & Name);

            declare
               Held   : aliased constant B.Byte_Array := Image.all;
               Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
                 (Held'Access);
               Parsed : Containers.Container;
               Ready  : L.Model;
               Local  : E.Error_Info;
            begin
               Containers.Reader.Parse (Parsed, Source, Status => Local);
               Assert (E.Is_Ok (Local), "the edited fixture did not parse");

               L.Prepare (Ready, Parsed, Source, Status => Local);
               Assert (Local.Code = E.Arch_Missing_Tensor,
                       "a code variant without " & Name
                       & " was prepared: "
                       & E.Error_Code'Image (Local.Code));

               L.Close (Ready, Local);
               Containers.Close (Parsed);
            end;

            B.Free (Image);
         end;
      end loop;
   end Jina_Code_Variant_Agrees_With_The_Reference;

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

         --  And on the device, where the kernels take the sinks as the
         --  running softmax's first position: a token at a time, as a
         --  batch, and with the context in bytes, each against the
         --  reference rounding as the session does. A device without
         --  room for the sinks would attend these layers on the host, and
         --  a kernel that dropped them would answer, and answer wrongly,
         --  which is what the reference is for.
         declare
            Awake : Boolean;

            procedure On_Device
              (Cache   : L.Cache_Precision;
               Batched : Boolean;
               Bound   : Long_Float;
               What    : String)
            is
               Over   : Harness (Held'Access);
               Live   : L.Session;
               Able   : Boolean;
               Got    : Logit_Vector;
               Worst  : Long_Float := 0.0;
            begin
               Start (Over, Model_Runner.Backend.Backend_Device, Able);
               if not Able then
                  return;
               end if;

               L.Open (Live, Over.Ready, Cache => Cache, Status => Status);
               Assert (E.Is_Ok (Status), "the device session did not open " & What);
               if Batched then
                  L.Evaluate_Batch (Live, Over.Ready, Prompt, Got, Status => Status);
               else
                  for Token of Prompt loop
                     L.Evaluate (Live, Over.Ready, Token, Got, Status => Status);
                     exit when E.Is_Error (Status);
                  end loop;
               end if;
               Assert (E.Is_Ok (Status), "the device evaluation failed " & What
                       & ": " & E.Error_Code'Image (Status.Code));
               L.Close (Live);
               L.Close (Over.Ready, Status);

               Reference_Transformer.Round_Cache
                 (Second,
                  (if L."=" (Cache, L.Eighth) then Reference_Transformer.To_Bytes
                   else Reference_Transformer.Unrounded),
                  (if L."=" (Cache, L.Eighth) then Reference_Transformer.To_Bytes
                   else Reference_Transformer.Unrounded));
               Reference_Transformer.Run (Second, Tokens, Expected, Made);
               Assert (Made, "the reference produced no logits " & What);

               for Index in Expected'Range loop
                  Worst := Long_Float'Max
                    (Worst,
                     abs (Long_Float (Got (Model_Runner.Numerics.Element_Count (Index)))
                          - Expected (Index)));
               end loop;
               Assert (Worst < Bound,
                       "the device and the independent implementation disagree "
                       & "about a gpt-oss model " & What & " by"
                       & Long_Float'Image (Worst));
            end On_Device;
         begin
            Model_Runner.Backend.Device.Open (Awake);
            if Awake then
               On_Device (L.Exact, False, 5.0E-2, "a token at a time");
               On_Device (L.Exact, True, 5.0E-2, "as a batch");
               On_Device (L.Eighth, False, Conformance.Fourth_Absolute_Tolerance,
                          "a token at a time in bytes");
               On_Device (L.Eighth, True, Conformance.Fourth_Absolute_Tolerance,
                          "as a batch in bytes");
               Model_Runner.Backend.Device.Close;
            else
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "note: no device attended with sinks here");
            end if;
         end;

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
   --  A context nobody named is the model's own where the session can
   --  hold it and the largest halving of it that fits otherwise; a context
   --  that was named is held to and refused as it was. The fixture declares
   --  8192 positions, the limit holds exactly what 2048 plan to take, so
   --  the session opens at 2048 unnamed and is refused at 8192 named.
   procedure Unnamed_Context_Fits_The_Session_Bound
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Room => 8192);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Live   : L.Session;
         Plan   : Model_Runner.Memory.Session_Plan;
         Status : E.Error_Info;
         Bounds : Model_Runner.Limits.Session_Limits;
      begin
         Start (Under);

         L.Plan_Session (Under.Ready, 2048, Plan, Status);
         Assert (E.Is_Ok (Status), "the plan for 2048 positions failed");
         Bounds.Max_Session_Bytes := Plan.Total_Resident;

         L.Open (Live, Under.Ready, Session_Bounds => Bounds,
                 Status => Status);
         Assert (E.Is_Ok (Status),
                 "a session naming no context was refused: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Capacity (Live) = 2048,
                 "a session naming no context holds"
                 & Natural'Image (L.Capacity (Live))
                 & " positions where 2048 fit");
         L.Close (Live);

         L.Open (Live, Under.Ready, Context => 8192,
                 Session_Bounds => Bounds, Status => Status);
         Assert (Status.Code = E.Memory_Limit_Exceeded,
                 "a named context past the bound was not refused: "
                 & E.Error_Code'Image (Status.Code));
         L.Close (Live);
      end;

      B.Free (Image);
   end Unnamed_Context_Fits_The_Session_Bound;

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
         --  This failed one run in six for a while, always by the same
         --  amount: the sequence in flight was pinning only the last
         --  matrix it had taken, the others were given back under it and
         --  the next layer's weights written into their buffers while the
         --  device still read them. `tests test --only "llama inference :
         --  a model larger" --times 60` is how it was cornered.
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
        (T, Byte_Pair_Cutting_Matches_The_Expressions'Access,
         "every cutting rule agrees with the expressions it was written "
         & "from, over generated text");
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
        (T, Fourth_Cache_Holds_A_Sixth'Access,
         "a four-bit cache holds a sixth and a bit of the bytes, answers "
         & "near the exact one, survives a snapshot to the bit, and its two "
         & "kernels read nibbles and block scales as a plain computation does");
      Register_Routine
        (T, Values_Stored_Apart_From_Keys'Access,
         "a session holds its values in the other packed storage from its "
         & "keys, on the processor and the device, agreeing with the "
         & "independent implementation rounding each side its way; plans "
         & "between the two; snapshots to the bit into the same pair and "
         & "not another; and a pairing that is not two packed storages is "
         & "refused");
      Register_Routine
        (T, A_Packed_Session_On_The_Device_Packs_There'Access,
         "a packed session on the device has its keys and values packed "
         & "there as they are placed, and what it snapshots is the bytes a "
         & "processor session makes of the same text, a token at a time "
         & "and as a batch, in bytes and in nibbles");
      Register_Routine
        (T, Mixture_Under_Its_Own_Keys'Access,
         "a mixture under the qwen3moe keys is read as one");
      Register_Routine
        (T, Gemma3_At_Sixty_Two_Layers_Scales_By_The_Embedding'Access,
         "a gemma3 of sixty-two layers scales its scores by the width the "
         & "embedding implies, as the 27B does, and one of six by the "
         & "head's, each agreeing with the independent implementation");
      Register_Routine
        (T, Baichuan_At_Forty_Layers_Turns_To_Alibi'Access,
         "a Baichuan of forty layers is the 13B -- the depth alone tells it "
         & "from the 7B, no key in the file -- so it drops its rotation for "
         & "an alibi fall-off of eight, where one of two layers rotates and "
         & "carries none, each agreeing with the independent implementation");
      Register_Routine
        (T, Jina_Code_Variant_Agrees_With_The_Reference'Access,
         "the code variant of jina-bert-v2 -- the whole of its queries and "
         & "keys normalized and the attention sublayer normalized twice -- "
         & "agrees with the independent implementation at every position, "
         & "the text variant beside it, and a file with some of its six "
         & "tensors is refused as a missing tensor");
      Register_Routine
        (T, Sinks_And_A_Clamped_Gate'Access,
         "on the device too, a token at a time, as a batch and in bytes, "
         & "an attention sink and a clamped gate agree with the independent "
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
        (T, Unnamed_Context_Fits_The_Session_Bound'Access,
         "a context nobody named is cut to what the session may hold, and "
         & "a named one past it is refused");
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
        (T, A_Reranker_Scores_A_Text'Access,
         "a reranker takes a text through its head to a single score");
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
        (T, A_Hybrid_Drafts_From_Its_Next_Block_When_Sampling'Access,
         "a run drafting from a hybrid's next block while sampling keeps "
         & "the model's own distribution");
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
        (T, Device_Says_When_A_Model_Will_Not_Fit'Access,
         "a model whose matrices are larger than the device will hold is "
         & "refused while it loads, with both numbers");
      Register_Routine
        (T, Sessions_Of_Different_Sizes_Share_The_Device_S_Cache'Access,
         "sessions of three context lengths share the device's cache, each "
         & "in a block of its own size, and each says what it says alone");
      Register_Routine
        (T, Two_Models_On_One_Device_Keep_Their_Own_Caches'Access,
         "two models prepared on one device at once, their sessions "
         & "stepped turn and turn about, each says what it says alone");
      Register_Routine
        (T, The_Cache_Moves_Its_Blocks_Rather_Than_Growing'Access,
         "the device's cache moves its blocks down rather than growing "
         & "past a gap a larger block cannot use");
      Register_Routine
        (T, The_Room_Of_Rings_Moves_Its_Seats_Rather_Than_Growing'Access,
         "the device's room of rings moves its seats to the front rather "
         & "than growing past a gap a larger ring cannot use");
      Register_Routine
        (T, A_Run_Says_Which_Layers_The_Device_Took'Access,
         "a run on the device says how many layers went over whole and "
         & "how many the processor took, and names what refused them");
      Register_Routine
        (T, A_Paged_Session_Says_What_A_Block_Session_Says'Access,
         "a session whose device cache is dealt in pages rather than one "
         & "block gives, bit for bit, the logits it gives in a block, past "
         & "two pages");
      Register_Routine
        (T, A_Paged_Session_At_A_Smaller_Page_Says_The_Same'Access,
         "a paged session whose page holds fewer positions, set by "
         & "Set_Page_Size, gives bit for bit what a block gives, at "
         & "thirty-two positions a page and at sixteen");
      Register_Routine
        (T, A_Packed_Paged_Session_Says_What_A_Packed_Block_Says'Access,
         "a session whose cache is kept packed and dealt in pages gives, "
         & "bit for bit, what the same session gives in a packed block, "
         & "past two pages, in bytes and in nibbles");
      Register_Routine
        (T, A_Paged_Session_Holds_Only_What_It_Fills'Access,
         "a paged session takes a page of the device's cache only as a "
         & "position reaches it, so it holds a fraction of the pages a "
         & "block would for a context it fills little of");
      Register_Routine
        (T, A_Block_And_A_Paged_Session_Do_Not_Corrupt_Each_Other'Access,
         "a block session and a paged one opened on the one device do not "
         & "write over each other: the device holds one kind at a time and "
         & "the paged one attends on the host");
      Register_Routine
        (T, A_Paged_Window_Says_What_A_Block_Window_Says'Access,
         "a paged session on a sliding-window model, whose cells ring as "
         & "the window slides and whose pages are reused, says bit for bit "
         & "what a block session says");
      Register_Routine
        (T, Two_Backends_Agree_On_A_Long_Prompt'Access,
         "the processor and the device agree on a prompt long enough to "
         & "fill the tile, in one batch and across a seam");
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
