# Corrected edit-contract Ada transfer comparison

Declared 2026-11-24 after the user requested a response to repeated timeouts, before any model attempt
with the corrected edit schema. This is a separate engineering evaluation, not a replacement of failed
attempts in the [original protocol](ada-transfer-protocol.md).

The original comparison stops after six of its planned 24 attempts. Base passes both CRLF seeds;
trained times out on both. Both arms time out on empty-TOML seed 71. All six starting-source identities
match, and every failure remains failed. Eighteen original attempts remain unattempted, not failed or
passed. The held dispatcher is terminated only after the sixth model process finishes.

Captured calls expose a contract defect: edit_file's JSON schema requires only path and new_text while
its executor also requires ref or old_text. Both trained CRLF attempts repeat selector-less calls, and
the base TOML attempt exhausts its reply budget writing an incomplete selector-less full-file edit.
These are observed workflow failures, not evidence that protected test execution is too slow.

Correct the advertised schema to the union of two complete, closed argument objects:

- path, ref, new_text, with optional revision;
- path, old_text, new_text, with optional revision.

Neither and both selectors must be impossible in the constrained call grammar. Keep source matching,
reference boundaries, revision checks and protected grading unchanged. Clarify recovery errors and tell
the model not to copy displayed line-number prefixes. Verify the actual JSON and tag call grammars,
including the full tool set remaining constrained rather than silently taking its loose fallback.

Run required builds, focused regressions, the complete suite and repository audit with no model process
active. Freeze the corrected executable, driver, runtime resources, compiler, configuration, curriculum
and this protocol before generation. Regenerate all six unchanged/reference controls; their source trees,
task notes and public/independent test hashes must match the original curriculum exactly.

Use the same six tasks in the same order: text-crlf, toml-empty, toml-boolean, regexp-property,
regexp-backreference, version-refnames. Use seeds 71 and 72, both base and adapted arms: **12 pairs,
24 fresh attempts**. Alternate order using task index plus seed parity as before. Retain the exact base
and selected epoch-six merged weights, the user's inference defaults, unforced thinking and effort,
disabled carried knowledge, 600-second work bound, 300-second startup bounds and 1,200-second child bound.
Run serially. No repository build, unrelated test or training job runs alongside inference.

Apply the original completion, protected independent test, exact source-scope, configuration and confinement
requirements. Retain every failure without replacement. Inspect a completed failure's captured calls and
termination reasons immediately; distinguish invalid calls, incorrect source, deadline exhaustion and
infrastructure errors. Do not silently extend deadlines, alter sampling, repair submissions or tune weights.

After all 24 corrected-harness attempts, produce every grade, per-task totals, paired wins/losses,
configuration/source identities, calls, generated tokens and work costs. Efficiency comparisons use only
pairs both models solve. Separately diagnose final failed sources without upgrading workflow grades.
Archive the original partial comparison and corrected complete comparison separately.

This evaluation is adaptive: the edit-contract correction was selected after observing six original
attempts, and those two task families are reused. It tests practical behavior under the corrected harness;
it is not a blind confirmation or a reliable general accuracy margin. Other limits remain six historical
tasks from three repositories, two seeds, cold sessions, large prompts, one machine and a small output-only
adapter. No further fitting, checkpoint selection, automatic default-model change or promotion is authorized.
