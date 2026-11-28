# Native Inkling timing baseline

Measured on 2026-11-24/25 with the verified Q4_K_M weights, native execution,
eight CPU threads, F32 activations/cache, no repacking, context 128 and a 24 GiB
host limit. The Ryzen 7 7840U/780M host retained its powersave governor.
The [evidence](inkling2-native-benchmark-evidence.json) pins sources, executables,
checkpoint, protocols, hardware and every retained sample. Each process uses
the existing quiet-host gate, an untimed warmup and one measured pass.

The [operation-count correction](inkling2-benchmark-interpretation.md) explains
an incorrect assumption in the original protocols. The runner evaluates the
last output token to commit its cache. Commands, outputs and times are unchanged.

## Five-token prompt, sixteen generated tokens on CPU

| Measurement | Median | Range | Sample standard deviation |
| --- | ---: | ---: | ---: |
| Prompt evaluation | 1.783 tokens/s | 1.774–1.850 | 0.033 |
| Generation / sixteen decoder evaluations | 1.786 tokens/s | 1.733–1.840 | 0.040 |
| Measured pass | 11.764 s | 11.517–12.048 | 0.206 |
| Warm model preparation | 0.269 s | 0.261–0.318 | 0.023 |

Peak process RSS ranges from 8.751 to 8.753 GiB.
Every sample matches the independent sixteen-token reference output exactly.

## One-token prompt and one decoder evaluation

Five independent processes per measured mode, each producing the independent
reference comma token. The existing device timeline is enabled; its overhead
is included. These short cases are not long-context throughput measurements.

| Mode | Prompt evaluation, median (range) | Decode evaluation, median (range) | Measured pass, median |
| --- | ---: | ---: | ---: |
| CPU | 0.515 s (0.489–0.529) | 0.560 s (0.472–0.581) | 1.072 s |
| Vulkan, private 4 GiB budget | 0.692 s (0.627–0.708) | 0.628 s (0.569–0.677) | 1.288 s |
| Vulkan, host-shared weights | 27.740 s (27.709–27.898) | 27.727 s (27.677–27.805) | 55.519 s |

All fifteen short-case outputs match. The bounded GPU mode records nonzero actual
device work in every process and passes the complete 834-tensor five-token
checkpoint comparison. CPU is faster for this instrumented short case.

The initial host-shared attempt was deferred before measurement. On Nov25 the
user authorized 0.5 GiB additional memory use, lowering required free headroom
from 22 GiB to 21.5 GiB. The full shared-host 834-tensor reference check then passed.
The timing tool also needed its existing memory-limit option forwarded to
model preparation, matching native CLI behavior; the original failed attempt
is retained. All five corrected-driver samples pass exact output and identity
checks. Native inference source is unchanged; earlier CPU/private-GPU data are
preserved. See the [memory adjustment protocol](inkling2-shared-memory-protocol.md).

These are short-context warm measurements. They do not qualify cold loading,
the planned long-context matrix or autonomous coding throughput. The canonical
reference uses a different activation/cache profile, so its published rate
is not a direct comparison. Variable-loop and vision support and the 30-task
adoption corpus remain separate work.


The later [batched-prefill campaign](inkling2-batched-prefill-benchmarks.md) records the updated decoder, five-sample longer-context measurements and a fresh V3 task. The earlier measurements above remain unchanged.

## Subsequent native optimizations

The [combined optimization evidence](inkling2-optimization-set-evidence.json)
retains source/executable identities, exact activation comparisons, focused
AUnit results, independent CPU/Vulkan/F16-cache checks and the shared-engine
regression. These are later single measurements, separate from the five-run
baselines above. Weights remain the original Q4_K_M GGUF; F32 refers to
activations and cache storage.

| CPU stage, 512 prompt / 16 generated tokens | Prefill | Decode | Decode tokens/s |
| --- | ---: | ---: | ---: |
| Before this set | 28.752 s | 5.401 s | 2.96 |
| Fused Q8 products | 28.435 s | 4.874 s | 3.28 |
| Combined set | 28.502 s | 5.093 s | 3.14 |

The separate five-token private-GPU comparison reads 7.006 s before and 6.961 s after for sixteen decoder evaluations. Both produce the same digest. This comparison includes the combined kernel changes and grouped control projections; it does not isolate GPU dispatch savings.

Explicit four-token context lookup drafting reads 4.709 s for sixteen decoder evaluations, proposing 8 tokens and accepting 8. Output matches undrafted greedy generation. Drafting remains opt-in (`--draft-lookup --draft-tokens 4`); a single workload does not establish a general benefit. Embedded prefix reuse is also opt-in and has correctness coverage rather than a separate latency measurement.

## Eight subsequent native candidates

Workspace/table reuse, fused Q4_K products, four-channel convolution, reduced
mixing copies, a bounded rewind checkpoint and grouped CPU/Vulkan projections
are recorded in [the evidence](inkling2-eight-candidates-evidence.json). Each
configuration below has one warmup and one measured pass. These observations
compare complete versions and do not isolate individual changes.

| CPU, 512 prompt / 16 generated tokens | Prefill | Decode | Decode tokens/s |
| --- | ---: | ---: | ---: |
| Previous undrafted | 28.502 s | 5.093 s | 3.14 |
| Eight candidates, undrafted | 28.499 s | 4.138 s | 3.87 |
| Eight candidates, context lookup | 28.512 s | 3.771 s | 4.24 |

Lookup proposed 8 tokens and accepted 8; its greedy digest matches the undrafted run. Drafting remains opt-in. The separate five-token private-Vulkan workload changes from 6.961 to 6.532 seconds for sixteen decoder evaluations, also with identical output. CPU and GPU prompts differ and their rates are not a placement comparison. All 2,425 captured activation files match the original implementation exactly.

## Small batches, quantized products and pointwise execution

The [next eight changes](inkling2-next-eight-evidence.json) cover two/three-token
products, fused Q5_K/Q6_K products, finite checks, unweighted RMS, workspace
lifetimes, shared rewind backup, decode head grouping and Vulkan pointwise
execution. Each Inkling configuration has one warmup and one measured pass;
prior rows are retained historical measurements. The complete versions are
compared without attributing a gain to any individual change.

| CPU, 512 prompt / 16 generated tokens | Prefill | Decode | Decode tokens/s |
| --- | ---: | ---: | ---: |
| Previous undrafted | 28.499 s | 4.138 s | 3.87 |
| Next eight, undrafted | 27.822 s | 4.077 s | 3.92 |
| Previous context lookup | 28.512 s | 3.771 s | 4.24 |
| Next eight, context lookup | 27.812 s | 2.885 s | 5.55 |

Context lookup proposed 8 tokens and accepted 8; the greedy output matches undrafted execution and drafting remains opt-in. The separate five-token private-Vulkan workload took 6.431 seconds (2.49 tokens/s), versus the preceding 6.532 seconds, with matching output. The GPU and CPU prompts differ, so this is not a placement comparison. All 2,425 CPU activation captures match the pinned original bytes.

## Fused small batches, retained scratch and device output

The [further eight changes](inkling2-further-eight-evidence.json) cover fused
small batches, retained expert scratch, in-place RMS, residual mixing, shared
attention KV loads, batched GPU gates, device output normalization and rewind
checkpoints. Each Inkling configuration has one warmup and one measured pass;
prior rows are retained historical measurements. The complete versions are
compared without attributing a gain to any individual change.

| CPU, 512 prompt / 16 generated tokens | Prefill | Decode | Decode tokens/s |
| --- | ---: | ---: | ---: |
| Previous undrafted | 27.822 s | 4.077 s | 3.92 |
| Further eight, undrafted | 26.426 s | 4.094 s | 3.91 |
| Previous context lookup | 27.812 s | 2.885 s | 5.55 |
| Further eight, context lookup | 26.401 s | 3.009 s | 5.32 |

Context lookup proposed 8 tokens and accepted 8; the greedy output matches undrafted execution and drafting remains opt-in. The separate five-token private-Vulkan workload took 6.196 seconds (2.58 tokens/s), versus the preceding 6.431 seconds, with matching output. The GPU and CPU prompts differ, so this is not a placement comparison. All 2,425 CPU activation captures match the pinned original bytes.

The undrafted prompt-plus-decode total changes from 31.899 to 30.520 seconds; context lookup changes from 30.697 to 29.410 seconds. The CPU decode-only sample is slightly slower and the context-lookup decode-only sample is slower. Prefill gains do not establish a decode gain.

## Expert input routing and native GPU convolution/controllers

[Pipeline evidence](inkling2-pipeline-eight-evidence.json) records stable routing
buckets, indexed expert inputs, wider fused batches, bounded physical scale
metadata, adaptive chunks and cost-aware explicit context lookup. The Vulkan
sequence now includes actual three/four-tap output convolution and controller
blending. An accurate optional controller shader passes the existing reference
tolerances; the initial float32-only failure remains in the raw evidence.

Each Inkling configuration has one warmup and one measured pass; prior rows
are retained historical samples. Individual candidate gains and statistical
significance are not established.

| CPU, 512 prompt / 16 generated tokens | Prefill | Decode | Decode tokens/s |
| --- | ---: | ---: | ---: |
| Previous undrafted | 26.426 s | 4.094 s | 3.91 |
| Pipeline changes, undrafted | 26.461 s | 3.944 s | 4.06 |
| Previous context lookup | 26.401 s | 3.009 s | 5.32 |
| Pipeline changes, context lookup | 26.606 s | 2.926 s | 5.47 |

Context lookup proposed 8 and accepted 8 tokens; output matches undrafted greedy execution and drafting remains opt-in. The separate five-token private-Vulkan workload took 6.137 seconds (2.61 tokens/s) versus 6.196 seconds, with matching output. GPU and CPU prompts differ, so these rates are not a placement comparison. All 2,425 captured CPU activation files match the original bytes.

The unrestricted first trial is preserved under `artifacts/inkling2/obj/pipeline-eight/full-fusion-trial`: CPU prefill 36.917 seconds and decode 4.001 seconds, GPU decode 6.038 seconds, context-lookup prefill 36.748 seconds and decode 3.011 seconds. Its complete version regressed prefill, so dispatch was revised to reuse staged wide-vector weights with indexed four/six-vector products and avoid unused large-batch scale tables. Each version was measured once per configuration. These samples do not isolate individual candidate contributions.

## Eight native candidates: retained F16-cache optimization

[Evidence](inkling2-resident-eight-evidence.json) records all eight implemented
and tested candidates, frozen sources/executables, failures and slower trials.
Seven CPU/GPU candidates were rejected after measurements. The previous
production paths were restored. Only vectorized F16 KV expansion and shared
conversion remain. Defaults and model weights are unchanged.

Each Inkling configuration/version has one warmup and one measured pass.
These observations compare complete versions and do not establish statistical
significance or individual contributions. Weights are Q4_K_M; activations are
F32. The F16 comparison uses F16 KV; the long-prompt comparison uses F32 KV.

### Matched F16-cache comparison, 512 prompt / 16 generated tokens

| Version | Prefill tok/s | Decode tok/s |
| --- | ---: | ---: |
| before | 14.44 | 3.44 |
| after | 17.64 | 3.68 |

Both outputs match the independent expected digest. The final selection keeps
this F16 mathematical implementation while removing rejected GPU code. These
samples retain their measured executable identities; they are not new timings
of the final executable.

### Matched 2,048-token prompts, 16 generated tokens

CPU and private Vulkan use the same independently tokenized prompt, context
2176, batch 128, eight CPU threads and F32 KV. All successful runs match the
independent output. The initially failed GPU run remains recorded.

| Backend | Trial version | Prefill tok/s | Decode tok/s |
| --- | --- | ---: | ---: |
| cpu | before | 16.87 | 3.69 |
| cpu | after | 16.81 | 3.76 |
| device | before | 16.32 | 2.43 |
| device | after | failed (exit 1) | — |
| device | after-fixed | 10.51 | 0.50 |
| device | after-parallel | 9.89 | 2.39 |

The failed grouped GPU trial exposed a missing barrier for independent tiled
inputs and a converted-input cache identity that omitted the input offset.
The corrected trial and a further parallel-position score trial passed their
reference checks, but remained slower than the preceding implementation.
Those implementations, reproducer, tests and raw results are archived under
`artifacts/inkling2/obj/resident-eight`; the final GPU implementation is restored
to the frozen preceding source. CPU F32 showed no material improvement.

Earlier short trials are retained in the evidence. They use a 512-token CPU
prompt and a separate five-token GPU prompt and cannot compare backend
placement. The 28-process shared-engine CPU regression passed both unchanged
1.05 gates. It is qualified for the final selection by unchanged applicable
CPU paths. An earlier empty generic `.text` extraction is explicitly rejected
as evidence of compiled-code equivalence. Final builds, focused/native device
cases and CPU/Vulkan/F16 real-checkpoint profiles are run after selection.

## Six attention and scheduling candidates

[Evidence](inkling2-attention-six-evidence.json) retains both implemented
versions, independent comparisons and all measured results. Each configuration
has one warmup and one measured pass on the same 2,048-token prompt and 16
generated tokens, batch 128, eight CPU threads, context 2176, Q4_K_M weights
and F32 activations. Cache precision is identified below.

| CPU cache | Before prefill tok/s | Retained prefill tok/s | Before decode tok/s | Retained decode tok/s |
| --- | ---: | ---: | ---: | ---: |
| cpu-f32 | 17.11 | 17.17 | 3.91 | 3.87 |
| cpu-f16 | 14.26 | 17.20 | 3.64 | 3.72 |

All successful continuations match their baseline digest. These are observations
of complete versions, without individual attribution or statistical significance.
The retained rows belong to the first measured CPU implementation. Final
selection removes the GPU prototype only; source qualification and fresh
final correctness checks are recorded separately. These are not fresh
timings of the final executable.
The selected implementation retains fused scalar finite checks. A later
SIMD-output refinement was measured separately and rejected because it
reduced decode throughput. Both complete versions remain recorded.

| First trial | Prefill tok/s | Decode tok/s |
| --- | ---: | ---: |
| cpu-f32 | 17.17 | 3.87 |
| cpu-f16 | 17.20 | 3.72 |
| device-f32 | 10.06 | 2.35 |

| Rejected SIMD-output refinement | Prefill tok/s | Decode tok/s |
| --- | ---: | ---: |
| cpu-f32 | 17.31 | 3.60 |
| cpu-f16 | 17.37 | 3.30 |

The GPU prototype regressed from 16.18 to 10.06 tok/s prefill and from 2.38 to 2.35 tok/s decode. It passed independent numerical and lifecycle checks, then was rejected and the previous GPU implementation restored. Its boundary began at normalized Q/K/V inputs; complete projection/preprocessing residency was outside that prototype and is not a delivered capability. No final-version GPU rate is claimed.

The final version passes 106 focused AUnit cases and three real-checkpoint profiles. The separate fixed 28-process shared-engine comparison passes both unchanged 1.05 gates. Compiler/source/binary identities, failures and precision-specific reference results remain in the evidence. Weights, cache defaults and drafting defaults are unchanged.

## Exact native products, placement and retained prefixes

One warmup and one measured pass per version/configuration, the same 2,048-token prompt and 16 generated tokens, eight threads, batch 128, F32 arithmetic, Q4_K_M weights and unchanged memory limits. No repacking, prompt reuse or drafting was enabled in the model timing. All outcomes are retained in [the five-candidate evidence](inkling2-expert-five-evidence.json).

| CPU KV cache | Before prefill | After prefill | Before decode | After decode |
| --- | ---: | ---: | ---: | ---: |
| F32 | 17.12 tok/s | 17.04 tok/s | 3.79 tok/s | 3.69 tok/s |
| F16 | 16.94 tok/s | 17.16 tok/s | 3.44 tok/s | 3.58 tok/s |

These are observed single-pass differences. The direct Q4_K panel path was measured separately using the existing synthetic expert-shaped benchmark, since the unchanged `--repack none` model run does not exercise it. Its input tok/s figures describe a matrix kernel rather than complete-model inference. AUnit verifies that explicitly marked conversation prefixes survive later decoding and restore without replay while their KV history remains reachable. Older evicted KV prefixes still reconstruct through the normal native path.

## Native Q4T cache

The same Q4_K_M model, 2,048-token prompt, 16 generated tokens, eight threads,
batch128, F32 activation arithmetic and original memory limits; one warmup and
one measured pass. The earlier frozen F32-cache sample remains the comparison.

| KV cache | Prefill | Decode |
| --- | ---: | ---: |
| F32 | 17.04 tok/s | 3.69 tok/s |
| Q4T keys / Q4 values | 16.90 tok/s | 3.72 tok/s |

KV arrays take 6.4 times fewer bytes including scales; whole-model memory does
not shrink by that factor. Q4T is lossy. All outputs and the digest comparison
are preserved in [the Q4T evidence](inkling2-q4t-evidence.json). These single
samples do not establish repeated-run confidence.

## Q4T context lookup and fused attention

The same Q4_K_M checkpoint, 2,048 prompt tokens, 16 generated tokens, eight CPU
threads, batch128 and context2176; one warmup and one measured pass per version.
All memory caps, quantized weights, prompt and output digest remain unchanged.

| Configuration | Prefill tok/s | Decode tok/s |
| --- | ---: | ---: |
| Q4T without drafting | 16.90 | 3.72 |
| Context lookup, four draft tokens | 16.93 | 4.85 |
| Context lookup and fused packed attention | 16.72 | 4.97 |

Each drafted sample offered eight tokens and accepted all eight. Acceptance
depends on matching existing context. The fused sample has a prefill tradeoff;
no repeated-run or overall latency improvement is established by these samples.
The original slower/failing results, commands, numerical checks and source/binary
identities are retained in [the four-target evidence](inkling2-q4t-four-evidence.json).
Integer activation conformance and its dependent batched integer experts remain
unqualified. Device Q4T prefill serialization fixes correctness; it is not a
Vulkan speed result.


## Batched GPU and fused CPU follow-up

The selected changed-candidate CPU sample is 24.87 tok/s prefill and
10.30 tok/s decode for the unchanged 2,048/16 workload, Q4_K_M weights,
Q4T cache and explicit int8 activations. The previous sample was 25.20/10.38.
One warmup and one measured pass were used. An earlier combined candidate
gave 24.00/10.36 tok/s; its new sixteen-token K tile was removed, with the
qualified eight-token K path restored. Both results and the bounded GPU
outcome are retained in [current evidence](inkling2-batch-chain-eight-evidence.json).
No individual speed attribution or repeated-run confidence is claimed.


The K-format follow-up uses the unchanged 2,048/16 workload, Q4_K_M weights, Q4T cache and explicit int8 activations. One warmup and one measured pass gives 25.93 tok/s prefill and 10.32 tok/s decode versus 24.87/10.30. Native K tile width remains eight; metadata remains bounded at 128 MiB. The existing dynamic expert queue is retained. The complete CPU/GPU outcomes, exact reference comparisons and fixed shared-engine campaign are in [current evidence](inkling2-super-eight-evidence.json). No individual attribution or repeated-run confidence is claimed.


The dispatch follow-up gives 26.20 tok/s prefill and 10.06 tok/s decode versus25.93/10.32: prefill improves, decode regresses in this single sample. The unchanged2048/16 Q4_K_M/Q4T integer workload uses one warmup and one measured pass. A256-bit comparison gives 14.15/7.42 tok/s, so512-bit remains selected. The grouped/overlapped Vulkan candidate retains the existing300-second practical budget. Full outcomes and the fixed shared-engine campaign appear in [dispatch evidence](inkling2-dispatch-eight-evidence.json). No individual speed attribution or repeated-run confidence is claimed.


One warmup and one measured 2048/16 pass: 26.19 tok/s prefill and 10.26 tok/s decode versus 26.20/10.06; changes -0.03%/+1.99%. Prefill is effectively unchanged; decode improves in this single sample. No individual speed attribution or repeated-run confidence. The warmup and measured pass each record 41 work-plan hits and 343 misses. Metadata occupies 134,120,448bytes; the largest layer occupies 14,929,920bytes within the unchanged 128 MiB global limit. The separate GPU trial reached its unchanged 300-second practical limit before completing the measured pass; no GPU tok/s result is reported. See [all outcomes](inkling2-plans-eight-evidence.json).


Correct fused reduction candidate measured 26.14 tok/s prefill and 9.96 tok/s decode versus selected 26.19/10.26; changes -0.21%/-2.99% in one measured pass. Candidate rejected and preceding engine restored. No speed gain retained and no unchanged benchmark repeated. Both trials use the same 2048/16 Q4_K_M/Q4T/int8, eight-thread, batch 128, context 2176 and four-token lookup profile. DSpark was not active. The restored engine retains the preceding selected result; no fresh measurement of unchanged code is claimed. See [evidence](inkling2-dspark-depth-mix-evidence.json).
