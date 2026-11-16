# Code Health

Code Health checks source changes made by an agent and returns trusted,
bounded diagnostics in the tool result. A successful edit and a passing
assessment are separate outcomes: the harness, not the model, decides whether
the current evidence permits completion.

The initial provider is native Ada. It recognizes `.ads`, `.adb` and `.gpr`
files and relevant project metadata, uses GNAT and the configured language
server where available, and reuses change-scoped `ada_quality` source
indicators. Providers report missing mandatory tools as unavailable; they do
not turn that condition into a pass.

## Interactive conversations

Code Health is off by default for an ordinary conversation. Enable the fast
post-edit assessment in the settings file:

```
code-health.enabled = true
code-health.on-edit = true
code-health.focused-test = alr test
```

After a successful filesystem-changing tool call, model_runner reconciles the
actual project tree. This includes files created by shell commands and files
that are not tracked by Git. Failed, refused and no-op calls do not manufacture
a successful assessment. A finding is appended to the tool result as trusted
harness metadata; compiler messages and source excerpts inside it remain
untrusted diagnostic data.

When the model next proposes a final answer, the completion controller runs a
fresh focused assessment over the accumulated changed-file scope. The result
is bound to the current tree snapshot and replaces the latest fast result for
that completion decision. Blocking or unavailable checks cannot be replaced
by a statement such as “all tests pass.” If budgets permit, blocking feedback
starts another repair turn. Repeated ineffective repairs stop at the configured
stagnation or assessment limit.

With `code-health.on-edit = false`, that completion-boundary assessment still
runs. It reconciles the actual tree against the captured baseline, so shell,
external and otherwise undispatched changes cannot bypass enforcement.

The focused test is empty by default. Without an explicit reliable command,
the affected-test check is unavailable rather than guessing that no tests are
affected.

The existing `hook.after-edit` and `hook.after-turn` settings remain
independent. Hook output is not Code Health evidence. When Code Health is
enabled, configured language-server findings are normalized by the Ada
provider instead of also being printed as a duplicate post-edit report.

## Spec-driven projects

Generated Ada application and library projects enable Code Health. Their
resolved configuration includes, in logical form:

```
scalar code_health.enabled = true
scalar code_health.block_on = error
set code_health.providers = ada
set code_health.fast_checks = syntax,formatting,hygiene,security
set code_health.focused_checks = build,affected_tests
profile code_health.full = tests
set task.gates.implementation = code_health
```

The Ada provider resolves these names before an agent starts. `syntax` maps
to the GNAT syntax check; `formatting`, `hygiene`, `security`, and
`complexity` share one change-scoped `ada_quality` execution; `build` maps
to dependency-aware project validation; and `affected_tests` maps to the
configured affected-test scope (or its explicit fallback). Repeated aliases
for the shared source analysis are coalesced. Unknown checks and providers
are configuration errors, not silently skipped checks. The language-server
check can be selected as `language_server` or `lsp`; it is optional in the
built-in interactive profiles and reports its actual availability.
The shared source execution also retains applicable `DOC-01` findings for a
changed public specification, so documentation regressions use the same
ada_quality rule identifier and evidence contract rather than a copied rule.
`contracts`, `proof`, and `gnatprove` select the optional focused
`ada-contracts` check. It runs GNATprove in check mode through the same
execution policy, deadline, output, cancellation, and source-mutation guards
as other native checks; a selected mandatory instance is unavailable rather
than passed when GNATprove or its project mapping is absent.

Equivalent entries are emitted for the applicable bug-fix and test task
kinds. The project configuration remains authoritative: user settings cannot
weaken a mandatory task gate.

`/work` captures the task generation, agent invocation and workspace in each assessment. Fast
checks run synchronously after observed changes, including delegated and shell
changes. A focused assessment runs when the agent proposes its answer, and a
blocking result is fed back through the bounded remediation loop. At task
completion, the configured full verification profile produces an immutable
Code Health assessment linked to the verification evidence. The `code_health`
gate accepts only current, passing evidence for the task's generation and
integrated source state. Evidence from a different task or workspace, stale
evidence, and unavailable providers do not satisfy it.

`/task audit ID` shows the current Code Health assessment beside the task's
verification evidence, including passed/failed check counts and new, changed,
existing, resolved, and incomparable finding counts.

## Profiles and findings

The provider API supports three levels:

- `fast` checks changed files and local context after a modification;
- `focused` adds dependency-aware compilation and an explicitly mapped or
  configured fallback test scope;
- `full` is the project's existing formal verification profile at a mandatory
  completion boundary.

An absent affected-test mapping is not treated as proof that no tests are
affected. A focused caller must supply a fallback scope or receive an
unavailable check.

Validated profile fields are execution policy, not documentation. Each
selected check carries its required flag, deadline, prerequisite checks,
blocking severity, changed/dependency/project scope, cache policy,
external-tool requirements, and retained-output limit into the provider
request. Native commands receive the smaller of the check and owning
assessment limits. A failed or unavailable prerequisite prevents its dependent
check from running and produces an explicit unavailable result. A check cannot
silently widen or narrow its configured scope; whole-project checks receive
the captured project snapshot, while dependency checks receive only explicit
dependency information and report unavailable when a reliable mapping is
required but absent.

Diagnostics carry the provider, originating check and native rule, severity, location when one is
available, remediation, stable fingerprint, source snapshot and evidence
provenance. They are sorted deterministically and bounded before reaching the
model. Full records are retained as immutable framework evidence where a
project store is active.

Framework-backed assessments may reuse an immutable result only when the
provider can probe a complete current cache context. The key covers provider
and version, selected checks and analyzed scope, source snapshot,
configuration, toolchain, and analysis environment; framework applicability
also binds it to the task generation, workspace, agent, and invocation.
Providers without that capability always execute. Focused test commands and
live language-server diagnostics are deliberately uncached because V1 cannot
yet fingerprint all of their prerequisites.

New errors and critical findings block by default. Existing comparable
findings can be classified separately from regressions; changed policy,
provider, toolchain, scope or analysis environment prevents an unsafe baseline
comparison. An unavailable, cancelled or stale mandatory check never becomes a
pass.

More than one registered provider may analyze the same change. Selection and
execution order are stable by provider identifier, and immutable evidence
retains each provider result separately. Overlapping diagnostics are merged
only when their semantic identity proves equivalence; their contributing
provenance remains visible.

## Acceptance coverage

The `Code Health contracts` AUnit group is the deterministic release authority
for CH-E2E-01 through CH-E2E-20. Its cases cover valid and invalid Ada edits,
repair/recheck, shared exception and source rules, compilation and affected-test
regressions, stagnation, baseline classification, unavailable tooling, stale
snapshots, shell and delegated changes, policy weakening, completion
interception, disabled behavior, malformed providers, cancellation,
LSP/provider deduplication, cache-safe repeated calls, and the final task gate.

The suite also exercises the cross-cutting contracts that the scenario list
depends on: deterministic multi-provider evidence, per-check severity and
scope enforcement, GNATprove selection, bounded untrusted feedback, exact
cache invalidation, and the concise `/task audit` health summary. Live-model
agent trials remain optional diagnostics; scripted agents and fake providers
are authoritative for orchestration so release results do not depend on model
sampling.

## Execution and safety

Automatic checks receive no authority beyond the active execution policy.
External tools use the framework's allowed-program, working-directory,
environment, deadline, cancellation, network and resource controls. The
framework runner binds those permissions before analysis, so editing the
project policy during a task cannot grant a running assessment new authority.

Checks advertised as read-only are guarded against source modification.
Unexpected changes make the result stale or operationally failed. Provider
data is structurally validated before persistence; malformed data or a
provider exception cannot crash the agent session. Model-facing output repairs
invalid UTF-8, redacts secret-shaped values and applies diagnostic and byte
limits.

## Current scope

V1 registers native providers at startup; dynamically loaded provider
libraries and a second quality-judging LLM are not supported. Analysis
providers never edit application source. Ada is the shipped language provider;
the registry and normalized contracts are available for additional languages.

The release authority is the deterministic AUnit suite, including change
reconciliation, malformed-provider, completion-gate, repair/recheck,
cancellation, workspace and evidence-isolation cases. Live-model exercises are
diagnostic and do not replace those tests.
