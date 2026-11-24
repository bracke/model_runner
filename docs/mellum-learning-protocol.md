# Local Mellum learning and held-out workflow evaluation

Authorized by the user on 2026-11-23: complete training and evaluation without further prompts.
This protocol is declared before new teacher rollouts, parameter fitting or held-out evaluation.

## Model, resources and intervention

Use the existing user model `Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf`, SHA-256
`ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755`.
The host has 30 GiB RAM, an eight-core Ryzen 7840U and its integrated GPU. There is no installed trainer.
Use native Ada tooling in the tests crate, with no external service, paid compute or production dependency.
Keep the frozen quantized transformer. Train a rank-eight LoRA update to `output.weight`, with alpha eight.
This is output-projection adaptation, not full-transformer fine-tuning or reinforcement learning.

Capture normalized hidden states and base logits by teacher forcing verified native trajectories once;
optimize cross-entropy on selected actual assistant tokens with the rest of the model frozen. Environment,
prompt and forced tokens receive no loss. Use bounded storage, explicit shapes and finite-value checks.
Numerically test the gradient independently before fitting. Retain a zero-update control and trained weights.
Apply the learned update by streaming a new GGUF, preserving every byte outside the output tensor and
retaining its original quantization. Record quantization error and validate the resulting native model.
No change to the user's default model or configuration is part of this experiment.

## Data split and collection

Create fresh, independently graded families: ASCII case conversion, array parity counting, reverse character
search and record visibility for training; Gregorian calendar logic for validation. These are newly authored
MIT-licensed fixtures. Preserve neighboring code and protected original tests. Qualify all five graders with
unchanged failing code and a passing reference before generation. Ordinary tool choice is retained: no
mandatory reference editing, alternative template or reasoning override.

Collect three attempts per family using seeds 42, 43 and 44, each in a fresh Bubblewrap project. Use the
existing 300-second work and startup bounds. Retain every outcome. Only independently passing, complete,
exact-token captures are supervised demonstrations. Failed attempts remain labeled diagnostic evidence.
Never relabel an evaluator's repair as a model-generated success. Native configuration and resolved settings
must be recorded. Use the user's defaults, with knowledge carry disabled across attempts.

Cap fitting data at 1,024 loss positions, balanced across the four training families, and validation at 256.
Select positions deterministically across eligible completed assistant generations, independent of token
likelihood. The entire family stays in one split. Existing Add, Times and Subtract evaluation examples,
including all previous captures and their corrections, are excluded from training and model selection.
Record every selected position, generation, source digest and token identity. Refuse incomplete evidence.

## Fit and select

Use deterministic rank-eight initialization with a zero output factor, Adam optimization, learning rate
0.001, gradient clipping, batches of eight, and at most eight epochs. Keep the base frozen. Record every
epoch's train and validation cross-entropy, elapsed time, nonzero update norms and checkpoint digest.
Select the best nonzero checkpoint by validation loss alone; report if none improves over the zero control.
The held-out workflows cannot select the epoch, learning rate, examples or adapter scale. Keep the final
training checkpoint as well as the selected checkpoint. Fit actual parameters; a synthetic adapter or a
prompt change cannot satisfy this deliverable.

## Independent held-out comparison and completion

Freeze the native executable before comparison. Run the ordinary `edit`, `times-negative` and `subtract`
fixtures, base versus the selected adapted GGUF, with paired seeds 51, 52 and 53. Alternate arm order.
Both arms keep the same deployed tools, sampling, context, cache, device policy, 300-second work bound and
startup bound. Do not force reference editing or thinking settings. Protect graders and source baselines.
Record settings, source hashes, grade, new failures, work/loading times, calls and generated tokens.

Complete all nine pairs. Distinguish infrastructure errors from task failures and preserve interrupted
attempts if infrastructure repairs are required. Do not omit timeouts or collect replacement successes.
Report all-attempt completion first, paired wins and losses, then costs on jointly passing tasks. This
small, three-family local experiment cannot establish broad accuracy or a reliable non-inferiority margin.
Report uncertainty and every regression. A negative or inconclusive outcome is a completed experiment,
not permission to claim a gain or silently change the user's defaults.

Completion requires reproducible native tools, qualified data and numerical tests, actual trained adapter
weights and their applied GGUF, native execution checks after conversion, the complete held-out comparison,
normal builds and required tests, and a committed report linking retained local artifacts and limitations.
Use the previously authorized 16-hour compute ceiling; preserve checkpoints and all outcomes within it.
