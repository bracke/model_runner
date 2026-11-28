# Native Inkling DSpark drafting

The fixed 58-tensor Q8 DSpark variant runs inside the existing Ada CPU engine.
The target remains Inkling 2 Mini Q4_K_M with Q4T KV storage and the explicit
integer-activation performance profile. The drafter is optional; throughput
and the selected default are recorded in [the evidence](inkling2-dspark-native-evidence.json).

## Execution and ownership

`Llama.Prepare` accepts an optional prepared `Target` for `dflash`. The loader
validates every tensor, shape, format, target tap and shared token identity.
It borrows the target embedding and output views, keeps the drafter's Q8_0 and
BF16 matrices mapped, and converts only its small normalization/bias vectors.
The target model and byte source must outlive the drafter. Closing a borrowed
target is refused until its dependent drafter has closed.

`Evaluate_Features` captures logical inputs 5, 23 and 41 and the normalized
output input at 48. Its temporary request does not install a tensor watcher
or disable normal batched execution. `Draft_Feature_Room` borrows session-owned
room for 512 token-major four-feature rows; callers must not free it.

`Inject_Draft_Context` applies the exported, already normalized feature mixes,
RMS normalization, separate context K/V projections, per-head K normalization
and split-pair RoPE. It appends to the existing session cache and publishes
history, context and Markov features only after every layer succeeds.

`Propose_Draft_Block` evaluates the assured next target token and up to seven
learned mask rows through three dense blocks. Attention includes the complete
noise block; local layers share the anchor's window. No noise KV is committed.
The recurrent Markov head reads the previous token, rank state, normalized
hidden row and last accepted target feature. Its BF16 matrix inputs use
nearest-even BF16 conversion, and softcap 30 follows the correction.

Generation uses its existing sampler and verifier. It captures verification
features, rewinds rejected target tokens, and injects only accepted rows.
Paired in-memory prefixes are retained. A target prefix restored without its
matching draft context is replayed to obtain real features. Generated tools
and structured output retain the existing target/harness validation path.

## Supported limits

The initial adapter supports CPU target and drafter execution and greedy
verification. Other DFlash variants, sampled drafting, vision, context shifting,
changed RoPE configuration and standalone drafter evaluation are rejected.
The ordinary target inference paths retain their existing backend support.

The target cache stays Q4T. The small auxiliary drafter cache initially uses
exact storage; its context KV, feature buffers, Markov context and scratch are
included in the existing session memory plan and limit. Both source caches can
reset, rewind and close. Standalone drafter snapshots are explicitly refused;
the target's existing durable cache remains usable through feature replay.

The BF16 pair-dot kernel extends the existing tensor backend. Dispatch checks
CPUID and operating-system register state before using the instruction; its
fallback and partial-row bounds have focused coverage. CPU capability answers
are cached once, avoiding a serializing CPUID query for every attention value
or exponential. No external model executor is linked or invoked by inference.

## Independent validation

The drafter reference is ggml-org/llama.cpp
`4c7344447cb1727f1e2f982febc99a8f88dcb77f`. Native target features are checked
separately against the existing canonical target fixtures from
`29b52d398b294509746ec0a3f28948a3107c0213`, with `GGML_LLAMAFILE=OFF`.
The newer upstream target changed clipping and residual reductions as well as
build-dependent arithmetic. Both initial combined-reference tap mismatches
are retained. They do not justify changing the already qualified native target
mathematics or enlarging a tolerance. Full drafter conformance therefore uses
fixed independent newer-reference feature inputs; target capture uses the
original independent target fixture. End-to-end Q4T generation checks exact
agreement with ordinary native target verification. This is component
conformance, not a claim that the two upstream target versions are identical.

The small fixtures exercise three injected positions, seven proposals and a
1,030-position prefix crossing the local window. The backbone and context
come from the independent reference; the small Markov chain is independently
computed with NumPy and BF16 input rounding. A separate fixture comes directly
from the pinned BF16 dot kernel and includes nearest-even ties.

Full-checkpoint tests compare all context K/V, Markov features, hidden states,
raw logits, corrected logits, proposal IDs and real native target taps.
Numerical bounds remain `1e-5 + 2e-5 * abs(expected)`; IDs and scheduling are exact.
Tests also cover scalar/batched injection, repeat proposals, cancellation,
rewind across a local-window boundary, reset, memory refusal, malformed metadata,
weight ownership and Q4T generation/prefix reuse. Full results and the single
throughput trial are in the evidence file.

The target and drafter hashes remain those in the
[compatibility audit](inkling2-dspark-compatibility.md). Checkpoints remain
outside Git; the fixture directories contain only small synthetic weights and
independent outputs. Earlier fixtures and the protected integer-kernel source
remain unchanged.

## Measured CPU profile

One warmup and one measured pass used 2,048 prompt tokens, 16 output tokens,
eight threads, batch 128, context 2,176, explicit int8 activations, no repack,
Q4_K_M weights and Q4T target cache. Native DSpark achieved **26.06 tok/s
prefill and 12.69 tok/s decode**, compared with **26.19 / 10.26 tok/s** for the
previous four-token context lookup. All 14 proposals were accepted and output
digest `4f1d96c1112e7b25` was unchanged. Peak resident memory was 5.85 GiB.
This is one short decode sample: about 24% faster decode on this workload,
with effectively unchanged prefill, rather than a general-workload claim.

The existing `--draft-model /home/bent/models/Inkling-2-Mini-dspark-Q8_0.gguf`
option selects the companion; use `--draft-tokens 7`, CPU, greedy sampling and
Q4T target storage. Automatic context lookup is disabled for this feature-based
block drafter; an explicitly incompatible lookup request remains an error.
Ordinary draft-model policy and the default activation profile are unchanged.
The first setup attempt was refused before processing tokens; its logs and the
subsequent policy fix are preserved. No completed unchanged trial was repeated.

## Parallel block attention

Each anchor/noise position now runs through the existing CPU pool with its own
scores, 64-lane value accumulators, output and diagnostic. Prefix and noise KV
are immutable during that job. A head retains its original score order,
softmax reduction and value fold. Workers settle before error propagation or
the following projection. The existing session plan budgets all eight scratch
slices, adding 284 KiB at context 2,176; no buffer is allocated in attention.

The 1,030-position fixture now requires exact serial/parallel logits across the
local-window boundary. Full published-drafter and Q4T lifecycle comparisons
also pass, with existing numeric bounds and fixtures unchanged.

One warmup and one measured 2,048/16 pass, otherwise the same seven-proposal
DSpark profile, gives **26.07 tok/s prefill and 14.34 tok/s decode**, versus
**26.06 / 12.69 tok/s** before sharing attention: about **13% faster decode** in
this single short sample. All 14 proposals are accepted and output digest
`4f1d96c1112e7b25` is unchanged. Peak resident memory is 5.86 GiB. Q4_K_M weights,
Q4T target cache, explicit int8 activations and existing memory limits remain.
See [the attention evidence](inkling2-dspark-attention-evidence.json).


## Fused vocabulary readout

The Markov vocabulary projection and its finishing stages share one CPU job.
Workers reuse the existing tensor kernels in 512-row tiles, then add Markov
bias and raw logits in their original order, apply the same scalar tanhf
softcap, check finiteness and retain a local winner. A bounded protected
reduction preserves lowest-token-ID ties after softcap; the next recurrent
step starts only after all workers settle. No session buffer or expanded
weight copy is added. Tensor watchers and attached adapters retain the ordinary
Product path. Both readout paths pass the full independent corrected-logit
and proposal fixture, with existing numerical bounds unchanged.

One warmup and one measured 2,048/16 pass, with the same CPU/Q4_K_M/Q4T/int8,
no-repack, seven-proposal profile, gives **26.03 tok/s prefill
and 14.57 tok/s decode**, versus **26.07 / 14.34 tok/s** previously.
Decode improves **1.6%** in this short single sample. All 14 proposals are
accepted and output digest `4f1d96c1112e7b25` is unchanged. Peak resident memory
is 5.85 GiB. See [readout evidence](inkling2-dspark-readout-evidence.json).


## Grouped dense projections

The existing grouped-product route now handles contiguous CPU batches. DSpark
query/key/value, gate/up and context key/value projections share one input
packing and one worker job. Packed batches keep the full team, matching the
ordinary batched product; single-vector tuning is unchanged. Observed or
adapted batches retain per-matrix products. Arithmetic-role eligibility is
checked before sharing a packed input. No session buffer or expanded weight
copy is added.

Direct Q8 tests require exact serial/grouped equality for 1, 8 and 33 inputs,
two and three matrices with unequal row counts, shifted output bounds and both
arithmetic-role modes. The full model test independently checks the ordinary
watched path and a fresh grouped context/decoder path against existing logits
and proposal fixtures. All earlier fixture bytes and numeric bounds remain.

One warmup and one measured 2,048/16 pass, with the same CPU/Q4_K_M/Q4T/int8,
no-repack, seven-proposal profile, reports **26.05 tok/s prefill
and 14.70 tok/s decode**, versus **26.03 / 14.57 tok/s** previously.
This is a small **0.9%** decode increase in a single short trial, not an
established general-workload gain. The speed tool's own rates are primary;
derivations from printed three-decimal timings are retained separately.
All 14 proposals are accepted and output digest `4f1d96c1112e7b25` is unchanged.
Peak resident memory is 5.86 GiB. See
[grouped-projection evidence](inkling2-dspark-groups-evidence.json).


## Strided score experiment (rejected)

A native candidate reused query loads across strided 128-component key rows
in groups of four, preserving the reference FP32 reduction and scale order.
Independent exact-bit fixtures, full DSpark logits/proposals and Q4T checks
passed. The implementation and its new fixtures are preserved in the
[candidate source archive](../artifacts/inkling2/obj/dspark-scores/final-source.tar).

One warmup and one measured 2,048/16 CPU/Q4_K_M/Q4T/int8 trial reported
**26.12 tok/s prefill and 14.51 tok/s decode**, versus the previous
**26.05 / 14.70 tok/s**. Output digest and all 14 accepted proposals
matched. This single sample did not demonstrate a decode improvement, so
the candidate was removed and the earlier grouped-projection implementation
restored exactly. The earlier 14.70 tok/s remains a historical measurement;
the restored version was not timed again. All 197 prior fixture files are
unchanged. See [rejected-candidate evidence](inkling2-dspark-scores-evidence.json).

## GSQ-RCO IQ3_S trial

The IQ3_S checkpoint is pinned to revision
`f0da1097633dd7c2f5733e4077cff861be122245`, 11,425,259,648 bytes,
SHA-256 `8a3515374c3cd9b65a1677b17e805bb1e32df8e98756e5f0d2fe1837d62aa4cb`.
The downloaded header matches all 704 published tensor assignments. Its
expert down matrices use IQ4_NL in 21 layers and Q2_0 in three; the previous
Q4_K_M file uses Q8_0 in 12 and Q5_0 in 12.

Native row-major integer products for both small-block formats now use the
existing quantization package. They retain the reference's two FP32 FMA
chains and reduction, handle signed-minimum activation bytes, and decline
invalid extents or unsupported ISA settings before writing output. Reference
activation half scales are consistent across packing, grouping, reuse and
expert batches. Incompatible packing classes retain ordinary dispatch.
Q4T, physical expert storage, DSpark and the default model remain unchanged.

Independent GGML fixtures require exact output bits at widths 64, 128, 1152
and 2304, including shifted arrays, padded rows, strided vectors, accumulation
and guards. Grouped/serial tests cover 1, 2, 8 and 33 inputs and mixed packing
classes. All 197 previous fixture files and the protected shared kernel file
are unchanged. A generator initialization mistake is preserved in the
experiment evidence; corrected fixtures explicitly initialize GGML's CPU
half-to-float table. No tolerance was widened.

The complete checkpoint passed its pinned SHA-256 check and native metadata
inspection. One warmup and one measured 2,048/16 pass, CPU/Q4T/int8,
no-repack and seven DSpark proposals, reports **22.24 tok/s prefill
and 14.10 tok/s decode**, versus the earlier Q4_K_M result of
**26.05 / 14.70 tok/s**. Decode changed by -4.1% in this one
short trial. Peak resident memory was 4.30 GiB. Proposed
14 tokens and accepted 14; output digest is
`4f1d96c1112e7b25`. Different quantized weights can change both outputs
and draft acceptance. This does not establish a repeatable speed or quality
difference across workloads. Default model selection is unchanged.

The changed-engine fixed two-by-seven campaign passes. New primitive outputs
match independent GGML exactly, and existing architecture, full Q4T and
DSpark regressions pass. This trial does not add a full-checkpoint GSQ
differential fixture or claim release qualification. See
[trial evidence](inkling2-gsq-rco-evidence.json).


## Selected GSQ-RCO decode reuse

The main native engine now decodes each IQ4_NL or Q2_0 compressed block once
for two or four input vectors. Each vector keeps its own reference FP32 FMA
chains and final reduction. Single-vector work and trailing vectors retain
the ordinary operation. No persistent buffer or expanded-weight cache is
added; Q4T and default model selection are unchanged.

The independent exact-bit fixtures cover widths 64, 128, 1152 and 2304,
strided inputs, padded rows, shifted bounds, accumulation and signed-minimum
bytes, including two/four-vector batches and tails. Grouped batches preserve
serial results and fall back for incompatible scale classes. Additional
validation covers the new checkpoint's nine-block grid rows with all seven
grid formats, both packing modes and each available CPU compilation. The
integrated build passes focused checks and all 43 native Inkling cases. Its
quantization instruction sections are byte-identical to the measured
candidate. All 197 earlier fixture files and the protected kernel source
remain unchanged.

| Configuration | Prefill (tok/s) | Decode (tok/s) | Peak RSS (GiB) |
|---|---:|---:|---:|
| Earlier Q4_K_M / Q4T | 26.05 | 14.70 | 5.86 |
| IQ3_S / Q4T, scalar-vector kernel | 22.24 | 14.10 | 4.30 |
| IQ3_S / Q4T, selected two/four-vector kernel | 23.70 | 14.58 | 4.32 |

One warmup and one measured 2,048/16 pass per completed candidate, CPU,
eight threads, batch 128, context 2176, int8 activations, no repack and seven
DSpark proposals. IQ3_S prefill improves by 6.6% and decode by 3.4% in
this single trial. Output digest `4f1d96c1112e7b25` and all 14 accepted
proposals match. These observations do not establish repeatability. The
Q4_K_M row is an earlier measurement with different weights, not a new paired
comparison. Published GSQ quality scores were not independently rerun.

The four-only intermediate candidate was preserved and superseded before
measurement; it was not timed. See
[selected implementation evidence](inkling2-gsq-selected-evidence.json).

A subsequent trial split reference grid batches of 9–16 vectors into existing
register-kernel groups. It measured 23.68 tok/s prefill and 14.79 tok/s decode
with the same output digest and 14/14 proposals accepted. Prefill did not
improve over 23.70 tok/s; decode used the unchanged path. The candidate was
rejected and the selected sources and executables restored exactly. Its new
cross-path test also omitted explicit byte-kernel enablement, so its passing
result does not qualify candidate arithmetic. No fixture or tolerance changed.
See [rejected grid-batch trial](inkling2-gsq-grid-medium-evidence.json).

The retained IQ4_NL signed-dot simplification applies the activation sign to
weights (whose minimum is -127) and uses unsigned activation magnitudes,
including 128 for a -128 byte. This replaces two biased VNNI products and a
correction with one product, preserving every FP32 FMA chain and fold. Exact
independent fixtures, 3,456 exhaustive signed-edge batches and the focused
backend/native suite pass. No persistent allocation or public API was added.

Its single 2,048/16 trial measured **23.76 tok/s prefill and 14.80 tok/s decode**
versus 23.70 and 14.58 tok/s. These small differences do not establish a speedup;
the earlier rejected candidate's unchanged decode path already measured
14.79 tok/s. Output digest and 14/14 accepted proposals match. Q4T, int8
activations, no repack and the seven-proposal setting remain. See
[signed-dot evidence](inkling2-gsq-signed-dot-evidence.json).


## Six GSQ candidates and the retained implementation

The retained CPU implementation reuses Q4T key/value decoding across eight
queries, with the existing four/two/one-query fallbacks and unchanged reference
reduction order. The eight-row score workspace is included in memory admission;
this adds four FP32 score rows per head and context position. Compressed model
weights, physical expert ownership and Q4T storage remain.

The final built and qualified executable measured **24.24 tok/s
prefill and 14.91 tok/s decode**, versus the prior selected
23.76 and 14.80 tok/s. Output digest `4f1d96c1112e7b25` and 14/14 accepted
proposals match. This is one warmup and one measured 2,048/16 pass, with int8
activations, eight CPU threads, batch 128, context 2176, no repack and seven
DSpark proposals. These short single trials do not establish repeatability.

The configuration comparison used one frozen preceding build of the retained
CPU implementation. Eight threads with batch 128 was fastest:

| Threads | Prefill batch | Prefill (tok/s) | Decode (tok/s) |
|---:|---:|---:|---:|
| 8 | 128 | 24.40 | 15.38 |
| 6 | 64 | 14.44 | 9.36 |
| 8 | 64 | 23.19 | 15.09 |
| 12 | 128 | 16.93 | 10.65 |

Small-block activation/packing fusion measured 23.70/14.41 tok/s, and combined
grid-row tiling plus format-aware scheduling measured 23.61/14.55 tok/s. Their
speed changes were removed. Validated direct small-block destinations and
activation-contract registration remain. The two grid/scheduling changes were
not timed independently.

Native Vulkan reference products now cover IQ4_NL, Q2_0, IQ3_S and IQ3_XXS,
including fused expert dispatch. Unsupported mixed-format experts retain CPU
fallback. Device slices preserve prepared expert roles and activation contracts.
Independent small-block GPU products are exact; grid products satisfy the
existing FP32 envelope without widening it. Native expert and cache lifecycle
regressions pass on the Radeon 780M. End-to-end GPU timing and its limitations
are recorded in the evidence; component coverage alone is not a full-model
throughput or conformance claim. DSpark's CPU-target requirement is preserved.

All 45 native Inkling cases and five focused backend/reference checks pass in
the final build. All 228 earlier Inkling fixture files and the protected
quantization kernel source remain unchanged. Eight synthetic grid fixture files
include pinned independent-reference provenance and reproduction sources. No
new runtime dependency or model default is introduced. See the
[six-candidate evidence](inkling2-gsq-six-evidence.json) and
[current selection](inkling2-gsq-selected-evidence.json).


## Indexed inputs, stable routing and compiler profiles

Native small-block products accept validated indexed activation rows. The CPU
backend tries compatible direct reference products before allocating gathered
activation tables. Matching Inkling layers use a stable single-pass 8-of-128
selection with unchanged score weighting and lowest-ID ties.

Direct IQ-grid output, paired gate/up kernels and compact grid scale metadata
were implemented and independently qualified. Both combined grid trials lost
prefill throughput, so those production changes were reverted. Their source,
reference comparisons and measurements are retained in the evidence. All seven
formats retain new independent synthetic GGML regression fixtures.

| Candidate | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Prior selected build | 24.24 | 14.91 |
| 01-native | 21.90 | 14.46 |
| 02-tiled | 23.77 | 15.08 |
| 03-selected | 25.18 | 15.09 |
| 05-pgo | 24.66 | 15.47 |

The selected build is `03-selected`: **25.18 tok/s prefill and
15.09 tok/s decode**. Every comparison uses a 2,048-token
prompt, 16 output tokens, eight workers, batch 128, Q4T, int8 activations,
context 2176, no repack and seven DSpark proposals. All output digests are
`4f1d96c1112e7b25`, with 14/14 proposals accepted. Each result is one warmup
and one measured pass; differences do not establish repeatability.

Profile-guided compilation is opt-in: set `MODEL_RUNNER_PGO=generate` and
`MODEL_RUNNER_PGO_DIR` to an absolute writable directory, build production and
tests with the existing Alire/GPR commands and `gprbuild -s`, and collect native
runs. Rebuild both with `MODEL_RUNNER_PGO=use` and the same directory, then
run numerical qualification before timing. Missing profiles are errors. Five
CPU units share this policy in the executable and reusable inference project.
Pass `-s` in every profiling phase and when returning to `off`, so changed
compiler switches trigger recompilation. Default mode is `off`; target gates and arithmetic switches
remain. Generate mode uses atomic counters; use mode needs no profile files at
runtime and contains no gcov instrumentation.

This trial trained with 128 prompt tokens and 16 output tokens on one worker,
plus focused reference tests. Training throughput is not a comparison result.
The final use build was validated and measured with the full 2,048-token prompt
and eight workers. Profiles and compiler flags are pinned in the
[next-six evidence](inkling2-gsq-next-six-evidence.json). All 236 previous
Inkling fixture files and the protected quantization source remain unchanged.
No new model runtime or default model selection is introduced.


## Shared packing, grouped attention, compact verification and matched PGO

All four candidates were implemented and evaluated. Session-owned layer packing
reuses bounded allocations, grouped DSpark attention shares prefix key/value
loads, and compact greedy verification preserves target feature taps and recovers
the distribution needed for rejected proposals before rewind. Focused arithmetic,
feature, cancellation and lifetime tests pass. The first three were timed together;
the results do not attribute speed changes to individual operations.

| Candidate | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Preceding selection, earlier run | 25.18 | 15.09 |
| 01-native | 22.88 | 14.84 |
| 04-pgo-decoder | 24.68 | 15.83 |
| 05-baseline-confirmation | 24.28 | 15.04 |

The selected build is `04-pgo-decoder`: **24.68 tok/s prefill and
15.83 tok/s decode**. The combined candidate and selective profile use are retained.
The Q4T cache, compressed IQ3_S model, Q8 DSpark companion, eight workers,
batch 128, 2,048-token prompt, 16 generated tokens and seven proposals are
unchanged. Each timed result uses one warmup and one measured pass; outputs
match digest `4f1d96c1112e7b25`, with 14/14 proposals accepted. Short, single
trials do not establish a repeatable gain.

`MODEL_RUNNER_PGO_UNITS=all|decoder|quantization` now selects which units
receive profile switches in both `generate` and `use` modes. `decoder` covers
the Llama adapter and CPU backend; `quantization` covers tensors and the two
integer-product units. Default is `all`; default PGO mode remains `off`. Use
the existing Alire/GPR builds with `gprbuild -s` in every phase, including
returning to `off`. Keep the same absolute `MODEL_RUNNER_PGO_DIR` for
generation and use, run qualification before timing, and regenerate profiles
after source changes. The executable and inference library share this policy.

Full five-unit atomic training was stopped after more than twelve minutes
of instrumentation overhead. Selective decoder/CPU training completed on the
actual eight-worker, 2,048/16 workload and preserved the expected output. The
other three units were compiled normally in this completed trial. Its profile-use
build passed all 55 focused tests before timing; training timings are not speed
results. The paired baseline confirmation uses the unchanged frozen preceding
binary under current conditions. No production gcov instrumentation remains.
All 254 existing Inkling fixture files and the protected quantization source
are unchanged. No new runtime or
model default is introduced. See the [four-candidate evidence](inkling2-gsq-four-evidence.json)
for source archives, profiles, hashes, rejected candidates and limits.


## Deferred copies, vector arithmetic and drafter scheduling

Six further native candidates were implemented together: deferred fallback-only
MoE input gathering, vector reference exponentials and SiLU, per-block rotary
table reuse, token/KV-group attention work sharing, logical-visit scheduling
plans, and tiled Q8 projection/residual epilogues. The combined candidate is retained.
All use the existing CPU pool, tensor operations and session lifecycle. Weights
remain compressed and physically shared across visits; Q4T is retained.

| Build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Preceding selected build | 24.68 | 15.83 |
| Six-change build, selected | 24.65 | 15.71 |
| Frozen preceding build, paired check | 24.63 | 15.40 |

Each measurement uses one warmup and one measured 2,048-token prompt with
16 generated tokens, eight CPU workers, batch 128, int8 activations, context
2176, no repack and seven DSpark proposals. Output digest remains
`4f1d96c1112e7b25`, with 14/14 accepted proposals. Single trials do not
establish repeatability or individual contributions. Fresh selective profiles
were collected for the changed decoder and CPU backend using the actual
eight-worker, 2,048/16 workload. Preserve the environment pinned in the
[evidence](inkling2-gsq-follow-six-evidence.json) when rebuilding this selection;
default PGO mode remains `off`, and profile-use binaries contain no counters.

The vector polynomial and activation match scalar bits across shifted/guarded
slices, tails and saturation/signed-zero boundaries. Cached rotations match
the original angle and FMA order. Synthetic Q8 products cover 139 rows and
batches 1..8, including tile tails, exact residual additions and cancellation.
Existing independent short/long drafter fixtures cover intermediate values,
serial/parallel results, rewind and reinjection. Final qualification passes
56 focused cases, including Radeon component regressions. All 254 previous
Inkling fixtures and the protected quantization source are unchanged. No full
checkpoint conformance, autonomous-coding benchmark or release-gate rerun
is claimed by these optimization checks.

New scratch is bounded and budgeted. Rotation tables cover eight positions;
attention reuses at most eight worker slots, and projection workers use
128-row tiles. Scheduling descriptors are separate for logical visits and
validate the full route key on every use; expert tensors keep physical IDs.
Retained projection packing is budgeted for the largest query, embedding or
feed-forward width and freed at session close.


## Target softmax, vocabulary work and balanced residual ranges

Six candidates were implemented: compatible reference-target softmax
vectorization, omission of the unused drafter anchor vocabulary row, balanced
residual row ranges, local greedy Markov product tiles, fused Q4T probability
normalization and expert-view preparation before dispatch.

Q4T's target attention uses a different double-exponential calculation from
the drafter polynomial. That calculation is preserved. Polynomial reuse is
restricted to reference-fold attention and is not presented as a Q4T speed
gain. The Q4T change removes its separate normalization pass while preserving
the binary32 multiplication before widening and the original value-sum order.

| Build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Preceding selected build, earlier run | 24.65 | 15.71 |
| Six-change candidate | 24.72 | 16.32 |


The selected build is `02-pgo`. Each timed result uses one warmup and
one measured 2,048-token prompt, 16 generated tokens, eight workers, batch
128, int8 activations, Q4T, context 2176, no repack and seven DSpark proposals.
Output digest remains `4f1d96c1112e7b25`, with 14/14 accepted proposals.
Six changes and fresh selective PGO were timed together; no individual
contribution or repeatability is established by these short single trials.

Final qualification passes 56 focused cases. Expanded tests cover
untouched anchor/guard rows, exact proposal projections for batches 2..8,
greedy/full-output agreement for proposal lengths 1..7, uneven residual
ranges, cancellation and existing independent decoder/drafter fixtures.
All 254 existing fixtures and the protected quantization source are unchanged.
No new full-checkpoint independent conformance, coding-quality benchmark,
whole-engine audit or release-gate run is claimed.

Expert views are resolved after all metadata admission, preventing eviction
from invalidating captured scale pointers before dispatch. Only descriptors
are copied; expert weights and their cache keys keep physical ownership.
Descriptor storage and bounded greedy tiles are included in the memory plan.
Full output, observers, adapters, finite-value checks and global lowest-ID
ties keep their existing behavior. The anchor still participates in all
attention/feed-forward computation; only its unused vocabulary row is omitted.

The [evidence](inkling2-gsq-more-six-evidence.json) pins sources, binaries,
profiles, build settings and measurements. Rebuild with its recorded
selective-PGO environment; default PGO mode remains `off`. Production binaries
contain no profiling counters. IQ3_S weights and Q4T cache storage remain.


## Six further candidates: measured and reverted

Deferred MoE input gathering, vector drafter softmax/activation, per-block
rotation reuse, token/KV-group attention jobs, logical-visit scheduling plans
and tiled Q8 projection/residual epilogues were implemented together.
All 56 focused tests passed, including exact arithmetic/tails, rotary tables,
139-row Q8 residual tiles, cancellation and existing long-context drafter
reference and recovery cases. Fresh decoder/CPU profiles were trained on
the actual eight-worker, 2,048/16 Q4T workload.

| Build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Six-change candidate | 24.58 | 15.25 |
| Frozen preceding build, paired check | 24.75 | 15.68 |

The preceding build is selected and its sources and exact measured binaries
are restored. Dependent units were rebuilt with its original selective-PGO
environment and all 56 focused checks pass in the installed build.
The candidate's source, tests, profiles and measurements are preserved in the
[evidence](inkling2-gsq-context-six-evidence.json). The six changes were timed
together; the result does not attribute a regression to any individual change.

Each result uses one warmup and one measured 2,048-token prompt with 16
generated tokens, eight workers, batch 128, int8 activations, Q4T, context
2176, no repack and seven proposals. Both match output digest
`4f1d96c1112e7b25` and 14/14 accepted proposals. Single trials do not
establish repeatability. All 254 existing Inkling fixture files and the
protected quantization source are unchanged. No new runtime, persistent
activation cache or model default is retained by this experiment.


## Seven-vector Q5_K projection: initial 16-token trial (superseded)

The selected IQ3_S checkpoint stores its vocabulary matrix as Q5_K,
2304 columns by 201024 rows. A candidate used one existing eight-vector tile
instead of 4+2+1 for seven native, unpaired vectors. The spare lane repeated
the last mapped input; only seven outputs were stored. Validation and result
maps continued to use the real count. Extra local address storage was 24 bytes.
The candidate was initially reverted after this short trial; the longer
comparison below supersedes that decision.

| Measurement | Before (tok/s) | Candidate (tok/s) |
|---|---:|---:|
| Vocabulary projection only | 349.4 | 427.1 |
| Full 2048/16 prefill | 24.75 | 24.71 |
| Full 2048/16 decode | 15.68 | 15.62 |

Projection measurements each used one warmup and twelve timed projections,
eight workers and the actual quantized matrix. All 1,407,168 output values
matched bit for bit. This projection throughput is not full-generation
throughput. Each full result used one warmup and one measured 2048/16 pass,
eight workers, batch128, int8, Q4T, context2176, no repack and seven DSpark
proposals. The output digest and 14/14 acceptance were unchanged. Short
single trials establish no confidence interval or repeatability claim.

The candidate passed 58 focused cases, including new independent GGML fixture
checks for seven-vector products, input/result maps, shifted bounds, output
guards and truncated weights. Existing CPU/Vulkan component checks were
enabled. The original source, exact measured binaries and consistent build
objects are restored; 56 focused cases pass on the restored executable.
All 254 existing fixtures and the protected parent kernel source are unchanged.
Existing two-unit PGO profiles were reused because their profiled decoder and
CPU backend sources were unchanged; the candidate kernel compiled normally.
IQ3_S weights and Q4T storage were preserved. No full release-gate run is claimed.

The component result was faster, but the full inference trial showed no
overall benefit. The 0.06 tok/s decode difference does not establish a
statistical regression. [Evidence](inkling2-gsq-head-seven-evidence.json)
preserves candidate sources, tests, binary hashes, output hashes, compiler
profile provenance and commands for further work.


## Seven-vector Q5_K projection: longer decode comparison

This longer comparison supersedes the earlier 16-token decision. The candidate
is retained, with a 1.7% decode improvement in this paired trial.

The selected IQ3_S checkpoint stores its vocabulary matrix as Q5_K,
2304 columns by 201024 rows. For seven live proposal vectors, the native
unpaired kernel now uses one existing eight-vector tile instead of 4+2+1.
The spare lane repeats the last mapped input. Only seven outputs are stored;
validation and result maps continue to use the real count. Quantized weights
and Q4T cache storage remain unchanged. Extra local address storage is 24 bytes.

| Measurement | Before (tok/s) | Candidate (tok/s) |
|---|---:|---:|
| Vocabulary projection only | 349.4 | 427.1 |
| Full 2048/512 prefill | 24.69 | 24.68 |
| Full 2048/512 decode | 15.38 | 15.64 |

Projection measurements each use one warmup and twelve timed projections with
eight workers and the actual quantized matrix. All 1,407,168 output values
match bit for bit. Projection throughput is not full-generation throughput.
Each full inference result uses one warmup and one measured pass, eight
workers, batch128, int8, Q4T, context2688, no repack and seven DSpark proposals.
The output digest and 448/448 accepted proposals are unchanged. These short
single trials establish no confidence interval or repeatability claim.

Qualification passes 58 focused cases, including new independent GGML fixture
checks for seven-vector products, input/result maps, shifted bounds, output
guards and truncated weights. Existing CPU/Vulkan component checks were
enabled. All 254 existing fixture files and the protected parent kernel source
are unchanged. The existing two-unit PGO profiles are reused because the
profiled decoder and CPU backend sources are unchanged; the modified kernel
is compiled normally. No full release-gate run is claimed.

[Evidence](inkling2-gsq-head-seven-evidence.json) records sources, binaries,
component output hashes, reused compiler profiles and measurement commands.


## Exact CPU SIMD SiTU

The reference Inkling expert activation uses sixteen-lane CPU math adapted
from the existing Vulkan reference activation shader. Binary32 stage order,
softcaps and the raw gate's sigmoid cutoff are preserved. Runtime feature
checks select SIMD; unsupported hosts, short tails and non-finite blocks use
the scalar platform math contract. The original activation peak tracking is
retained. Shared executable/library compiler policy disables contraction for
the math kernel, and generated vector code is checked for accidental FMAs.
Copyright and license notices from the existing shader are preserved.

The independent 65,536-value C libm fixture matches bit for bit. Another
65,536 arbitrary finite binary32 input pairs agree with scalar C libm.
Additional cases exercise shifted bounds, guarded tails of lengths 0..35,
malformed dimensions/caps, signed zero, subnormals, extreme finite inputs,
infinities and NaN payloads. The activation-only comparison used
0.235547 seconds for scalar work versus
0.188565 seconds for SIMD work, a
19.95% time reduction; this is not model token throughput.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen prior build, paired confirmation | 24.65 | 15.58 |
| CPU SIMD SiTU and fresh matched profiles | 24.99 | 15.62 |

Each build received one warmup and one measured pass: 2048 prompt tokens,
512 generated tokens, eight workers, batch 128, int8, Q4T, context 2688,
no repack and seven DSpark proposals. Candidate ran before baseline. Output
digest `ef944d4b056d2325` and 448/448 acceptance match.
This paired trial gives no confidence interval or repeatability estimate.
The component test isolates activation math; the full comparison also
includes fresh matched compiler profiles, whose effect is not separated.

Fresh decoder/CPU profiles were collected on one actual 2048/16 turn with
eight workers and the same IQ3_S/Q4T configuration, plus focused fixtures.
Profile-collection timings are not performance results. The measured and
installed binaries use profiles without runtime instrumentation.
Qualification passes 67 focused cases, including legacy attention,
activation and mixture regressions. This is not a full release-gate run.

Compressed IQ3_S weights, Q4T storage and the prior seven-vector Q5_K head
optimization remain. The new math uses bounded automatic scratch and the
existing admitted activation buffers. All 254 existing fixtures and the
protected quantization parent source are unchanged. Rebuild using the
recorded source-matched PGO environment in the
[evidence](inkling2-gsq-situ-evidence.json), which pins sources, binaries,
profiles, component timings, assembly checks and the paired comparison.


## Native IQ3_S seven/eight-query reuse

A lossless 110-byte interleaved index layout was implemented and tested first.
Its byte round trips and numerical comparisons passed. The eight-query expert
projection improved about 10%, but smaller batches and 128-query prefill lost
throughput, so that layout and its production hooks were removed. Prototype
sources and binaries remain in the evidence. The model still reads native
IQ3_S bytes, using no repacking or additional weight cache.

The useful part was reusing one decoded block across eight queries. A native
kernel now does that for seven/eight-query reference products. Seven-query
calls repeat one valid input in an unused eighth lane and store only seven
outputs. The original integer sums, FP32 lane FMA chains and sequential
binary64 fold are preserved. Input/output maps and all ranges are checked
before writes; other query counts retain their prior kernels.

The prototype expert component used actual 1152 × 2304 dimensions, eight CPU
workers and independent synthetic compressed blocks. Native projection rates
changed from 63464.3 to
90796.3 tok/s for seven queries,
and 66879.5 to
101857.5 tok/s for eight.
These are projection-only rates, not model-generation rates. Unchanged-path
measurement differences are not attributed to this optimization. The final
cleanup keeps this native arithmetic and hoists immutable input pointers out
of the row loop.

| Full native build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build, paired confirmation | 25.08 | 15.69 |
| Native IQ3_S seven/eight-query reuse | 25.07 | 15.73 |

Each build uses one warmup and one measured 2048/512 pass, eight workers,
batch 128, int8, Q4T, context 2688, no repack and seven DSpark proposals.
Candidate ran before baseline. Digest `ef944d4b056d2325` and
448/448 acceptance match. Overall throughput is essentially unchanged; this
trial does not establish a meaningful generation-speed gain. One pair establishes no confidence interval
or repeatability estimate. The full result, not the component rate, describes
actual generation performance.

Qualification passes 68 focused cases, including independent GGML grid goldens
within their existing envelope, exact comparisons against the prior native
kernel, mapped rows, shifted bounds, output guards, malformed spans and
unchanged-query dispatch. Existing native/backend/legacy regressions and
CPU/Vulkan components pass. This is not a full release-gate run.

The profiled decoder/CPU objects, SiTU object, SiTU source and Q5 head source
are unchanged. Their existing source-matched profiles are reused; the new
quantization code is compiled normally. All 254 existing fixtures and the
protected quantization parent source remain unchanged. Compressed IQ3_S
weights and Q4T retain their storage, with only bounded stack scratch for
query addresses and accumulators. Existing model/session/backend ownership
and APIs are retained.

[Evidence](inkling2-gsq-iq3-native8-evidence.json) records both rejected and
retained experiments, source archives, installed binaries, unchanged-object
proof, compiler settings and the paired measurement.


## SIMD softcap experiment (not selected)

An exact sixteen-lane softcap reused SiTU tanh arithmetic in Inkling final
logits and DSpark Markov correction. It preserved binary32 stages, saturation
ties, existing 512-row scratch and scalar fallbacks. The candidate passed
69 focused cases, including CPU/Vulkan and existing DSpark regressions.
Exact comparisons against independent C `tanhf` covered 458,752 values across
seven caps, plus signed zero, subnormals, extreme values, NaNs, infinities,
guarded tails, invalid caps and lowest-ID saturation ties.

The isolated softcap comparison reduced elapsed time by
42.43%. This was not a full-generation improvement:

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Preceding selected build, paired confirmation | 25.13 | 15.85 |
| SIMD softcap candidate | 25.04 | 15.58 |

Each build received one warmup and one measured 2048/512 pass with eight
workers, batch128, int8, Q4T, context2688, no repack and seven DSpark proposals.
Output digest `ef944d4b056d2325` and 448/448 acceptance match.
The candidate also included fresh source-matched decoder/CPU profiles; their
effect is not separated. One pair does not establish a persistent regression.

The preceding production source and three binaries were restored byte for
byte. IQ3_S, Q4T, native IQ3 seven/eight-query reuse, SiTU and the Q5_K
seven-vector head remain selected. The unused candidate source was removed
from the production tree. Its source archive, patch, exact executable hashes,
profiles, component checks and full comparison are preserved in
[experimental evidence](inkling2-gsq-softcap-evidence.json).


## Small IQ3_S groups and fused expert reduction (retained)

The requested pair of native CPU optimizations was implemented and qualified.
One-to-four-query IQ3_S products decode each native block for live queries,
process validated row ranges in one call, preserve original FP32 lane FMAs
and ordered binary64 folds, and write directly to mapped destinations.
Seven/eight-query arithmetic and unsupported-count fallbacks remain intact.

Inkling reference MoE reduction keeps four output vectors in registers across
experts in rank order. Every product rounds to binary32 before addition, with
no FMA. Only the completed output tile is written; raw expert scratch is no
longer scaled in place and is not read after the reduction. Short tails and
unsupported hosts use the original Scale/Add operations with bounded scratch,
preserving their non-finite operand behavior. Other architectures retain their
existing reduction loop. Preliminary two-buffer fusion prototypes were slower
and were superseded by this full ordered reduction.

The final isolated expert-sum comparison reduced elapsed time by
49.00%. Small-query component results varied
between trials; their projection rates do not establish model-generation gains.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build, paired confirmation | 24.82 | 15.54 |
| Combined small-group/reduction candidate | 25.00 | 15.76 |

Each build received one warmup and one measured 2048/512 pass, eight workers,
batch128, int8, Q4T, context2688, no repack and seven DSpark proposals.
Output digest `ef944d4b056d2325` and 448/448 acceptance match.
These are single paired observations without a repeatability claim. Fresh
matched decoder/CPU profiles were trained on one actual 2048/16 turn plus
focused fixtures; their contribution is not separated from the source changes.
Profile training timings are excluded from throughput results.

Qualification passes 70 focused cases. Native IQ3 outputs match the unchanged
integer kernels bit for bit and independent GGML goldens within their original
envelope. Indexed mappings, invalid inputs, output guards and unchanged query
counts are covered. Weighted sums match original Scale/Add output bits across
zero to sixteen experts, guarded tails, shifted bounds, non-finite payloads,
signed zero, subnormals and random actual-width eight-expert data. Existing
native DSpark and CPU/Vulkan component and legacy regressions pass.
This is not a full release or full-checkpoint independent conformance run.

IQ3_S weights, Q4T, SiTU and the seven-vector Q5_K projection retain their
storage. No model weights are repacked or expanded and no persistent buffers
or runtime dependencies are introduced. All 254 fixtures and the protected
quantization parent are unchanged. Source snapshots, candidate binaries,
profiles, assembly checks, rejected prototypes and selection are recorded in
[small-group/reduction evidence](inkling2-gsq-small-moe-evidence.json).


## Q4T normalization, five/six-query IQ3_S and loading experiments

All three requested directions were implemented and evaluated. The exact
Q4T exponential helper passed bit comparisons against the original calculation
for all 1,117,782,017 negative binary32 inputs from signed zero through -80,
plus shifted maxima, guarded tails, non-finite/clamped cases, an independent
C exp oracle and unchanged SiTU fixtures. It preserved binary32 subtraction,
binary64 exponential evaluation, binary32 probabilities and the chronological
binary64 denominator sum. Conservative midpoint guards retained scalar math
for uncertain lanes. The combined full-model comparison regressed, so this
normalization helper is not active and its source was removed from production.
Its source, binary, exhaustive check and matched profiles remain archived.

Buffered decode pipelining with bounded block lookahead and a separate
next-row-only prefetch variant passed exact native arithmetic checks. Hot and
cold comparisons used one versus 32 compressed synthetic experts (36.5 MB).
The explicit pipeline generally lost throughput; reference-controlled row
prefetch comparisons were mixed. Neither loading experiment is retained.

The five/six-query IQ3_S kernels were then isolated: retained.
They decode each native block once for live queries, keep the original integer
lanes/FP32 FMA chains and ordered binary64 fold, and write mapped outputs
directly. Existing one-to-four and seven/eight-query paths remain. All eight
counts match unchanged native kernels bit for bit and independent GGML golden
fixtures within their original tolerances. Input/output maps, guards, invalid
spans, unsupported counts and signed-byte fallback are covered.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build, confirmation | 25.10 | 15.70 |
| Normalization plus five/six-query candidate, rejected | 23.87 | 15.31 |
| Isolated five/six-query candidate | 25.09 | 15.82 |

Each configuration received one warmup and one measured 2048/512 pass: eight
workers, batch128, int8, Q4T, context2688, no repack and seven DSpark proposals.
Digest `ef944d4b056d2325` and 448/448 acceptance match.
The baseline ran between the combined and isolated candidates and was not
repeated. These single observations establish no repeatability estimate.
The rejected combined candidate used fresh profiles; the isolated candidate
reuses the original matched decoder/CPU profiles. Its decoder, CPU and math
executable code and constants match the preceding selection, removing changed
profiles/math from that comparison. Object-level debug metadata may differ.

The isolated build passes 70 focused cases, including CPU/Vulkan component
and legacy regressions. This is not a full release-gate, coding-quality or new
full-checkpoint conformance run. Compressed IQ3_S weights and Q4T, original
workspaces, all 254 fixture files and the protected quantization parent remain.
No weights are repacked/expanded, no persistent cache or external runtime is
added, and no normalization or loading experiment is active. See
[evidence](inkling2-gsq-attn-six-evidence.json) for source/binary/profile pins,
unchanged-code proof, exhaustive checks and rejected candidates.


## Native sixteen-query IQ3_S, expert jobs and score publication

The proposed longer DSpark block is unavailable for the selected checkpoint.
Its metadata declares block size eight and `mask_embd.weight` contains seven
learned mask rows. The validated seven-proposal limit is retained; no learned
positions are duplicated or invented. Extending it requires a compatible
checkpoint, not changing an array bound.

A vector index/gather IQ3_S prototype passed the exact arithmetic checks but
lost component throughput, especially on five/six-query groups. Its source,
binary and hot/cold comparisons are archived; the native scalar index extraction
remains selected. The loading/prefetch experiments from the prior task remain
excluded.

The existing MoE pool already performs gate, up, activation and down in one
worker job. The rejected scheduling prototype let IQ3_S groups use up to
sixteen members in a job, removing the four-query split for five-to-eight-member
groups. Expert ordering, per-token rank reduction and physical ownership were
preserved. The original scheduler is active.

The new native nine-to-sixteen-query kernel holds two independent eight-lane
queries in each ZMM accumulator, decoding each original 110-byte weight block
once. Unused lanes duplicate a validated live input and are never published.
Original integer dot products, FP32 FMA chains and sequential binary64 folds
are retained. Counts one through eight keep their prior arithmetic. There is
no model repacking, expanded weight cache or new inference runtime.

Focused checks compare counts one through sixteen against independent GGML
fixtures within the existing tolerance and against the old native products
bit for bit. Shifted bounds, indexed/repeated inputs, distinct mapped outputs,
padding, invalid spans, block counts one and sixty-four, unsupported counts
and the signed-byte fallback are covered. The component test uses the same
1152-by-2304 expert dimensions and eight-worker dispatch for both paths.
At sixteen queries it observed approximately 123,241 projection tok/s versus
86,111 for the fallback when hot, and 116,258 versus 80,374 when cycling through
32 compressed synthetic experts. Projection rates are not generation rates.

The rejected attention prototype combined maximum tracking and score publication
in one finishing pass and checked a full tile's validity once. Border tiles
retained per-position causal/window checks. Bias, sink, exponential calculation
and chronological accumulation order were preserved. The original attention
implementation is active.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build, paired confirmation | 25.00 | 15.56 |
| Combined jobs/kernel/attention candidate, rejected | 24.63 | 14.86 |
| Isolated native sixteen-query kernel | 25.08 | 15.53 |

Selection: **native nine-to-sixteen-query kernel retained**. The combined
job/attention/profile candidate was rejected; original scheduler and attention
sources and matched original profiles were restored byte for byte. Decoder,
CPU and math executable code/constants match the preceding selection.
Full-model throughput is essentially unchanged. The kernel is retained for its
component benefit; no meaningful generation-speed gain is established.
Each build received one warmup and one measured 2048/512 pass, eight workers,
batch128, int8, Q4T, context2688, no repack and seven DSpark proposals. Output
digest `ef944d4b056d2325` and 448/448 acceptance match.
This single pair establishes no repeatability estimate. Changes to scheduling,
attention and source-matched compiler profiles are timed together where present;
no individual full-model speed attribution is made for that combined candidate.
The isolated kernel instead uses the original matched profiles; its profiled
decoder/CPU and math code/constants match the preceding build.

All 70 focused checks pass, including CPU/Vulkan components and legacy
regressions. This is not a full release or new independent full-checkpoint
conformance run. All 254 fixtures and the protected quantization parent remain
unchanged. IQ3_S weights and Q4T retain their storage. Source/profile archives,
exact executable pins, rejected experiments and final decisions are in the
[evidence](inkling2-gsq-next-five-evidence.json).


## Profile-guided convolution channel sharing

A 99 Hz user-cycle profile of the preceding frozen selected executable sampled
one 2048/512 turn with the same IQ3_S/Q4T configuration. All 77,338 samples were
retained, with none lost; output and 448/448 proposal acceptance match. Sampling
and phase accounting are diagnostic, not a throughput comparison. The dedicated
IQ3_S helper accounted for about 1.3% of sampled user cycles, while shared
small-block products accounted for about 13%. The existing joining phase took
12.401 s, about 11.3% of accounted target wall time; source inspection showed
scalar reference convolution walking channels serially.

Two IQ4_NL paired-row kernels passed independent GGML, strided/padded-row,
signed-byte extrema and distinct-row scaling checks. Their short component
comparisons were insufficient/inconsistent, so neither is retained or subjected
to a full-model trial. Original IQ3_S/IQ4_NL products remain byte for byte.
Their prototype sources, executables and comparisons are archived.

The convolution candidate uses the existing CPU pool for reference batches of
at least eight tokens, subject to its ordinary cost threshold. Each job owns
a channel range for every token, preserving causal state, tap order, explicit
FP32 FMAs, dynamic additions and output joins. One atomic finite flag only
transitions to False in workers. The caller waits for all shares before
resolving errors/cancellation; existing evaluation rollback owns recovery.
Null-pool, small-batch and existing non-reference SIMD paths remain. Only
bounded call-stack descriptors are added; no persistent buffers or weights
are added, expanded or repacked.

A 64-token aligned-head AUnit case compares serial and pooled execution bit for
bit for every logit and hidden-state row, then continuation, rewind with an
alternative batch, reset and reuse. Both exact and Q4T caches are covered.
Existing cancellation, logical-visit recovery and independent fixtures remain.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build | 25.10 | 15.69 |
| Convolution candidate | 26.64 | 16.29 |

The measured joining phase changed from 12.551 s to
4.142 s. These times cover the target session's combined
prefill and decode work, not isolated convolution or drafter cost.
Selection: **retained**.

Both configurations enable the existing phase accounting and receive one
warmup and one measured 2048/512 pass: eight workers, batch128, int8, Q4T,
context2688, no repack and seven proposals. Digest `ef944d4b056d2325` and
448/448 acceptance match. One pair establishes no
repeatability estimate. The candidate includes fresh source-matched decoder/CPU
profiles trained on one 2048/16 turn plus focused fixtures; their contribution
is not separated from the source change. Final executables have no profiling
counters or runtime dependency on perf, profiles or another executor.

All 72 focused checks pass, including CPU/Vulkan components and legacy
regressions. All 254 existing fixtures and the protected quantization parent
remain unchanged. This is not a full release or independent full-checkpoint
conformance run. IQ3_S weights, Q4T, device/session ownership and memory limits
remain. See [evidence](inkling2-gsq-profiled-convolution-evidence.json) for the
profile, rejected experiments, source/binary pins, phase reports and matched
compiler-profile provenance.


## Token-parallel normalization and shared relative features

The normalization candidate distributes independent token rows over the existing
CPU pool for batches of at least eight tokens, subject to the normal cost
threshold. Each row calls the unchanged RMS kernel with its original reduction
and weighting order. A per-row finite flag stays local; workers can only publish
False to the call's atomic validity flag. All workers settle before the caller
resolves cancellation or errors. Small batches and absent pools retain serial
execution, and the normal transaction owns rollback.

`Relative_Scores_Three_Eight` finishes three heads' eight scores together. Each
relative-feature gather serves all three heads, while every head retains its
own ordered binary32 multiplication/addition, coefficients and sink. Masks are
applied after multiplication, preserving masked non-finite coefficient behavior.
Full valid Q4T tiles use the new kernel; border tiles, unsupported hosts and
shapes retain the old path. Maximum tracking and score publication retain their
original order. No softmax, exponential or KV-quantization change is included.

The component case compares against three calls to the existing one-head kernel
bit for bit over widths 1/4/8/16/32, shifted bounds, relative extents, masked
positions, signed zero, infinities, NaN payloads and malformed shapes. The
one-million-pass component comparison took 0.159918081 s for separate heads and
0.056067518 s for shared gathers, approximately 65% less time. These are isolated
attention-feature results, not model-generation throughput.

The existing 64-token serial/pooled state case also exercises the parallel norm
threshold with aligned heads. Every logit and hidden-state row matches exactly,
followed by continuation, rewind, alternative continuation, reset and reuse for
both exact and Q4T caches. Existing cancellation/recovery cases remain active.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build | 26.65 | 16.59 |
| Normalization/shared-feature candidate | 26.57 | 16.23 |

Accounted normalization changed from 8.972 s to
7.674 s; attention changed from 26.007 s to
28.469 s. Phase times cover combined target prefill and
decode, not isolated operations or drafter work. Selection:
**rejected; preceding sources and binaries restored**.

Both configurations enable phase accounting and receive one warmup and one
measured 2048/512 pass: eight workers, batch 128, int8, Q4T, context 2688, no repack,
seven proposals. Digest `ef944d4b056d2325` and 448/448 acceptance match.
One pair establishes no repeatability estimate. Fresh matched decoder/CPU
profiles were trained on one 2048/16 turn plus focused fixtures; their contribution
and the two source changes are not individually attributed. Final executables
have no profiling counters or new runtime dependency.

All 74 focused cases pass, including independent numerical, CPU/Vulkan and legacy
regressions. All 254 fixtures, the protected quantization parent, compressed
IQ3_S weights and Q4T remain unchanged. No persistent activation or weight
buffers are added. Selected channel-parallel convolution remains. This is not
a full release or independent full-checkpoint conformance run. See
[evidence](inkling2-gsq-norm-bias-evidence.json) for source/binary/profile pins,
component coverage, phase reports and the paired comparison.


## Normalization alone after the shared-gather trial

The combined normalization/shared-gather candidate passed all 74 focused cases
but measured 26.57 tok/s prefill and 16.23 tok/s decode against 26.65/16.59 tok/s
for the frozen preceding build. Normalization fell from 8.972 to 7.674 seconds,
while attention rose from 26.007 to 28.469 seconds. The combination was rejected;
its source, binaries and results remain in the
[combined-trial evidence](inkling2-gsq-norm-bias-evidence.json).

The isolated candidate changes only `Norm` in `Inkling_Evaluate`. Independent
token rows share the existing CPU pool at batches of at least eight, subject to
the existing cost threshold. Each row calls the unchanged RMS kernel in its
original arithmetic order. Finite flags remain local to each row; workers only
publish False to an atomic flag. The caller resolves cancellation and errors
after every worker settles. Small batches and absent pools retain serial
execution. There are no new persistent buffers. The preceding attention path,
channel-parallel convolution, compressed IQ3_S weights and Q4T cache remain.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen preceding build | 26.65 | 16.59 |
| Normalization alone | 26.66 | 16.39 |

Selection: **rejected; preceding sources and binaries restored**.
Normalization accounting changed from 8.972 to
7.769 seconds; attention changed from
26.007 to 26.889 seconds. Phase
times include target prefill and decode, and exclude drafter work.

Each configuration receives one warmup and one measured 2048/512 pass: eight
workers, batch 128, int8, Q4T, context 2688, no repack and seven proposals. The
same frozen baseline measurement is reused from the combined trial. Digest
`ef944d4b056d2325` and 448/448 proposal acceptance match.
One measured pass per configuration provides no repeatability estimate. Fresh
source-matched decoder/CPU profiles use a 512/16 training turn and focused
fixtures; source and compiler-profile effects are measured together. Training
is not throughput evidence. Production executables have no profiling counters.

All 72 focused cases pass, including exact serial/parallel logits and hidden
rows, continuation, rewind and reset/reuse in exact and Q4T cache modes, plus
existing cancellation/recovery, independent numerical, CPU/Vulkan and legacy
checks. All 254 fixtures and the protected quantization parent remain unchanged.
This is focused validation rather than a full release or independent full-model
reference-conformance run. The
[normalization evidence](inkling2-gsq-norm-only-evidence.json) pins source,
binaries, profiles, qualification and measured results.


## Eight-query native IQ4_NL products

The saved user-cycle profile attributed 12.87% of samples to
`Quantization.Integers.Small_Block_Rows`. The selected path processed IQ4_NL
queries in groups of four, decoding the same physical row again for each group.
The candidate's eight-query kernel decodes each 18-byte block once and keeps
sixteen accumulators in registers: the original even/odd binary32 FMA chains
for all eight queries. It retains the original binary32 final fold. Existing
validation precedes writes, and the prior four/two/one-query tails remain.
Q2_0 and every other format keep their previous path. The new function has the
same local ISA target and byte-product capability gate used by native IQ3_S.

The existing independently generated GGML small-block fixtures match exactly.
Additional tests cover 8/9/15/16/17/31/32/128 queries at widths 64/128/1152/2304,
shifted array bounds, padded rows, reordered/repeated input members, reordered
output members and duplicate-output refusal without writes. Existing all-level
signed-byte extrema, truncated-buffer and disabled-kernel cases also pass.

| Full inference build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen selected v15 baseline | 26.65 | 16.59 |
| Eight-query IQ4_NL candidate | 26.69 | 16.42 |

Selection: **rejected; preceding sources and binaries restored**.
Feed accounting changed from 38.476 to
38.579 seconds; projection changed from
23.952 to 24.082 seconds.
Phase times include target prefill and decode, and exclude drafter work.

One warmup and one measured 2048/512 pass use eight workers, batch 128, int8,
Q4T, context 2688, no repacking and seven DSpark proposals. The completed frozen
baseline measurement from the normalization trials is reused; no extra baseline
run or profile training was performed. Exact selected v15 decoder/CPU profiles
are reused. Production executables have no profiling counters. Unchanged
object-section comparisons are recorded in the evidence. Digest
`ef944d4b056d2325` and 448/448 proposal acceptance match.
A single measured pass provides no repeatability estimate.

All 72 focused cases pass, including native inference, independent numerical,
CPU/Vulkan and legacy checks. All 254 fixtures and the protected quantization
parent are unchanged. IQ3_S weights and Q4T remain compressed; bounded stack
arguments/result rows add no persistent weight or activation buffers. No full
release or independent full-model conformance claim is made. See the
[eight-query evidence](inkling2-gsq-iq4-eight-evidence.json) for source, binary,
profile and qualification pins and the measured comparison.


## Wider native IQ3_S batches and K-quant decode reuse

The first candidate removes the native IQ3_S driver's 16-query request limit.
It validates the complete input/output maps, buffer extents and signed bytes
before publishing any result, then invokes the existing native kernels in
groups of at most 16 queries. The original FP32 lane FMAs, chronological
binary64 fold and repeated final input for padded lanes remain. Small final
groups retain their original direct-output kernels. The descriptor and carry
arrays stay bounded to 16 entries; there are no new persistent buffers.

The extended arithmetic case covers 1..18, 21..25, 31/32/33, 64/65 and
127/128/129 queries. Repeated independent fixture inputs are compared bit for
bit with the original nine-query native oracle and against unchanged independent
GGML goldens within their existing tolerance. Reordered/repeated source maps,
reversed destinations, padding, 1/64-block boundaries and late invalid inputs
are covered. Cross-tile duplicate destinations or a signed -128 in the final
query refuse the whole request without writes.

The second candidate reuses the existing decoded-row path for native
Q4_K/Q5_K/Q6_K calls with at least 16 queries, no joint projection and at most
64 blocks. Each pair of rows is decoded once into bounded call-local scratch;
the original eight-query arithmetic consumes it across the batch. This avoids
adding another 16-query assembly implementation. Small/joint calls and other
formats keep their original paths. No persistent or repacked model weights are
introduced. Existing scalar, cached/uncached, indexed and paired tests remain;
additional 64/128-query indexed cases match the scalar reference exactly.

| Build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen selected baseline | 26.65 | 16.59 |
| Native IQ3_S query tiling | 26.76 | 16.43 |
| Bounded K-quant decode reuse | 26.58 | 16.43 |

IQ3_S tiling selection: **rejected at batch 128; preceding sources and binaries restored**.
K-quant selection: **rejected; preceding sources and binaries restored**.
Each candidate is built and qualified separately. Each gets one warmup and one
measured 2048/512 pass with eight workers, batch 128, int8, Q4T, context 2688,
no repack and seven DSpark proposals. The completed frozen baseline run is
reused. Single measurements provide no repeatability estimate.

No profile training or refresh occurs: the original selected decoder/CPU profile
files are reused and their hashes checked. The decoder, CPU and math-kernel
code/read-only-data section comparisons are recorded per trial. Production
executables have no profiling counters. All 72 focused checks pass per trial,
including native inference, independent numerical, CPU/Vulkan and legacy cases.
Digest `ef944d4b056d2325` and 448/448 proposal acceptance match.
All 254 fixtures, compressed IQ3_S weights, Q4T and the protected quantization
parent remain unchanged. Existing 20 GiB process and 24 GiB host/session limits
remain. This is focused verification, not a full release or independent
full-checkpoint conformance claim. See the
[IQ3_S evidence](inkling2-gsq-wide-iq3-evidence.json) and
[K-quant evidence](inkling2-gsq-wide-kquant-evidence.json) for archived source,
binaries, patches, profile pins, phase accounting and qualification.


The additional batch-256 trial used the unchanged frozen native-IQ3 candidate
from the first trial. It measured **27.47 tok/s prefill and 16.21 tok/s decode**,
against **26.65/16.59 tok/s** for the saved selected baseline. Total prompt-plus-
decode time fell from 107.704 to 106.143 seconds (about 1.45%), while prefill
throughput rose 3.08% and decode throughput fell 2.29%. This is a measured
trade-off, not a general speed improvement. The baseline remains selected;
the wide-batch sources and executables remain archived for reproducibility.
No additional build, profile training or baseline measurement was performed.
The same 72-case qualified executable preserved digest `ef944d4b056d2325` and
448/448 acceptance at batch 256 under the existing memory limits. This single
measurement provides no repeatability estimate. See the
[batch-256 evidence](inkling2-gsq-wide-batch256-evidence.json).


## Adaptive waiting for early-finishing CPU workers

The candidate extends the existing MWAITX-gated low-power waiting to workers
that finish while peers still have shares outstanding. After 64 initial polls,
those workers arm a monitor on the job ticket and use the existing timed wait.
Unheld workers perform at most 128 such waits before the ordinary suspension
path. Once peers finish, normal polling covers the short gap to the next job.
Explicitly held workers retain hardware waiting; unsupported hosts retain the
pause/suspension path. The submission, ticket publication, sleeping flags,
gate handshake, team partition, caller settling and shutdown logic are unchanged.
The monitor is armed before rechecking the ticket and shutdown flag. There is
no arithmetic change or new persistent state.

The new lifecycle case runs 48 skewed jobs with 2/3/4-share teams. A delayed last
share exercises early-worker waiting; protected epoch/count checks detect missed
or repeated items and stale jobs. Held/unheld transitions, between-job gaps,
worker exception recovery and immediate/idempotent close are checked. Existing
pre-sleep shutdown races, unused/closed pool, reuse, affinity and exact share
coverage cases also pass, alongside the native inference and CPU/Vulkan suite.

| Build | Prefill (tok/s) | Decode (tok/s) |
|---|---:|---:|
| Frozen selected baseline | 26.65 | 16.59 |
| Adaptive-wait candidate | 26.35 | 16.37 |

Selection: **rejected; preceding sources and binaries restored**.
One warmup and one measured 2048/512 pass use eight workers, batch 128, int8,
Q4T, context 2688, no repack and seven proposals. The completed frozen baseline
measurement is reused. The single comparison provides no repeatability estimate.
Digest `ef944d4b056d2325` and 448/448 proposal acceptance match.

Training instruments only the changed CPU unit using existing gprbuild unique
compilation. Its focused cases and one 512/16 training turn produce fresh CPU
profiles; the decoder object stays byte-identical throughout training and its
original profile is copied unchanged. Standard final project builds use that
combined directory. Final binaries contain no profiling counters. CPU source
and refreshed CPU-profile effects are measured together; no isolated policy
speed attribution is claimed. Source, binary, profile and code-section pins are
recorded in the [adaptive-wait evidence](inkling2-gsq-adaptive-wait-evidence.json).

All 82 focused checks pass in both training and final builds. All 254 existing
fixtures and the protected quantization parent remain unchanged. IQ3_S weights,
Q4T and the existing 20 GiB process/24 GiB host-session limits remain. Only
bounded per-call stack counters are added. This is focused verification rather
than a full release or independent full-checkpoint conformance run.


## Relative tables, residual jobs and Q4T encoding trials

Three candidates were tried separately against the current selected build.
Each used one warmup and one measured 2048-token prompt/512-generated-token
pass, eight workers, batch 128, int8 arithmetic, the IQ3_S checkpoint, Q4T,
no repack and seven DSpark proposals. The completed frozen baseline was reused.

| Candidate | Prefill (tok/s) | Decode (tok/s) | Selection | Focused checks |
|---|---:|---:|---|---:|
| Frozen baseline | 26.65 | 16.59 | Prior selection | 72 |
| Contiguous relative tables | 24.97 | 16.05 | Rejected; prior selection restored | 72 |
| Fused residual mixing | 26.21 | 16.15 | Rejected; prior selection restored | 73 |
| SIMD Q4T encoding | 26.51 | 16.36 | Rejected; prior selection restored | 73 |

The relative-table candidate transposed the existing context-clipped CPU
feature buffer without increasing persistent storage. Its AVX2 kernel used
contiguous eight-position loads with the original separate binary32 channel
multiply/add order; partial shapes retained scalar handling. CPU/Vulkan
layout ownership remained separate.

The residual candidate combined normalization, tiny learned-query projections,
softmax and weighted sums into token-owned jobs on the existing pool. Original
arithmetic routines, candidate order and error/cancellation handling were kept.
The new 64-channel fixture compares serial and pooled logits and hidden states
through prefill, continuation, rewind and reset under exact and Q4T caches.

The Q4T candidate used explicit caller-gated AVX2 maximum selection and nibble
packing. The pure codec retained its scalar default, Hadamard transform order,
first-maximum sign, finite checks and short-group fallback. Added checks compare
scalar and independent bytes/scales, signed zeros, ties, subnormals, nonfinite
inputs, odd lengths and output guards. Model weights were not expanded.

All measured candidates preserved digest `ef944d4b056d2325` and 448/448
proposal acceptance. All 254 original fixtures and the protected quantization
parent remain unchanged. Existing 20 GiB process and 24 GiB host/session limits
remain. Candidate training instruments only the changed decoder; the CPU profile
is reused exactly. Production executables contain no profiling counters.
Source and refreshed decoder-profile effects are measured together. A single
measured pass gives no repeatability estimate. Qualification covers focused
native, independent numerical, CPU/Vulkan and legacy checks, without claiming
a full release or independent full-checkpoint conformance run.

See the [three-trial evidence](inkling2-gsq-layout-mix-pack-evidence.json),
[relative-table evidence](inkling2-gsq-relative-columns-evidence.json),
[residual-mixing evidence](inkling2-gsq-fused-mix-evidence.json) and
[Q4T-encoding evidence](inkling2-gsq-simd-cache-pack-evidence.json) for frozen
source, binaries, patches, profile identities, raw logs and qualification.

The Q4T candidate build returned success but GCC reported missing call-count
information for an internal decoder floating helper. The exact message is
retained in its evidence and raw production build log.
