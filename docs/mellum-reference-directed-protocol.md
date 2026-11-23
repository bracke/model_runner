# Directed Mellum reference integration check

Declared before generation on 2026-11-23. The earlier ordinary Mellum task passed through `old_text`
and did not exercise reference editing. Its evidence is retained unchanged. This separate check must
exercise the production reference path and independently verify the resulting behavior and source scope.

Run the native named-only `edit-ref` fixture: make `Calc.Add` saturate at Integer bounds, changing only
Add. It explicitly instructs the model to obtain the complete body reference with `find`, replace it
using `edit_file` with `path`, `ref` and `new_text`, and run checks. No `old_text`, `write_file` or helper
is permitted. The native grader requires a complete exact capture with an actually successful reference
replacement before applying its protected behavioral verifier and source-diff checks. A passage edit,
failed reference call, no-op or missing capture cannot qualify this directed test.

Use the user's existing Mellum model and configuration without inference overrides, adapters, training,
downloads or template changes. Model SHA-256 is
`ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755`; configuration SHA-256 is
`ed2d533da3ce230ea54872e752ca689885ab353fa78df3666c58778fe763a8da`. Freeze the program, driver and
implementation identities before generation. Finish builds, full tests and the repository audit first;
run no build or test campaigns alongside the model.

Use one fresh native driver under `tests/obj/mellum-reference-directed-v1/probe`, with one repeat, a
300-second work limit, the existing 300-second startup wait and a 900-second whole-driver bound.
Use the existing Bubblewrap confinement: only the fresh project is writable and the enclosing evidence
and protected verifier are hidden. The fixture enables capture inside the project's reserved runtime
directory. Preserve actual configuration and resolved settings.

Retain the first outcome, including failure. Do not silently substitute attempts or change time limits.
If an actual integration defect prevents completion, retain its evidence, fix and test the defect, and
declare a revised attempt explicitly before running it. A model task failure is not itself a tool defect.

After the model stops, inspect the actual call/result pair and independently compile and execute the
protected original verifier against the submitted source, ignoring actor-built objects. Confirm only
Add changes and verifier sources remain unchanged. Bind the actual result to the completed capture,
export full evidence locally, and validate the export normally and with the original evidence hidden.
Keep the fixture family in the test split. Commit concise result records and retain raw evidence locally.

Completion means successful real reference use, independently correct behavior, preserved source scope
and validated evidence. This directed integration check does not establish spontaneous adoption, higher
completion rates or a speed advantage. Those claims require a separately designed comparison.
