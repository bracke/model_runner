# Mellum local training and held-out results

**Subsequent decision: checkpoint retired.** The user rejected this adapter after the
[historical Ada transfer check](ada-transfer-results.md). The original pilot below remains unchanged;
its small descriptive difference did not establish a general benefit.

The original predeclared comparison is complete: **trained 5/9, base 4/9**, with two trained wins,
one trained loss, three pairs both passed and three both failed. All eighteen attempts finished with
zero infrastructure errors. This is a descriptive pilot on three task families and three seeds;
it cannot establish a reliable general accuracy or non-inferiority margin. The user's default model
and configuration are unchanged.

The [complete native report](mellum-learning-results.json) retains every outcome, settings and counters.
The [protocol](mellum-learning-protocol.md) was fixed before collection, fitting or held-out generation.

## Every original pair

| Task | Seed | Base | Trained | Base work (s) | Trained work (s) |
| --- | ---: | --- | --- | ---: | ---: |
| edit | 51 | passed | passed | 194.3 | 143.3 |
| edit | 52 | passed | failed | 158.3 | 300.2 |
| edit | 53 | passed | passed | 138.0 | 162.9 |
| times-negative | 51 | passed | passed | 185.9 | 163.7 |
| times-negative | 52 | failed | failed | 300.2 | 300.3 |
| times-negative | 53 | failed | passed | 300.1 | 133.6 |
| subtract | 51 | failed | failed | 138.5 | 196.6 |
| subtract | 52 | failed | failed | 110.5 | 180.4 |
| subtract | 53 | failed | passed | 155.6 | 110.2 |

A pass requires native workflow completion followed by protected source checks. Timeouts and invalid
completion reports remain failures. Work time excludes model startup. Faster failures do not count
as efficiency improvements: among the **three pairs both models passed**, median work time is
**162.9 seconds trained versus 185.9 seconds base**. Across all attempts, medians are 163.7 and
158.3 seconds respectively; those include failed workflows and are not a solved-task speed comparison.
Both arrays of costs and every generated-token/call count remain in the native report.

The trained loss is Add seed 52. The trained wins are Times seed 53 and Subtract seed 53.
These opposing outcomes and the small number of task families prevent a broad gain claim.

## What was actually trained

Fifteen fresh native teaching attempts all passed, across four training families and a separate calendar
validation family. The [collection ledger](mellum-learning-collection.json) retains all fifteen.
Two earlier infrastructure starts produced sixteen startup failures with zero generated tokens;
their records remain in the local archive. No existing Add, Times or Subtract capture or repair entered fitting.

The curator selected 45 frames: final verified edits, passed checks and completion replies, with exact
contexts and token IDs. It masks reasoning, tool output, prompt and forced text. Each training family
contributes 256 positions, totaling **1,024 training and 256 validation positions**.
The [feature manifest](mellum-learning-features.json) binds both datasets and frozen native feature files.

The native Ada fitter trains **804,864 actual parameters**, a rank-eight update to the output projection,
with the transformer frozen. This is output-only supervised learning, not full-transformer tuning or RL.
All eight epochs and the zero control are retained. Epoch six was selected solely by validation loss:
**0.04401747 versus 0.05423763** for zero, about 19% lower. The
[fit record](mellum-learning-fit.json) and [entire curve](mellum-learning-curve.json) retain selection evidence.
This token loss concerns unmerged frozen features; it does not establish correct autonomous work.

The selected adapter SHA-256 is
`535c8f558cfd2f27f689d128c1daf7f4d853cc4d96d01ad472e867ebb66baf22`.
It was applied at its declared scale into a new GGUF, SHA-256
`49d512650e5a8cfc79f22357a5d6fad5ef863fa8307b8aacda01bb9bf0ff1b5a`.
The [independent byte comparison](mellum-learning-merge-verification.json) confirms a changed Q6_K
output tensor and exact identity everywhere else. Encoding squared error is 52.292 against a learned
update squared norm of 1,629.126. The workflow test uses that actual converted model, including encoding
and deployed arithmetic effects.

## Failure evidence and separate source checks

The ordinary native grader fails an unfinished workflow before rebuilding its final source.
Consequently, a timeout or rejected completion report does not by itself prove the final patch is wrong.

After every timed attempt ended, the nine failed patches were rebuilt in fresh object directories against
their original protected tests. [These separate diagnostics](mellum-learning-posthoc-source.json)
find **six passing patches, two test failures and one compile failure**. No original grade is upgraded.

The trained Add seed-52 patch has incorrect overflow guards and fails its protected tests.
The trained Times seed-52 patch omits an end-loop statement and does not compile.
Base Times seed 53 compiles but fails its protected tests. Base Times seed 52 passes the source checks,
but its native workflow did not finish before the deadline.

All five failed Subtract patches pass the separate source checks. Their native reports joined filenames
with spaces, producing one nonexistent claimed path. The captured instructions asked for
`changed_files: the files you wrote` without specifying a separator, although the existing parser accepts
commas or separate lines. A separately declared [guidance check](mellum-completion-files-protocol.md)
addresses this observed friction without altering the original comparison or its grades.
The [completed separate check](mellum-completion-files-results.md) passes once with each model on seed 61;
both native replies use commas and both protected graders pass. It is not added to the original totals.

## Controls, artifacts and limits

All nine pairs have identical trusted initial source/test identities, recorded in
[the source-identity ledger](mellum-learning-source-identities.json). The native report confirms matching
paired settings and unchanged per-project configuration. Both arms used the same frozen executable,
ordinary tools, sampling, device/cache policy, 300-second work limit and unforced thinking defaults.
Carried knowledge was disabled. Arm order alternated. Repository build and test jobs ended before comparison.

The evaluation executable SHA-256 is
`27d02ebbf288d721e0ce944d13ac79ac1ec451b4a31c54c9946540df0f845d9d`;
the frozen comparison driver is
`3845ca6afc86448181727644ebe6775aab5adf68d42e96d371a462ccdccfb351`.
The user configuration remained
`ed2d533da3ce230ea54872e752ca689885ab353fa78df3666c58778fe763a8da`.
The model base remained
`ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755`.

The teacher executable was the earlier normal build with SHA-256
`300ff259277d837371271cfa44b0211e7cd35bfba8d57a98ec8c3f4b0d78e0b0`.
The collector and training binary images are preserved. Before any held-out attempt, comparison
confinement was hardened to hide all sibling attempts; its real visibility/write/descendant check passes.
Observed teaching file requests stayed within the fixture sources.

Local retained artifacts are under `artifacts/mellum-learning-v1/obj/`:
`fitted/selected.gguf` is the retired adapter; `mellum-output-lora-r8-merged.gguf` is its retired merged model.
The zero control, all epochs, final checkpoint, features, datasets, raw projects/captures and frozen programs
remain local. Large weights are excluded from version control. See [usage and limits](mellum-learning.md).

The original implementation passed [997 tests and the repository audit](mellum-learning-validation.md).
The audit's structural checks passed; its duration remained unqualified under the existing load gate.
The final guidance correction passes 998 tests and 30,924 audit checks; its
[two native checks](mellum-completion-files-results.md) pass and remain separate from this comparison.
