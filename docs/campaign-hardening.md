# Campaign isolation and resolved settings

Subsequent real-model startup qualification places confined `XDG_CACHE_HOME` under the project's ignored
`obj` directory. Other homes remain inside the writable project. Initialization has a 300-second bound,
with early refusal on a reported startup error, separate from the unchanged per-task model-work budget.

This implements the campaign-hardening item in [the adapter plan](plan-harness-adapters.md).
It does not establish trained-adapter quality or complete the model resource gate.

## Operating-system boundary

Campaign execution requires Linux, Bubblewrap and usable user/process/mount namespaces. A real confined
preflight process must succeed before any attempt starts. There is no unconfined fallback. Check-only mode
can inspect existing records without starting a model.

The entire native interactive session runs inside the boundary, including its `/work` agents, helpers,
build commands and descendants. The host filesystem is read-only. Only the attempt's own project is writable;
the campaign directory is hidden before that project and exact model/program/configuration inputs are exposed
again. Other attempts, result records and preserved verifier sources are outside its writable scope and hidden.
Temporary storage and `/run` are private. Process, network and IPC namespaces are separate, capabilities are
dropped, and the child ends with the harness. Available render devices are explicitly exposed for native
compute backends; this is filesystem/process confinement, not a claim to sandbox graphics-driver internals.

The session must stop before independent grading starts. The grader rebuilds preserved tests into its own
object directory and confines both compilation and submitted-code execution. That object directory is its
only writable host directory. Preserved tests, campaign records and the project source are read-only there.

Scope checks use a separate bare Git baseline with an independent index and object storage, preserved before
work begins. Trusted initialization is sealed before `/work`, without replacing the preserved verifier tests.
Changes to tracked fixture inputs and unexpected untracked outputs are checked independently of ignore rules;
only declared native runtime locations are excluded. Changing or committing the agent project's `.git` state
cannot hide unrelated edits. Parent
diff reporting also uses this baseline. Parent-created transcript/diff entries are unlinked before opening,
so an agent-created symbolic or hard link cannot redirect a parent write after the confined process stops.

These controls preserve the existing independently qualified graders. They do not turn prose evaluation into
a semantic oracle or expand the pilot into an independent confirmation workload.

## Native resolved-setting evidence

`/settings json` prints a `MODEL_RUNNER_SETTINGS ` frame from the prepared model and open session.
`MODEL_RUNNER_REPORT_SETTINGS=1` additionally emits a frame before each `/work` root or helper round,
after policy fitting. Campaigns enable this automatically and preserve the frames in their attempt records.

Snapshots record actual backend, context capacity, worker count and key/value cache storage; arithmetic,
repacking, batch and output limits; seed and thinking/reasoning choices; template identity; runtime attachment
count; drafting and context-reuse controls; and the fitted policy and its value sources. Work-call frames
also identify root/helper role and round, remaining step/token/time allowances and the CLI helper limits.
Effective project helper policy is retained separately in the full configuration snapshots. Requested batch
size is kept alongside the effective model batch limit.
All twenty-one sampler fields are included, using the fitted request rather than command defaults.

The parent captures the full resolved project configuration before and after work, including retrieval,
permissions, inference policy, knowledge and task/helper budgets. A successful result cannot change that
configuration. Native work counters continue to record observed calls, tokens and compactions separately.
Unavailable memory observations remain null.

The parser bounds individual frames, aggregate bytes, frame count and nesting; rejects malformed or duplicate
JSON keys; requires all sampler fields; and rejects missing/duplicate session snapshots. Successful work
requires a root work-call frame. Every snapshot must preserve the paired seed, thinking choice and runtime
attachment count; session/root capacities must match the campaign's context. Helper capacities are recorded
as actually opened. These records are runtime evidence captured by the harness, not cryptographic attestation
of arbitrary model-produced output.

Version-two manifests bind the isolation backend and its executable digest as well as the existing model,
adapter, native program, harness and requested-control identities. The backend digest is checked again before
each new attempt. Version-two finished records require native settings and configuration snapshots before
reuse. Older records need a new campaign directory. Interrupted records remain available for reconciliation.

## Validation

The final focused suite passes **10/10**, including native boundary/descendant attacks, a confined independent
grader, Git-history spoofing, ignored outputs and tracked-input changes. A deterministic native helper-budget
case also passes **1/1** with reporting enabled. Its [raw output](campaign-hardening-helper-evidence.txt) contains
two root rounds and eleven helper rounds, including their actual decreasing token allowances.

The [native smoke evidence](campaign-hardening-evidence.json) and [manifest](campaign-hardening-manifest.json)
retain eight attempts through the actual interactive `/work` workflow. Both slots use the local Qwen3.5 0.8B
Q8_0 base; adapted arms attach the existing artificial rank-two adapter. All four arms use CPU, four workers,
F32 cache/arithmetic, no repacking, batch 32, context 8192, seed 42, temperature zero and disabled drafting.

All eight attempts reach their ten-second task budgets and are graded failed; there are **zero infrastructure
failures, zero pending attempts and no blocked records**. Sixteen native frames retain eight session and
eight fitted root snapshots, the correct zero/one attachment counts and unchanged project configuration.
This validates instrumentation and bounded failure handling, not adapter quality or a useful coding outcome.
The smoke runs alongside regression checks and is not a qualified speed measurement.

Check-only resume reuses all eight finished records with zero new attempts. The preserved summary's SHA-256
is `248e30b8b8e6a0013470f83fdad014924e2713f8ed6122ab0d020d0b532a7276` before and after that check.
The manifest pins the binaries actually run; its source revision names the preceding committed checkpoint
because the implementation was still uncommitted during validation. No artifact digests are restamped.

An earlier startup check exposed the interactive parser dropping the `json` argument. Its incomplete records
remain under `tests/obj/campaign-hardening-smoke-v2`; that run was stopped and the parser regression fixed.
The later metadata check under `tests/obj/campaign-hardening-qualified-v2` also completed eight bounded failures
without infrastructure errors and passed check-only and ordinary resume. The final sealed-baseline run is
under `tests/obj/campaign-hardening-final-v2` and supplies the linked evidence above.

The full regression suite passes **968/968**, with zero failed assertions and unexpected errors. After that
run, audit cleanup removes an obsolete unused-API exemption, normalizes a test log reader, captures resume
test output and corrects a schema-version comment. It changes no campaign or inference behavior. Native
evidence retains its original binary digests. After cleanup, campaign regressions pass **10/10** and release-gate
regressions pass **11/11**. The final repository audit completes **30,606 checks with zero failures** (exit 0).

The audit leaves its own duration unqualified: 231.24 CPU seconds exceeds the existing 195-second budget,
but host load 4.89 exceeds its idle-load requirement. It reports no dependency-warning verdict for Ada_Quality
or SSH_Lib because they have no qualifying compilation evidence in this tree. No allowance or threshold changed.

Final local logs:

- `/tmp/model-runner-campaign-hardening-root-complete-build.log`
- `/tmp/model-runner-campaign-hardening-audit-cleanup-build.log`
- `/tmp/model-runner-campaign-hardening-full-suite-final.log`
- `/tmp/model-runner-campaign-hardening-post-cleanup-focused.log`
- `/tmp/model-runner-campaign-hardening-release-gate.log`
- `/tmp/model-runner-campaign-hardening-helper-report-final.log`
- `/tmp/model-runner-campaign-hardening-final-repository.log`
