# Directed Mellum reference result

Completed on 2026-11-23 under the [declared protocol](mellum-reference-directed-protocol.md).
**The directed coding task failed. Reference replacement and stale-reference refusal worked, but Mellum
left uncompilable Ada when its original 300-second work allowance expired. A completion benefit is unproven.**

## Actual outcome

The user-configured `Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf` ran once with unchanged inference defaults.
There was no retry, adapter, training, download or template override. Protected grader controls passed
before launch. Model, configuration, program and driver identities were frozen and remained unchanged.

| Observation | Result |
| --- | --- |
| Native independent grade | Failed; out of time |
| Work / loading / elapsed | 300.3 / 207.836230 / 509.481534 seconds |
| Generated tokens / tool calls | 8,129 / 11 |
| Reference edit attempts | 3 |
| Successful replacements / stale refusals | 2 / 1 |
| Passage edits / whole-file writes / helpers | 0 / 0 / 0 |
| Source outside Add | Unchanged, including Times |
| Independent protected rebuild | Failed, exit 4 |

Mellum found the complete body reference and replaced Add through `ref`. Its first implementation used
`and` where Ada requires `and then` to avoid evaluating an overflowing guard expression. The check
reported that failure with a concrete correction. The next repair reused the original reference and was
refused as stale, leaving the current file intact. Mellum then used the fresh reference returned by the
first replacement, proving that the refreshed reference can authorize another edit.

That replacement introduced a `declare` block missing its `begin` and closing `end;`. The compiler
reported both errors. Mellum read the source and eventually fetched its current declaration, but did not
complete another edit before timeout. No final source was repaired by the evaluator.

After the model stopped, a separate Bubblewrap build compiled the protected original behavioral test
against the submitted source, with only the protected object directory writable. It reproduced the syntax
errors. No stale executable was run. The protected test source matches the original; a baseline diff and
byte comparison confirm only Add changed. The [independent result](mellum-reference-directed-independent-result.json)
retains the actual native grade and post-run result.

## Validation and evidence

Normal builds and the frozen driver build pass. Six focused reference tests and all 11 campaign tests
pass. The final complete suite passes **988/988**, and the repository audit passes **30,785 checks with
zero failures**. The first full run caught a registration error in the new fixture's grader controls;
that error was corrected, its focused controls passed, and the full suite was rerun successfully.
The audit's existing load gate leaves its duration unqualified; no timing bound was changed.

The completed capture contains 24,459 events and exact token evidence for 14 generations. One forced
thought closure is recorded separately with loss mask zero; the last generation ends at the time limit.
Capture completeness means the failed task was fully recorded, not that the task succeeded.

Native capture validation passes. The 6,354,294-byte full export validates normally and with its original
capture and verifier artifacts hidden. It contains the independently bound failed result, reports
`supervised_eligible=false` and `rl_ready=false`, and remains in the test split. No training is started.
The [result record](mellum-reference-directed-results.json) contains settings, hashes, call results and limits.

Raw evidence is retained locally under `tests/obj/mellum-reference-directed-v1`, including the frozen Ada
driver, original baseline, final source diff, protected compiler output, complete capture and full export.
The run log is `/tmp/model-runner-mellum-reference-directed-run.log`. No model process remains running.

## What this establishes

Mellum actually used revision-bound body replacement, received usable fresh references and encountered a
correct stale-reference refusal. This qualifies real use of those tool paths. The complete directed
workflow did not pass. Reference acceptance checks the target's structural identity and revision; it does
not validate Ada syntax or behavior. Independent checks remain necessary.

The earlier ordinary task passed using `old_text`; this directed task failed using `ref`. These are
unpaired stochastic runs with different instructions, so they do not establish a causal advantage or
disadvantage. Keep reference editing as an optional editing aid; do not describe it as a demonstrated
Mellum completion or speed improvement.
