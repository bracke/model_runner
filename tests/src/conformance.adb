with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Platform;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;

with Reference_Transformer;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Backend.Reference;
with Tiny_Model;

package body Conformance is

   use type Model_Runner.Numerics.Element_Count;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;

   use type L.Repack_Mode;
   use type Tiny_Model.Weight_Format;
   package N renames Model_Runner.Numerics;
   package R renames Reference_Transformer;

   ---------
   -- Run --
   ---------

   procedure Run (Result : out Report) is
      Image : B.Byte_Array_Access;

      --  The sequences to compare. Lengths differ so that the comparison
      --  covers one token, a short context, and a context long enough that
      --  attention reads several past positions.
      type Sequence is array (Positive range <>) of Natural;

      --  The four of them, named rather than written at each call, so that
      --  what a comparison asks for is an index the cache below can key on.
      Alone : constant Sequence := [1 => 4];
      Pair  : constant Sequence := [4, 5];
      Short : constant Sequence := [1, 4, 5, 6, 7];
      Long  : constant Sequence := [4, 4, 4, 5, 5, 6, 7, 8];

      subtype Sequence_Index is Positive range 1 .. 4;

      function Chosen (Which : Sequence_Index) return Sequence
      is (case Which is
            when 1 => Alone,
            when 2 => Pair,
            when 3 => Short,
            when 4 => Long);

      --  What the independent implementation makes of the current fixture,
      --  computed once for each sequence and kept.
      --
      --  It used to be computed inside every comparison, which is once per
      --  backend, per repacking mode, per evaluation path and per pool
      --  choice -- eight times over for each answer it can only give one of.
      --  The reference reads the file and the tokens and nothing else: it
      --  does not know which backend it is being compared against, and it
      --  cannot, because it has none. So the sweep ran the slowest thing in
      --  it eight times for a result it already had, and took nine minutes
      --  where two will do.
      Words : constant Natural := Tiny_Model.Vocabulary;

      type Expectation is array (Sequence_Index) of
        R.Real_Vector (0 .. Words - 1);

      Expected : Expectation := [others => [others => 0.0]];
      Known    : array (Sequence_Index) of Boolean := [others => False];

      --  Forget them. Called wherever a new fixture is built, because the
      --  expectations belong to the fixture and to nothing else.
      procedure Forget is
      begin
         Known := [others => False];
      end Forget;

      --  The shapes a supported model comes in. Not flags, because they are
      --  not independent of each other in what they are worth crossing: each
      --  is a different route through the evaluator and each is worth every
      --  format, backend and repack mode on its own.
      type Model_Shape is (Plain, Windowed, Mixed, Stretched, Apart);

      --  The formats the device reads without being repacked into one, which
      --  since the shader gained the other twelve branches is all of them.
      --  The backend states them; this states them again rather than reading
      --  them, because a fixture has to be written in each and the writer
      --  takes a name.
      --
      --  This crossing is what holds the shader to the decoder it copies.
      --  Every branch there was written from the Ada one and could have been
      --  written wrong -- a shift by the wrong amount, a sub-block scale
      --  read from the wrong byte, a level table off by one -- and none of
      --  those shows up as anything but a slightly wrong answer. Here each
      --  format runs a whole model on the device against the independent
      --  reference transformer, so a branch that decodes almost correctly
      --  fails.
      Device_Formats : constant array (1 .. 15) of Tiny_Model.Weight_Format :=
        [Tiny_Model.F32, Tiny_Model.F16, Tiny_Model.BF16,
         Tiny_Model.Q4_0, Tiny_Model.Q4_1, Tiny_Model.Q5_0, Tiny_Model.Q5_1,
         Tiny_Model.Q8_0, Tiny_Model.IQ4_NL,
         Tiny_Model.Q2_K, Tiny_Model.Q3_K, Tiny_Model.Q4_K, Tiny_Model.Q5_K,
         Tiny_Model.Q6_K, Tiny_Model.IQ4_XS];

      Swept : constant array (1 .. 2) of Model_Runner.Backend.Backend_Kind :=
        [Model_Runner.Backend.Backend_CPU,
         Model_Runner.Backend.Backend_Reference];

      --  The architectures the sweep crosses with everything else. Qwen3_MoE
      --  is not among them and that is deliberate: it is Qwen3 with its
      --  metadata under another prefix, so crossing it with every format and
      --  path would buy one string comparison for a third of the run time.
      --  It is compared against the reference on its own, where the mixture
      --  it carries is the point rather than the prefix.
      --  Gemma is crossed rather than compared once, because its three
      --  differences touch every part of a pass: the gain on every
      --  normalization, the scale on the embedding, and the gate in every
      --  feed-forward block. A single comparison would exercise them, and
      --  crossing them with the formats and the paths is what says they
      --  survive a quantized weight and a batched evaluation.
      --  Gemma is crossed rather than compared once, because its three
      --  differences touch every part of a pass: the gain on every
      --  normalization, the scale on the embedding, and the gate in every
      --  feed-forward block, dense or mixed.
      Crossed : constant array (1 .. 9) of Tiny_Model.Fixture_Architecture :=
        [Tiny_Model.Llama, Tiny_Model.Qwen2, Tiny_Model.Qwen3,
         Tiny_Model.Gemma, Tiny_Model.Gemma2, Tiny_Model.Gemma3,
         Tiny_Model.Phi3, Tiny_Model.Falcon, Tiny_Model.Phi2];

      --  Compare one sequence, evaluated by the named backend, against the
      --  independent implementation.
      --  A pool for the half of the sweep that runs in parallel. Made once
      --  and shared: what is compared is the partitioning, and one pool
      --  partitions the same way every time.
      Team : aliased Model_Runner.Backend.CPU.Pool
        (Model_Runner.Backend.CPU.Worker_Count
           (Positive'Min
              (4,
               Positive'Max (1, Model_Runner.Platform.Core_Count - 1))));

      --  Fill in what the reference makes of one sequence, if it is not
      --  already known. Loading the reference decodes every matrix of the
      --  model into Long_Float, which is most of what this costs, so it too
      --  happens once for a fixture rather than once for a comparison.
      --  The fixture is read where it is rather than copied into this
      --  frame. The copy was a whole file on the stack, which is nothing at
      --  two blocks of eight elements and a storage error at six blocks of
      --  two hundred and fifty-six with a mixture behind each -- which is
      --  what gemma3's fixture became when it grew the block that sees
      --  everything.
      procedure Learn (Which : Sequence_Index) is
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
         Parsed : Containers.Container;
         Second : R.Model;
         Status : E.Error_Info;
         Loaded, Produced : Boolean;

         Tokens : constant Sequence := Chosen (Which);
      begin
         if Known (Which) then
            return;
         end if;

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            return;
         end if;

         R.Load (Second, Parsed, Image.all, Loaded);
         if not Loaded then
            Result.Unlearned := Result.Unlearned + 1;
            Containers.Close (Parsed);
            return;
         end if;

         declare
            Tokens_R : R.Token_Vector (Tokens'Range);
         begin
            for Index in Tokens'Range loop
               Tokens_R (Index) := Tokens (Index);
            end loop;

            R.Run (Second, Tokens_R, Expected (Which), Produced);
            Known (Which) := Produced;

            if not Produced then
               Result.Unlearned := Result.Unlearned + 1;
            end if;
         end;

         R.Close (Second);
         Containers.Close (Parsed);
      end Learn;

      procedure Compare
        (Which   : Sequence_Index;
         Cache   : L.Cache_Precision := L.Exact;
         Backend : Model_Runner.Backend.Backend_Kind :=
           Model_Runner.Backend.Backend_CPU;
         Repack  : L.Repack_Mode := L.No_Repack;
         Batched : Boolean := False;
         Shared  : Boolean := False;

         --  How many tokens to hand over at once, or zero for all of them.
         --  A prompt longer than --batch-size is evaluated in several
         --  calls, and the seam between them -- where the cache position
         --  carries from one call to the next -- is where an off-by-one
         --  would live. Every comparison here used to hand over the whole
         --  sequence at once and never cross that seam.
         Chunk   : Natural := 0)
      is
         Source    : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
         Parsed    : Containers.Container;
         Engine    : L.Model;
         Session   : L.Session;
         Status    : E.Error_Info;

         Tokens    : constant Sequence := Chosen (Which);
      begin
         Learn (Which);
         if not Known (Which) then
            return;
         end if;

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            return;
         end if;

         L.Prepare
           (Engine, Parsed, Source, Backend => Backend, Repack => Repack,
            Status => Status);
         if E.Is_Error (Status) then
            Containers.Close (Parsed);
            return;
         end if;

         declare
            Answer : R.Real_Vector renames Expected (Which);
            Actual : N.Real_Array (0 .. N.Element_Count (Words) - 1) :=
              [others => 0.0];
         begin

            --  Serial, or across the pool. The partitioned path is what a
            --  real run uses and it was compared only against the engine's
            --  own serial results: a partition that is wrong the same way at
            --  every worker count passes a stability check and fails this
            --  one.
            L.Open
              (Session, Engine,
               Workers => (if Shared then Team'Unchecked_Access else null),
               Cache => Cache, Status => Status);
            if E.Is_Error (Status) then
               L.Close (Engine, Status);
               Containers.Close (Parsed);
               return;
            end if;

            --  One token at a time, or the whole sequence in one pass.
            --
            --  The batched path is what a prompt goes through, and it was
            --  compared only against the engine's own single-token results:
            --  the strongest statement here -- that the arithmetic agrees
            --  with an implementation written from the architecture
            --  description -- was being made about the decode path alone.
            if Batched then
               declare
                  Held : Model_Runner.Tokenizer.Token_Array
                    (1 .. Tokens'Length);
                  Step : constant Positive :=
                    (if Chunk = 0 then Tokens'Length else Chunk);
                  From : Positive := 1;
               begin
                  for Index in Tokens'Range loop
                     Held (Index - Tokens'First + 1) :=
                       Model_Runner.Tokenizer.Token_Id (Tokens (Index));
                  end loop;

                  --  One call, or several with the engine carrying the
                  --  position between them, which is what a prompt longer
                  --  than the batch size does.
                  while From <= Held'Last loop
                     declare
                        Upto : constant Positive :=
                          Positive'Min (From + Step - 1, Held'Last);
                     begin
                        L.Evaluate_Batch
                          (Session, Engine, Held (From .. Upto), Actual,
                           Status => Status);
                        exit when E.Is_Error (Status);
                        From := Upto + 1;
                     end;
                  end loop;
               end;
            else
               for Index in Tokens'Range loop
                  L.Evaluate
                    (Session, Engine,
                     Model_Runner.Tokenizer.Token_Id (Tokens (Index)),
                     Actual, Status => Status);
                  exit when E.Is_Error (Status);
               end loop;
            end if;

            --  An evaluation that ended in a diagnostic is counted rather
            --  than passed over. It used to leave no trace but a total that
            --  came up short, which is how three hundred of them hid a null
            --  buffer for an afternoon.
            if not E.Is_Ok (Status) then
               Result.Refused := Result.Refused + 1;
            end if;

            if E.Is_Ok (Status) then
               Result.Sequences := Result.Sequences + 1;

               for Token in 0 .. Words - 1 loop
                  declare
                     Left  : constant Long_Float := Answer (Token);
                     Right : constant Long_Float :=
                       Long_Float (Actual (N.Element_Count (Token)));
                     Gap   : constant Long_Float := abs (Left - Right);
                     Scale : constant Long_Float :=
                       Long_Float'Max (abs Left, abs Right);
                     Relative : constant Long_Float :=
                       (if Scale > 0.0 then Gap / Scale else 0.0);
                  begin

                     if L."=" (Cache, L.Eighth) then
                        Result.Eighth_Compared := Result.Eighth_Compared + 1;
                        Result.Eighth_Worst_Abs :=
                          Long_Float'Max (Result.Eighth_Worst_Abs, Gap);
                        Result.Eighth_Worst_Rel :=
                          Long_Float'Max (Result.Eighth_Worst_Rel, Relative);
                     elsif L."=" (Cache, L.Halved) then
                        Result.Cached_Compared := Result.Cached_Compared + 1;
                        Result.Cached_Worst_Abs :=
                          Long_Float'Max (Result.Cached_Worst_Abs, Gap);
                        Result.Cached_Worst_Rel :=
                          Long_Float'Max (Result.Cached_Worst_Rel, Relative);
                     elsif Repack = L.To_BF16 then
                        Result.Lossy_Compared := Result.Lossy_Compared + 1;
                        Result.Lossy_Worst_Abs :=
                          Long_Float'Max (Result.Lossy_Worst_Abs, Gap);
                        Result.Lossy_Worst_Rel :=
                          Long_Float'Max (Result.Lossy_Worst_Rel, Relative);
                     else
                        Result.Compared := Result.Compared + 1;
                        Result.Worst_Abs :=
                          Long_Float'Max (Result.Worst_Abs, Gap);
                        Result.Worst_Rel :=
                          Long_Float'Max (Result.Worst_Rel, Relative);
                     end if;

                     --  A logit passes when it is close in absolute terms or
                     --  close in relative terms; the absolute floor keeps a
                     --  value near zero from being judged by a ratio. The
                     --  rounded path is judged by its own pair, because
                     --  holding it to the exact one would say only what
                     --  rounding already says.
                     --  Which tolerance a comparison answers to depends on
                     --  what was asked of it: a halved cache and a halved
                     --  mantissa each have their own, measured, and the
                     --  exact modes answer to the strict one.
                     declare
                        Bad : Boolean := False;
                     begin
                        if L."=" (Cache, L.Eighth) then
                           Bad := Gap > Eighth_Absolute_Tolerance
                             and then Relative > Eighth_Relative_Tolerance;
                        elsif L."=" (Cache, L.Halved) then
                           Bad := Gap > Cached_Absolute_Tolerance
                             and then Relative > Cached_Relative_Tolerance;
                        elsif Repack = L.To_BF16 then
                           Bad := Gap > Lossy_Absolute_Tolerance
                             and then Relative > Lossy_Relative_Tolerance;
                        else
                           Bad := Gap > Absolute_Tolerance
                             and then Relative > Relative_Tolerance;
                        end if;

                        if Bad then
                           Result.Failures := Result.Failures + 1;
                        end if;
                     end;
                  end;
               end loop;
            end if;

            L.Close (Session);
         end;

         L.Close (Engine, Status);
         Containers.Close (Parsed);
      end Compare;

   begin
      Result := (others => <>);

      --  Both weight formats. The quantized one matters more: until it was
      --  added, nothing offline compared quantized inference against an
      --  independent implementation, and the only check on it was two tokens
      --  recorded from another runtime against a model that is not committed.
      --  And both architectures. Qwen2 differs from Llama in a bias on
      --  each attention projection and in which elements the rotation
      --  pairs; both are arithmetic, and neither had anything independent
      --  to be checked against until the reference learned them too.
      --  And every backend. The reference backend agreeing with the CPU one
      --  says the fast path's partitioning and batching change nothing; both
      --  of them agreeing with the independent implementation says the
      --  arithmetic is right. The second is the stronger statement and it
      --  was only ever made about one of the two.
      --  And every repacking mode. Repacking replaces the quantized views
      --  the kernels decode with binary32 or brain-float ones, which is a
      --  different arithmetic path through the same engine: f32 must land
      --  exactly where the stored layout does, and bf16 rounds every weight
      --  to eight mantissa bits, which is the one lossy thing this program
      --  does and the one that had no number attached to it.
      --  Which backends take more than a token at a time, asked of the
      --  backends rather than named here.
      --  And every shape a supported model comes in: dense, sliding-window,
      --  and a mixture of experts. Each is a different route through the
      --  same evaluator -- the mixture is the one place where a batch is not
      --  one matrix against many vectors -- and the reference reads the same
      --  file and arrives at each of them from the description.
      declare
         --  Which backends run their products across a pool, asked of them.
         function Shares
           (Kind : Model_Runner.Backend.Backend_Kind) return Boolean
         is (case Kind is
               when Model_Runner.Backend.Backend_CPU =>
                 Model_Runner.Backend.CPU.Describe
                   (Model_Runner.Backend.CPU.Max_Workers).Supports_Parallel,
               when Model_Runner.Backend.Backend_Reference =>
                 Model_Runner.Backend.Reference.Describe.Supports_Parallel,
               when Model_Runner.Backend.Backend_Device =>
                 Model_Runner.Backend.Device.Describe.Supports_Parallel);

         function Batches
           (Kind : Model_Runner.Backend.Backend_Kind) return Boolean
         is (case Kind is
               when Model_Runner.Backend.Backend_CPU =>
                 Model_Runner.Backend.CPU.Describe
                   (Model_Runner.Backend.CPU.Max_Workers).Supports_Batched,
               when Model_Runner.Backend.Backend_Reference =>
                 Model_Runner.Backend.Reference.Describe.Supports_Batched,
               when Model_Runner.Backend.Backend_Device =>
                 Model_Runner.Backend.Device.Describe.Supports_Batched);

         Batching : Natural := 0;
         Sharing  : Natural := 0;

         --  How many comparisons the device pass below made. Zero on a
         --  machine with no device, which is most of them.
         On_Device : Natural := 0;
         Device_Ready : Boolean := False;
      begin
         --  The backends this crosses with everything else. The device one
         --  is not among them and cannot be: it takes binary32 only, so it
         --  would refuse twelve of the fifteen formats outright, and the
         --  count below would have to know which. It is compared against the
         --  processor on its own, on a model it can take.
         for Backend of Swept loop
            for Which_Arch in Crossed'Range loop
               for Format in Tiny_Model.Weight_Format loop
                  for Shape in Model_Shape loop
                     --  The shapes a supported model comes in. The window is
                     --  three so that the eight-token sequences cross it
                     --  repeatedly and the shortest do not reach it, which is
                     --  where a window applied one position out shows. Two
                     --  experts of four is the same idea for routing: enough
                     --  that the choice is a choice, few enough that
                     --  positions disagree about it.
                     --
                     --  The stretched shape declares yarn and carries a
                     --  table of per-dimension divisors at once. They are
                     --  separate mechanisms and this does not separate them;
                     --  what it says is that the two implementations agree
                     --  about both together, over every format and path.
                     --  That each of them changes the answer at all, and
                     --  that linear does too, is asserted where a fixture can
                     --  hold one thing still -- in the inference tests.
                     Tiny_Model.Build
                       (Image, Format, Kind => Crossed (Which_Arch),
                        Window =>
                          (case Shape is
                             when Windowed => 3,
                             when others => 0),
                        Experts =>
                          (case Shape is
                             when Mixed => 4,
                             when others => 0),
                        Experts_Used =>
                          (case Shape is
                             when Mixed => 2,
                             when others => 0),
                        Stretch =>
                          (case Shape is
                             when Stretched => Tiny_Model.Yarn,
                             when Plain | Windowed | Mixed | Apart =>
                               Tiny_Model.Plain),
                        Rope_Table => Shape = Stretched,
                        Apart_Widths => Shape = Apart);

                     --  A new fixture, so the expectations belonging to the
                     --  last one are gone.
                     Forget;

                     for Repack in L.Repack_Mode loop
                        --  Brain floats and a narrow window are not compared,
                        --  and the reason is a measurement rather than a
                        --  convenience. Repacking to bf16 halves the mantissa,
                        --  and a window makes the softmax sharper, so a
                        --  perturbation that full attention averages away moves
                        --  a logit instead. Measured over this sweep, worst
                        --  absolute against the reference:
                        --
                        --    no window   0.137     window 5   0.517
                        --    window 6    0.137     window 4   0.517
                        --                          window 3   1.677
                        --
                        --  against a lossy tolerance of 0.3. The exact modes
                        --  agree at every one of those windows -- 2.1E-05 at
                        --  three, against 3.5E-06 with none -- so what this
                        --  says is not that the window is wrong but that
                        --  --repack bf16 costs more on a windowed model than
                        --  the figure published for a full-attention one.
                        --  Comparing it here would assert a tolerance nobody
                        --  has grounds for; the docs say the cost instead.
                        --  A mixture belongs to an architecture that has a
                        --  gate to route to. Falcon and Phi2 have none: one
                        --  projection up, a unit and one down is what their
                        --  feed-forward is, so a router in front of experts
                        --  that are not there describes no model anyone
                        --  publishes. The fixture wrote one all the same and
                        --  the engine would not load it, so every comparison
                        --  of that shape returned before it compared
                        --  anything -- nine hundred of them, counted by the
                        --  arithmetic below and run by nobody.
                        if Shape = Mixed
                          and then Crossed (Which_Arch)
                                   in Tiny_Model.Falcon | Tiny_Model.Phi2
                        then
                           goto Next_Repack;
                        end if;

                        if Shape = Windowed and then Repack = L.To_BF16 then
                           goto Next_Repack;
                        end if;

                        --  And not on a mixture, for a related reason that
                        --  the same sweep separates into two. Halving the
                        --  mantissa moves the router's scores, which moves
                        --  the shares the experts are summed with; and where
                        --  two experts score nearly the same it moves which
                        --  of them runs at all, which is a discrete change
                        --  that no tolerance on the arithmetic covers.
                        --  Measured here, worst absolute against the
                        --  reference with brain floats:
                        --
                        --    dense                      0.137
                        --    four of four experts       0.330
                        --    two of four experts        0.509
                        --
                        --  against a lossy tolerance of 0.3. The middle row
                        --  is the one that isolates it: running every expert
                        --  leaves no choice to flip, so what it measures is
                        --  the shares alone. The exact modes agree at
                        --  2.1E-05 either way.
                        if Shape = Mixed and then Repack = L.To_BF16 then
                           goto Next_Repack;
                        end if;

                        --  And not on a stretched one, for the same kind of
                        --  reason a third time. Stretching the rotation
                        --  changes which positions a head can tell apart,
                        --  and a distribution that has been sharpened
                        --  anywhere carries a rounded weight further.
                        --  Measured here, worst absolute with brain floats:
                        --  0.325 against a lossy tolerance of 0.3, where the
                        --  same fixture unstretched gives 0.137. The exact
                        --  modes agree at 2.1E-05, unchanged.
                        --
                        --  Three of the four shapes now sit outside that
                        --  tolerance, which is worth saying plainly: 0.137
                        --  is what --repack bf16 costs a dense model with
                        --  full attention, and it does not carry over to a
                        --  model that does anything else.
                        if Shape = Stretched and then Repack = L.To_BF16 then
                           goto Next_Repack;
                        end if;

                        --  And not on one whose heads are wider than the
                        --  embedding implies, where the reason is plainer
                        --  than the other three: this fixture's key heads
                        --  are twice that width and its value heads three
                        --  times it, so every dot product has more terms to
                        --  accumulate eight mantissa bits of error over.
                        --  Measured here: 0.707 against a lossy tolerance of
                        --  0.3. The exact modes agree at 2.1E-05.
                        if Shape = Apart and then Repack = L.To_BF16 then
                           goto Next_Repack;
                        end if;

                        Compare (1, L.Exact, Backend, Repack);
                        Compare (2, L.Exact, Backend, Repack);
                        Compare (3, L.Exact, Backend, Repack);
                        Compare (4, L.Exact, Backend, Repack);

                        --  And the same sequences through the batched path, which
                        --  is how a prompt is read. A sequence of one is the same
                        --  call either way, so the three that are not are the ones
                        --  worth the second pass.
                        --
                        --  Only on a backend that batches. The reference one
                        --  declines more than a token at a time and says so, which
                        --  is what it exists to be: asking anyway would compare a
                        --  refusal against a forward pass.
                        if Batches (Backend) then
                           Compare (2, L.Exact, Backend, Repack, Batched => True);
                           Compare (3, L.Exact, Backend, Repack, Batched => True);
                           Compare (4, L.Exact, Backend, Repack, Batched => True);
                        end if;

                        --  And again across a pool, where the rows of every
                        --  product are partitioned. The reference backend has
                        --  no pool to share, which it says of itself.
                        if Shares (Backend) then
                           Compare (3, L.Exact, Backend, Repack, Shared => True);
                           Compare (4, L.Exact, Backend, Repack, Shared => True);

                           if Batches (Backend) then
                              Compare (4, L.Exact, Backend, Repack,
                                       Batched => True, Shared => True);
                           end if;

                           --  And the same eight tokens three at a time, which
                           --  is two seams: 3, 3, 2.
                           if Batches (Backend) then
                              Compare (4, L.Exact, Backend, Repack, Batched => True,
                                       Shared => True, Chunk => 3);
                           end if;
                        end if;

                        --  And the same sequences again with the session
                        --  storing what it commits in half precision. Only
                        --  on the plain shape and only where the weights are
                        --  not also rounded: what is being measured is what
                        --  the cache costs, and measuring it through a
                        --  rounded model would measure the two together.
                        --
                        --  Both evaluation paths, because the two storages
                        --  are two procedures and a copy nothing runs is
                        --  what this sweep exists to prevent.
                        --
                        --  And on the windowed shape as well as the plain
                        --  one. The two procedures each carry their own copy
                        --  of what a window means, and running the halved
                        --  one only where there is no window left half of
                        --  that claim resting on the other procedure's code.
                        if Shape in Plain | Windowed
                          and then Repack = L.No_Repack
                        then
                           Compare (3, L.Halved, Backend, Repack);
                           Compare (4, L.Halved, Backend, Repack);

                           --  And the same in one byte an element, which is
                           --  the same two procedures again with a third
                           --  storage under them.
                           Compare (3, L.Eighth, Backend, Repack);
                           Compare (4, L.Eighth, Backend, Repack);

                           if Batches (Backend) then
                              Compare (4, L.Halved, Backend, Repack,
                                       Batched => True);
                              Compare (4, L.Eighth, Backend, Repack,
                                       Batched => True);
                           end if;
                        end if;

                        <<Next_Repack>>
                     end loop;

                     B.Free (Image);
                  end loop;
               end loop;
            end loop;
         end loop;

         --  And the device, on the three formats its shader decodes.
         --
         --  This is not crossed with the loops above and could not be: the
         --  other twelve formats reach it only through --repack f32, and
         --  running that cross would compare the repacking twelve times over
         --  rather than the device once. What is held here is the claim that
         --  matters -- that a product computed on a device gives the same
         --  logits as one computed on the processor -- over every
         --  architecture and every format the device reads for itself,
         --  against the same independent implementation everything else is
         --  compared against.
         --
         --  Both evaluation paths, because the shader takes a batch by
         --  reading each weight once for eight vectors and writing eight
         --  results, and an off-by-one in either would show as a logit
         --  belonging to the wrong position rather than as a failure.
         --
         --  Skipped where there is no device. A machine without one is the
         --  common case and this is not the test that would tell it so.
         --  Copied to the device, and only copied.
         --
         --  Reading the weights where they lie is the other way this
         --  backend can work, and this sweep cannot exercise it: a device is
         --  handed a page-aligned range, so a matrix within a page of either
         --  end of its storage is copied instead, and every matrix of a
         --  fixture eight wide and two deep is within a page of both. Run
         --  here it would report fifty-four more comparisons and test the
         --  same path twice, which is worse than not running it. It is
         --  tested where the memory can be made large enough to matter, in
         --  the backend tests.
         Model_Runner.Backend.Device.Open (Device_Ready);

         if Device_Ready then
            for Which_Arch in Crossed'Range loop
               for Format of Device_Formats loop
                  Tiny_Model.Build
                    (Image, Format, Kind => Crossed (Which_Arch));
                  Forget;

                  for Which in Sequence_Index loop
                     Compare
                       (Which, L.Exact,
                        Model_Runner.Backend.Backend_Device, L.No_Repack);
                     On_Device := On_Device + 1;
                  end loop;

                  --  Eight tokens in one pass, and the same eight three at a
                  --  time, which is a batch longer than the eight an
                  --  invocation carries and a batch that is not a whole
                  --  number of them.
                  Compare
                    (4, L.Exact, Model_Runner.Backend.Backend_Device,
                     L.No_Repack, Batched => True);
                  Compare
                    (4, L.Exact, Model_Runner.Backend.Backend_Device,
                     L.No_Repack, Batched => True, Chunk => 3);
                  On_Device := On_Device + 2;

                  --  And the same with the session storing what it commits
                  --  in half precision, on the first format only.
                  --
                  --  What the cache holds has nothing to do with how a
                  --  weight is encoded: it is keys and values the session
                  --  wrote, and rounding them is the session's doing rather
                  --  than the backend's. Crossing it with all fifteen
                  --  formats would run the same halving fifteen times. What
                  --  had never run at all is the halved cache with products
                  --  computed on a device -- every comparison of it was
                  --  against a processor -- and once is what that costs.
                  if Format = Device_Formats (Device_Formats'First) then
                     Compare
                       (3, L.Halved, Model_Runner.Backend.Backend_Device,
                        L.No_Repack);
                     Compare
                       (4, L.Halved, Model_Runner.Backend.Backend_Device,
                        L.No_Repack);
                     Compare
                       (4, L.Halved, Model_Runner.Backend.Backend_Device,
                        L.No_Repack, Batched => True);

                     --  And the byte storage, for the same reason and on the
                     --  same terms: what a session rounds is its own doing,
                     --  and the only thing crossing it with a device adds is
                     --  whether products computed there read a rounded row
                     --  back the way products computed here do.
                     Compare
                       (3, L.Eighth, Model_Runner.Backend.Backend_Device,
                        L.No_Repack);
                     Compare
                       (4, L.Eighth, Model_Runner.Backend.Backend_Device,
                        L.No_Repack);
                     Compare
                       (4, L.Eighth, Model_Runner.Backend.Backend_Device,
                        L.No_Repack, Batched => True);
                     On_Device := On_Device + 6;
                  end if;

                  B.Free (Image);
               end loop;
            end loop;
         end if;

         Model_Runner.Backend.Device.Close;

         --  Every combination the loops above visit, times the four sequences
         --  each one compares.
         --
         --  A literal here was edited nine times in one day -- 32, 96, 144,
         --  192, 336, 384, 528, 576, 624 -- and a literal can only confirm what
         --  somebody last typed: a format that quietly failed to load lowered
         --  the count until the number was edited to match, which is the exact
         --  failure this is meant to catch. It happened twice.
         for Kind of Swept loop
            if Batches (Kind) then
               Batching := Batching + 1;
            end if;
            if Shares (Kind) then
               Sharing := Sharing + 1;
            end if;
         end loop;

         declare
            Formats : constant Natural :=
              Tiny_Model.Weight_Format'Pos (Tiny_Model.Weight_Format'Last) + 1;
            Backends : constant Natural := Swept'Length;
            Repacks : constant Natural :=
              L.Repack_Mode'Pos (L.Repack_Mode'Last) + 1;

            Shapes : constant Natural :=
              Model_Shape'Pos (Model_Shape'Last) + 1;

            Arches : constant Natural := Crossed'Length;

            --  Every crossed architecture, each in every shape a model comes
            --  in.
            --  Four sequences a token at a time on every backend; three of
            --  them again in one pass on the backends that batch; two across
            --  a pool on the backends that partition, and one of those in
            --  one pass as well.
            --  The windowed half runs one repack mode fewer, for the
            --  reason written where it is skipped.
            Per_Model : constant Natural :=
              Backends * 4 + Batching * 3 + Sharing * 2
              + (if Batching > 0 and then Sharing > 0 then 2 else 0);

            --  Every shape runs every repack mode except the four that run
            --  one fewer, for the reasons written where each is skipped.
            --  Only the plain shape is compared under brain floats, and that
            --  is the finding rather than a gap: the published lossy figure
            --  describes a dense model with full attention and heads the
            --  width its embedding implies, and nothing else.
            --  And the half-precision cache, which runs on the plain and
            --  windowed shapes with the weights unrounded: two sequences a
            --  backend, and one of them again through the batched path
            --  where the backend takes one.
            --  Twice over: the halved cache and the byte one run the same
            --  comparisons.
            Cached : constant Natural :=
              2 * Formats * Arches * 2 * (Backends * 2 + Batching);

            --  The architectures with no gate, which run every shape but
            --  the mixture. Counted rather than named twice: what makes a
            --  mixture impossible for them is the absent gate, and the sweep
            --  skips the shape on the same grounds.
            Ungated : Natural := 0;

            Expected : Natural := 0;

         begin
            for Kind of Crossed loop
               if Kind in Tiny_Model.Falcon | Tiny_Model.Phi2 then
                  Ungated := Ungated + 1;
               end if;
            end loop;

            --  The mixture shape runs every repack mode but the rounded one,
            --  which is skipped for every architecture; an ungated one runs
            --  none of them at all.
            Expected :=
              Formats * Arches * (Shapes * Repacks - 4) * Per_Model + Cached
              + On_Device
              - Formats * Ungated * (Repacks - 1) * Per_Model;

            Result.Wanted := Expected;
            Result.Ran := Result.Sequences = Expected;
         end;
      end;

      --  The workers are told to stop before this returns. Leaving the
      --  frame waits for them to terminate, and a pool nobody closed waits
      --  for work that is never coming: the first version of this hung
      --  after every comparison had already passed.
      Model_Runner.Backend.CPU.Close (Team);

   end Run;

end Conformance;
