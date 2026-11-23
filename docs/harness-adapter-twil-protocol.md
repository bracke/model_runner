# TwIL trained-adapter evaluation protocol

Frozen before inference on 2026-11-23. The [artifact record](harness-adapter-twil-artifacts.json) binds the inputs.
This tests the publisher's trained TwIL Pi adapter through native
model_runner execution. It is a separate candidate from the originally pinned Qwen3.8-27B Pi release.
No score or model recommendation transfers between those experiments.

## Inputs

Base: `mradermacher/TwIL-8B-GGUF`, revision `00e9ccad554b6bb1308ca1c068a70d040b84f052`,
file `TwIL-8B.Q4_K_M.gguf`, 5,347,918,528 bytes, SHA-256
`d99ef62463658c8d4a6f54b1744599146414e68b836e3541247026987cdbb0f8`.
Both base and adapted arms use this exact file. The quantization is an explicit local-study choice;
the publisher recommends Q8_0. This does not reproduce BF16 training or upstream Pi scores.

Adapter: `harness-hub/TwIL-8B-pi-GGUF`, revision `f199641d170167657244f9e3a2e462df0a1ee59e`,
file `TwIL-8B-harbor-pi-lora-F16.gguf`, 197,958,112 bytes, SHA-256
`21e610324dd21e488a3c8c3cb6ff18135a74c7fb4cb1e121aedd5eb400db5eaf`.
Use runtime attachment at scale one only in adapted arms. Rank is 32, alpha is 64, with 280 projection pairs.

The [adapter card][adapter] names `webAI-Official/TwIL-8B` as its trained base and names the matching
quantized-base repository. The original PEFT source at `650d3169db36542f4429641fe518ce4f1f268078`
confirms that base, rank, alpha and the seven standard projections, without DoRA or transposed weights.
Header inspection resolves all 280 pairs against the pinned base; architecture is `granite`.
Training lineage is declared by the publisher, rather than inferred from compatible dimensions.

Both arms use `chat_template.jinja` from that PEFT source revision, as required by the publisher's card.
Its SHA-256 is `b0a1ec95f3ad2f879f8d9a8eea3355c6a7ff6f33e7ae0e75bf92a0285cd26a3b`.
Pin a read-only copy outside the campaign's hidden directory and record its hash before and after execution.
The template uses XML function/parameter calls supported by the native parser. Native offline rendering
must exercise both thinking choices and a tool definition before model inference.

[adapter]: https://huggingface.co/harness-hub/TwIL-8B-pi-GGUF/tree/f199641d170167657244f9e3a2e462df0a1ee59e

## Admission

Require exact whole-file sizes and SHA-256 digests before generation. Partial headers and synthetic fixtures
do not satisfy this gate. Preserve any failed or interrupted attempt separately.

The host has 32,814,366,720 physical bytes. Budget 5,347,918,528 bytes for the mapped base, 395,837,440
for decoded adapter matrices, 440,617,024 for the context-8192 q4t session estimate, and another 2 GiB for
workspace and host margin: 8,331,856,640 bytes before packed panels. Allow another 10,695,837,056 bytes
as a conservative two-times-base bound for panels while the input pages remain resident, giving a
19,027,693,696-byte admission bound. Measure the actual panel size and recheck available RAM before loading.
Account mapped pages as resident even though native allocation accounting excludes them. Measure peak RSS
and elapsed time independently for CLI smoke runs; estimates are not observations.

The base has 8,791,592,960 parameters. F32 weights alone would be 35,166,371,840 bytes, above physical RAM.
Use native CPU runtime attachment, without F32 expansion, device execution or drafting. Granite's existing
projection routes must first pass independent binary64 projection checks and token/batch comparisons against
same-base F32 merging on bounded fixtures, including Granite's four nontrivial scaling controls.

## Execution and screening

First run base, zero-scale attachment and active attachment sequentially with a short deterministic prompt,
eight generated tokens maximum, temperature zero and seed one. Bound each process to fifteen minutes.
Compare base and zero-scale generated text and token counts exactly. Active output need not differ.
Retain commands, exact binary hashes, output, errors, exit codes, elapsed times and measured maximum RSS.

Then run the existing confined native `/work` edit task across four arms with one repeat and 300 seconds
of work per attempt. These are feasibility and tool-contract checks, not the full pilot. Require actual
native settings, genuine tool execution, an independently graded outcome and unchanged project configuration.
Timeouts are outcomes and cannot establish successful editing. Keep infrastructure failures separate.

Use CPU, eight workers, context 8192, batch size 16, q4t cache, integer arithmetic, memory mapping,
native packed CPU rows and drafting disabled throughout. Qualify the packed layout against the reference
before inference. For work use temperature 0.8, top-p 1, top-k 0, min-p 0, fixed inference
policy, no carried knowledge and paired seed 42. The campaign resolves and retains remaining sampler controls.
Both arms use the identical pinned template. Alternate arm order through the existing campaign driver.
Pin executable and harness bytes after validation; do not build or relink during inference. Generated
panel caches may be removed from finished attempts to bound disk use; retain all transcripts, verifier
results, settings, configuration snapshots, diffs and outcome records.

The user authorized sixteen hours at 2026-11-23 12:07:54 UTC. Use a wall-clock deadline of
2026-11-24 04:07:54 UTC for the screen and full pilot together. The initial feasibility screen remains
bounded to two hours. Acquisition and compilation preceding authorization are separate. If the gates pass,
advance to the twelve-task, three-repeat, four-arm pilot in [the original plan](plan-harness-adapters.md).
Freeze a new campaign manifest before starting it. Do not treat the four edit attempts as that pilot.
The user reported the host quiet before coding attempts; keep builds and validation jobs out of the pilot.
After an initialization timeout in the first pilot launch, startup may take up to 300 seconds; explicit
startup errors stop immediately. This does not extend the 300-second model-work budget. Runtime caches
belong under the project's ignored `obj` directory, preserving the same namespace boundary.

Confirmation remains conditional on a promising pilot and requires at least thirty independent frozen tasks,
five attempts per arm, an explicit compute budget and task-cluster uncertainty. The original acceptance rule
still applies: credible completion gain at acceptable latency, or at least 10% lower median work time with
completion loss bounded by five percentage points. An unresolved margin is inconclusive. Keep the default
unchanged unless confirmation supports a recommendation; fewer tokens alone cannot pass this rule.
