# Native local Mellum output-adapter experiment

The [protocol](mellum-learning-protocol.md) and [data-selection contract](mellum-learning-curation.md)
define this experiment. It trains a rank-eight low-rank output-projection update against the exact local
quantized Mellum base. The transformer is frozen. This is a small supervised local experiment, not
full-transformer fine-tuning, reinforcement learning or reproduction of a published harness adapter.

All project-owned tools are Ada in the tests crate. Normal `alr build` from `tests` builds both `tests`
and `mellum_learning_main`. No training dependency enters production and no external service is used.

The local fit is retained in [the checkpoint record](mellum-learning-fit.json) and
[complete learning curve](mellum-learning-curve.json). The [feature manifest](mellum-learning-features.json)
binds both source datasets and frozen feature files. The [collection ledger](mellum-learning-collection.json)
retains all fifteen generated teaching outcomes. These fitting results alone do not establish a workflow gain.
The [completed original comparison](mellum-learning-results.md) records all nine pairs: trained 5/9,
base 4/9, two trained wins and one loss, with no reliable general-gain claim.
The [implementation checks](mellum-learning-validation.md) and separately declared
[completed report-guidance check](mellum-completion-files-results.md) retain their own scopes.

## Operations

Run from the tests crate. Destinations must be new; existing models and checkpoints are never overwritten.
The `MODEL_RUNNER_CONFIG` environment variable selects the same settings file used by the real sessions.

```text
./bin/mellum_learning_main controls NEW_CONTROL_ROOT
./bin/mellum_learning_main collect-all NEW_COLLECTION_ROOT MODEL PROGRAM
./bin/mellum_learning_main curate COLLECTION NEW_DATASET
./bin/mellum_learning_main extract MODEL DATASET NEW_FEATURES
./bin/mellum_learning_main fit MODEL FEATURES NEW_CHECKPOINTS
./bin/mellum_learning_main merge MODEL ADAPTER NEW_MODEL
./bin/mellum_learning_main evaluate-all NEW_EVALUATION_ROOT BASE ADAPTED PROGRAM
./bin/mellum_learning_main summarize EVALUATION NEW_JSON
```

`MODEL_RUNNER_LEARNING_PROTOCOL_SHA256` can bind a separately declared follow-up to its own protocol
digest. It defaults to the original protocol and refuses values other than 64 lowercase hexadecimal digits.
It changes provenance only; it does not alter model, sampling, task, budget or grading settings.

Collection creates fresh committed teaching projects and runs the ordinary native `/work` harness inside
Bubblewrap. A passing grade requires a completed native workflow and then independent protected tests and
baseline checks. A timeout fails the completion gate before that final rebuild; separate source diagnostics
cannot upgrade its workflow outcome. The fixed collection is fifteen attempts across five families and three seeds.
Task failures are retained; infrastructure errors stop collection for diagnosis. The first four families train; the
calendar family validates. No existing Add, Times or Subtract test example is used for fitting.

The curator selects actual visible assistant tokens from verified final edits, successful checks and
completion replies. Earlier wrong edits, reasoning, tool output and forced text receive no loss.
Each frame retains exact token IDs and selected positions, plus capture and independent-result hashes.
A diagnostic `curate-preview` mode selects the completed first family only; it is not a complete dataset.

Extraction produces frozen normalized states and base logits once. Fitting uses full-vocabulary
cross-entropy, deterministic initialization and shuffle, Adam, gradient clipping and eight epochs.
It retains `zero.gguf`, every epoch, `final.gguf`, `selected.gguf`, `curve.jsonl` and `fit.json`.
Selection uses validation loss alone and always retains an actually updated checkpoint; the result says
whether validation improved over the zero control. Held-out outcomes cannot tune the checkpoint or scale.

## Use and limits of artifacts

The adapter contains F32 `output.weight.lora_a` and `output.weight.lora_b`, with alpha equal to rank and
the exact base SHA-256. Use this tool's `merge` operation to apply it. The production runtime attachment
API does not support this output-only Mellum adapter; do not pass it to `--lora` and describe that as support.

The merger writes a new GGUF with the original tensor formats, dimensions and offsets. Every byte outside
`output.weight` is copied. The output tensor is decoded, updated and encoded at its original precision.
Its sidecar records model and adapter hashes, update norm and quantization error. A zero adapter preserves
the whole file exactly. The resulting merged GGUF runs through ordinary native inference:

```text
../bin/model_runner /path/to/adapted-model.gguf
```

The original model and user configuration remain unchanged. Training a valid adapter does not establish
a quality gain. The final comparison uses the actual converted model on ordinary held-out workflows,
with paired seeds and unchanged thinking defaults. It reports every failure and descriptive paired costs;
nine pairs on three task families cannot establish a broad accuracy or non-inferiority claim.

Local weights and evidence live under `artifacts/mellum-learning-v1/obj/`, outside version control:
`fitted/selected.gguf` is the trained adapter, and `mellum-output-lora-r8-merged.gguf` is the usable model.
`fitted/` also retains the zero control, every epoch and the final checkpoint. The original collection and
the two infrastructure starts are preserved in `collection-evidence.tar.gz`, with repository-relative paths.
`evaluation-evidence.tar.gz` preserves all eighteen original attempts and the separate failed-source checks.
The [artifact ledger](mellum-learning-artifacts.json) records archive and weight hashes; local `SHA256SUMS`
also covers retained checkpoints, datasets, features and frozen programs.
The [independent merged-file comparison](mellum-learning-merge-verification.json) verifies the actual
nonzero output tensor and exact byte identity everywhere else. Encoding error remains part of the applied
artifact; the workflow comparison measures that converted artifact rather than an isolated F32 update.

The mandatory numerical checks cover independently differentiated gradients, real parameter learning,
lineage and zero-merge identity, nonzero F32/Q6_K weight oracles, feature/next-token alignment, complete
checkpoint fitting and tamper refusal, regression-safe default-arm statistics and hidden sibling solutions.
The collection/comparison driver hides its entire enclosing campaign, then rebinds only the active project
and declared inputs. Its native regression checks visibility, project writes and descendant confinement.
Large Mellum runs are explicit experiments outside the normal suite.
Synthetic numerical fixtures never enter the real corpus.
