# Ada transfer comparison with runtime call constraints

Declared 2026-11-24 after two stopped partial comparisons and before any model attempt using the runtime
constraint repair. This adaptive engineering evaluation retains the original model weights and task
selection. It is separate from the [original six attempts](ada-transfer-original-partial.json) and the
[schema-only four attempts](ada-transfer-schema-partial.json); no original outcome is replaced or upgraded.

The original schema admitted edits without selectors. Correcting that schema did not constrain Mellum's
actual later calls: the agent explicitly disabled constraints for its Open_JSON reader. A captured trained
seed-72 CRLF call therefore lacked a selector again. The schema-only run stops after all four CRLF attempts;
base seed 71 passes, the other three time out, and twenty planned attempts remain unattempted.

Repair the runtime boundary before further comparison. Marked calls in Open_JSON must use the tool grammar
on every turn; ordinary JSON examples and the existing bare-call reader remain available. Generation
resumed after a budget cuts a call must advance the grammar over its already generated prefix rather than
drop the constraint. Capture that prefix explicitly without emitting or counting it again. Invalid prefixes
must fail before sampling. Verify actual sampled agent turns and sampled continuations, then required
builds, the complete suite and repository audit, with no model inference active.

Regenerate and qualify all six historical controls. Require exact equality of their task records with the
original curriculum: whole source trees, notes, public and independent test hashes, and permitted paths.
Freeze protocol, curriculum, executable, native driver, runtime resources, compiler and configuration
before generation. Record native runtime resource and upstream-isolation preflights.

Run all six tasks in their original order: text-crlf, toml-empty, toml-boolean, regexp-property,
regexp-backreference and version-refnames. Use seeds 71 and 72 and both base and adapted arms: **12 pairs,
24 fresh attempts**. Alternate arm order using task index plus seed parity. Retain the original base and
selected epoch-six merged weights, user's inference defaults, unforced thinking/effort, disabled carried
knowledge, 600-second work bound, 300-second startup bounds and 1,200-second child bound. Run serially;
no build, unrelated test or training job runs alongside inference.

Inspect actual generation_start capture records, including continuations, while the first model attempt
runs and after each attempt. Require non-null compiled grammars and grammar_constrained=true in each.
Inspect every failed attempt's calls, tool results and termination reasons immediately. Stop orchestration
for a repeated runtime constraint or setup defect; preserve completed grades and distinguish an interrupted
study from a completed one. Valid model errors, incorrect Ada, failed tests and deadline exhaustion remain
failed attempts. Never extend a deadline, repair a submission or replace a failed attempt within the study.

After all 24 outcomes, require protected independent tests, exact change scopes, matching initial source
identities and unchanged/equal paired configuration snapshots as in the original protocol. Report every
grade, runtime constraint evidence, task totals, paired wins/losses, calls, tokens and time. Compare costs
only on pairs both arms solve. Diagnose failed final sources separately without upgrading workflow grades.
Archive both partial runs and the completed runtime comparison separately with checksums and frozen images.

Two repairs were selected after ten observed attempts, all on CRLF or empty TOML. Those tasks and seeds are
reused. This is not a blind confirmation or a reliable general accuracy margin. Other limits remain six
historical tasks from three repositories, two correlated seeds, cold sessions, large prompts, one machine
and a small output-only adapter. No further fitting, checkpoint selection, default-model change or automatic
promotion is part of this evaluation. A harness repair alone is not evidence of a model-quality gain.
