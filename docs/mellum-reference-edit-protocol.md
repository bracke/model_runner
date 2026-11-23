# One Mellum check after reference editing

Declared before generation on 2026-11-23. This checks the new `edit_file` reference mode with the user's
configured Mellum model. It is one bounded workflow check, not a quality comparison or a training run.
The earlier failed task and [offline diagnosis](mellum-trajectory-review.md) remain unchanged evidence.

Run the same existing native `edit` fixture once: make `Calc.Add` saturate at Integer bounds, changing
only Add. Retain its ordinary task wording; do not add a reference-mode hint to the task or force the
model to choose the new mode. Record whether it actually uses `ref`, what the tool returns and the
independently graded outcome. A pass without reference-mode use does not qualify that path in a real model.
One outcome, even with successful reference use, cannot establish an improvement in completion rates.

Use `/home/bent/models/Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf`, SHA-256
`ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755`, with the unchanged settings file,
SHA-256 `ed2d533da3ce230ea54872e752ca689885ab353fa78df3666c58778fe763a8da`.
Leave backend, context, arithmetic, cache, batching, sampling, seed, thinking and drafting automatic.
Use no adapter, template override, model download, extra attempt or retry.

Finish normal builds, the complete native suite, focused structural tests and the repository audit before
generation. Freeze the implementation checkpoint, executable, native trial driver and model/settings
identities. Do no build or test campaigns alongside the model. The program's build is recorded; the old
run is not treated as a matched experimental control.

Use the existing one-run Ada driver in `tests/obj/mellum-reference-edit-v1/probe`, with unchanged driver
source SHA-256 `a34216b8bba965ec8d41f682d08c48249383ef04af289b7c6bfdf1100ed792f2`.
It qualifies the protected native grader before starting the one ordinary interactive `/work` task.
The fresh project is the only writable directory inside the existing Bubblewrap boundary, with the
enclosing evidence and verifier baseline hidden. Retain conversations, cache and opt-in captures inside
the project, using the capture feature's normal limits. Preserve the actual settings and configuration.

Limit work to 300 seconds, keep the existing 300-second startup wait, and bound the complete driver to
900 seconds. Preserve ordinary failures and infrastructure errors distinctly, including any startup
failure. There is no automatic expansion of the time limit based on progress or outcome.

After the process stops, retain the native grade and independently compile/run the protected original
behavioral test against the final submitted source, ignoring agent-produced objects. Verify unchanged
grader sources and a bounded diff. Do not modify the submitted source to make a check pass.

Validate the completed captured streams, bind the actual independent outcome and result artifact, export
full content locally, and validate the export both normally and with original evidence hidden. Keep
successful-demonstration eligibility derived from the actual result, completeness and provenance.
Reserve this fixture family for `test`; create no training dataset or adapter.
