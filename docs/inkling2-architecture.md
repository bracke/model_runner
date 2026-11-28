# Inkling 2 Mini architecture audit

Status: fixed-loop text execution is implemented in the existing native engine,
2026-11-24. CPU and Vulkan Q4_K_M conformance cover the complete execution graph.
The scheduler shares 24 physical weight sets across 48 logical applications.
See [verification](inkling2-verification.md) for precision profiles, lifecycle
coverage and outstanding release gates. Variable-loop checkpoints and vision
remain explicitly unsupported.

## Sources and authority

- [Official model configuration](https://huggingface.co/thinkingmachines/Inkling-2-Mini/blob/main/config.json),
  captured in `tests/fixtures/inkling2/config.json` with a content hash.
- [llama.cpp loop implementation][llama-loop]
  and its `inkling2.cpp` base implementation. The inspected Git blob IDs are
  `8366a1191f253c0d6e5cc1c611979eca33e462dc` and `45477a69e35e13bfe638aa3617486edea26fb78d`.
- [Independent Transformers implementation][transformers],
  inspected Git blob `78498834e2806e83a1bb96eea5cf5447d9b1531f`.
- [Official design and research discussion](https://thinkingmachines.ai/news/inkling-2-mini/).

[llama-loop]: https://github.com/ggml-org/llama.cpp/tree/690b87d88151dbd775bb6eff5581663688785928/src/models
[transformers]: https://github.com/huggingface/transformers/commit/046bdb8cc2cee29d233964bb77fe6fd37cfe4aa3

The loop source path is `src/models/inkling2-loop.cpp`; the independent path
is `src/transformers/models/inkling2_loop/modeling_inkling2_loop.py` at the linked revisions.

The source implementations agree on the schedule, cache offsets, prelude
restart, four message channels, relative-position attention, convolutions
and MoE operations below. Source agreement is not checkpoint conformance.
Precision boundaries are recorded in the independent fixtures. Native routing breaks exact ties by lowest expert ID;
reference ID comparisons require stable ranks.

Tied expert IDs have no shared ordering guarantee in the inspected sources:
Transformers uses `torch.topk(..., sorted=False)`, while b12600's CPU
`cmp_argsort` compares scores only and its Vulkan shader uses a bitonic
score comparison. Neither defines an expert-ID tie breaker. Pin runtime,
compiler and backend for tie recordings; a deterministic native tie policy
must be explicit. Exact ID conformance applies to numerically stable ranks;
an ambiguous tie must be investigated separately rather than hidden behind
a larger activation tolerance.

## Physical layers, execution positions and state

The fixed checkpoint stores 24 layers, hidden width 2304, and repeats the
half-open region `[6,18)` three times. Its attention-residual blocks contain
six physical layers. The execution order is:

```text
0..5, 6..17, 6..17, 6..17, 18..23
```

There are 48 execution positions, 24 physical weight owners and 48 state
owners. These are separate identities. First visits and epilogue use state
slots matching their physical layers; later visits append slots after 24.
For visit `v > 1` to physical layer `p`, the state slot is
`24 + (v - 2) * 12 + p - 6`. Epilogue layer 18 executes at logical position
42 but uses state slot 18. This numbering matches both inspected runtimes.

`Model_Runner.Llama.Execution_Schedules` builds bounded orders and refuses
invalid regions or excessive logical counts before multiplication. It owns
no tensors, allocations, messages or activations. Its general region/count
interface does not authorize changing the fixed checkpoint's three visits.
The architecture adapter validates those checkpoint restrictions before execution.

The native adapter consumes this representation through the existing evaluator.
Session KV and convolution state use its logical state identities; tensor views
and expert residency retain physical ownership. Profiling identifies physical
layer, logical application, visit and token position. Ordinary models retain
their single-pass traversal.

## Depth attention and loop messages

Block attention residuals attend over completed block states and the current
partial stream. Each candidate is converted to F32 and RMS-normalized with
epsilon `1e-6`. A learned query scores the normalized candidates, scaled by
`1/sqrt(hidden_width)`; softmax weights their normalized values too. The
first physical layer has no attention-input residual query. Local attention
uses one query; global attention uses separate Q/K/V queries. FFN and final
output also have learned depth queries.

At a six-layer block boundary the incoming stream becomes a completed block
candidate; the attention output begins a new partial stream. Other layers
add the incoming stream to the attention output. The FFN input is obtained
through depth attention and its output is added to the partial stream.
Preserve the exact residual ordering rather than wrapping a normal Llama
layer in a repetition loop.

Each later pass restarts from the saved prelude output and prelude block
bank. Its messages use the previous pass's block states after the first
core block, together with that pass's final partial stream. There are four
learned message queries per physical core layer: Q, K, V and FFN. The first
pass consumes none. The previous pass's bank remains live until its last
consumer finishes.

For current input `x` and a message `m`, each controller computes:

```text
z      = W_down * concat(RMS(x), RMS(m))
gain   = tanh(W_gain * z)
forget = tanh(W_forget * z)
result = (1 - forget) * x + gain * m
```

The controller rank is 64. Gates are signed tanh values, not sigmoid gates.
Q/K/V inputs of a local layer differ after these controllers even though
they shared the original attention-input residual query. FFN control occurs
after its depth mix and before its learned input normalization.

## Attention and positional information

The decoder has **no RoPE**. Its MTP configuration contains a rotary base,
which must not be mistaken for a decoder parameter. Learned relative bias
and logarithmic scaling supply decoder position information.

Local layers are 0-4, 6-10, 12-16 and 18-22. Global layers are 5, 11, 17 and
23. Every visit inherits its physical layer's attention kind. Both kinds
have 24 query heads, eight KV heads and head width 128; the local window and
global relative-bias extent are both 1024. A global layer keeps full causal
attention even when its relative bias becomes zero beyond that extent.

Q is scaled per channel and L2-clipped; K is L2-clipped without that learned
scale. The Q/K threshold is `22.627416997969522`. V receives unweighted
per-head RMS normalization. Relative features have 16 components per head,
a learned scale and L2 threshold 8. Relative bias is zero outside
`0 <= query_position - key_position < extent`.

Global Q and relative features additionally receive
`1 + 0.1 * log(max(1, (position + 1) / 8192))`. This follows clipping.
Global layers have separate learned Q/K/V input RMS norms; local layers
share their learned norm, applying it separately after loop controllers.

Attention scores combine scaled QK products and relative bias under a
causal/window mask. A query-dependent sink is an extra logit with zero
value: it absorbs probability without contributing an output vector.
The head output is gated by a sigmoid projection of the query input before
the output projection and post-attention convolution.

## Short convolutions and session state

Four causal short convolutions run at every visit: K, V, attention output
and FFN output. Kernel size is four, requiring three historical inputs per
channel. Global K/V also have input-dependent taps per KV head. A static
convolution adds its input and scales by `1/sqrt(5)`; with dynamic taps it
scales by `1/sqrt(9)`. Lag orientation and dynamic tap layout need fixtures.

Each logical state owner needs independent KV and all four histories.
Resetting or truncating KV alone leaves an incorrect decoder. Rewind must
restore histories at the chosen prefix; cancellation must leave a coherent
commit boundary across visits. Local eviction must preserve the valid
window; global retention is not limited by relative-bias extent. Session
budgets must count both kinds, message banks and device allocations.

## MoE and output

Routing runs in F32 on every token and visit: project to 128 logits, apply
sigmoid, select eight using score plus correction bias, gather the original
unbiased scores, divide by their selected sum plus `1e-20`, then scale by 8.
Ties need a documented deterministic policy and reference qualification.

Experts use intermediate width 1152 and fused gate/up weights. Their
activation is `softcap(gate,4) * sigmoid(gate) * softcap(up,25)`, with
`softcap(x,c) = c*tanh(x/c)`. The sigmoid sees the raw gate. Expert outputs
accumulate in F32 before the reference-defined cast and post-FFN convolution.

Expert cache keys identify physical weights. They must include all associated
scale tensors through each visit. [Upstream scale-sharing repair](https://github.com/ggml-org/llama.cpp/pull/32704)
demonstrates why copying layer descriptors before scale attachment is unsafe.
Existing NVFP4 block decoding does not qualify original checkpoint scale/layout
conventions or MXFP8. Initial inference must target one inspected GGUF.

Text embeddings have a learned RMS norm. Raw image embeddings bypass it.
Final depth mixing precedes learned output RMS normalization, output
projection, logit softcap 30 and removal of padded vocabulary rows. Stored
vocabulary width is 201024; the unpadded vocabulary contains 200058 entries.

## State-size calculations

The 48 visits contain 40 local and eight global attention instances. Each
token/instance has 1024 key and 1024 value elements. With element width `b`
bytes, independently retained KV payload is therefore
`2048*b*(40*min(context,1024) + 8*context)` bytes if local windows are bounded
and no otherwise-invalid positions are retained. At context 32768 this is
1241513984 bytes for F16; storing a full context in all 48 slots instead
would take 6442450944 bytes. These are payload calculations, excluding
alignment, cache bookkeeping, rollback and backend workspaces; they are not
measured allocations or evidence that the native cache implements them.

Three past inputs for K, V, attention-output and FFN-output convolutions
require `48*3*(1024+1024+2304+2304)` elements, or 3833856 bytes at F32,
before rollback snapshots or padding. Physical weight ownership remains
24 layers in either calculation. Cross-loop banks and prefill workspaces
need separate lifetime analysis; no allocation budget is inferred from
these formulas alone.

## Remaining audit gates

The Q4_K_M artifact and converter/checkpoint provenance are pinned, its payload
and descriptor inventory are verified, and independent mathematical and full
checkpoint fixtures pass for the documented F32 activation profiles. Reference
CPU baselines are measured. Full release, native performance and autonomous
workflow acceptance still require the evidence tracked in verification.
The original byte-activation profile remains unqualified; exact ties follow
the explicit native policy above.
See [reference qualification](inkling2-reference.md),
[metadata inventory](inkling2-model-metadata.md) and [native tasks](inkling2-tasks.md).

The separate `TML-d24-varloop-research` checkpoint needs its own control and
allowed-count audit. Vision and MTP weights do not imply validated native
vision or speculative decoding. Neither extension is required to qualify
the fixed-loop text milestone.

## Native batched prefill

The common Inkling evaluator now accepts one or several embedding rows. Its
outer loop follows the same 48 logical visits. Projection products and the
qualified CPU expert paths operate on batches; convolutions and causal cache
updates advance in token order within each visit. Physical weights and expert
cache keys remain attached to the 24 stored layers.

Each token retains its own prelude, completed residual blocks and cross-loop
message banks. Default prefill computes the output head only for the last
row. Callers requesting every distribution or an observer receive every row.
The CPU integer profile now uses the existing expert batch scheduler with
reference activation packing, scale precision, routing and SiTU stages.
Observed and grouped execution match exactly on both independent checkpoint
cases. The recorded AVX-512 host also passes independent checkpoint comparisons
with compressed interleaved weights. The optional Vulkan reference integer
path also matches both captured checkpoints and all five native operator
formats exactly; it has no completed long-prompt throughput result. See
[latest evidence](inkling2-quantized-next-eight-evidence.json).
Q4T attention can share decoded keys and values across four queries, with
pair and single-query tails. Score storage reserves four query rows per head;
the session memory plan includes the additional rows.

The temporary arena has `N * (30H + 3QD + 2KVD + QR + Q + 2KVT + rank + 20)
+ R * max(window, relative_extent)`
F32 elements for N tokens, where H is hidden width, Q/KV are head counts, D is
head width, R is relative width and T is convolution length. At the supported
checkpoint dimensions, batch 128 uses 41,506,816 bytes for this arena. This
excludes embeddings, existing expert workspaces, optional per-token output
heads and session cache; it is a layout calculation, not a peak-memory claim.

Attention uses the existing CPU worker pool to share independent heads, with
the existing inline threshold for small jobs. Each head uses its session-owned
score row and private reduction scratch. The visit's batch KV rows are published
before one worker dispatch. Each head processes tokens in order and each query
reads only its own causal window. All heads finish before the next operation.
Each head keeps the original score, softmax and value accumulation order.
Heads sharing a KV group form one work item when the team size fits; other
team sizes keep individual heads. Relative-bias rows
are decoded once per logical visit, for reachable distances only, and shared
read-only across its heads and tokens. The added distance table is 64 KiB at
the supported checkpoint dimensions; it is temporary workspace.
The [single-run scheduler comparison](inkling2-batch-attention-speed-evidence.json)
passes the reference checks but establishes no meaningful throughput gain.

Convolution walks each channel across the batch in token order. Its fixed
taps are decoded once per channel and reused for those tokens; dynamic taps
still come from each token's own projection and KV head. Channels have
independent histories, so this ordering preserves every channel's original
arithmetic and causal updates. Scalar decoding uses the same implementation.
Tap reuse requires no extra persistent storage.

Head clipping also decodes each head's learned weights once per batch and
reuses them across tokens. Each token retains the original weighted-square
sum, normalization conversions and clipping factor. Unweighted key clipping
uses the same path with unit weights.
The [focused verification](inkling2-clip-speed-evidence.json) records passing
reference checks and one fixed-work timing. That timing establishes no
meaningful speedup over the preceding convolution implementation.

The shared CPU dot product uses four SIMD binary64 lanes when the existing
wide-vector capability check permits it. F32 values are widened before separate
multiply and add instructions; span boundaries, scalar tails and final lane
folding preserve the original reduction exactly. Other hosts retain the
portable implementation. Quantized checkpoint storage is unchanged. Exact
portable/SIMD comparisons cover fifteen formats and varied input exponents.
The [single measured comparison](inkling2-wide-dot-speed-evidence.json) records
512-token CPU prefill at 79.967 seconds versus 107.022 seconds before this change,
and sixteen-token decoding at 7.884 versus 9.126 seconds, with identical output.
These are individual samples, without repeated-run confidence.

Batched dot products now compute four vectors together, reusing each weight
load and conversion. Each vector retains its original four binary64 sums;
scalar tails and final folding are unchanged. Leftover vectors use the
previous SIMD kernel, and unsupported hosts keep the portable path. Exact
comparisons cover every batch size from one through thirteen, including
multiple groups and partial groups. The [single measured comparison](inkling2-four-dot-speed-evidence.json)
records 512-token CPU prefill at 48.150 seconds versus 79.967 seconds previously,
with identical output. Sixteen-token decode remains essentially unchanged
at 7.886 versus 7.884 seconds. These are individual samples.

Attention value accumulation advances four independent channels together on
SIMD-capable CPUs, keeping each channel's chronological binary64 sum and
separate multiply/add operations. Exact-cache rows are read directly; F16
cache conversion is unchanged. Scalar remainders and the portable fallback
retain the same arithmetic. All 2,425 captured native activation files match
the preceding executable byte-for-byte. The [single measured comparison](inkling2-attention-values-speed-evidence.json)
records sixteen-token decode at 7.531 seconds versus 7.886 seconds previously.
Prefill at 47.785 versus 48.150 seconds establishes no meaningful improvement.
These observations do not establish repeated-run confidence.

Exact-cache attention scoring now computes four positions together when the
existing CPU capability permits it. Each SIMD lane represents one position;
its channels retain the original F32 multiplication and addition order.
Relative bias, scaling, maxima and softmax remain in chronological order.
Each cache position is resolved separately, preserving circular-cache wraps.
Short remainders and F16 key caches retain the scalar calculation. No cache
transpose or persistent buffer is added. All 2,425 captured activation files
match the preceding executable exactly. The [single measured comparison](inkling2-attention-scores-speed-evidence.json)
records 512-token prefill at 46.126 versus 47.785 seconds. Decode at 7.466
versus 7.531 seconds establishes no meaningful improvement; these are
individual samples without repeated-run confidence.

Eight-vector groups extend weight reuse for larger CPU batches. Each vector
keeps its original four binary64 sums, span boundaries, scalar tail and final
fold; remaining vectors use the existing four-vector and scalar paths. Exact
comparisons cover every batch size from one through seventeen across fifteen
formats. Temporary lane scratch grows from sixteen to thirty-two doubles,
with no persistent allocation or weight duplication. The [single measured comparison](inkling2-eight-dot-speed-evidence.json)
records 512-token prefill at 44.657 versus 46.126 seconds. Decode at 7.385
versus 7.466 seconds establishes no meaningful improvement. These are
individual samples without repeated-run confidence.

Completed residual blocks are normalized once when saved in the existing
block buffers. Loop-message banks retain those normalized blocks, and each
previous-loop partial stream is normalized once when its bank is formed.
Depth mixing copies these reusable candidates while continuing to normalize
each changing current stream. For the canonical schedule, depth-mixing RMS
operations fall from 380 to 106 per token; this excludes other normalizations.
Workspace size, candidate order, epsilon and scalar arithmetic are unchanged.
The [normalization-only check](inkling2-residual-norm-speed-evidence.json)
passes exact comparisons but establishes no meaningful standalone speedup.

Controller gains, forget gates and channel blends now use the existing CPU
worker pool. Every channel retains its scalar tanh, conversion and blending
order. Shards may cross token boundaries; the dispatch joins all workers
before continuation and retains inline execution for small jobs. All 2,425
captured activation files match exactly. The [combined comparison](inkling2-control-pool-speed-evidence.json)
records prefill at 43.110 seconds versus 44.657 seconds at task start, and
decode at 7.241 versus 7.385 seconds. These are individual samples without
repeated-run confidence.

Native CPU Q4_K batches also pair adjacent weight rows, sharing each widened
activation across both rows for groups of four vectors. The existing decoder
fills bounded 2048-element spans; each output retains its original four
binary64 partial sums and span folding. Odd rows, vector remainders, partial
row ranges and independent row refusals retain their existing behavior.
Single-token decoding, interleaved weights and other tensor formats use the
previous paths. No persistent cache or weight duplication is added. The
[exact comparisons and one timing](inkling2-q4-row-pair-speed-evidence.json)
record 512-token prefill at 41.339 versus 43.110 seconds and decode at 7.277
versus 7.241 seconds. Decode is essentially unchanged; the individual samples
do not establish repeated-run confidence. All 2,425 activation files match.

The paired-row path now extends to Q5_K, Q6_K, Q5_0 and Q8_0 alongside
Q4_K. Existing GGUF block metadata determines span sizes and byte offsets,
so the same exact kernel also handles the checkpoint's 1152-column
expert-down tensors and Q8 projections. The expanded test covers all five
formats; single-token and interleaved paths remain unchanged. The
[single measured comparison](inkling2-quant-row-pair-speed-evidence.json)
records prefill at 37.858 versus 41.339 seconds, and total inference wall
time at 45.473 versus 48.617 seconds. Decode was slower in that sample,
at 7.615 versus 7.277 seconds; one sample does not establish the cause or
repeated-run confidence. All 2,425 captured activation files match exactly.

Quantized row pairs can now process six activation vectors together, using
twelve SIMD accumulators to share each weight conversion across six vectors.
The four-vector kernel and scalar remainder remain available, with the same
per-output reduction order and span boundaries. Single-token execution and
weight storage are unchanged. Expanded exact tests cover batch counts through
129. The [one measured comparison](inkling2-six-row-pair-speed-evidence.json)
records prefill at 37.108 versus 37.858 seconds, decode at
7.179 versus 7.615 seconds, and inference wall time at
44.288 versus 45.473 seconds. These are individual samples;
all 2,425 checkpoint captures and the existing reference profiles pass.
Floating-point row pairs and a sixteen-row activation cache were also measured;
neither is retained. Their measurements are preserved in the same evidence.

The paired kernels now fuse each widened binary32 product with its binary64
addition. This preserves exact finite results: the product needs at most 48
significand bits, fits the binary64 exponent range, and therefore incurs no
rounding before either version's addition. The four-lane and span folds stay
separate. The existing x86-64-v3 guard already requires FMA. This reasoning
applies to widened binary32 operands, not arbitrary binary64 multiplication;
other kernels and the compiler's contraction policy remain unchanged.

A new scalar-reference test covers maximum finite inputs, subnormals,
cancellation and signed zeros across both paired kernels and span boundaries.
All 96 focused tests and reference profiles pass, and all 2,425 checkpoint
captures match exactly. The [single measured comparison](inkling2-exact-fma-speed-evidence.json)
records prefill at 30.508 versus 37.108 seconds, decode at
7.575 versus 7.179 seconds, and inference wall time at
38.084 versus 44.288 seconds. These individual samples do not
establish repeated-run confidence. Single-token dot arithmetic is unchanged.
The same evidence preserves a measured tail-dispatch experiment that was
reverted before this candidate.

Quantized batches can also process three weight rows together for groups
of four vectors. Twelve output accumulators, three widened weights and one
widened activation fit in the sixteen vector registers. Each activation
conversion feeds three rows; seven conversions serve twelve four-lane outputs,
compared with eight in the paired six-vector kernel. The decoded workspace is
24 KiB, with at most 3 KiB of totals and 384 bytes of lane results. The path is
limited to batch counts through 128 with remainder zero or one modulo four;
other counts and leftover rows use the existing pair and single-row paths.

Expanded bitwise tests cover up to eight rows, partial ranges, counts through
129 and scalar-reference extreme inputs at two, three and five rows. All 96
focused tests and reference profiles pass; all 2,425 checkpoint captures match.
The [one measured comparison](inkling2-three-row-speed-evidence.json) records
prefill at 29.879 versus 30.508 seconds, decode at
7.826 versus 7.575 seconds, and inference wall time at
37.706 versus 38.084 seconds. These individual samples do not
establish repeated-run confidence. Single-token arithmetic is unchanged.

Single-token quantized execution now groups eight weight rows. Each four
activation values are widened once for eight independent output accumulators,
so the processor can advance independent rows while preserving each output's
four-lane order and 2048-element span folds. The existing decoder fills a fixed
64-KiB workspace; lane results and totals occupy another 320 bytes. The compiler
reports a bounded 66,080-byte frame. The existing x86-64-v3/FMA guard and five
quantized formats apply; leftover rows, interleaved weights and other formats
retain their existing paths. Batch dispatch is unchanged.

Expanded exact cases cover eight-row boundaries, multiple groups, leftover
rows, nonzero range starts and batch fallback. Scalar-reference extreme-input
cases now also exercise single-vector execution at eight, nine, sixteen and
seventeen rows. All 96 focused tests and reference profiles pass, and all 2,425
checkpoint captures match exactly. The
[one measured comparison](inkling2-eight-row-decode-speed-evidence.json) records
prefill at 29.712 versus 29.879 seconds, decode at
6.412 versus 7.826 seconds, and inference wall time at
36.126 versus 37.706 seconds. These individual samples do not
establish repeated-run confidence.

The eight-row single-vector kernel now also handles F32, F16 and BF16
weights when the width is a multiple of four. F32 rows are read directly from
validated little-endian mapped bytes, with their original row stride and no
workspace copy. The byte-range check includes the last of all eight rows, and
unaligned offsets are supported by the guarded x86 loads. F16 and BF16 reuse
the existing decoder and workspace. Odd widths, leftover rows and floating
batch execution retain their earlier paths. The checkpoint remains Q4_K_M;
its existing floating-point tensors benefit without changing model precision.

Exact tests now cover eight formats, widths through 4608 and odd-width
fallback, plus scalar-reference extremes in all three floating formats. All 96
focused tests and reference profiles pass; all 2,425 checkpoint captures match.
The [one measured comparison](inkling2-float-decode-speed-evidence.json) records
prefill at 29.691 versus 29.712 seconds, decode at
6.169 versus 6.412 seconds, and inference wall time at
35.860 versus 36.126 seconds. These individual samples do not
establish repeated-run confidence.

Q8_0 spans now unpack signed bytes with AVX2 and convert block scales with
F16C inside one native loop. Each block still produces 32 binary32 values
from its 34 packed bytes; accumulation and reduction order are unchanged.
The existing x86-64-v3 guard already requires both features. The scalar
fallback and all byte-range, target-size and count checks remain in place.
Every vector byte load is exactly eight bytes, including at the last block.
No additional workspace or persistent cache is introduced.

An exhaustive AUnit comparison covers all 65,536 half-scale encodings and
all 256 signed-byte values (16,777,216 combinations). Finite outputs, signed
zeros and infinities match exactly; NaN classification matches. It also checks
unaligned source data, shifted array bounds, the exact final source boundary
and untouched target storage. All 97 focused tests and reference profiles pass;
all 2,425 checkpoint captures match exactly. The
[one measured comparison](inkling2-q8-unpack-speed-evidence.json) records
prefill at 29.154 versus 29.691 seconds, decode at
5.403 versus 6.169 seconds, and inference wall time at
34.559 versus 35.860 seconds. These individual samples do not
establish repeated-run confidence. The same Q4_K_M checkpoint is used; its
existing Q8_0 tensors benefit without changing stored precision.

Q4_K now uses an explicit eight-lane nibble kernel in the existing wide
generic decoder instance. The scalar instance remains unchanged, and both
paths share scale extraction and sub-block parameters. The existing CPU guard
selects the wide instance. Each eight-byte read supplies low and high nibbles
for the original two sub-blocks, with no read past the packed group.

For finite half scales, multiplying by a six-bit factor and a four-bit nibble
needs at most 21 significand bits and fits binary32's exponent range. That
product is exact, so a fused subtraction rounds the same final operation as
the scalar path. This is specific to Q4_K; compiler contraction remains off
and other formats' arithmetic is unchanged.

Scalar comparisons sweep every half encoding as scale and minimum, exercise
all six-bit factor/minimum pairs at every sub-block position, and compare
37,748,736 decoded values across the additional sweeps. Finite results,
signed zeros and infinities are bit-exact; NaN classification matches.
Independent layout goldens and existing refusal checks also pass. All 98
focused tests and reference profiles pass; all 2,425 checkpoint captures match.
The [one measured comparison](inkling2-q4-unpack-speed-evidence.json) records
prefill at 28.752 versus 29.154 seconds, decode at
5.401 versus 5.403 seconds, and inference wall time at
34.154 versus 34.559 seconds. These individual samples do not
establish repeated-run confidence.

On failure, convolution history and the previously committed normalized state
are restored. The caller commits token history only after the complete batch
succeeds. Rewind reconstructs the retained prefix through bounded calls to this
same native batch path. Tests cover exact scalar/batch outputs, nonzero array
bounds, partitioned prefixes, cancellation, independent long-prefix state and
rewind after local-cache eviction. Measurement conditions are recorded in the
[batched prefill protocol](inkling2-batched-prefill-protocol.md).

## Reusable native execution state

The session retains its evaluation arena and optional per-position logit buffer,
growing them only when a larger batch needs more capacity. Each call uses only
its active slices. Physical-layer scalar tables are decoded lazily into bounded
session-owned storage: normalization/clip weights, convolution taps and the
relative-bias rows reachable within the context. Repeated logical visits share
these immutable decoded tables. Reset retains allocations; Close releases them.
The session memory estimate includes these tables and one rewind checkpoint.

A checkpoint records convolution history and the final activation, normalization
and logits before the latest evaluation call. A rewind at or after that boundary
restores it and evaluates only the retained suffix when the sliding KV origins
still cover the boundary's attention window. Otherwise the existing full native
replay runs. Reset and context adoption invalidate the checkpoint; a newly
adopted context must first produce a complete final row before a checkpoint is
usable. Checkpoints and tensor caches are transient and are not serialized.

Three-tap convolutions use four independent SIMD channels on supported hosts,
preserving the binary32 tap accumulation order. Other shapes retain scalar
execution. Residual mixing projects saved normalized blocks directly and keeps
the reference reverse-block order when applying scores and summing candidates.

On Vulkan, a control sequence keeps the down projection on the device while
both gain and forget projections consume it, returning only their outputs.
Observed execution retains its individual product notifications. Independent
single-token attention projections use an existing apart-input group. Prefill
control outputs use grouped CPU jobs or Vulkan sequences; CPU groups keep the
ordinary batched tensor kernels and the existing activation arithmetic policy.

The eight-output Q4_K CPU path stages only scale/minimum parameters. Packed
nibbles are decoded in registers, rounded as binary32 weights, and accumulated
in the same four binary64 lanes and span order as the unfused path. The runtime
feature guard, scalar fallback and original GGUF weight storage remain in use.

Validation and measured limits are recorded in
[the eight-candidate evidence](inkling2-eight-candidates-evidence.json).

## Further native execution refinements

Two- and three-token products now share decoded weight rows across activation
vectors. Eight-output Q5_K and Q6_K products stage only compact scales and decode
weights in registers, retaining each binary32 dequantization stage and the
original binary64 accumulation order. The existing feature guards and fallbacks
apply. Eight-lane integer exponent checks classify non-finite activations without
floating comparison, including signalling NaNs; scalar tails remain checked.

Unweighted RMS uses a dedicated overload with the exact unit-weight numerical
contract. Reused evaluation scratch is no longer cleared wholesale. Accumulators
still initialize explicitly, and saved-block visit guards prevent reads before
production. Tests poison retained scratch before smaller partitioned calls.
The call-boundary convolution backup serves both cancellation rollback and the
rewind checkpoint, eliminating a duplicate copy and allocation. Their validity
guards and the original full-replay fallback remain in force. Single-token
attention can group query heads sharing a KV head under the existing compatible
worker-count and shape conditions; per-head numerical order is unchanged.

For one-token F32 device execution, an existing backend sequence can project the
raw attention gate, apply the CPU-compatible logistic polynomial, multiply the
attention result and project the output. The raw gate returns for the required
finite check; observers receive the actual weighted activation. Unsupported
sequence shapes use the existing path. Production architecture code accesses
this through the backend interface. A positive device test requires the sequence
to execute and verifies observed and unobserved results. This does not establish
a fully device-resident decoder. Verification and individual sample limitations
are retained in [the next-eight evidence](inkling2-next-eight-evidence.json).

## Further fused execution and rewind state

Two-through-six-token Q4_K/Q5_K/Q6_K products consume packed weights without
staging F32 rows. Their original binary32 weight stages, binary64 lanes and
span folds remain; larger batches keep the existing kernels. Inkling MoE jobs
retain four buffers per exclusive invocation slot in the session, grow as
needed and free on Close. Memory planning reserves the bounded worst case.
Other architectures keep the prior temporary-buffer lifetime.

Learned binary32 RMS operates in place. Residual mixing uses eight independent
channels with the original multiply/add and candidate ordering. Three attention
heads can share key tiles and converted value rows. Their sums retain the
original order, and existing score storage holds intermediate dots and
probabilities. No context-sized automatic array is introduced.

Vulkan attention gate sequences now support batches. One-token final RMS and
vocabulary projection can also share a sequence, returning the actual normalized
row for session state and observers under the existing GPU normalization policy
and unchanged tolerances. Convolution and loop-control pointwise operations
remain on their existing paths; a fully GPU-resident decoder is not claimed.

Four additional successful call-boundary checkpoints retain convolution and
final rows. Rewind selects the newest reachable boundary and invalidates future
branches. Reset/adoption invalidate the ring and Close frees it. Evicted windows
still use full replay. The memory plan includes all four entries; individual
tokens within a batch do not each acquire a checkpoint. Verification and single
measurement limits are recorded in [the evidence](inkling2-further-eight-evidence.json).

## Indexed experts and complete output/controller sequences

MoE routing builds stable expert buckets in one histogram/prefix/fill pass.
Native F32-activation experts can read checked token indices directly, sharing
physical weight decoding across selected vectors. Panels and integer activation
profiles retain their prior gather path. Packed K-format kernels cover counts
two through sixteen; larger batches retain the preceding kernels. Inkling's
chunk caps are four, eight and sixteen for small, medium and large batches.
Each actual expert's occupancy bounds its chunks and the existing dynamic job
distribution remains in use. Selection-slot aggregation order is unchanged.

CPU adapter projections can borrow immutable physical block-scale tables from
the session. Storage is capped at 128 MiB and reserved in memory planning.
Tables are keyed by physical layer/role, shared across visits and retained by
reset; Close releases them. Unsupported layouts and uncached tensors use the
original native scale decoding. No mapped weights or model-owned views change.

Vulkan gate/output sequences can apply the causal three- or four-tap output
convolution, including the checkpoint's four taps, before returning results.
Raw projected rows still return for finite checks. The host history is committed
only on successful execution and remains protected by the call rollback copy.
Controller sequences project down/gain/forget and blend messages without a CPU
pointwise stage. Their optional accurate shader uses range-reduced binary64
arithmetic for tanh, rounded once to binary32. Its availability is gated by the
existing usable Float64 rotation pipeline; the original CPU control fallback
remains for unavailable devices. Ordinary shared shader modes keep their path.

Explicit greedy Inkling context lookup uses existing cost arrays to record
warmup-filtered verification costs. Expected kept tokens per position price
each length. At least three samples and a two-percent predicted advantage are
needed to change its bounded proposal cap; the explicit maximum, rejection
backoff and default drafting enablement are preserved. Other architectures and
sampled lookup retain their existing policy. The pure chooser and generation
are covered by existing AUnit suites. See [evidence](inkling2-pipeline-eight-evidence.json)
for the exact scopes, precision qualification and single-run limitations.

## F16 KV expansion and head reuse

The existing CPU capability guard enables eight-value binary16 expansion.
Exceptional encodings retain scalar conversion semantics; arbitrary array
bounds and scalar tails are supported. F16 attention reuses each converted
four-position key tile across its three-head group and converts each value
row once for the group. Channel/position accumulation order is preserved.
All 65,536 binary16 encodings are compared with the scalar operation.

Seven additional CPU/GPU candidates were implemented and tested, then rejected
after measurements did not demonstrate a benefit. Their trial implementations
and evidence are archived; the preceding production paths remain. See the
[selection evidence](inkling2-resident-eight-evidence.json).

## Paired CPU attention and finite producers

The native three-head work group scores eight positions per vector. A paired
prefill kernel loads each key vector once for six head/query accumulators,
sharing F16 expansion across queries. Per-head score rows remain independent;
Open reserves a second query's score rows and the session plan includes their
bytes. Four-position and scalar tails preserve cache boundaries. Maximum,
softmax and binary64 value accumulation keep their chronological order.

F16 expansion checks exponent fields in SIMD and repairs exceptional payloads
only when needed. In-place RMS optionally checks its final stores; legacy unchecked callers
retain their preceding loops. Native clipping validates its final writes.
The later SIMD-output refinement regressed decode and was reverted.
Native normalization/clipping use these flags
with the existing non-finite diagnostic and recovery path.

Inkling's existing expert job formation uses physical tensor bytes (format
and dimensions), token traffic and a four-vector reuse estimate to choose
chunks and stable job order. This does not reorder expert aggregation or
change another architecture's scheduling.

A resident-GPU core prototype passed numerical and lifecycle fixtures but
regressed throughput and was reverted. Upstream projection/preprocessing
residency was outside that prototype; it is not an implemented capability.
See [selection and validation evidence](inkling2-attention-six-evidence.json).

## Exact Q4 products and marked conversation boundaries

Native Q4_K products keep eight rows of scale/minimum parameters in the
extra AVX-512 registers, retaining the original 256-bit arithmetic and four
independent binary64 accumulation lanes per row. The slower pair-packed
row prototype was replaced after measurement. A separately
targeted unit is entered through the existing CPU and OS-state feature
validation; other formats keep their existing products. Independent selected
row loads run ahead of arithmetic, and a bounded lookahead prefetches only
the next selected Q4_K block.

The F32 product can consume the existing lossless eight-row Q4_K panels
directly. Block scale/minimum preparation is shared across inputs; original
2048-element reduction boundaries and partial-range fallbacks are preserved.
The GGUF data and opt-in repack policy are unchanged.

On Linux, the CPU pool can bind workers to distinct physical cores within
the allowed CPU mask. The caller uses a scope that restores its prior mask
on every exit. Insufficient or unknown topology and unsupported hosts leave
placement to the existing scheduler. No process-wide affinity is changed.

For Inkling, the existing Mark_Checkpoint operation reserves rewind slot zero
for a conversation boundary. The remaining three recent checkpoints rotate.
Generation applies the existing reusable-prefix boundary policy to Inkling.
This allocates no fifth checkpoint and copies no KV history. Rewind checks
KV reachability before restoration; an evicted prefix still takes the exact
replay path. Reset, adoption and invalidation clear the reservation.

See [selection and verification evidence](inkling2-expert-five-evidence.json).

## Transformed four-bit Inkling cache

Inkling accepts the existing Q4T key codec with ordinary-Q4 values when each
head is a multiple of 32 coordinates. Pack_Row writes through the common codec
under the logical visit's cache identity. Queries are rotated once per head,
using one head-sized temporary. Grouped heads and paired queries consume full
eight-position tiles directly in registers; tail positions use bounded readers.
They do not inverse-rotate every cached key. Relative bias and sinks remain in
their original basis.

A guarded SIMD expansion in the existing private Unpack_Row reader decodes
complete nibble groups exactly as the scalar reader. Other callers retain the
original default. Attention reductions retain their existing order, and the
ordinary snapshot, cancellation, rewind and eviction mechanisms remain in use.
KV storage including scales is five bits per element, 6.4 times smaller than
F32; this does not shrink the physical weights or convolution history.

CPU and Vulkan matrix backends share this host attention path. Dedicated
resident Vulkan Inkling attention is not implied by Q4T support. New diagnostic
observations attn_q4t_sinks and attn_q4t_output expose the sink rows and weighted
values for independent cache-attention comparisons; Qcur remains in model basis.

See [validation and timing evidence](inkling2-q4t-evidence.json).

### Fused packed attention and device prefill transactions

For the existing three-head CPU work groups, eight-position Q4T score kernels
unpack key nibbles directly into position lanes. They keep each dot product's
binary32 channel order and separate multiply/add operations. Grouped value
kernels unpack eight coordinates in registers, round scaled values to binary32,
then widen them for the existing chronological binary64 sums. Other cache formats
and the independent-head fallback keep their previous kernels. The packed format,
logical cache indexing and memory plan do not change.

A 17-token checkpoint test exposed device prefill/decode differences when batch
reductions crossed a cache quantization boundary. Inkling Q4T device prefill now
uses one-token evaluations within the existing outer batch transaction, sharing
its arena and rollback buffers. Only the outer call publishes a rewind checkpoint
or commits positions. Cancellation restores the original convolution state,
hidden state, output row and validity flag. CPU Q4T retains batched projections
and expert execution. This is a correctness constraint on device prefill; it is
not a Vulkan speed claim. The original failing comparison is retained with the
[four-target optimization evidence](inkling2-q4t-four-evidence.json).

## CPU integer activations with Q4T

The explicitly selected CPU profile (`--arith int8 --repack none`) now matches
all 834 independent tensors exactly for Hello and the cached five-token
prefix. Physical expert weights remain shared across logical visits. Batched
experts preserve nearest-even Q8_K/Q8_0 packing, binary16 activation scales
where required, deterministic routing and reference SiTU stages. The shared
packer checks its arithmetic and scale contract before reusing rows.

Native binary32 reductions retain the reference's FMA streams for Q4_K,
Q5_K, Q6_K, Q5_0, Q8_0 and F32 products. Convolution and uncompressed-cache attention value sums
retain their reference fold order. Q4T reuses its independently checked fused
packed score/value kernels for either activation profile. Ordinary platform `expf`, `tanhf` and the
non-vector `fmaf` fallback supply scalar math; no external model runtime is
linked or invoked. A 64-position attention accumulator uses 32 KiB per active
head at width 128 for the uncompressed reference cache, independently of
context length. Q4T storage is unchanged.
Its full-checkpoint integer test covers 816 attention rows, prefill/decode,
partial-batch cancellation and rewind. See
[qualification and measurement](inkling2-integer-native-evidence.json).

## CPU integer tiles and shared expert packing

The existing deep integer-kernel compilation handles two physical output rows
and up to four token vectors together. Q4_K, Q5_K, Q6_K, Q8_0 and Q5_0 decode
one bounded tile of byte codes, reuse its loads across vectors and retain the
independent reference's binary32 FMA streams and final lane fold. VNNI products
use exact integer corrections before conversion. Native batches of up to four
vectors retain the previously qualified latency kernels; staged tiles serve
larger batches and interleaved weights. Other instruction sets retain the
existing portable/wide fallback. No full floating-point weight copy is made.

Gate and up products gather their selected packed inputs once. Worker-local
packed storage is reused across expert chunks, and reference SiTU is computed
in 32-coordinate blocks directly before down-input packing. Integer chunk
limits are 4, 16 and 32 according to batch size, with their own work estimate.
The existing 128-MiB session metadata budget also holds immutable physical
expert D/min headers for the looped region; logical visits share those entries.
The normal session cleanup releases the table and worker scratch. The session
plan reserves 32-member worker capacity, including coexisting packed buffers.
An independent workspace-growth lower bound catches the previous 16-member
underestimate.

Native and interleaved products pass the independent fixtures, including odd
rows, nonzero offsets, vector tails, cached headers and rejection without
partial results. The full interleaved Q4_K_M checkpoint matches all 834 captured
tensors exactly; its timing has not been inferred from row-major execution.

The combined row-major CPU sample with Q4T and lookup drafting measured
15.39 prefill tok/s and 7.66 decode tok/s, versus
11.65 and 6.73 tok/s for the preceding integer implementation.
These are single measurements after warmup, using the same 2048/16-token
workload, eight threads and batch 128. Q4_K_M weights and Q4T cache storage
remain selected. See [the eight-candidate evidence](inkling2-integer-eight-evidence.json).


## Streaming reference integer execution

Native batches of one to four vectors now read quantized weight codes directly
into SIMD registers. Each block's decode is shared by those vectors, with the
original eight-lane binary32 FMA streams. Q6 retains the reference's paired
sixteen-coordinate bias in its original integer lanes before conversion. The
2304-coordinate regression compares all five supported formats and one through
nine vectors with the previously qualified scalar reference kernels; independent
512-coordinate golden fixtures remain unchanged.

Reference activation packing uses SIMD finite/magnitude checks and explicit
nearest-even rounding. Q8_K keeps the sign of the first maximum, with the same
scale divisions. Binary16 conversion applies to the stored scale after byte
rounding. Existing non-reference packing keeps its original arithmetic.

The SiTU producer can measure its finite peak while writing each 32-coordinate
block. Packing consumes that peak, removing the extra extent scan, repeated
whole-batch shape checks and a separate half-scale conversion pass. Ordinary
activation callbacks and existing callers retain their defaults.

Large integer products keep correction workspace for at most four vectors,
independently of prompt batch size. SIMD produces scale/minimum corrections.
The existing 128-MiB physical metadata cache holds numeric D/min headers followed
by sixteen compact coefficient bytes, occupying six aligned words for Q4_K/Q5_K
and five for Q6_K. These entries are immutable and shared by logical visits.
No floating-point weight matrix is created.

Interleaved kernels gather compressed codes directly from their panels, avoiding
native-row reconstruction. Native streaming/staging selection also considers
format and width; wider Q8_0/Q5_0 products stream through eight vectors. Expert
chunks retain a maximum of 32, with smaller caps for Q5_K/Q6_K or wide inputs.
The existing memory plan covers the maximum and its packed workspaces.

All 30 native cases, 86 GGUF cases, existing MoE regressions, independent
checkpoint captures and Q4T CPU/Vulkan lifecycle checks pass. The direct-panel
checkpoint matches all 834 independent tensors exactly. Existing kernel
instruction/literal strings outside the reference adapter remain identical to
the before snapshot. See [qualification evidence](inkling2-integer-stream-eight-evidence.json).

The matched CPU integer/Q4T sample with lookup drafting measured
21.57 prefill tok/s and 10.04 decode tok/s, versus
15.39 and 7.66 tok/s previously.
Both use 2048 prompt tokens, 16 generated tokens, eight threads and batch 128,
with one measured pass after warmup. The output digest is unchanged. Panel
execution is independently validated; this row-major sample does not time it.

### Native packed relative attention and constrained projection

The packed Vulkan attention ABI appends one metadata offset at byte124,
keeping the push block within128bytes. Metadata contains typed width, extent,
cache origin and physical-table offset words, then relative coefficients and
sinks. The host validates all metadata/table ranges before dispatch. Queries
use the existing CPU Q4T rotation; the shader skips its ordinary rotation for
this path. Relative scores retain channel order and subtract learned sinks;
a zero-score sink joins the denominator. Cache positions subtract the current
origin before reading resident packed keys, values and scales.

Native loop attention uses existing block ownership, device budgets, release
and CPU fallback machinery. Physical tables have one copy per stored layer;
logical visits retain separate KV regions. Reset/adopt invalidate residency
marks; a moved cache block invalidates table/origin marks. Changed origins
refresh their logical state; ordinary decode uploads only the new row.
Snapshot, rewind, cancellation and final release have actual-checkpoint tests.
No floating model-weight expansion or second runtime is introduced.

The CPU decode path finishes relative scores while producing packed key-dot
tiles. Expert scale occupancy is maintained per physical layer. Narrow greedy
projection reuses one packed hidden input; a per-generation first-byte index
provides allowed IDs, whose adjusted logits are sampled directly. Existing
mask, history, bias and lowest-ID tie semantics remain unchanged. See
[routing/attention evidence](inkling2-routing-eight-evidence.json).

### Shared projections and reference packing

CPU grouping packs each compatible activation layout once for Q/K/V and the
relative/sink projections. Different global inputs remain separate; local RMS
normalization is reused only when loop controls have not differentiated inputs.
Workers write disjoint output rows through the existing packed-product API.
Native Q8_0/Q5_0 prefill can keep sixteen token accumulators while sharing a
physical two-row block decode; K formats retain their qualified eight-token path.
Checkpoint publication swaps completed backup buffers into the bounded rewind
ring, with separate convolution/activation owners and unchanged rollback rules.

Vulkan reference products distribute the original eight accumulation streams
across eight invocations and preserve the fixed final fold through shared memory.
The optional reference packer retains signed first maxima, division boundaries,
nearest-even bytes and explicit nearest-even half scales. It publishes packed
activations through the existing compute barrier before products read them.
The all-reference/non-chained restriction remains: current widened controller
math does not supply the integer SiTU contract. No resident integer MoE chain
is advertised. See [qualification evidence](inkling2-projection-eight-evidence.json).
