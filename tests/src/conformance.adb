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
with Model_Runner.Backend.Reference;
with Tiny_Model;

package body Conformance is

   use type Model_Runner.Numerics.Element_Count;

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;

   use type L.Repack_Mode;
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

      procedure Compare
        (Tokens  : Sequence;
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
         Held      : aliased constant B.Byte_Array := Image.all;
         Source    : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed    : Containers.Container;
         Engine    : L.Model;
         Session   : L.Session;
         Reference : R.Model;
         Status    : E.Error_Info;
         Loaded    : Boolean;
      begin
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

         R.Load (Reference, Parsed, Held, Loaded);
         if not Loaded then
            L.Close (Engine, Status);
            Containers.Close (Parsed);
            return;
         end if;

         declare
            Words  : constant Natural := R.Vocabulary (Reference);
            Expected : R.Real_Vector (0 .. Words - 1) := [others => 0.0];
            Actual   : N.Real_Array (0 .. N.Element_Count (Words) - 1) :=
              [others => 0.0];
            Produced : Boolean;
            Tokens_R : R.Token_Vector (Tokens'Range);
         begin
            for Index in Tokens'Range loop
               Tokens_R (Index) := Tokens (Index);
            end loop;

            R.Run (Reference, Tokens_R, Expected, Produced);
            if not Produced then
               R.Close (Reference);
               L.Close (Engine, Status);
               Containers.Close (Parsed);
               return;
            end if;

            --  Serial, or across the pool. The partitioned path is what a
            --  real run uses and it was compared only against the engine's
            --  own serial results: a partition that is wrong the same way at
            --  every worker count passes a stability check and fails this
            --  one.
            L.Open
              (Session, Engine,
               Workers => (if Shared then Team'Unchecked_Access else null),
               Status => Status);
            if E.Is_Error (Status) then
               R.Close (Reference);
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

            if E.Is_Ok (Status) then
               Result.Sequences := Result.Sequences + 1;

               for Token in 0 .. Words - 1 loop
                  declare
                     Left  : constant Long_Float := Expected (Token);
                     Right : constant Long_Float :=
                       Long_Float (Actual (N.Element_Count (Token)));
                     Gap   : constant Long_Float := abs (Left - Right);
                     Scale : constant Long_Float :=
                       Long_Float'Max (abs Left, abs Right);
                     Relative : constant Long_Float :=
                       (if Scale > 0.0 then Gap / Scale else 0.0);
                  begin
                     if Repack = L.To_BF16 then
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
                     if Repack = L.To_BF16 then
                        if Gap > Lossy_Absolute_Tolerance
                          and then Relative > Lossy_Relative_Tolerance
                        then
                           Result.Failures := Result.Failures + 1;
                        end if;
                     elsif Gap > Absolute_Tolerance
                       and then Relative > Relative_Tolerance
                     then
                        Result.Failures := Result.Failures + 1;
                     end if;
                  end;
               end loop;
            end if;

            L.Close (Session);
         end;

         R.Close (Reference);
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
      declare
         --  Which backends run their products across a pool, asked of them.
         function Shares
           (Kind : Model_Runner.Backend.Backend_Kind) return Boolean
         is (case Kind is
               when Model_Runner.Backend.Backend_CPU =>
                 Model_Runner.Backend.CPU.Describe
                   (Model_Runner.Backend.CPU.Max_Workers).Supports_Parallel,
               when Model_Runner.Backend.Backend_Reference =>
                 Model_Runner.Backend.Reference.Describe.Supports_Parallel);

         function Batches
           (Kind : Model_Runner.Backend.Backend_Kind) return Boolean
         is (case Kind is
               when Model_Runner.Backend.Backend_CPU =>
                 Model_Runner.Backend.CPU.Describe
                   (Model_Runner.Backend.CPU.Max_Workers).Supports_Batched,
               when Model_Runner.Backend.Backend_Reference =>
                 Model_Runner.Backend.Reference.Describe.Supports_Batched);

         Batching : Natural := 0;
         Sharing  : Natural := 0;
      begin
         for Backend in Model_Runner.Backend.Backend_Kind loop
            for Qwen in Boolean loop
               for Format in Tiny_Model.Weight_Format loop
                  Tiny_Model.Build (Image, Format, Qwen => Qwen);

                  for Repack in L.Repack_Mode loop
                     Compare (Sequence'(1 => 4), Backend, Repack);
                     Compare (Sequence'(4, 5), Backend, Repack);
                     Compare (Sequence'(1, 4, 5, 6, 7), Backend, Repack);
                     Compare (Sequence'(4, 4, 4, 5, 5, 6, 7, 8), Backend,
                              Repack);

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
                        Compare (Sequence'(4, 5), Backend, Repack,
                                 Batched => True);
                        Compare (Sequence'(1, 4, 5, 6, 7), Backend, Repack,
                                 Batched => True);
                        Compare (Sequence'(4, 4, 4, 5, 5, 6, 7, 8), Backend,
                                 Repack, Batched => True);
                     end if;

                     --  And again across a pool, where the rows of every
                     --  product are partitioned. The reference backend has
                     --  no pool to share, which it says of itself.
                     if Shares (Backend) then
                        Compare (Sequence'(1, 4, 5, 6, 7), Backend, Repack,
                                 Shared => True);
                        Compare (Sequence'(4, 4, 4, 5, 5, 6, 7, 8), Backend,
                                 Repack, Shared => True);

                        if Batches (Backend) then
                           Compare (Sequence'(4, 4, 4, 5, 5, 6, 7, 8),
                                    Backend, Repack,
                                    Batched => True, Shared => True);
                        end if;

                        --  And the same eight tokens three at a time, which
                        --  is two seams: 3, 3, 2.
                        if Batches (Backend) then
                           Compare (Sequence'(4, 4, 4, 5, 5, 6, 7, 8),
                                    Backend, Repack, Batched => True,
                                    Shared => True, Chunk => 3);
                        end if;
                     end if;
                  end loop;

                  B.Free (Image);
               end loop;
            end loop;
         end loop;

         --  Every combination the loops above visit, times the four sequences
         --  each one compares.
         --
         --  A literal here was edited nine times in one day -- 32, 96, 144,
         --  192, 336, 384, 528, 576, 624 -- and a literal can only confirm what
         --  somebody last typed: a format that quietly failed to load lowered
         --  the count until the number was edited to match, which is the exact
         --  failure this is meant to catch. It happened twice.
         for Kind in Model_Runner.Backend.Backend_Kind loop
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
            Backends : constant Natural :=
              Model_Runner.Backend.Backend_Kind'Pos
                (Model_Runner.Backend.Backend_Kind'Last) + 1;
            Repacks : constant Natural :=
              L.Repack_Mode'Pos (L.Repack_Mode'Last) + 1;

            --  Two architectures. Four sequences a token at a time on every
            --  backend; three of them again in one pass on the backends that
            --  batch; two across a pool on the backends that partition, and
            --  one of those in one pass as well.
            Expected : constant Natural :=
              Formats * 2 * Repacks
              * (Backends * 4 + Batching * 3 + Sharing * 2
                 + (if Batching > 0 and then Sharing > 0 then 2 else 0));
         begin
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
