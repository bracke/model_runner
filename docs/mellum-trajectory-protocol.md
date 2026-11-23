# One captured Mellum coding task

Frozen before model execution on 2026-11-23, following the user's instruction to validate the capture
pipeline with the model selected in their actual settings. This is one end-to-end capture check, not
an adapter comparison, model-quality benchmark, training run or restart of the cancelled TwIL pilot.

Use the existing `/home/bent/models/Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf` (8,071,295,264 bytes),
SHA-256 `ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755`.
Read the unchanged `/home/bent/.config/model_runner/config`, SHA-256
`ed2d533da3ce230ea54872e752ca689885ab353fa78df3666c58778fe763a8da`.
It selects this model and hides models from the chooser; it sets no runtime tuning options.
Preserve automatic backend, context, cache, arithmetic, batching, sampling, drafting and thinking choices.
Record the actual resolved settings rather than copying the former TwIL campaign's overrides.

Use the current executable, SHA-256
`633eb1a9fc430d15f518042aa0e67582889237f4d6590e9ce18609d054886eec`, from source `b5d35726`.
Freeze the native trial driver binary and source before starting it. Build no software during inference.

Run exactly one existing `Agent_Trial` edit fixture with no repeat or retry. Through the normal interactive
`/work` route, make `Calc.Add` saturate at Integer bounds instead of overflowing, changing only Add.
Use the session's context and fixed inference policy, with the fixture's ordinary knowledge setting.
Limit model work to 300 seconds and the complete driver, including controls and startup, to 900 seconds.
Do not disable thinking, attach an adapter, override a template or download another model.

Run the existing independent grader's reference/no-op/known-wrong/scope controls before the model.
Confine the actual session with the existing Bubblewrap boundary: only its fresh project is writable;
the enclosing evidence directory and protected verifier baseline are hidden. Keep capture inside the
project's `.trial-runtime` directory, with the feature's default limits. Preserve the user's settings file
as a read-only input, while keeping conversations and caches in the isolated project's runtime directories.
The trusted parent grades only after the session stops, using protected verifier sources and bounded-diff
checks. Preserve every ordinary failure or infrastructure failure distinctly, without substituting a retry.

Validate every complete captured stream, retain incomplete streams, and select the actual root episode
for a full export. Bind its capture hash, native task/revision, expected output and independent result to
the frozen verifier binary and actual protected result artifact. Assign this fixture family to `test`.
Validate the self-contained export and confirm supervised eligibility agrees with the actual grade,
capture completeness and provenance. Do not execute tools again when validating an export.

Retain native settings, transcript, diff, protected grader outputs, event streams, artifact hashes and
export. Report what the check proves and any missing evidence; do not claim coding quality or train an adapter.

## Frozen driver

The one-run Ada driver and project are retained under `tests/obj/mellum-trajectory-v1/probe`.
Driver binary SHA-256: `c8a247a9a2fb9e880ba0dd83f5a075467d49b6de9010ab007839ec7125bc48a6`.
Driver source SHA-256: `a34216b8bba965ec8d41f682d08c48249383ef04af289b7c6bfdf1100ed792f2`.
It calls the existing `Agent_Trial` and `Trial_Graders` implementations and records their returned outcome.
The native grader source SHA-256 is
`0e350da0bf9f243abc6c0f7915667333b382d6b3e5fb54af3d8ff2e3a0238609`.
The driver builds without warnings. No product or inference implementation is changed for this check.
