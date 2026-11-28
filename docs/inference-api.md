# Embedded inference API

Inkling 2 Mini's fixed three-loop GGUF decoder executes through this API using
its existing session, sampling and lifecycle interfaces. Native CPU and Vulkan
F32 activation execution pass independent checkpoint comparisons; F16 cache
storage has a separate, reference-calibrated precision profile. Set an explicit
context and session-memory budget: the checkpoint's declared 1,048,576-token
ceiling is not a practical allocation target on a 32 GB machine. Inkling also
accepts `Transformed_Fourth` (CLI `--kv-cache q4t`) with ordinary-Q4 values and
head widths divisible by 32. The shared codec and cache lifecycle are reused;
native Vulkan Q4T relative attention can retain packed KV state on the device
using existing cache ownership and allocation limits. Physical bias tables are
shared across visits; per-visit state remains separate. Unsupported shapes or
unavailable device room retain the existing CPU attention fallback. The private
4-GiB GPU profile passes attention and cache lifecycle conformance; its long
throughput trial remains impractical within the recorded budget. Other packed
KV pairings, variable-loop checkpoints and image input are explicitly refused. Production
release status, qualified CPU/private-GPU settings and remaining shared-host
measurements are tracked in [Inkling verification](inkling2-verification.md).

Native CPU integer Inkling generation can project only a narrow grammar's
allowed vocabulary rows when sampling greedily. `Constrained_Projection` is
True by default; setting it False requests complete projection. Drafting,
logprobs, capture, observers, adapters, context shifting, broad constraints and
other backends retain full projection. `Llama.Evaluate_Selected` validates
1–256 sorted unique IDs before execution; callers must mask unselected logits.
Sparse rows are excluded from full-distribution checkpoints. Rewind can rebuild
from an earlier boundary, and `Complete_Logits` materializes the current full
head without adding a token. Generation performs that completion before return.
The selected-head implementation packs the normalized input once for all
selected rows. Grammar candidate lookup uses first-byte lists, and
`Sampling.Sample_Allowed` preserves greedy biases, history penalties, permanent
and step masks, and lowest-ID ties without walking unmaterialized rows.
`Llama.Loop_Device_Attention_Runs` reports actual native loop-attention device
calls, preventing a fallback from being mistaken for GPU execution. The
checkpoint and lifecycle evidence is in
[the eight-candidate evaluation](inkling2-routing-eight-evidence.json).

Inkling F32 prefill uses the existing batch limit to batch projections and
expert execution. Attention and convolution state advance in token order;
prefix reconstruction uses bounded calls to the same evaluator. Physical
weights remain shared across the 48 logical visits. Q4T with Vulkan matrix
products evaluates prompt rows with the decode arithmetic inside one batch
transaction. This avoids batch-dependent reductions crossing packed-cache
rounding boundaries; CPU Q4T keeps batched projections and experts. A cancelled
device batch restores its original convolution state, hidden state and position.
See the
[batching contract](inkling2-architecture.md#native-batched-prefill).

The native row-major CPU integer profile (`--backend cpu --arith int8
--repack none --kv-cache q4t`) also passes independent checkpoint conformance:
all captured values and expert routes match exactly for Hello and the cached
five-token prefix. Expert batching preserves these results, and the Q4T
integer lifecycle test passes. This profile is qualified on the recorded
AVX-512 host. Optional `--repack rows` also passes the independent checkpoint
comparisons with compressed interleaved weights. The optional Vulkan integer
path now passes five-format operator and two full-checkpoint comparisons; its
long-prompt throughput trial did not finish within 300 seconds. Two-row/four-vector
integer tiles, shared expert packing, bounded
physical header tables and fused SiTU/down-input packing retain the reference
reductions. See [integer evidence](inkling2-integer-native-evidence.json) and
[the subsequent performance qualification](inkling2-integer-eight-evidence.json).
The CPU integer profile also uses streaming small-batch kernels, SIMD reference
packing, bounded correction tiles and direct compressed-panel reading; Q4T
storage is unchanged. See [streaming qualification](inkling2-integer-stream-eight-evidence.json).
The subsequent CPU integer path retains packed worker buffers until session
close, shares activation loads between gate/up products and paired rows, writes
completed results directly, and uses eight-vector Q8_0/Q5_0 tiles. Signed
products use a cheaper transform only after checking that no activation is
-128; otherwise the unsigned-bias calculation remains in use. Physical
coefficient tables compete by observed route use within per-layer shares of
the existing 128 MiB cap. Larger K-format batches reuse bounded byte staging.
See [joint product qualification](inkling2-integer-pair-eight-evidence.json).
K-format products also tile eight vectors, stream batches through eight and
read cached coefficients directly. A two-vector Q8_0/Q5_0 product with at most
4096 output rows shares activations across four rows. Expert down products can
write distinct destination slots without an intermediate copy. Q4T query
rotations batch four rows with the same binary64 butterfly order, and packed
attention shares key/value decoding across four queries before its pair and
single tails. Q4T storage remains unchanged.
Vulkan uses the existing engine and native quantized weights for reference
integer products; activation packing uses the existing Ada reference packer.
The supported formats are Q4_K,Q5_K,Q6_K,Q8_0 and Q5_0, with host-fed batches
up to 128 and integer-dot capability. Independent groups now pack each input into its own region of the existing
4 MiB rounding buffer, including separate input slices and mixed supported
quantizations. Unsupported chained or mixed reference/non-reference groups,
interleaved weights and a final partial weight word are refused. The private
4 GiB device profile passes independent checkpoint and full Q4T lifecycle
checks. The earlier shared-host integer Q4T timeout remains unqualified. See the
[previous qualification](inkling2-quantized-next-eight-evidence.json) and
[latest evaluation](inkling2-quantized-followup-eight-evidence.json).
Expert runs of eight or more vectors can read selected packed inputs directly,
without copying their bytes, scales and sums. Smaller runs keep the previous
gather path. Indexed source strides must align to whole quantization blocks,
including a single selected vector. Scheduling estimates eight-vector work,
and native streaming
kernels avoid unused staging arrays. Single-query Q4T value updates can use
AVX-512 independent channels on the existing hardware capability gate. Scalar
convolution checks finite results while producing them. Q4T storage and
reference accumulation order are unchanged.



`Model_Runner.Inference` is the supported in-process Ada boundary for one
local, schema-constrained completion without the command-line presentation or
model-selection layers. It owns the GGUF files, parsed container, prepared
model, worker pool, generation context and, when requested, the device. A
session can be reused sequentially. The status-bearing `Close` releases every
owned resource, reports the first cleanup failure, and joins worker tasks before
their storage is reclaimed. The parameterless overload raises on an operational
cleanup failure. Controlled finalization remains non-raising and best effort.

Embeddings import the named `model_runner_inference.gpr` project from the Alire
dependency solution. The underlying `inference/model_runner_inference.gpr` has
no main unit and does not pull CLI presentation into the embedding's source
closure. Inference and the task framework import one neutral core project; a
consumer may import both without assigning the shared Ada units to two project
views. Their source ownership comes from `build/model_runner_sources.gpr`, the
single list used by all three projects.

The neutral core has its own compiler profile because independently consumable
projects cannot impose conflicting switches on one imported project. It defaults
to `release`; development and validation builds can select
`-XMODEL_RUNNER_CORE_PROFILE=development` or `validation`. Each profile has a
separate object directory. The root `model_runner_test_support.gpr` exposes only
deterministic `Fixtures` and `Tiny_Model` units for downstream integration tests;
it is not a production project file.

`Open` accepts the backbone path and bounded `Open_Options`. The options expose
the runtime facilities that affect loading: explicit auxiliary GGUF files (for
separately distributed PLE/engram tensors), repacking and its panel cache,
context and cache layout, model/session limits, worker counts, cooperative
cancellation, and the device's index, memory budget, host-sharing policy and
patience. A progress observer can receive the same semantic preparation events
as the command-line application. Device sessions are exclusive because the
underlying runtime owns one global device queue: while one public session owns
that queue, the backend refuses every other `Open` request. Conversely, a
public session is refused while a direct backend user owns the queue. The
session holds an opaque lease, so an unrelated or stale closer cannot release
its acquisition. The low-level backend operations still require the package's
documented single-task discipline; they are engine internals, not an isolation
boundary for mutually untrusted code in one process. Closing the owner releases
the queue for a later session. Loading never resolves aliases or downloads a
model.

CPU sessions can load separate runtime LoRA adapters through `Open_Options.Runtime_Adapters` and
`Runtime_Adapter_Count`. The bounded list holds at most eight `Adapter_Option` records, each with an exact
local `Path` and finite `Scale`. Leading entries load in order; zero and negative scales are accepted.
`Adapter_Bounds` can tighten the native limits on total files, pairs, rank and owned decoded bytes. The
model's parsing limits, load observer and cancellation token also apply to adapter loading. Unused list
entries are ignored. With a zero count, existing loading behavior is unchanged.

```ada
declare
   Opening : I.Open_Options := (others => <>);
begin
   Opening.Runtime_Adapter_Count := 1;
   Opening.Runtime_Adapters (1) :=
     (Path => Model_Runner.Text.To_Bounded ("/models/adapter.gguf"), Scale => 0.5);
   I.Open (Session, "/models/base.gguf", Opening, Status);
end;
```

Attachments use the CPU runtime path without expanding or merging the base. Dense Llama, Qwen2, Qwen3,
Qwen35 and Granite main-layer projections follow the native attachment support boundary. An adapter request with a
non-CPU backend, invalid scale/path or invalid file-count bounds is refused before device acquisition or
model IO. Architecture, descriptor, tensor and memory checks occur during loading. The API does not select
F32 merging or silently fall back from a requested backend. Sources close after their matrices are owned;
completion no longer reads the adapter files. All attachments load before opening the generation context
or allocating its worker pool. A failed later attachment closes the entire new session, preserving the
primary diagnostic. As with every `Open`, the session's previous resources are closed first.

`Prepare` converts a JSON Schema to a reusable grammar. The overload of
`Complete` taking `Prepared_Schema` avoids compiling an invariant response
contract for every request; the string overload remains available for one-off
calls. `Complete` resets the context by default and runs synchronously on the calling task.
Its options bound tokens and returned bytes and carry an absolute deadline,
sampling configuration, progress observer, and cooperative cancellation token.
`Fill_Context` permits a response to use whatever context remains after the
prompt when its byte bound is not a useful token reservation; `Maximum_Tokens`
still caps generation. The result distinguishes complete output, incomplete token/context stops,
cancellation, timeout, bounded-output closure, and typed schema or engine
failure. `Completion_Ready` therefore means the engine reached a complete stop;
the embedding must still parse and validate the returned JSON value.

For sequential tool turns, opt in with `Reuse_Prompt_Prefix (Session)`. Continue
to provide the complete rendered prompt; the existing generation engine validates
its token prefix against committed session state. `Reused_Prompt_Tokens (Session)`
reports the count retained by the last completion, and resets on Close, a policy
change, or the next failed completion before generation. Disable reuse with
`Reuse_Prompt_Prefix (Session, False)` to restore fresh-context calls.

For Inkling, appending to the complete committed token sequence takes the direct
extension path. An edited or repeated prompt can require prefix replay to rebuild
convolution history, so retained-token counts alone do not establish a latency
saving. The command-line and harness generation interfaces already expose prefix
reuse; these procedures make that existing facility available to embedded callers.

`Provenance` returns the canonical backbone path, declared model name,
architecture, engine fingerprint, byte total, and part count. `SHA256` is an
explicit potentially expensive operation over the exact joined model bytes;
`Open` never hashes the model implicitly. Hashing accepts cooperative
cancellation and reports `Hashing_Model` byte progress through the normal load
observer.

For attached models, `Provenance.Runtime_Adapter_Count` and `Runtime_Adapter_Bytes` report attachment count
and decoded matrix/descriptor storage. Adapter bytes exclude session scratch; they are not total process memory.
The fingerprint binds adapter contents, application order, scales and runtime arithmetic identity.
The existing `Bytes`, `Parts` and explicit `SHA256` continue to describe backbone and auxiliary files;
they do not become a combined adapter-file size or digest. Closed sessions return empty provenance.

```ada
with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Model_Runner.Errors;
with Model_Runner.Inference;

procedure Ask_Local_Model is
   package I renames Model_Runner.Inference;
   Session : I.Session;
   Status  : Model_Runner.Errors.Error_Info;
   Answer  : I.Completion;
   Schema  : I.Prepared_Schema;
begin
   I.Prepare (Schema, "{""type"":""integer""}", Status);
   if Model_Runner.Errors.Is_Error (Status) then
      return;
   end if;

   I.Open (Session, "/models/model.gguf", Status => Status);
   if Model_Runner.Errors.Is_Error (Status) then
      return;
   end if;

   I.Complete
     (Session, "Return a priority from one to three.",
      Schema,
      (Maximum_Tokens => 8, Maximum_Output_Bytes => 32, others => <>),
      Answer);
   if Answer.State = I.Completion_Ready then
      Ada.Text_IO.Put_Line (Ada.Strings.Unbounded.To_String (Answer.Text));
   end if;
end Ask_Local_Model;
```

The session is single-owner: do not call `Open`, `Complete`, or `Close`
concurrently and do not asynchronously abort the task while the engine owns
resources. Cancellation is the supported way to stop work. See
[Library API lifecycle](api-lifecycle.md) for the compatibility policy.

The [projection and packing evaluation](inkling2-projection-eight-evidence.json)
qualifies shared CPU activation packing and bounded row ranges in
`Backend.CPU.Multiply_Packed_Whole`. Untouched output rows remain unchanged.
`Platform.Device.Products.Takes_Reference_Integers` accepts an optional
`Device_Packing` flag to require device reference packing as well as native
integer products. Unsupported devices retain the existing host reference packer.
This capability does not imply resident integer SiTU/MoE chain support.


Native Inkling's explicit integer profile permits Q4T Vulkan prefill batches
through 128 positions and grouped integer decode projections. With the
existing explicit expert-cache reserve, a fully resident selected expert set
can execute a reference-equivalent SiTU/MoE chain, reusing the existing native
runtime and physical allocations. Partial selected-set residency uses the
existing CPU expert path; the default F32 profile is unchanged. See
[qualification and measurements](inkling2-batch-chain-eight-evidence.json).


The integer/Q4T follow-up retains Q4_K_M weights and bounds gate/up/down metadata within the existing 128 MiB budget. Resident expert batches gather tokens per physical expert and return to the existing ordered host reduction. Native integer attention epilogues chain exact sigmoid gating, output projection, convolution and residual addition under the existing adapter, observer and device-capability guards. See [current evidence](inkling2-super-eight-evidence.json).


`Llama.Evaluate_Greedy` retains full logits and optionally returns the deterministic lowest-ID maximum, excluding one token. Use its winner only when no other token masks, penalties or biases apply. The ordinary generation path guards this optimization; constrained sampling and lookup drafting keep their existing protocols. CPU pool indexed jobs may run independent caller-side work while workers execute, then settle before returning errors. Native resident experts may share a submission and overlap nonresident CPU work. Recorded packed Q4T attention can feed its native epilogue directly. Existing session ownership and adapter/observer guards apply. See [dispatch evidence](inkling2-dispatch-eight-evidence.json).


`Backend.Device.Add_Packed_Attention` records unkept packed attention into the existing opaque sequence. Architecture adapters use this backend builder without importing the platform layer. The forwarded storage, masking, relative metadata and query offsets are unchanged.


`Llama.Evaluate_Greedy_Batch` retains complete logit rows in `Every`, returns final logits and one deterministic lowest-ID maximum per token, excluding an optional token. Its eligibility and shape checks run before evaluation. Errors leave all winners invalid. Callers may use those winners only when no other sampling masks, penalties or biases apply; generation guards this optimization and retains ordinary sampling otherwise. Existing expert-cache statistics expose work-plan hits/misses, metadata bytes/largest layer and batched device aggregation counts. `Backend.Device.Reference_Packing_Reuses` reports compatible adjacent native input-packing reuse. These counters do not change model/session ownership. See [work-plan evidence](inkling2-plans-eight-evidence.json).


The native CPU DSpark adapter adds `Llama.Prepare(Target => ...)`, `Evaluate_Features`, `Draft_Feature_Layers`, `Draft_Feature_Room`, `Inject_Draft_Context` and `Propose_Draft_Block`. The prepared target owns shared embedding/output weights and must outlive its drafter. Feature capture preserves normal batching; only accepted verifier rows become draft context. Initial support is greedy CPU text drafting with at most seven proposals, a Q4T target cache and an independently budgeted exact auxiliary draft cache. Unsupported variants, sampled drafting and standalone drafter snapshots are rejected. The existing generation and `Model_Runner.Inference` interfaces remain compatible. See the [adapter contract](inkling2-dspark-native.md) and [evidence](inkling2-dspark-native-evidence.json).


Greedy native DSpark verification can use `Llama.Evaluate_Feature_Winners` to retain the same target feature taps while returning per-token winners and the final complete logit row for up to eight inputs. `Verification_Logits` projects one retained normalized row when a rejected proposal needs an earlier accepted distribution; callers must consume it before rewind, reset or another evaluation. Sampling, output observers and unsupported compact configurations keep the existing full-logit path. The workspace is session-owned, budgeted and released on close. See [qualification and measured tradeoffs](inkling2-gsq-four-evidence.json).
