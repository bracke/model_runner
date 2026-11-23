# Quantized adapter execution contract, version 1

This specifies CPU attachments and the later device stage of [the harness-adapter plan](plan-harness-adapters.md).
The production CPU API is `Attach_Adapter`, selected by `--lora-mode runtime` in the CLI.
The independent oracle is in the tests crate; `Merge_Adapter` remains the default F32 operation.

## Tensor arithmetic and scope

Let a projection have input width n, output width m and base weight W of shape m by n. GGUF dimension one
is contiguous. An adapter A has GGUF dimensions [n, r], and B has dimensions [r, m]. Both are rank-two tensors;
a higher-dimensional tensor that happens to flatten to the same shape is refused by the new attachment loader.

For each input column vector x, evaluate:

```text
base = decode(W) * x
factor_i = scale_i                         if alpha_i is absent or zero
factor_i = scale_i * alpha_i / rank_i      otherwise
y = base + sum_i factor_i * B_i * (A_i * x)
```

Adapters are accumulated in attachment order. Negative scales subtract. A zero scale preserves the projection's
bits and still requires validation of the attachment. A missing or zero alpha follows the existing merger's
convention; it does not zero the adapter. Present negative, non-finite, incorrectly typed or out-of-range alpha
is an error, not a request to substitute the missing-alpha convention.

The same decoded quantized W is used in reference and candidate. Quantizing W+BA is a different operation
from retaining quantized W and adding BA at execution time. The premerged Q8 release is a quality comparison,
not a numerical oracle for runtime attachment.

The initial target set is explicit and limited to the seven existing projection names:

| GGUF stem in `blk.L.<stem>.weight` | Prepared layer view | Apply before |
| --- | --- | --- |
| `attn_q` | `Query` | query/gate splitting, bias, clipping, normalization and RoPE |
| `attn_k` | `Key` | bias, clipping, normalization, RoPE and cache publication |
| `attn_v` | `Value` | bias, clipping, normalization and cache publication |
| `attn_output` | `Attention_Out` | projection bias, post-attention normalization and residual addition |
| `ffn_gate` | `Gate` | gate activation and multiplication by the up projection |
| `ffn_up` | `Up` | bias, gate multiplication or the ungated activation |
| `ffn_down` | `Down` | bias, post-feed normalization and residual addition |

The target must exist in that exact layer. Key/value output widths need not equal the query width. For a hybrid
Qwen35 full-attention query, the target includes the interleaved gate rows: adapt the whole stored projection
before splitting it. Its recurrent layers have feed-forward targets but no ordinary attention Q/K/V targets.
Do not infer a recurrent target from an attention projection with similar dimensions. The pinned 27B adapter
has ordinary feed-forward pairs on recurrent layers; its attention pairs target full-attention layers.

This contract does not cover output heads, embeddings, recurrent-state projections, expert stacks, MLA's
special latent projections, vision, activated adapters, transposed aliases, live switching or target slicing.
The first production loader must refuse architectures/targets that bypass the audited projection routes.
An accepted file may not contain ignored tensor pairs, unmatched halves or an unsupported target beside valid ones.

## Admission and validation

First validate metadata and every descriptor without changing the prepared model. Require matching
`general.architecture`, `general.type=adapter`, `adapter.type=lora`, and no activated-adapter invocation metadata.
Resolve every name to one supported prepared projection. Validate exact rank, dimensions, pair uniqueness,
format, byte ranges and checked arithmetic for element counts, allocations and scratch. A valid early pair
does not permit a bad later pair to be ignored.

The first execution implementation accepts F16 and F32 adapter matrices and stores owned F32 matrices.
Base weight formats and panel layouts remain unchanged. Finite source values are checked while decoding;
conversion and the effective factor must remain finite and representable by the chosen arithmetic path.
Scales are finite binary32 values. Present alpha is finite and in [0, 1E6]. No invalid alpha silently becomes zero.

Implemented limits are eight attachments, 4096 total pairs, rank at most 64, and one GiB of decoded adapter
storage across the prepared model. These are loader limits, not statements that every host admits that memory.
The pinned adapter's rank 32 and roughly 638 MB F32 payload fit these nominal limits. The host still needs
headroom for its base weights, descriptors, caches, recurrent state, workspace and session scratch.
Limits and backend compatibility are checked before allocation; callers may tighten the limits.

Host accounting includes owned matrices, descriptors and per-session rank/output scratch. The loader also
uses two fixed 64 KiB stack buffers for reading and hashing. Session scratch is bounded at
4*8*(maximum rank + maximum output rows) bytes. CPU batches use tiles of up to eight positions, reusing the
existing binary64 tensor product for A*x and worker-shared binary64 B*(A*x) accumulation into staged output.
The scaled B result is not rounded to F32 before combining it with the base; a large unscaled dot can have
a finite scaled result. Only complete tiles are published. Reference and non-little-endian hosts retain the
scalar adapter route. Input validation reads only active rows; workers write disjoint staged rows and join
before their borrowed input or scratch can expire.
Allocate per-session scratch at session admission and include it in host/device budgets. No token-time allocation.
Device admission also counts resident adapter matrices and device scratch before choosing placement.

The stage-3 CPU implementation accepts CPU and reference prepared models. A device or split prepared model
is refused until the device stage is implemented and qualified. It may not silently drop deltas or transfer each
projection through a hidden host fallback. Speculative and draft combinations must either execute the same
effective attachment in every relevant session or be refused explicitly until tested. This implementation
disables next-layer drafting on attached sessions and refuses explicit CLI drafting. Unused next-layer
weights may remain in the model. Dense Llama, Qwen2, Qwen3 and Qwen35 are accepted; experts are refused.

## Ownership, transaction and lifecycle

Preparation is transactional. Build a temporary attachment, validate all descriptors, read and validate all
matrix values, calculate its identity and accounting, and reserve lookup/storage before publishing it.
On failure or cancellation, release temporary storage and leave existing attachments, base weights,
accounting, cached fingerprint and session admission unchanged. Failed attempts consume no attachment slot.

The prepared model owns the committed matrices and descriptors. It borrows nothing from the caller's GGUF
container or byte source after attachment returns. Those sources can close immediately. Concurrent sessions
read immutable adapter data; each has separate scratch. Attachment, scale changes and detach are refused while
any session is open, before reading a payload or changing any identity. The first implementation need not expose
scale-change or detach operations at all: close/reprepare is sufficient.

Close with an active session keeps the existing structured lifecycle refusal. Successful close/finalization
releases attachments exactly once and resets their accounting, lookup and identity. Cancellation during a
projection follows the session's existing evaluation rollback rules; partially computed activations cannot be
published as a committed token or cache row. Cancellation during attachment is independent of an active session.

Use existing structured errors where appropriate: lifecycle refusals; unsupported feature or tensor format;
missing tensor; invalid tensor shape; non-finite tensor value; metadata type/range; checked arithmetic overflow;
allocation/admission failure; cancellation and source I/O failure. Include the offending tensor/key in diagnostics.
Never turn a failed attachment into a successful unadapted run.

## Effective identity and caches

The effective identity must bind the full decoded content of every attached A/B matrix, resolved layer/target,
shape, order, exact scale bits, alpha presence/value and an execution-mode/version tag. A SHA-256 over a canonical
length-delimited representation can be folded into the existing model fingerprint; this is identity, not file
authentication. Compute it once during attachment, not by scanning matrices at every saved-session operation.
Two same-sized files with different tensor values must differ even when names/ranks/scales/alpha are identical.

No-attachment model fingerprints remain unchanged. A zero-scale attachment may conservatively have its own
identity even though it changes no arithmetic. Tiled CPU execution uses the version-two runtime mode tag:
the existing tensor product groups the A*x reduction differently from the first scalar implementation.
Saved runtime contexts made with version one are refused and must be regenerated.
Failed attachment preserves the prior identity. Reject contexts
computed with different effective weights, scales, order or application mode. Bind all attention and recurrent
state, committed-prefix reuse and draft state to the same effective model. The no-live-mutation rule is essential
for existing in-process prefix reuse; a persisted context also needs the updated fingerprint.

Reuse immutable base panel caches: their tensors and arithmetic are unchanged. Any cache containing adapted
weights, derived adapted projections or evaluated activations requires the effective identity. Audit named views,
host panel aliases, device residency, shared tensor aliases and prepared draft ownership explicitly.

The existing F32 merger is an additional numerical reference, not an attachment validator. It now simulates
all recognized pairs before writing weights, rejects non-finite or unrepresentable results, and hashes the full
owned payload plus descriptor names, shapes, formats, offsets and scaling into `Adapted`. Failed recognized pairs
leave existing weights and identity unchanged. This adds preparation work and bounded row scratch; it does not
change the merger's forward kernels. The separate CPU attachment implementation applies low-rank products
over the unchanged base. Older adapted saved contexts may be
refused under the new content identity; no-attachment fingerprints and the cache layout version are unchanged.
The attachment loader validates every file target, format, limit and owned value before atomic publication.

## Integration audit

The relevant current implementation points are:

- `model_runner-llama.adb`: `Product`, `Product_Group`, `Product_Batch`, `Product_Slice`, `Fingerprint`,
  model/session admission and close. Both the CPU group's early return and the ordinary per-matrix route need
  deltas exactly once. Matching solely by shape is unsafe; distinct projections can have the same dimensions.
- `model_runner-llama-evaluate_token_body.adb`: Q/K/V products, hybrid query/gate splitting, attention output,
  and gate/up/down products. Add deltas before the following bias, nonlinear operation or residual update.
- `model_runner-llama-evaluate_batch_body.adb`: the same operations for every active row, including partial
  batches. Update query/gate rows before deinterleaving. Recurrent feed-forward projections also use adapters.
- CPU/reference dispatch must reuse existing base kernels and multiply the two small adapter matrices separately.
  Reordering base panel packing or decoding a whole base model to F32 defeats the memory objective.
- Device `Normalize_And_Project`, fused attention/layer operations, `Dispatch_Gated`, grouped products and deferred
  resident rows can bypass the ordinary helpers. Extending only `Product` is insufficient. The device stage must
  insert the delta inside each corresponding device sequence and test that it is neither omitted nor doubled.

The public operation is distinct `Attach_Adapter`, with `--lora-mode runtime` beside
`--lora`. The existing merge path remains the default (`--lora-mode merge`). The CPU execution
implementation refuses mixing merge and attachment modes and validates CLI combinations before large acquisition.
No automatic mode choice or default change follows from this specification.

## Independent numerical qualification

`tests/src/adapter_oracle.adb` computes binary64 base products and explicitly expands B*A before multiplying x.
It calls no production tensor product, backend or merger. This differs from the factorized B*(A*x) path
and the merger's binary32 weight updates. Analytic non-square examples first establish the oracle's answers,
including nonzero array origins, rank two, alpha/rank, missing/zero alpha, negative stacking and signed zero.

Reference limits are explicit: width <=32768, rank <=64, at most 2**21 base elements and 2**24 expanded products
per call. Large projections can be checked one output row at a time. Inputs must be finite with magnitude <=1E40
(covering every binary32 operand); an accumulated result is bounded by 1E240. These bounds keep the expanded
binary64 arithmetic finite. Reference refusal preserves the caller's result. These are reference limits, not
permission for a production loader to accept unbounded files.

Projection acceptance is fixed before candidate optimization:

```text
abs(candidate - reference) <= 1E-5 + 2E-5 * abs(reference)
```

The test matrix compares all seven F32-merged and runtime projections against that reference, starting from the
same decoded quantized Llama base. It also checks Qwen35's gated query and recurrent-layer feed-forward targets.
Ranks two and three carry nonzero, nonuniform values in every rank, with F16/F32 matrices, absent/zero/nonzero
alpha, signed scales and stacking. No independently quantized merged model enters the arithmetic comparison.
An additional hand-encoded Q8_0 matrix has independently specified signed codes and scale, so base decoding and
projection are not defined by the merger or fixture quantizer. Test-only child inspection exposes prepared views;
it adds no production API or executable path.

Malformed controls cover oracle shape/rank/width limits and non-finite operands/scalars, plus first-pair native
merger refusals for missing halves, input/output/rank mismatches, foreign targets/types and activated adapters.
Additional native regressions check a bad later pair, late NaN, overflowing results, invalid alpha, non-finite
scales and invalid payload at zero scale. Existing merged weights and fingerprint survive refusal. Context tests
accept the same adapter after reopening, refuse a same-sized adapter with different values, and refuse changed
descriptor offsets with identical payload bytes. The content control changes only the last byte of a 128 KiB
payload over a Q4_K base, exercising more than one hash chunk. Runtime saved contexts undergo the same
content/offset checks and refuse cross-mode reuse.

Production attachment tests also cover extra targets, rank-three tensors, unsupported quantized adapter data,
short/changed sources, source I/O failure, rank/storage/file limits, F16/F32 NaNs at zero scale, active sessions,
cancellation before and during payload loading, source closure and account preservation. Projection tests
require bitwise unchanged results when stacking a zero-scale attachment. End-to-end tests compare token logits
on CPU/reference and CPU prompt batches with tails for dense Llama, Qwen2, Qwen3 and Qwen35 against the
same-base F32 merger at 1E-4 absolute plus 1E-4 relative tolerance. Separate sessions have separate scratch.
The reference backend retains its existing multi-token prompt-batch refusal.

The execution report records a real Qwen35 Q8 smoke check and paired timing with an artificial rank-32,
96-pair adapter. Bounded CPU tiles reduce the observed prompt overhead in that case; both raw timing batches
and their scalar predecessors are retained. Trained-adapter quality and released-27B qualification remain pending.
