# Bounded TwIL adapter comparison

Frozen on 2026-11-23 before these model runs. The user authorized a new six-attempt paired comparison after
the [CPU investigation](twil-cpu-profile.md). The cancelled 144-attempt pilot remains cancelled.

## Question and scope

Does the published Pi adapter improve independently verified completion on the existing edit task under
model_runner's native workflow? Run three paired seeds, not a general benchmark or confirmation campaign.
The earlier three-of-three smoke gate is not required for this exploratory comparison: baseline failures
provide headroom to measure improvement. Coding acceptance, verification and time budgets do not change.
The earlier native grades remain unchanged and are not reused as this comparison's baseline.

## Frozen inputs

Both arms use `TwIL-8B.Q4_K_M.gguf`, 5,347,918,528 bytes, SHA-256
`d99ef62463658c8d4a6f54b1744599146414e68b836e3541247026987cdbb0f8`.
Only the adapted arm attaches `TwIL-8B-harbor-pi-lora-F16.gguf`, 197,958,112 bytes, SHA-256
`21e610324dd21e488a3c8c3cb6ff18135a74c7fb4cb1e121aedd5eb400db5eaf`, at runtime scale one.
Rank is 32 and alpha is 64. The [artifact record](harness-adapter-twil-artifacts.json) preserves publisher
revisions, original trained-base declaration, all 280 matched pairs and prior whole-payload verification.
Verify those digests again before generation. Neither arm merges the base into F32 weights.

Use the fixed release-engine program SHA-256
`c8d3ab420981a1ed5814ed55b5926b70ec3be4895bc58dba194de73751f5d7a7`, including the XML report repair.
Both arms use the publisher template SHA-256
`b0a1ec95f3ad2f879f8d9a8eea3355c6a7ff6f33e7ae0e75bf92a0285cd26a3b` and complete pinned resources.
Pin the new campaign harness, its source checkpoint and all hashes after validation, before execution.

## Matched settings and order

CPU, eight workers, batch 512, F16 keys and values, context 8192, integer arithmetic, packed rows and memory
mapping. Thinking is off in every session and work invocation. Drafting is disabled. Use temperature 0.8,
top-p one, top-k zero, min-p zero and the native default repeat penalty of one. Inference policy is fixed;
knowledge and carry are off. Native snapshots must confirm every effective control, including runtime
attachment count zero for base and one for adapted. Project configuration must remain unchanged.

Use `agent-campaign --thinking off --task edit --repeats 3 --seed 42 --max-seconds 300`. Each attempt opens
a fresh project under the existing Bubblewrap boundary and protected independent graders. The arm order is:

| Seed | First | Second |
| ---: | --- | --- |
| 42 | base | adapted |
| 43 | adapted | base |
| 44 | base | adapted |

Allow at most 300 seconds of model work per attempt: six attempts give a 1,800-second model-work allowance.
Startup, independent grading and hashing are separate. Apply a 2,400-second overall process timeout with
bounded termination grace. Stop on infrastructure failure or that hard limit; preserve incomplete records
without converting them into model failures. Continue after ordinary coding failures and timeouts. Do not
retry, replace seeds, change task or precision, or extend the work limit based on observed results.

Run sequentially on the quiet host with no builds, test suites, audits or competing model jobs. Temporary
idle/sleep inhibition lasts only for this process. F16 cache changes numeric outputs from the earlier q4t
pilot, so this is a separate matched experiment. Base and adapter fit the previously admitted 32 GB host;
recheck available memory. Keep grading records, transcripts, diffs and configuration snapshots. Generated
panel caches may be removed only after their attempt's processes have stopped.

## Reporting and interpretation

Primary outcome: paired verified completions, including adapted wins, adapted losses, both passed and both
failed. Report every attempt and every infrastructure error. A faster failure or fewer tokens without
completion is not an efficiency win. Report work and end-to-end time separately; successful-pair cost
comparisons must include only pairs where both arms passed. Retain unavailable metrics as null.

After completion, use the same pinned source, inputs and selector for check-only reuse, without running
missing attempts. Preserve the native manifest and summary, verify that reuse does not change the summary,
and publish the six results. The driver may exit one for ordinary failed outcomes; that is not by itself
an infrastructure failure. This three-pair, single-task screen supplies descriptive evidence without
significance, independence, noninferiority or general adapter-transfer claims. Do not start the old pilot
or a larger confirmation automatically, and do not change the model default.

## Completed result

The [six-attempt result](twil-adapter-paired-results.md) and its native records are published separately.
The protocol above remains the pre-generation scope; no outcome changes its settings, budgets or grades.
