# Batched prefill and longer-context measurement protocol

Declared on 2026-11-25 before the new timed campaign. Preserve the earlier
native measurements and their interpretation correction unchanged.

The native implementation processes a token batch through each logical visit.
Projection products cover the batch; convolution histories and causal attention
advance in token order. Physical weights remain shared across loop visits. Prefix replay for rewind
uses bounded calls to the same native batch evaluator.
The qualified F32 profile groups selected experts through the existing expert
batch implementation. Reference integer activations retain per-row scalar product and expert
arithmetic. Their precision-dependent batching kernels remain unqualified.

Before timing, require focused independent CPU/Vulkan fixtures, batched versus
scalar per-token logits and hidden states, partition equivalence, cancellation
without a partial commit, local-cache eviction, and the real Q4 checkpoint's
834-tensor comparison and sixteen greedy reference tokens. No numerical bound
may be widened to admit batching.

Also repeat the existing CPU five-token France prompt and sixteen-token golden
output with batch 128, context 128 and the original command options (no device
timeline and no EOS override). Five independent processes, each with one
untimed warmup and one measured pass, permit a direct prefill comparison to the
preserved batch-one baseline. All other inference settings and work match.
Keep longer-context rates separate from this comparison.

Measure 512- and 2,048-token raw prompts, constructed as `Hello` followed by
` Hello` repeated N-1 times. Confirm the prompt counts independently. Use eight
CPU threads, F32 activations and KV, original Q4_K_M weights, no repacking,
batch 128, context N+128, sixteen greedy generated tokens, seed one, repetition
penalty one, EOS ignored, drafting disabled, no saved-context reuse, and a 24 GiB host limit.
Run native CPU and native Vulkan with a private 4 GiB device budget. The known
shared-host driver bottleneck is profiled separately; these configurations do
not qualify its longer-context throughput.

Use five independent processes per configuration. Each uses the existing
quiet-host gate (`--wait 5`), one untimed warmup, and one measured pass. Keep all
samples, failures, commands, outputs, peak RSS, and raw logs; no timing-based
retry or exclusion. Serialize measurements and avoid competing builds, model
runs and validation. Report median, range and sample standard deviation.
Each generated token includes its decoder evaluation, including the last.

Pin model, native executable, complete source manifest, compiler configuration,
prompts, protocol and hardware. Recheck identities after measurement. Output
must be deterministic across samples and agree between the measured backends.
These timings assess throughput and resource use, not autonomous coding
quality or the unmeasured 8K/16K/32K context matrix.

Repeat the existing real Ada addition task in a fresh V3 project and operation,
using normal tool dispatch and unchanged acceptance checks. Preserve the prior
proof. Record elapsed time, inference/token/tool counts, durable completion and
an independent final build/run check. The previous overlapped proof is not a
controlled latency comparator.

The first external-reference preparation was interrupted by a host memory
event before any native benchmark sample. Its empty output and logs are
preserved under `performance-round2/reference-unbounded-attempt/`. Resumed
reference generation explicitly selects CPU-only execution, microbatch eight,
and an enforced 20 GiB cgroup limit with swap disabled. Reference runs are
correctness fixtures, not throughput samples. Native timed configurations
remain as declared above.

Before any native timing sample, add outer cgroup caps of 20 GiB for CPU
and 16 GiB for private Vulkan, with swap disabled. The latter leaves room
for its existing 4 GiB device budget. Keep the native CLI host limit at
24 GiB, and record both limits. The fresh CPU V3 operation and its descendants
also run under a 20 GiB cgroup cap. Preserve any cap-triggered failure; do
not retry or exclude timing samples.

Operational correction during collection: `tests speed --device-timeline`
automatically runs a second complete campaign without the timeline, even on
CPU. The first three CPU 512-token processes therefore perform four passes
(two warmups and two measured runs); the reported CPU run itself has no GPU
timeline instrumentation. Retain those reported samples and all extra work.
After the third child exited successfully, pause only the controller at that
boundary and omit the flag for subsequent timing. No inference was cancelled,
retried or excluded. Five reported samples per configuration are still required.
All private-Vulkan timings start without timeline instrumentation; retain
separate current-binary GPU conformance and a short timeline diagnostic.
