# Harness adapter execution report

Execution date: 2026-11-22. The [plan](plan-harness-adapters.md) is partially implemented.
The published adapter has not been evaluated, and no inference default has changed.
Per-arm runtime campaign qualification was added on 2026-11-23.
The subsequent [TwIL experiment](harness-adapter-twil-protocol.md) pins a smaller trained candidate with
[verified complete payloads](harness-adapter-twil-artifacts.json). It adds qualified dense Granite runtime
attachment and preserves recognized tool syntax when a supplied template overrides the model's own.
These preparation changes do not yet establish trained-adapter quality or replace the original Qwen campaign.
The [native TwIL execution record](harness-adapter-twil-execution.md) tracks generation, memory, validation
and the pending independently graded work gate separately.
Subsequent [campaign hardening](campaign-hardening.md) adds OS-isolated verifiers, protected baselines and
native resolved-setting capture. Earlier isolation/reporting limitations below describe their checkpoints.

The subsequent [repository audit repair](repository-audit-repair.md) resolves the dependency conflict and
addresses the earlier findings. Validation counts and build limitations below describe their original
checkpoints; see the repair report for the latest status.

## Delivered

- Pinned original, merged Pi and separate adapter revisions, sizes and upstream whole-file digests in
  [the artifact manifest](harness-adapter-artifacts.json). Whole tensor payloads are not verified locally.
- Native bounded-prefix inspection found matching model headers and resolved all 256 adapter tensor pairs.
  [The inspection record](harness-adapter-header-inspection.json) distinguishes descriptors from payloads.
- `tests agent-campaign` runs four paired arms through the existing interactive `/work` workflow, with fresh
  projects, fixed inference policy, explicit drafting and thinking controls, and isolated campaign settings.
  It writes versioned manifests, durable attempt records and descriptive summaries, and refuses unsafe resume.
- Campaigns can select one separate runtime adapter and finite scale per model slot, including an identical
  quantized base in both slots. Explicit CPU settings apply to every arm. Adapter paths, whole-file digests,
  mode and scale bind the manifest; each finished attempt binds its manifest digest. Shared adapter controls
  are refused, paths containing spaces remain individual arguments, and changed adapter files refuse resume.
- Twelve pilot tasks have reference, unchanged and known-wrong grading controls. Coding checks rebuild preserved
  verifier sources after the agent exits and refuse unrelated source/document changes. Navigation grading uses
  the final report rather than incidental tool output. Verifier directories still need operating-system isolation
  before the plan's confirmation gate can pass.
- Native work figures now expose executed root calls, root and delegated tokens, and compactions. The campaign
  records unavailable metrics as null and keeps model failures distinct from infrastructure errors.
- Fixed a pre-existing trial-driver timing race that could send configuration text before the prompt was ready.
  Added checks for short terminal writes and normalized executable/model paths before changing directories.
- Added [the version-one execution contract](adapter-execution-contract.md), a bounded binary64 oracle and
  seven focused numerical/correctness checks. The reference explicitly expands B*A before multiplying x;
  the candidate reference is the existing F32 merger applied to the same decoded base.
- Fixed two reproduced F32-merger defects: a bad later pair changed earlier weights, and a saved context accepted
  a different same-sized adapter. All recognized pairs and numerical results are now checked before writing.
  Full payload, descriptor names/shapes/formats/offsets, exact scaling and mode identity bind saved contexts.
  Invalid alpha/scales, NaN payloads and unrepresentable updates are refused without damaging prior merged state.
  This adds validation/hash work at merge time and bounded row scratch. It changes no forward projection kernel.
- Added native CPU `Attach_Adapter` and `--lora-mode runtime`. Dense Llama, Qwen2, Qwen3 and Qwen35
  main-layer projections keep the base layout and apply owned low-rank matrices during token/CPU batch execution.
  The loader validates the whole file, bounds decoded storage, observes cancellation and publishes atomically.
  Session admission includes rank/output scratch; sources close after attachment. Context identity binds full
  decoded content, target/shape, order, scale, alpha and execution mode. No token-time adapter allocation occurs.
  Device, expert and draft execution are refused; unused next-layer weights can remain in a hybrid model.
  F32 merging remains the default. The reference backend retains scalar evaluation and its prompt-batch refusal.
- Embedded `Inference.Open_Options` accepts bounded CPU runtime adapters with individual scales and loading
  limits. Attachment finishes before the context opens; provenance reports adapter count and decoded bytes.
  Independent consumer execution also qualifies the standalone inference project's adapter source closure.
- Added `tests adapter-fixture` for bounded synthetic rank-two F16 adapters shaped from a named model tensor.
  These fixtures have no trained behavior and are only for execution/memory checks.

See [the campaign guide](harness-adapter-campaign.md) for commands, record semantics and measurement limits.

## Resource gate and remaining work

Each pinned Q8_0 weight file is 28,595,763,840 bytes. Available host RAM at the recorded probe was
22,787,031,040 bytes, before session state and workspace. The integrated GPU shares host RAM. The existing
F32 merge would need 107,583,993,856 bytes for base parameters alone. Neither path passes admission here.
The [follow-up native probe](harness-adapter-resource-check.json) records 22,334,054,400 available bytes and
again fails the Q8 weight-only check. It remains bounded header inspection, not payload verification or inference.

Large-file acquisition was stopped; about 8.2 GiB of incomplete downloads remain under
`/tmp/model-runner-harness-adapters` with partial names or range fragments. They are not runnable verified
model files. A fallback would require both complete, verified originals and the same native
quantization settings in both arms, followed by load, generation and tool-contract checks.

Stage 0 has artifact and descriptor evidence, but its inference gate is pending. Stage 1 has tooling and grader
controls, but no released-model pilot, frozen confirmation suite, uncertainty analysis or transfer decision.
Full resolved-setting reporting and verifier isolation also need qualification before confirmation.
Stage 2's contract and independent reference are implemented, with F32 baseline regressions. Stage 3 now has
production CPU attachment and token/batch execution, loader/ownership regressions and a real quantized-model
memory smoke check. Its broad trained-adapter throughput qualification remains pending; short synthetic runs
cannot establish acceptable overhead for the 256-pair released adapter. Stages 4 and 5 remain unimplemented:
device attachment and complete training-trajectory capture. No trainer is added.
Older adapted snapshots can be refused after the identity
fix; no-attachment fingerprints and the snapshot layout version are unchanged.

## Validation evidence

- Tiled continuation: the final build passes with no warnings, the focused adapter suite passes **11/11**,
  and the mandatory full suite passes **959/959**, with zero failed assertions or unexpected errors.
  The repository audit completes **30,552 checks with the same 19 known failures** and no new adapter finding.
  Logs are `/tmp/model-runner-adapter-tile-cancel-build.log`, `/tmp/model-runner-adapter-tile-cancel-cases.log`,
  `/tmp/model-runner-adapter-tile-full-suite.log` and `/tmp/model-runner-adapter-tile-repository-check.log`.
  Worker frames are 128/144 bytes and the bounded batch frame is 12,320 bytes in the compiler stack evidence.
- Performance continuation: the production crate builds in release mode, and the tests crate builds. The full suite
  passes **958/958**, with no failed assertions or unexpected errors; the focused adapter suite passes
  **10/10**. The final repository audit completes **30,538 checks with the same 19 known failures**.
  Logs are `/tmp/model-runner-adapter-bench-full-suite.log`, `/tmp/model-runner-adapter-bench-final-cases.log`
  and `/tmp/model-runner-adapter-bench-repository-final.log`. A shared dependency archive link error was
  resolved by rebuilding; two command-wiring lines were wrapped and their compiler diagnostics refreshed.
  The final relink also encountered a truncated shared HTTP archive; a serial `alr build -- -j1` completed
  successfully with no warnings. Its log is `/tmp/model-runner-adapter-bench-serial-build.log`.
  No dependency code or benchmark-warning allowances were edited for this change.
- Both Ada crates build. The CPU implementation's mandatory full suite passes **957/957**, with zero failed
  assertions or unexpected errors. The final full-suite log is
  `/tmp/model-runner-runtime-adapter-full-suite-final.log`. Its localhost HTTP integration test needs network
  access; an initial sandboxed run stalled there and was stopped before the successful normal-access run.
  The subsequent fixture-only safeguard was rebuilt and checked separately: existing output is refused,
  a new output reproduces the recorded fixture byte for byte, and all nine adapter cases still pass.
- CPU continuation: the focused adapter suite passes **9/9**, and the CLI combination/policy case passes.
  Both runtime and F32 merging match the expanded oracle over all seven targets and 84 configurations each.
  Four architectures pass token-logit comparisons on CPU/reference, and CPU prompt batches include a tail.
  Zero-scale stacking preserves projection bits. Tests cover source closure, NaN F16/F32 values, extra targets,
  rank-three/unsupported-format tensors, short/changed sources, I/O failures, pre/mid-read cancellation,
  storage/rank/file admission, active sessions, independent scratch and saved-context content/mode identity.
- The [CPU smoke record](harness-adapter-cpu-smoke.json) identifies a real 0.8B Qwen35 Q8 model and an
  artificial 18,752-byte adapter. Runtime attachment used about 0.9 GiB peak RSS and retained mapped base weights;
  F32 merging used about 4.7 GiB and reported 4,106,485,760 rewritten bytes. Zero-scale text matched the base.
  These are single short warm-cache observations on a shared host, not a benchmark or a quality result.
  The fixture owns 36,864 decoded matrix bytes plus descriptors and needs 14,344 bytes of session scratch.
- The current repository audit completed **30,499 checks with the same 19 failures** listed below; its log is
  `/tmp/model-runner-runtime-adapter-repository-final.log`. It found no new adapter API, compilation or
  dependency-layer violation. A missing README entry for the new fixture command was corrected before this run.
- Both Ada crates built successfully. After the merger fixes, the mandatory AUnit suite passed **955/955**,
  with no failed assertions or unexpected errors. The final focused adapter suite passed **7/7**; the earlier
  focused campaign suite passed **6/6**, and those campaign cases also pass in the full suite.
- Every pilot grader passed reference, unchanged and known-wrong controls; additional checks cover forbidden
  changes, weakened in-project tests, final-report grading, nullable metrics, header bounds and resume refusal.
- A real four-arm run with the same local 4B model in both slots reached `/work` in all four attempts.
  All four reached their 120-second budget; none was an infrastructure failure. Native root plus delegated
  token counts equaled the total, and executed calls did not exceed displayed requests.
  [The retained instrumentation evidence](harness-adapter-instrumentation-check.json) is explicitly not an
  adapter evaluation or a performance baseline. The attempt binaries are identified by their recorded digests;
  subsequent tooling fixes mean they are not necessarily the final binaries.
- A separate four-arm 0.8B smoke run verified relative model paths and the default relative executable path.
  Each attempt reached its one-second work budget, with zero infrastructure failures and no pending records.
  This validates path handling and failure accounting, not model quality.
- Continuation: all seven adapter contract cases pass. Across 84 configurations, 252 signed/zero-scale merges
  match the fixed projection tolerance (1E-5 absolute plus 2E-5 relative): all seven targets, Llama/Qwen35,
  F16/F32 adapter data, nonuniform ranks two/three and absent/zero/nonzero alpha. Llama starts from decoded Q8_0;
  the hybrid fixture is F32. A separate hand-encoded Q8_0 matrix has independently specified exact values.
- Both production regressions failed against the previous merger (five passed, two failed), then passed with the
  fix. Expanded refusal tests preserve existing merged weights and identity, and saved-context checks include
  changing only tensor offsets while retaining the same payload bytes. The final focused check strengthens
  the content control to change only the last byte of a 128 KiB adapter payload over a Q4_K base; this exercises
  more than one hash chunk. Production code is unchanged by that final fixture strengthening. Logs are
  `/tmp/model-runner-adapter-before-fix.log` and `/tmp/model-runner-adapter-contract-final-cases.log`.
  The complete final-production suite log is `/tmp/model-runner-adapter-contract-final-full-suite.log`.

Build and check logs are retained under `/tmp/model-runner-harness-*.log`; real attempt projects and complete
local campaign records are retained under `tests/obj/harness-adapter-*` and excluded from version control.

## CPU performance qualification

The continuation adds `tests adapter-bench` over the existing speed runner and widens `tests adapter-fixture`
to all present supported main-layer projections at ranks through 64. The native token/batch logit regressions
now also cover ranks 32 and 64. A new control case checks hybrid target selection, bounded input, reversed
arm order, fixed token counts, zero-scale identity and refusal to publish a failed attachment as a fast summary.

The [evidence manifest](harness-adapter-cpu-r32-evidence.json) identifies the real Qwen35 0.8B Q8 base,
an artificial rank-32 adapter with 96 pairs, and both complete raw timing batches. The prompt file tokenizes
to 100 tokens for this model; every sample generates 16 tokens, with CPU arithmetic F32, four workers,
batch size 16, context 512, exact cache and drafting disabled. Each sample has a full untimed warm-up;
model loading is separate, and arm order reverses between paired repetitions.

The [first batch](harness-adapter-cpu-r32-timing.json) has five repetitions of four arms:

| Arm | Median warm-cache load, s | Median prompt, s | Median decode, s |
| --- | ---: | ---: | ---: |
| Quantized base | 0.209 | 3.162 | 1.329 |
| Zero-scale runtime attachment | 0.404 | 3.094 | 1.317 |
| Active runtime attachment | 0.402 | 4.531 | 1.527 |
| Same-base F32 merge | 33.308 | 2.964 | 1.117 |

Median paired runtime/base time ratios were **1.442 for prompt** and **1.145 for decode**. One runtime
decode sample took 8.784 seconds, a 6.726 ratio, while host load rose from 4.10 to 7.61. Its cause is unknown;
it is retained rather than filtered out. A [second independent batch](harness-adapter-cpu-r32-repeat.json)
repeated five base/zero/runtime comparisons without the merge arm. Its median paired ratios were **1.459**
and **1.141**; decode ratios ranged from 1.096 to 1.180. All fixed-work and zero-scale controls passed.

The adapter owns **51,130,368 bytes** of decoded matrices and descriptors. A separate native CLI run with
the wide fixture used **979,000 KiB peak RSS** (about 0.93 GiB) and retained mapped base weights. The in-process
benchmark does not measure RSS; its model account excludes borrowed mapped pages. Host load and temperature
are retained in every raw sample. These shared-host observations establish a cost for this synthetic case,
not a worst-case latency bound or a quality gain. Runtime mode saves the full F32 expansion at the observed
prompt/decode cost; merging pays a much larger one-time load cost here. Neither default nor model recommendation
changes. That first CPU route applied low-rank deltas one position at a time. The tiled follow-up below
addresses its prompt overhead. Released-adapter timing,
other arithmetic policies, long contexts, broader before/after no-adapter timing,
the premerged-release arm and device execution remain separate qualification work.

## Tiled CPU follow-up

CPU prompt execution now processes up to eight positions at a time. The existing binary64 tensor product
computes A*x, with rows shared through the existing CPU pool. B*(A*x) keeps independent binary64 sums per
position, then combines scale and base output before the final F32 rounding. This preserves finite scaled
results even when the unscaled B dot exceeds F32 range. All worker shares join before a completed tile is
published. Reference models, singleton products and non-little-endian hosts retain scalar execution.

The [tiling evidence](harness-adapter-cpu-tiled-evidence.json) links both saved scalar batches and two new
five-repeat paired batches at the same model, adapter, prompt, arithmetic, workers, batch size and context:

| Implementation | Median paired prompt-time ratio | Median paired decode-time ratio |
| --- | ---: | ---: |
| Scalar first batch | 1.442 | 1.145 |
| Scalar repeat | 1.459 | 1.141 |
| Tiled first batch | 1.048 | 1.170 |
| Tiled repeat | 1.014 | 1.135 |

Each ratio compares active runtime attachment with the quantized base inside that batch. Observed prompt
overhead fell from 44–46% to about 1–5%. Median runtime prompt time was 3.378 and 3.279 seconds in the new
batches, against 4.531 and 4.548 seconds in the saved scalar batches. Decode arithmetic is unchanged and no
decode improvement is claimed. Generated output retained the saved scalar digest. Both batches passed the
zero-scale and fixed-work controls. These separate shared-host batches remain descriptive, not a universal
speed guarantee, a significance claim or a trained-adapter quality result.

Session scratch is now `4*8*(maximum rank + maximum output rows)` bytes, admitted before allocation and
reused across tiles; model-owned adapter bytes remain 51,130,368 for this fixture. A separate CLI run with
exact cache used 982,332 KiB peak RSS (about 0.94 GiB) and retained mapped base weights. Its cache setting
differs from the earlier default-cache CLI memory observation, so those RSS values are not a controlled
before/after comparison. No full base expansion or per-token adapter allocation was introduced.

Focused tests cover 1/3/7/8/9/15/16/17/33 positions, serial and worker-pool execution, rank-64/rank-3 stacking,
nonzero and maximum array origins, unused poisoned input rows, output guards, late invalid inputs, oversized
counts, cancellation, scratch recovery, finite scaled large dots and structured overflow refusal. Projection
and final-logit tolerances remain unchanged. The changed A*x reduction order is bound into runtime identity
version two: saved runtime contexts from the first scalar implementation are refused and must be regenerated.

## Separate runtime adapters in native campaigns

The campaign driver now accepts one separate runtime adapter and independent scale for each model slot.
Using the same quantized model in both slots compares the unadapted base against its attached adapter
without creating a second complete model. Both thinking settings retain their slot's adapter selection.
Shared `--lora`, `--lora-mode` and `--lora-scale` options are refused, and an explicit CPU backend is required
for every arm. Adapter paths remain individual arguments when they contain spaces.

The manifest binds both adapter paths, whole-file digests, execution modes and scales. Each finished
attempt also binds the manifest's SHA-256, preventing records from another configuration from being reused.
The driver rehashes the selected adapter before starting each new attached attempt. Scale formatting uses
plain decimal syntax and a native-parser preflight; a value that cannot round-trip exactly is refused before
campaign setup. Embedded inference integration is documented below; device support remains pending.

[The native qualification record](harness-adapter-runtime-campaign-check.json) retains the exact manifest
and all four outcomes for the local Qwen3.5 0.8B Q8_0 model. Only the adapted slots load a synthetic rank-two
FFN gate adapter, at scale 0.5, with a path containing spaces. All four sessions started and ended at the
deliberate one-second work limit, with zero infrastructure errors. Check-only resume reused all four finished
records with zero new attempts. Exit status remains one because all four tasks were independently graded
failed; this is execution instrumentation evidence, not a quality or trained-adapter result.

The focused campaign suite passes 8/8, covering arm selection, exact scale retention, changed scale/content,
moving adapters between slots, missing files, record/manifest mismatches, shared adapter refusal and CPU
controls. Nonfinite scales and values outside the native CLI's exact decimal representation are refused.

Both crates build successfully. The mandatory full suite passes **961/961**, with no failed assertions or
unexpected errors. The repository audit completed **30,561 checks with the same 19 known failures** described
below. Final logs are `/tmp/model-runner-adapter-campaign-root-build.log`,
`/tmp/model-runner-adapter-campaign-test-build-final.log`, `/tmp/model-runner-adapter-campaign-focused.log`,
`/tmp/model-runner-adapter-campaign-full-suite.log` and `/tmp/model-runner-adapter-campaign-repository.log`.

## Embedded inference attachment

`Model_Runner.Inference.Open_Options` now exposes up to eight ordered runtime adapter paths and finite
positional scales, plus tightenable native adapter bounds. Non-CPU requests, empty paths, nonfinite scales,
invalid hard limits and excessive file counts fail before model IO or device acquisition. Files parse with
the caller's model bounds, cancellation token and load observer, then attach through the existing native CPU
loader before workers and the generation context open. Every source closes after its matrices are owned.
If any attachment fails, the entire new public session closes and retains the primary typed diagnostic.

Provenance separates adapter count and owned matrix/descriptor bytes from backbone/auxiliary size and file
count. The existing explicit model SHA-256 still hashes backbone and auxiliary bytes; the engine fingerprint
binds runtime attachments and their arithmetic identity. No adapter request changes the base hashing contract.
The API selects runtime attachment explicitly; it does not add embedded F32 merging or device support.

The focused adapter suite passes **15/15**, including four public API regressions: generation with zero and
active scales, ordered stacking and identity, reuse after adapter deletion/replacement, backbone SHA stability,
quantized-base cleanup after a malformed later attachment, loading bounds, missing/malformed files, early
refusal and cancellation during adapter parsing followed by healthy reopen. Existing independent numerical
tests continue to qualify projection and logit correctness.

The independent inference consumer builds against the standalone inference and framework projects, and
passes both ordinary and adapter-backed schema completions with four workers. Its adapter path contains
spaces. The inference project's explicit source list now includes the three runtime adapter subunits; this
checks packaging outside the main application's source discovery. Consumer logs are
`/tmp/model-runner-embedded-adapter-consumer-base.log` and
`/tmp/model-runner-embedded-adapter-consumer-runtime.log`; the build log is
`/tmp/model-runner-embedded-adapter-consumer-build.log`. These use deterministic fixtures, not trained adapters.

The repository audit completed **30,562 checks with the same 19 known failures**; its log is
`/tmp/model-runner-embedded-adapter-repository.log`. Final application and test builds succeeded without new
warnings. A shared Cryptolib archive race during rebuilding was resolved by a serial retry; no dependency
sources changed. Build logs are `/tmp/model-runner-embedded-adapter-root-final.log` and
`/tmp/model-runner-embedded-adapter-tests-final.log`.
The final mandatory full suite passes **965/965**, with zero failed assertions and unexpected errors;
its log is `/tmp/model-runner-embedded-adapter-full-suite.log`. Focused results are retained in
`/tmp/model-runner-embedded-adapter-focused-final.log`.

## Before/after CPU execution without adapters

The [matched no-adapter campaign](harness-adapter-no-adapter-check.md) compares the pre-adapter engine at
commit `a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b` with the current engine using identical Ada probe source.
Both engines use matching release compiler flags; the speed harness remains development-built as in the
existing tests crate. The original engine and build-policy files were verified against a fresh commit archive.
The timed speed-harness section is identical. Shared dependency archives match across builds.

Two batches of seven pairs use the local Qwen3.5 0.8B Q8_0 model, four workers, batch sixteen, context 512,
F32 arithmetic, exact cache, no repacking, no panel-file cache, seed one, temperature zero, no drafting and
no adapter. Each sample performs a full untimed warm-up before its measured generation. Order alternates
within each batch and the second batch reverses the starting arm. Every measured run reads 100 prompt tokens,
generates sixteen tokens and produces the same output digest. All input, probe and binary hashes remain stable.

Paired median prompt time changes are **+0.6% and -1.9%**; decode changes are **+1.1% and -0.9%**. Both
batches pass the predeclared +5% boundary for both phases. No material slowdown is observed in this local
release-engine configuration. All raw samples remain in
[the evidence record](harness-adapter-no-adapter-evidence.json), including large wall-time stalls in each arm.
The medians do not establish zero overhead, significance, tail-latency guarantees or another configuration's
performance. RSS is unavailable. Two preliminary development-engine pairs were stopped on identifying the
profile mismatch and are retained separately; they are not included in this gate.

Normal Alire application and test builds currently fail because the external database manifest pins a remote
Cryptolib while this project pins the local worktree. Both application and test targets build successfully
through direct GPR invocation using the already-resolved local project paths. No external manifest is changed
and neither arm adopts a different Cryptolib. Build logs are `/tmp/model-runner-no-adapter-root-build.log`,
`/tmp/model-runner-no-adapter-tests-build.log`, `/tmp/model-runner-no-adapter-root-direct-build.log` and
`/tmp/model-runner-no-adapter-tests-direct-build.log`.

The current audit completed **30,569 checks with 53 failures**: the 19 existing findings, 33 host-body
compilation checks blocked by that same pin-resolution error, and one compiler-health failure because none
of those attempts reached the compiler. The host checks are blocked, not passed or waived. Its log is
`/tmp/model-runner-no-adapter-repository.log`. It reports no additional probe or evidence finding.
The mandatory full suite passes **965/965**, with zero failed assertions and unexpected errors; its log is
`/tmp/model-runner-no-adapter-full-suite.log`. The temporary release configuration was restored to the
original generated files after validation. Preserved release probe binaries and their digests are recorded
in the evidence file.

## Repository audit boundary

The repository audit is a separate gate from the passing AUnit suite. Existing audit failures must not be
hidden by marking stale measurements as current. A pristine archive of HEAD
`a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b` was inspected under `/tmp/model-runner-harness-baseline`.
Its fingerprint comparison already found eleven stale benchmark groups. Only that disposable copy was
restamped to inspect the differences; working-tree benchmark records were not changed or signed off.

The initial audit also found missing documentation and unused public declarations in unchanged
`model_runner-cli-headless_work.ads`, two fixture-path violations in unchanged `tests-framework_cases.adb`,
and build-warning/evidence failures. Missing API tags and text normalization introduced by this change were
corrected, and a changelog entry was added. The ancestry check compares committed history: writing that entry
does not change its verdict on HEAD. No commit was made as part of this execution.

Compilation records were refreshed, including bodyless test specs and the existing release-checker tools.
A failed exploratory attempt to compile a subunit by itself left an orphan diagnostic. After its parent compiled
successfully in the normal build, that obsolete diagnostic was moved to `/tmp/model-runner-harness-failed-subunit.*`.
The final continuation audit completed **30,432 checks with 19 failures** (exit 1):

| Remaining finding | Failures |
| --- | ---: |
| Unchanged headless API documentation and unused declarations | 4 |
| Unchanged hard-coded fixture paths | 2 |
| Existing pinned `ada_quality` warning above its recorded allowance | 1 |
| Eleven benchmark groups already stale in HEAD | 11 |
| Committed changelog ancestry | 1 |

Current compilation evidence and the new tooling's documentation/normalization checks no longer fail.
The adapter changes also pass the model-interpreter dependency checks. `Tensor_Non_Finite_Value` is now reached
by native merger tests and was removed from the unreached-error registry. The latest audit log is
`/tmp/model-runner-adapter-contract-verified-repository-check.log`. The repository audit remains red;
the passing AUnit result does not replace it. No benchmark figures or dependency-warning allowances were
restamped in the working tree.
