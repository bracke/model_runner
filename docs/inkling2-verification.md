# Inkling implementation verification

Status: native fixed-loop text inference and a real V3 task are verified;
the complete existing release checks pass for the qualified CPU/private-GPU profile.
Shared-host GPU reference validation and initial timing also pass after the
user-authorized 0.5 GiB memory allowance. Broader performance evaluation remains open. No V3 backlog candidate has been
marked complete. Variable-loop checkpoints and image input remain unsupported.
Commands, binary identities and retained log hashes are listed in
[the release evidence inventory](inkling2-release-evidence.json); pending gates
remain explicit there.

## Execution and precision contract

The existing loader recognizes `inkling2_loop` and validates required typed
metadata, dimensions, caller limits, quantization and all 704 tensor roles
before preparing weights. The reusable scheduler references 24 physical weight
owners over 48 deterministic logical applications. Session state is indexed by
logical visit; expert weight residency is indexed by physical layer/expert.

The native adapter implements depth attention residuals, prelude restarts,
four signed cross-loop controllers, per-visit convolution histories,
local/global relative attention with sinks and scale/clipping, sigmoid top-k
routing and SITU experts. Existing CPU/Vulkan tensor products, expert execution,
sampling, sessions and tool dispatch remain the runtime. External reference
executables are used only to produce test evidence.

The original qualified profile uses F32 activations and remains the default.
Its pinned independent llama.cpp reference has an explicit test-only F32
activation multiplication patch, documented with source and hashes in the
fixture manifests. The original quantized weights are unchanged.

The explicit row-major CPU integer profile now independently passes both
canonical byte-activation captures: Hello and the cached five-token prefix.
All 834 tensors and 1,352,826 values per case are bit-identical, including
expert IDs, and grouped expert execution preserves the logits. Q4T integer
attention, prefill/decode, cancellation and rewind also pass. This qualification
is for the recorded AVX-512 host with `--arith int8 --repack none`; compressed
interleaved CPU weights subsequently passed the same captures. The optional
Vulkan reference integer path now passes five-format operators and both full
checkpoint captures exactly. Its bounded throughput trial did not finish,
so CPU remains the selected performance profile. The earlier shared-host GPU
integer Q4T lifecycle trial timed out. The current private 4 GiB device profile
passes independent checkpoint and full Q4T cancellation/rewind checks. See
[latest evidence](inkling2-routing-eight-evidence.json). The independent
byte-activation runtime has no activation-math override. See
[current integer evidence](inkling2-integer-native-evidence.json), including
preserved failures and the single-pass tok/s measurements.

F32 cache comparisons use `1e-5 + 2e-5 * abs(reference)` per floating element;
expert IDs are exact. This bound was not widened for checkpoint failures.
F16 cache storage has a separate empirical envelope derived exclusively from
independent F16-versus-F32 reference captures: per-tensor maximum and RMS budgets
are `1e-5 + 2 * reference_precision_delta`, with the F32 relative allowance.
Exact routing and greedy IDs remain required. This is a measured precision
profile, not a mathematical error guarantee. Q4T keys with ordinary-Q4 values
are now validated separately; other packed KV pairings remain refused.

Q4T validation compares every new attention result with the existing independent
direct-Hadamard codec and a scalar local/global attention equation. Synthetic
coverage includes all 48 visits at 24 positions, snapshots, rewind, cancellation
and eviction. The longer actual-checkpoint test covers 2,506,752 attention values
on both CPU and private Vulkan hybrid, using the original F32 element envelope.
Both now produce exact prefill/incremental logits and pass partial-batch
cancellation recovery and rewind. Q4T device prefill uses decode arithmetic
inside one outer batch transaction; CPU prefill retains batching. Q4T is lossy
and is not required to reproduce F32-cache routing or logits. See the
[packed-attention and drafting evidence](inkling2-q4t-four-evidence.json).

## Passing focused evidence

| Check | Recorded result |
| --- | --- |
| Scheduler | Four AUnit routines: ordering, 24 owners, 48 independent state identities, bounds and ordinary single-pass schedules |
| Loader | Valid/malformed scalar and array metadata, all tensor roles, padded vocabulary, unsupported variants and caller limits |
| Synthetic F32 single token | All 834 tensors / 4952 values; maximum absolute difference 2.41399e-6 |
| Synthetic F32 ten-token cached prefix | All 834 tensors; maximum difference 2.92063e-6 |
| Synthetic quantized decoder | All 834 tensors / 14000 values; maximum difference 2.38419e-6 |
| Long context | 2200-token independent recomputation, actual eviction and alternative rewind; maximum difference 3.71039e-6 |
| Zero controls | Independent 834-tensor fixture with zero gain/forget projections and all three core visits |
| Q8 activation packing | Exact independent signed scales, ties, block sums and half scales |
| Full Q4_K_M CPU F32 | All 834 tensors / 1352826 values, exact routing; five-token cached prefix maximum difference 5.34058e-5, RMS 3.88485e-6 |
| Full Q4_K_M Vulkan F32 | Latest shared-host comparison passes all 834 tensors / 1352826 values and exact routing; maximum difference 7.62939e-5, RMS 4.35561e-6, unchanged tolerances |
| Full Q4_K_M CPU F16 cache | All 834 tensors within independent precision envelope; maximum difference 0.00106144, RMS 5.58668e-5; exact routing/greedy ID |
| CPU panel Q4_K_M F32 | Existing row panels, explicit 24 GiB owned-memory limit: all 834 reference tensors, exact routing and the 16-token greedy fixture pass |
| Final hybrid Q4_K_M F32 | Final source: all 834 tensors / 1352826 values, exact routing, explicit 4 GiB private Vulkan budget; maximum difference 5.34058e-5, RMS 3.84535e-6 |
| Pooled experts | Unwatched pooled execution and watched checkpoint logits are bit-for-bit identical |
| Native CLI greedy generation | Sixteen raw-prompt tokens match independently generated reference text byte-for-byte; `greedy-f32-16.json` records identities and CLI framing |
| Tokenizer | Four independent English/Ada/Unicode/special-token goldens, repeated against the verified full file |
| Chat template | All six official HF/Jinja cases, including tool result identity; 31 template routines pass |
| Tool protocol | Typed call grammar, malformed calls, JSON schema rejection, permission denial, normal execution/result dispatch |
| Streaming | Typed markers split at every fragment boundary; reasoning/call suppression and raw structured-output fallback |
| Conversation persistence | Sender/tool-call IDs survive compaction and version-2 checkpoints; older checkpoint versions remain readable |
| Cache lifecycle | Fresh/reset, cached continuation, snapshots, rewind/replay, cancellation during repeated visits, hidden/conv state recovery and arithmetic-profile identity |

The synthetic tests use independent captures from the pinned reference, not
native-generated golden outputs. The long-prefix reference is byte-identical
between full-batch and incremental reference execution at the last token.
F64 attention reductions correct a numerical accumulation defect exposed by
that long-context fixture. Native F32 prefill now batches projections and
expert work through the common evaluator; bounded rewind replay uses the same
path. Relative attention currently executes on the host. See the
[batching protocol](inkling2-batched-prefill-protocol.md) for current validation
and the separate throughput campaign.

The full file is 18,658,096,192 bytes, SHA-256
`ed38ac618a24ee65142c27073783a80aa3b100546a21212d59690c9081945a9b`.
Both native `Hub.Fetch` and GNU `sha256sum` verified it. The model is stored
outside Git. All reference commands, checkpoint revisions, patches and binary
identities belong in [the fixture inventory](../tests/fixtures/inkling2/README.md).

The canonical reference disables `GGML_LLAMAFILE`: its earlier optimized
microbatch-eight path differed from incremental decoding by 0.400331 in logits.
Disabling that optimization made all 834 captured final-token tensors
byte-identical across prefill/decode. Both outcomes remain recorded; the
optimized discrepancy was not converted into a permissive native tolerance.

## Remaining acceptance work

A real native Inkling V3 task completed through the existing headless workflow:
`inkling-native-ada-proof-0002`, invocation `INV-000002`, generation 2. The
model used the normal `read_file` and `edit_file` tools to change only
`Left - Right` to `Left + Right` in an Ada expression function. The parent
harness ran its configured required `sh check.sh` verification and recorded
`VER-000001` as passed before marking the task complete. The original check
fails on the bug; independent post-edit checks pass and confirm that the
acceptance script is unchanged. Replaying the same operation returns success
without adding or changing an invocation record.

The earlier automatic GPU attempt failed under shared-memory pressure. Its
failed invocation and the ordinary blocked-to-accepted CPU retry remain in
durable state. The CPU invocation used 6356 seconds and generated 258 tokens;
this is a correctness and recovery proof, not competitive coding throughput.
Logical prefix reuse currently reconstructs Inkling state by replay, so its
reported 63% reuse does not mean that inference work was avoided. See
[the real-task evidence](inkling2-v3-evidence.json) for configuration, identities,
normal verification, source/check hashes and idempotent replay.

The complete final AUnit regression suite passes: 1027 cases, zero assertion
failures and zero unexpected errors, with Vulkan enabled. Validation isolates
the root development V3 store so fixture sessions cannot adopt it through
ancestor discovery. All 343 saved durable-state file hashes were verified on
restoration; only regenerable repository indexes were moved outside the source
tree. Per-test teardown restores the working directory, configuration selection
and pending input. Conversation row tables use the existing heap holders; the
stack-frame gate passes its unchanged 262144-byte limit.

The final repository/source audit passes 31517 checks with zero failures after
the fresh measured-ledger update. Stage timing was reported too busy to judge
under the existing host-load policy; this is not a stage-speed qualification.

The final full 32-part arithmetic command passes, including its published-figure
check: 227688 sequences, 6056520 primary logit comparisons, zero outside
tolerance, unlearned operations or refusals, and all 239111 requested cases
accounted for. Fixture validation passes with 79875 tensor perturbations that
move outputs, zero unread tensors, unwanted effects or refusals. Seed-one
fuzzing passes 200 container cases and 800 text cases, with zero escaped
exceptions, invalid results, internal failures or slow cases. The complete
release logs and hashes are retained in the evidence inventory. An earlier
run caught two stale README figures; those were corrected from the measured
report before the full successful rerun. No check or tolerance was disabled.

The final 1027-case AUnit suite passed with Vulkan enabled. All 277 remaining
authoritative state files were restored with verified hashes, and compiler
stderr files are empty. The successful V3 task removed its transient runtime
logs through ordinary harness cleanup. No gate was weakened.

The final matched `no_adapter` CPU campaign completed all 28 prescribed runs.
Both seven-pair batches pass the unchanged 1.05 prompt/decode ratio gates;
all fixed-work output digests and frozen source, dependency, binary and input
identities match. After the benchmark model-limit fix, paired median prompt/decode changes are
+0.31%/+0.39% in batch one and +0.03%/-0.17% in batch two. The existing restamp command refreshed
only the measured group after that passing campaign. See the
[current evidence](inkling2-no-adapter-evidence.json) and
[predeclared follow-up protocol](inkling2-speed-limits-no-adapter-protocol.md).
The [initial campaign](inkling2-no-adapter-initial-evidence.json) is preserved.

Five reference CPU benchmark runs are retained in
[the benchmark evidence](../tests/fixtures/inkling2/benchmarks/README.md): median
512-token prefill 21.4122 tokens/s and 128-token decode at depth 512
7.88467 tokens/s. These are canonical reference byte-activation measurements,
not native F32 throughput. The [five-run native CPU baseline](inkling2-benchmarks.md) now passes with exact
reference text in every sample: median generation 1.786 tokens/s, range
1.733–1.840. It measures five prompt tokens and sixteen generated tokens at
context128 with F32 activations/cache; its first token uses prompt logits.
The final private-GPU five-token comparison and five-sample short-case timing
pass. CPU is faster than the instrumented 4 GiB GPU placement in that short
case. The user authorized 0.5 GiB extra memory, lowering the shared-host free-memory
guard from 22 to 21.5 GiB. Shared-host checkpoint validation and five timing
samples now pass. This path is much slower in the short case: median prompt
and decoder evaluations are 27.740 and 27.727 seconds respectively. The final repository audit passes 31517 checks with zero
failures. See the [operation-count correction](inkling2-benchmark-interpretation.md):
the generator evaluates its last emitted token before stopping, so sixteen
outputs cause sixteen decoder evaluations, and the short one-token case has
both a prompt and a decode evaluation. No default-model adoption decision is made;
the proposed 30-task comparative Ada evaluation has not been executed.

## Fixed-loop acceptance gates

| Gate | Status |
| --- | --- |
| GGUF validation / logical mapping | Focused AUnit and inventory evidence pass |
| Three-pass execution / messages / hybrid attention / MoE | Independent synthetic and full-checkpoint comparisons pass |
| Cache reset, rewind and reuse | Focused CPU lifecycle and long-context evidence pass |
| CPU/Vulkan differential correctness | CPU, private 4 GiB Vulkan and latest shared-host checkpoint comparisons pass |
| Tokenization and greedy generation | Exact tokenizer and checkpoint greedy fixtures pass |
| Tool calls and structured output | Parser, template, streaming, scripted dispatch and real native file-tool execution pass |
| V3 completion and recovery | Real native task complete; ordinary retry, required verification and idempotent replay pass |
| Memory limits and cancellation | Focused bounds/rollback tests and bounded CPU/GPU execution pass; expanded memory/context matrix pending |
| Existing architecture regression suite | Complete final 1027-case AUnit run passes with Vulkan enabled |
| Existing release checks | 1027 AUnit cases, 31512 source checks, full conformance, fixture validation and seeded fuzz pass |

Neither variable-loop nor vision capability is advertised as implemented.

The shared timing attempt exposed a benchmark-only defect: its explicit memory
limit reached the session but not model preparation, leaving the default 16 GiB
single-allocation cap in place for the 18.7 GB shared arena. The timing tool now
passes the existing caller limit to model preparation, matching native CLI.
A focused owned-repacking budget regression and all five related benchmark
AUnit cases pass with a real device required. Production inference source is
unchanged. The prior 1027-case full suite remains retained as core evidence;
no new 1028-case full-suite run is claimed. The original preparation failure
and all old measurements are preserved.


The subsequent batching qualification passes all 1029 AUnit cases, the CPU/private/shared 834-tensor checkpoints, exact scalar/batch outputs and cancellation/rewind tests. The refreshed no-adapter campaign passes both unchanged 1.05 gates (ledger `882945DE0BA411B7`). Updated native measurements and the fresh task are in the [batched-prefill report](inkling2-batched-prefill-benchmarks.md). Historical results above retain their original identities.

The six-candidate CPU follow-up passes 34 native AUnit tests, the exact
1,352,826-value integer checkpoint capture and the 2,506,752-value Q4T attention
lifecycle check. Relative bias retains scalar channel order bit for bit.
Selected output is checked against full Q4_K_M/Q4T projection and against full
constrained generation, including malformed selection, cancellation, rewind,
snapshot/adopt and subsequent full inference. The original golden files and
numerical tolerances remain unchanged. Performance is one combined 2048/16
sample after warmup; sparse constrained projection has no separate speed claim.

The routing/attention follow-up passes 35 native Inkling and 51 sampling cases,
including allowed-ID greedy equivalence with penalties and masks. Exact native
integer checkpoint capture and Q4T CPU lifecycle comparisons pass. The native
Vulkan Q4T path passes the scalar relative-bias/sink equation, malformed metadata
and shifted-origin tests, plus the actual-checkpoint 2,506,752-value attention
lifecycle within the original envelope. The lifecycle asserts actual device
attention execution and zero cache reservations after both sessions close.
Final test-only changes preserve every pinned qualified engine object. The
single CPU sample is 25.07 tok/s prefill and 10.52 tok/s decode; the latter is
effectively unchanged from 10.50 tok/s. The GPU long-prompt trial exceeds its
unchanged practical budget, so no GPU throughput improvement is claimed.

The projection/packing follow-up passes the35 native and51 sampling cases,
exact1,352,826-value integer checkpoint capture, CPU and private-GPU Q4T lifecycle,
watched versus grouped CPU prefill, five-format exact GPU products, non-finite
rejection and the existing architecture/packed-GPU regressions. Device packing
is required explicitly by its test capability check. The current GPU controller
fails integer-SiTU reuse eligibility at12/256 tanhf inputs; that chain stays off.
One 2048/16 sample is 25.20 tok/s prefill and 10.38
tok/s decode, effectively unchanged. The fixed shared-engine gate passes; see
[full evidence](inkling2-projection-eight-evidence.json) for the GPU timing outcome,
unchanged fixtures, failed development trials and final audit qualification.
