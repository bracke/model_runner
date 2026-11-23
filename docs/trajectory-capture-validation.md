# Trajectory capture validation

Validated locally on 2026-11-23. This implements stage five's capture/export foundation;
it does not train an adapter or establish that a training dataset improves coding quality.

The complete native suite passes **982/982**, with zero failed assertions and zero unexpected errors.
The ten trajectory tests include real generation through the tiny native model, identical captured and
uncaptured token output, terminal and partial UTF-8 tokens, grammar and stop controls, full content beyond
the ordinary excerpt limit, malformed input, interrupted writes, retention limits and corruption checks.
The agent-loop tests cover actual tool execution, nested delegation and capture failures that preserve
the model outcome. Disabled or incomplete helper capture also prevents a complete parent episode.

The independent-verdict fixture binds capture and verifier-result digests and qualifies a full export.
Changing its eligibility flag or an embedded helper is rejected. Standalone validation still succeeds
after source captures and verifier-result files are removed or changed, because full exports carry their
evidence. This exercises the data-integrity contract; the fixture is not a newly graded coding trial.
Production callers must supply a protected independent grader and curate repository/task-family splits.

CLI validation, full export and standalone validation also pass against a native tiny-model capture.
Standalone CLI validation passes against the self-contained helper-family fixture.
Root and test builds complete without compiler warnings or errors.

The final repository audit passes **30,760 checks with zero failures** (exit zero). The preceding audit
had only the expected stale no-adapter fingerprint; it was replaced after the passing fresh measurements,
and its original row and evidence remain historical. The audit's own 211.08-second processor cost exceeds
its 195-second allowance at host load 1.32, so its existing load gate leaves that duration unqualified.
No allowance or timing threshold was changed.

The first sandboxed full-suite run could not open a local HTTP fixture's loopback socket and was stopped
without a verdict. An unrestricted run then exposed that template provenance returned the compiler's
literal pool. The implementation now retains the exact original template source, and its regression
checks source equality and clearing on close. The subsequent complete suite passes all 982 tests.

Capture-disabled performance uses the separately frozen
[two-batch protocol](trajectory-no-adapter-protocol.md). All measured samples and qualification results
are retained separately; no coding-adapter quality study or cancelled pilot is resumed.

The [28-run evidence](trajectory-no-adapter-evidence.json) passes the unchanged 1.05 paired-median boundary
for both phases in both batches. All fixed-work output digests match. Measured paired median changes are
+0.02%/-0.01% for prompt/decode in batch one and +0.04%/+0.32% in batch two. Source, binary, dependency
and input identities are unchanged after timing. These are descriptive local results, with no significance
or tail-latency claim.

Known scope limits remain explicit: text-only exact episodes, trusted external verifier attestations,
root-level supervised labels, bounded local retention, no policy log probabilities and `rl_ready=false`.
See the [capture guide](trajectory-capture.md) for commands, limits and dataset requirements.
