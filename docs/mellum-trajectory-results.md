# Real Mellum trajectory check

Completed on 2026-11-23 under the [frozen protocol](mellum-trajectory-protocol.md).
**The coding task failed; capture, export and standalone validation passed.** The full export correctly
has `supervised_eligible=false`. No successful training example, adapter or model improvement is claimed.

## Model and actual settings

The run uses the model selected in the user's unchanged settings:
`Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf`. It uses the existing file and native automatic choices,
without a TwIL model, adapter, template override or thinking override. Actual snapshots show the device
backend, context 131,072, seven workers, batch 512, integer arithmetic, no repacking, q4t keys and q4 values,
temperature 0.4, top-k 40, top-p 0.95 and min-p 0.05. Drafting and runtime attachments are absent.
Thinking and reasoning remain unspecified, preserving the template's behavior. The fitted work policy
uses a 2,048-token thinking limit. Both forced thinking closures are preserved separately with mask zero.

Exactly one existing native `/work` edit fixture is run in a fresh, confined project. Its task is to make
`Calc.Add` saturate at Integer bounds, changing only Add. The model, settings file, executable and frozen
Ada driver retain their original hashes after execution. No task retry or additional model run occurs.

## Actual result

| Observation | Result |
| --- | --- |
| Native independent grade | Failed; out of time |
| Model work | 300.1 seconds against the declared 300-second limit |
| Native elapsed time | 507.666276 seconds |
| Native loading time | 206.183890 seconds, including fresh GPU setup |
| Committed generated tokens | 8,345 |
| Captured generations | 10 |
| Captured tool calls/results | 7 / 7 |
| Helpers / compactions | 0 / 0 |
| Project configuration | Unchanged |

Mellum edits Add and runs the project checks. The check fails with an overflow error, and subsequent reads
do not repair the edit before the time limit. The retained change uses eager Boolean operators in its
overflow guards and an incorrect negative bound. The protected baseline diff confirms only Add changes.

The native grader preserves the timeout as a failed task. After the agent stops, a separate check compiles
the protected original verifier against the final submitted source, ignoring agent-produced objects.
Compilation exits zero; the confined test exits one with
`CONSTRAINT_ERROR : calc.adb:5 overflow check failed`. The verifier source is unchanged. This additional
check does not replace or regrade the original timeout outcome. Grader reference/no-op/known-wrong/scope
controls passed before the model started. The grader and its baseline were outside the agent's writable
project; the enclosing evidence directory was hidden by the existing Bubblewrap boundary.

## Capture and export

The completed capture has 25,085 events, 10 model inputs, 8,352 selections, 8,345 commitments, seven paired
tool exchanges and two forced closures. Its 5,471,691 bytes validate with complete exact token evidence
and complete artifact provenance. There are no helper streams in this task.

The 6,334,563-byte full export embeds the complete event stream and the independently bound result.
Both ordinary standalone validation and validation inside a boundary hiding the entire original evidence
directory exit zero. Original event streams and grader-result files are therefore unavailable in the latter
check. Export permissions are 0600; capture directories remain 0700.

| Derived export flag | Value |
| --- | --- |
| `capture_complete` | true |
| `exact_tokens` | true |
| `provenance_complete` | true |
| Independent outcome | exhausted |
| `supervised_eligible` | false |
| `rl_ready` | false |

The fixture family is assigned to `test` and is not added to training data. This run exercises the real
negative-outcome path. A successful real demonstration and a real helper invocation remain untested by
this particular run; separate native component tests cover their serialization and eligibility rules.
One failed task is not a general model-quality result, and no capture-overhead comparison was run.

## Evidence

The [result record](mellum-trajectory-results.json) retains settings, counts, timings, paths and digests.
The [independent result](mellum-trajectory-independent-result.json) is copied byte-for-byte from protected
local evidence, including the native timeout grade and the additional source check.
Its SHA-256 is `1019400d1913d63dc106838e1e417f9dc1dc94b59836be5f92f94c24d355cbf8`.

Complete local evidence remains under `tests/obj/mellum-trajectory-v1`: frozen Ada driver, controls,
transcript, source diff, protected verifier outputs, capture, verdict and `full-export.json`.
Full event content is retained locally rather than committed. The source checkpoint is `b5d35726`;
no product or inference implementation changes are needed for this check. The run log is
`/tmp/model-runner-mellum-capture-run.log`.
