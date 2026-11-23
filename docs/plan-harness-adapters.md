# Harness adapters: measure transfer, reduce memory, then prepare training data

Status: execution started, 2026-11-22. The released-model campaign is held at the resource gate.

The artifact manifest, bounded header comparison, paired campaign driver, independently qualified pilot
graders and native work counters are implemented. Header inspection passes for the pinned release, including
all 256 adapter pairs. The Q8 working set does not fit this host's available memory; full payload acquisition
and an identically quantized fallback pair have not completed. No adapter-transfer result is claimed.

Stage 0 therefore has descriptor evidence but has not passed its inference gate. Stage 1 has tested campaign
instrumentation and grader controls, while the released-model pilot and confirmation decision remain pending.
Stage 2 now has [an execution contract](adapter-execution-contract.md), an independent binary64 oracle and
native projection/malformed-input regressions. The existing F32 merger also validates before writing and binds
full adapter content and descriptors to saved-context identity. Stage 3 now has native CPU attachments,
token/batch execution and ownership/admission regressions. Real-model memory checks and two batches of
paired synthetic rank-32 timing now document the CPU tradeoff. Per-arm runtime adapter selection is also
qualified through the native campaign workflow, with adapter hashes/scales and manifest-bound attempts.
The embedded API also accepts bounded CPU attachments and reports adapter ownership in provenance; its
standalone consumer completes with and without an adapter.
Campaign sessions and independent graders now use OS confinement and protected baselines. Version-two
records capture actual session/root/helper settings and project configuration; see
[campaign hardening and validation](campaign-hardening.md).
The released trained-adapter campaign remains pending. A matched before/after comparison without adapters
now passes the declared local 5% prompt/decode median gate in two seven-pair release-engine batches on the
0.8B CPU case; see [the evidence and limits](harness-adapter-no-adapter-check.md).
The mandatory full suite now passes 968/968. The
[repository repair](repository-audit-repair.md) fixes the dependency conflict and addresses the nineteen
earlier audit findings. [Campaign hardening](campaign-hardening.md) records the subsequent validation.
Bounded CPU tiles reduce observed prompt
overhead from 44–46% to about 1–5% in the saved synthetic case; runtime contexts are versioned accordingly.
Device attachment and complete training capture remain unimplemented.
See [the execution report](harness-adapter-execution.md) and
[campaign guide](harness-adapter-campaign.md).

A smaller same-base Q4 runtime-attachment experiment now has
[a frozen protocol](harness-adapter-q4-runtime-protocol.md) and
[separate artifact records](harness-adapter-q4-runtime-artifacts.json). The complete released F16 adapter
is verified against its pinned whole-file digest. Q4 base acquisition is deferred with its fragments retained;
its descriptors resolve all 256 trained pairs. This does not pass the inference gate or replace the Q8 campaign.
A smaller published TwIL Pi pair now has [its own frozen protocol](harness-adapter-twil-protocol.md).
Its Q4 base and trained adapter are verified against their pinned whole-file digests, and all 280 Granite
projection pairs resolve. Native Granite attachment and explicit-template tool-format recognition have
oracle and regression coverage; the independently graded work gate is still pending.
The [native generation and validation record](harness-adapter-twil-execution.md) now admits both models
without F32 expansion; independently graded coding attempts remain the next gate.

The objective is better verified coding work per unit of local time and memory. The first question is whether
the released harness adapters improve this program's actual `/work` agent. The second is whether keeping an
adapter beside quantized weights makes that improvement practical on the machines this program serves.
The third is how to collect reliable examples for an eventual model_runner-specific adapter.

These are separately useful deliverables. A negative transfer result ends the first experiment with evidence;
it does not establish that every adapter is ineffective. Native adapter execution needs its own memory,
correctness and speed case. Training data collection can proceed independently after its contract is defined.

## Evidence and the baseline already here

- The [video](https://www.youtube.com/watch?v=7asgk8dwCHw) describes adapters trained inside coding agents.
  Its linked [release](https://huggingface.co/blog/harness-adapters-at-scale) supplies the training recipe.
- The [Pi adapter card](https://huggingface.co/harness-hub/Qwen3.8-27B-pi-adapted) reports improvements under
  Pi. Those measurements do not establish a gain under model_runner's tools, constraints or Ada workload.
- The [GGUF release](https://huggingface.co/harness-hub/Qwen3.8-27B-pi-adapted-GGUF) offers a merged Q8_0
  model and a separate adapter. Its card says the published scores were measured at BF16 through vLLM;
  the GGUF builds have not been re-evaluated. Artifact revisions and current sizes must be pinned before use.
- `Llama.Merge_Adapter` and the CLI already load and stack GGUF adapters. They merge into F32 weights;
  acquisition chooses F32 repacking automatically when an adapter is named without another repacking mode.
  At nominally 27 billion parameters, four bytes per weight is approximately 108 GB before runtime overhead.
- `tests/src/agent_trial.adb` exercises real `/work` tasks in fresh projects and supports repeats and inference
  policy comparisons. `agent_eval.adb` supplies smaller tool-use checks and machine-readable transcripts.
- `Agent.Outcome` already records calls, tokens, timing and stop reasons. The agent already detects repeated
  calls and reasoning loops. Neither instrumentation nor loop detection needs to be invented for this work.
- `Framework.Invocations` records settings, replies, harness feedback and calls. Replies are capped at
  16,384 bytes, and call records retain excerpts. These records are useful provenance, not complete training
  trajectories. The existing inference policy already supports per-task reasoning choices.

## Scope and implementation rules

All project-owned implementation and campaign tooling follows `CONTRIBUTING.md`: Ada 2022, bounded input,
structured operational errors, and tests in the tests crate. Device work uses the existing shader pipeline.
Runtime inference remains native and local. No external model server or training dependency enters production.

The first adapter scope is text generation with the seven projections already handled by the merger:
attention query, key, value and output, and feed-forward gate, up and down. Architecture-specific shapes,
including fused or gated projections, must be checked against real artifacts. Unsupported targets are refused.
Vision adapters, expert-specific adapters, activated LoRA and live adapter switching are separate proposals.

Existing `Merge_Adapter` semantics remain available. A runtime attachment is a distinct operation with its own
ownership and accounting; it must not silently change what an existing API promises. Stage 3 exposes
`--lora-mode runtime` beside the unchanged default `--lora-mode merge`.

## Stage 0: pin compatible artifacts and establish a memory budget

Deliverable: an artifact manifest and a compatibility report before any large campaign or runtime change.

1. Record the model_runner revision, build options, machine, available RAM, device budget and disk space.
   Estimate base weights, cache, recurrent state, workspace and adapter bytes at an explicit context size.
   The release's roughly 28.6 GB Q8 model may leave too little room on a 30 GB host; CPU execution does not
   remove that constraint. Choose the backend and context only after this accounting.
2. Pin the original Qwen3.8-27B Q8_0, merged Pi Q8_0 and separate Pi GGUF adapter by repository revision,
   filename, byte size and digest. Record their base-model lineage, conversion and quantization provenance.
   Inspect small metadata first; downloads and expensive runs are implementation work, not part of this plan.
3. Inspect architecture, tokenizer, template, special tokens, context geometry and every adapter pair.
   Verify adapter rank, alpha, orientation and target dimensions, including hybrid-layer placement.
   Architecture names and matching dimensions alone do not prove the adapter belongs to a particular base.
4. Run load, deterministic text generation and tool-call smoke checks on both complete models. Confirm that
   thinking controls and tool grammars work without replacing the deployed harness with a test-only loop.
5. If these artifacts do not fit, record that result. A smaller quantization must have documented provenance
   and comparable conversion settings in both arms. A smaller model requires an adapter trained for that
   exact base. Do not substitute an unrelated adapter or silently change only one arm's precision.

Gate: both candidate arms execute the same tool contract within an explicit resource budget. If blocked by
capacity or compatibility, record the prerequisite and stop the comparison until it is resolved. A smaller
adapter fixture can still support the later numerical work, without claiming transfer from the 27B release.

## Stage 1: measure adapter transfer through the existing agent

Deliverable: a reproducible paired campaign and a report of quality, cost and regressions.

Extend `Agent_Trial` and its `tests_main.adb` entry point rather than creating a second agent harness.
Reuse `Agent_Eval` for quick checks, not as the primary measure of repository-editing quality.

### Workload and controls

Start with the current edit, find and delegate tasks as smoke checks. Build a pilot of twelve independently
graded tasks with three attempts per arm. Include Ada bug fixes, boundary conditions, repository navigation,
multi-file changes and recovery after failed checks. Add a few non-Ada controls to distinguish Ada transfer
from general tool-use transfer. Each run starts at the same source revision in a fresh project.

Use four arms: original and merged Pi model, each with thinking enabled and disabled. Hold tool definitions,
sampling settings, context, cache precision, backend, task budgets, helper policy and retrieval configuration
constant within a paired comparison. Give paired attempts the same seed, where supported, without assuming
identical generated sequences. Disable carried knowledge and lessons in the first campaign.

Pin drafting behavior explicitly so automatic draft selection cannot silently change between arms. Record
compaction and actual resolved inference settings. Treat task timeouts and agent failures as outcomes, not
missing observations. Separate infrastructure failures and rerun the affected pair after diagnosis.

Validate task graders before interpreting results: the reference change passes; unchanged code and plausible
wrong changes fail. Keep grading tests outside the agent's writable scope, and require a valid bounded diff
and independent checks rather than an agent's completion claim. Preserve the same permissions in all arms.

### Report contract

Add a versioned campaign manifest and per-attempt machine-readable records using the existing JSON support.
Record task and source identities; artifact and binary digests; full resolved settings; verified outcome;
stop reason; calls; generated and delegated tokens; prompt reads and reuse; compactions; load and execution
time separately; peak host memory and device residency where measurable; and links to transcripts and diffs.
Report unavailable measurements as unavailable, never as zero. Accounting estimates are labeled separately
from observed memory. Restart and resume must not count an attempt twice.

Report completion rate first, paired wins and losses next, and token, call and time distributions after them.
Show costs on all attempts and separately on tasks both models solve, so early failures cannot look efficient.
Alternate arm order on the same quiet host; separate cold-load measurements from work time.

### Decision

The pilot is a screening result. If it suggests a useful gain, confirm on at least thirty tasks with five
attempts per arm, within a declared compute budget. Freeze that suite before confirmation; do not use it for
adapter selection or training. Report paired uncertainty by task, since repeated attempts are not independent
new tasks. Small samples are not evidence of equivalent accuracy.

Before confirmation, freeze the acceptance rule: either a credible completion improvement at acceptable
latency, or at least 10% lower median work time with no completion loss beyond a five-percentage-point
non-inferiority margin. Include uncertainty for both claims and list every new failure. If the campaign cannot
resolve the margin, label the result inconclusive and keep the current default. Token savings alone do not pass.

Gate: a published local report decides whether to recommend this adapter. Nothing changes a model default
based solely on the upstream scores. The report also prices whether native adapter execution is worth building.

## Stage 2: specify an adapter execution contract and independent oracle

Deliverable: a reviewed tensor, lifecycle and numerical specification, followed by focused reference tests.

For each adapted linear projection, compute:

    y = W_quantized x + sum_i (scale_i * alpha_i / rank_i) * B_i (A_i x)

Preserve the existing convention for absent or zero alpha, and positional scales and stacking. Store bounded
adapter matrices beside the prepared model, with per-session scratch for intermediate rank vectors. Base
weights stay in their existing layout. The adapter is applied once before the projection's following bias,
gate, activation or residual operation, matching where a merged weight would act.

Build the reference from the same decoded quantized W used by the candidate. Comparing with a separately
quantized merged release would confound quantization order with implementation error. Use an independent
binary64 calculation on tiny matrices; use the existing F32 merger as an additional end-to-end reference.
Record absolute and relative error limits before optimized paths are accepted. Generated text equality alone
is not a numerical correctness check.

Specify validation of every tensor pair, shapes, rank bounds, finite scalars and checked byte arithmetic.
Validate the whole attachment before publishing it, so failure cannot leave half an adapter active. Specify
ownership after the source file closes, allocation cleanup, cancellation, close and errors with active sessions.
Attachments and scale changes are allowed only before sessions open in the first implementation.

Include adapter bytes and scratch in host/device admission. Bind effective adapter content, order, scales,
alpha and application mode to saved-context identity; preserve compatibility for models without adapters.
Keep immutable base panel caches reusable, with an explicit audit of any cache containing adapted data.
Never reuse attention computed with different effective weights.

Gate: the independent oracle and malformed-input tests pass, the supported-target matrix is explicit, and
the CPU/device integration points and identity changes are documented before production execution is added.

## Stage 3: execute adapters over quantized weights on the CPU

Deliverable: native CPU token and batch execution without whole-model F32 expansion.

Implement bounded loading, model-owned storage and session scratch in the inference layer. Integrate at the
projection sites reached from `llama-evaluate_token_body.adb` and `llama-evaluate_batch_body.adb`, sharing
the adapter operation across both. Cover all seven promised targets and the hybrid layers the artifact uses.
Retain existing base repacking and panel kernels; use existing matrix operations for the low-rank products
before considering a specialized kernel.

Add a distinct attachment API; keep `Merge_Adapter` as the F32 merge API. Initially expose runtime attachment
through an explicit opt-in execution mode beside `--lora`, with a documented way to retain merge behavior.
Choose and document the exact option during implementation; examples must distinguish proposed syntax from
existing commands. Validate unsupported combinations before allocating a large base model.

Prove zero-scale behavior, positive/negative scales, alpha/rank handling, stacked adapters, partial batches,
token/batch agreement, cancellation, cleanup and session-cache refusal after identity changes. Exercise
speculative verification and draft sessions where adapters are allowed; otherwise refuse or disable that
combination explicitly and test it. Include a real hybrid-model smoke run after tiny-fixture checks pass.

Measure peak memory, load time, prompt throughput and decode throughput against the unadapted quantized
base, the same-base F32 merge where it fits, and the premerged release as a practical but numerically distinct
alternative. Report adapter memory separately. Confirm that models without adapters have no material new
hot-path cost.

Gate: oracle tolerances pass, memory scales with adapter matrices and bounded scratch rather than all base
weights, and measured overhead is acceptable for the intended machine. Update documentation to claim only
the CPU paths and combinations actually exercised. Device support remains a separate stage.

## Stage 4: keep adapter execution on the device

Deliverable: device-resident adapter execution for token and batch projections, including supported split runs.

Extend the existing backend/device product sequence with low-rank products and scaled accumulation. Upload
adapter matrices once; keep intermediates on the device with their layer. Audit fused projections, gates and
split CPU/device placement so every projection receives its delta exactly once. Avoid a host transfer for each
adapted matrix. Admission includes adapter storage and batch scratch before device selection.

Compare device intermediates and logits against the stage-2 oracle and CPU path. Cover batch tails, both
residency choices, staging limits, cancellation and allocation failure. A selected unsupported mode must either
have a documented, tested CPU fallback or return a structured refusal; it cannot silently omit the adapter.

Measure complete prompt and decode execution as well as individual products. Repeat the useful stage-1
campaign arms with the separate adapter at matched settings. Quantized-base attachment and merging before
quantization can produce different answers; evaluate their quality separately.

Gate: correctness, memory and end-to-end speed results justify device support. Only then consider automatic
mode selection or a new default, with the F32 merge path still available explicitly. Update the inference API,
support matrix, CLI documentation and measured figures together with the implementation.

## Stage 5: export complete trajectories for future model_runner training

Deliverable: opt-in bounded capture, a versioned export format and a validator. Training is a later decision.

Add capture at the shared agent/generation boundary, including `/work`, helpers and ordinary tool-agent runs.
Build on invocation IDs and provenance without enlarging every normal journal entry into a transcript.
Use local bounded artifact storage with explicit capture and retention settings. Recording may contain source
and tool output; export has explicit selection/redaction rules and never uploads data automatically.

Each episode must preserve:

- Task, project revision, expected outputs, verifier identity and independent result; model, adapter, tokenizer,
  template and harness identities; sampling, reasoning, grammar and token-budget settings.
- The complete ordered messages, tool schemas, raw replies, parsed calls, tool results and harness feedback.
  Record rejected calls, interrupted generations, retries, compaction and the actual context of each turn.
- Exact model input and generated token IDs with boundaries and masks distinguishing generated tokens from
  tool/environment text. Record grammar intervention and forced reasoning closure; exclude or explicitly
  handle forced tokens in a training objective. Preserve helper parent/child relationships as separate streams.
- Completion, verification failure, refusal and resource exhaustion as distinct outcomes. Capture truncation
  or storage failure makes an episode incomplete and ineligible for training; it must not silently alter normal
  inference or masquerade as a complete record.

Validate serialization, message/call ordering, token boundaries, artifact digests and limits using deterministic
fake-model episodes. Check a real run against what was actually rendered and sampled. Do not re-execute
mutating tools to replay an export. Old excerpt-only journals can be exported as diagnostic history, but must
not be labeled complete training data.

Build a curated dataset only from eligible episodes. Retain failures as labeled outcomes for evaluation and
future RL; distinguish successful demonstrations for supervised training. Validate graders with reference,
no-op and known-wrong changes. Keep repository/task families separate across training, validation and final
evaluation, including near-duplicate fixes. A training process must not reward an agent for weakening tests.

Gate: exports reconstruct real model turns without silent loss, fail validation on corruption or missing data,
and carry independently verifiable outcomes. Project-owned capture, validation and export remain Ada tools.

## Optional follow-on: train and evaluate a model_runner-specific adapter

This requires a separate proposal naming the exact base model, dataset, licenses, training method, hardware,
cost ceiling and held-out evaluation. Published recipes use external training infrastructure; this plan does
not add a trainer or require that infrastructure to run model_runner. Any external experiment remains separate
from project-owned tooling and production dependencies.

Begin with the smallest informative pilot rather than reproducing a large training run. If RL is selected,
generate rollouts through the deployed harness and define policy-token/log-probability provenance before
training. Stored aggregate usage and transcripts alone are not an RL trainer integration. Confirm that the
chosen tasks yield informative rewards; do not train exclusively on tasks the base always passes or fails.

Correctness is the primary objective. Any efficiency reward is secondary to independently passing checks.
Compare base, released adapter and custom adapter at the same quantization and inference settings on the
untouched confirmation suite, reporting new failures and time/memory cost. Repeat after GGUF conversion:
improvement in a training server does not establish improvement in this native runtime.

Gate: independently reproduced local gains justify distributing or recommending the custom adapter.

## Delivery order and validation

1. Artifact manifest, compatibility and resource report (stage 0).
2. Trial/report extensions, grader controls and transfer decision (stage 1).
3. Adapter execution specification and independent numerical fixtures (stage 2).
4. CPU attachment and measured memory/speed results (stage 3).
5. Device attachment and matched local agent results (stage 4).
6. Complete trajectory capture, exporter, validator and dataset contract (stage 5).
7. Separately scoped training pilot, only if the preceding evidence warrants it.

Stages 0 and 1 come first. Stage 5 can be delivered independently after stage 1; it does not depend on device
adapters. Each implementation change includes focused AUnit coverage, then the required build and test
checks from `CONTRIBUTING.md`. Large model trials and device timing remain explicit campaigns outside the
default test gate. A documentation-only plan does not require model downloads or a benchmark run.

Keep measurements and rejected approaches alongside accepted ones. Completion means a stage's stated
deliverable and gate have evidence, not merely that the source accepts a new flag or artifact identifier.
