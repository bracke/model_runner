# Mellum check after reference editing

Completed on 2026-11-23 under the [predeclared protocol](mellum-reference-edit-protocol.md), at implementation
checkpoint `f43ec891`. **Mellum passes the coding task using ordinary passage editing. It makes no `ref`
call. Real-model use of the new reference mode therefore remains unqualified.**

The implemented reference primitive passes five deterministic tests through its production API and tool
path. The complete suite passes **987/987**, and the repository audit passes **30,781 checks with zero
failures**. See [structural validation](reference-editing-validation.md). Those results establish the
primitive's tested behavior; this model run does not establish that it improves completion.

## One ordinary task

The task wording is unchanged: make `Calc.Add` saturate at Integer bounds, changing only Add. There is no
additional reference-mode instruction in the task and no forced tool choice. The offered `edit_file`
description includes the new reference mode, as confirmed in the captured start metadata.
Exactly one attempt runs, with no retry, training, adapter, template override or model download.

The model is the existing user-configured `Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf`. Both native setting
snapshots retain automatic device execution, context 131,072, seven workers, batch 512, q4t keys, q4 values,
integer arithmetic, no repacking, temperature 0.4, top-k 40, top-p 0.95 and min-p 0.05. Seed, thinking and
reasoning remain unspecified. Drafting and runtime attachments are absent. The settings file, model,
executable and frozen Ada driver have the same hashes after the run as before it.

| Observation | Result |
| --- | --- |
| Native independent grade | Passed; complete |
| Model work | 96.8 seconds, within the 300-second limit |
| Native elapsed time | 306.687243 seconds |
| Native loading time | 208.350464 seconds |
| Committed generated tokens | 1,828 |
| Model generations | 4, all ending naturally |
| Tool calls | 3 |
| Reference / passage edits | 0 / 1 |
| Helpers / compactions / forced closures | 0 / 0 / 0 |
| Project configuration | Unchanged |

The calls are `read_file`, `edit_file` with `old_text`, and `run_checks`. Mellum replaces the whole Add
body through the existing passage mode, using branches that guard `Integer'Last - B` and
`Integer'First - B` correctly. The source check and protected baseline diff confirm only Add changes.
The native grader passes. A separate protected rebuild after the model stops also compiles and executes
the original behavioral verifier successfully, with the verifier source unchanged.

The native completion message includes an informational unreported-path warning beginning `.trial-r`.
The existing protected grader excludes reserved trial runtime artifacts; source scope, configuration and
behavioral checks pass. The full native message remains in the retained run log.

## Capture and export

The completed 1,336,532-byte capture contains 5,508 events, four model inputs, 1,832 selections, 1,828
commitments and three paired tool exchanges. Native validation reports complete exact token evidence
and complete provenance. No helper stream is present.

The 1,578,269-byte full export validates both normally and inside a boundary hiding the original evidence
directory, including captures and verifier result files. It embeds the actual independently bound passing
result. Its derived flags are `capture_complete=true`, `exact_tokens=true`, `provenance_complete=true`,
`supervised_eligible=true` and `rl_ready=false`. Export permissions are 0600.

This positive episode exercises the successful real-capture path. Its family remains assigned to `test`,
so the structural eligibility flag does not make it training data. No dataset or adapter is trained.

## Interpretation and retained evidence

The earlier failed run is preserved. One successful stochastic attempt, with a newly built program, is
not a matched comparison against that failure. No speed or completion-rate gain is attributed to the new
feature. Reference mode is available and structurally tested, but this attempt did not use it. No further
attempt is substituted to make that outcome look different.

The [result record](mellum-reference-edit-results.json) contains all settings, counts, timings, mode use
and artifact identities. The [independent result](mellum-reference-edit-independent-result.json) is copied
byte-for-byte from protected local evidence. Its SHA-256 is
`37a5c971e89a5b9dd3dd5d6f7f6c96677eaa1dbea6cb7e4849187df74b333bf3`.

Complete local evidence is retained under `tests/obj/mellum-reference-edit-v1`, including the frozen driver,
grader controls, transcript, source diff, protected outputs, capture, verdict and `full-export.json`.
The run log is `/tmp/model-runner-mellum-reference-edit-run.log`. No model process remains running.
