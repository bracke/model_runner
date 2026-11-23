# Complete local trajectories

Trajectory capture is an explicit opt-in. It records source, prompts and tool output and never uploads
them. Ordinary excerpt-only journals remain diagnostic history; they are not complete training episodes.
No trainer, training server or model download is part of this feature.

## Capture and retention

Set `MODEL_RUNNER_CAPTURE_DIR` to a dedicated absolute directory before starting model_runner. A missing
directory is created privately. An existing directory must be private and must not be a symbolic link.
Leave this variable unset for ordinary execution without capture.

```text
MODEL_RUNNER_CAPTURE_DIR=/absolute/private/captures bin/model_runner run MODEL.gguf --agent --prompt TASK
```

The shared agent loop captures ordinary tool agents, conversation tool turns, native `/work` and helpers.
Project subprocess work passes the capture settings explicitly through its environment allowlist. The
directory must also be writable within any OS confinement boundary; capture grants no extra filesystem
permissions. The embedded agent API accepts explicit `Trajectories.Options` instead of environment defaults.

Each run reserves a new `episode-N` directory. Defaults are 16 MiB per episode and 64 retained slots.
`MODEL_RUNNER_CAPTURE_MAX_BYTES` accepts 1,024 through 67,108,864 bytes;
`MODEL_RUNNER_CAPTURE_MAX_EPISODES` accepts 1 through 1,024 slots. An individual event is bounded to 4 MiB.
Retention refuses new captures at its limit and never deletes or overwrites old evidence. Remove selected
old directories explicitly after exporting or deciding they are no longer needed.

Active and interrupted captures are `events.jsonl.partial`. Only a successful finish publishes
`events.jsonl`. A failed write, limit or reservation is a capture failure, separate from the model's outcome;
the CLI reports it and model work continues. An interrupted file cannot qualify by merely having passing
project checks. Captures are private, and exported content also uses a private, new destination.
Each helper is bound to its actual parent call and its completed stream digest. A missing or failed helper
capture leaves the parent incomplete too. There are at most 1,024 active helper links. Validation/export
accepts families up to 1,024 streams, depth 32 and 64 MiB total raw evidence; export JSON is capped at 128 MiB.

## What is recorded

Schema version one is an ordered JSON-lines stream. Each envelope has `sequence`, `kind`, `payload`
and `sha256`. Payload is a JSON object encoded as a string, preserving its exact bytes for hashing.
The first previous digest is 64 zeroes. Each next digest is SHA-256 over previous digest, newline,
decimal sequence, newline, lower-case event kind, newline and the exact payload string bytes.
This detects missing, changed or reordered records; it is not a signature authenticating the producer.

The start records harness identity, full template source, offered tool schemas, reasoning and agent budgets,
parent linkage and provenance. CLI capture adds native invocation/task IDs where available, frozen project
revision, complete model/shard/auxiliary/adapter digests and scales, attachment mode and resolved native
runtime settings. The tokenizer is identified by its containing model artifacts. Template overrides are
preserved as their actual compiled source, rather than inferred from a format name or original model file.

Context events contain ordered roles, full message content, multimodal parts and parsed call arguments.
They preserve the actual contexts around retries, compaction, rejected replies and harness feedback.
Raw reply events preserve the agent-consumed reply. Output events separately preserve every emitted
generation fragment, even if the agent's ordinary retained-text buffer would shorten the reply.
Tool call/result events preserve complete parsed arguments and returned text, including failed or refused
calls; context snapshots also preserve what was actually fitted back into the next model input.

Each native generation records the actual fitted request and sampler values, effective seed, exact rendered
input and the input token IDs produced by tokenization. Sampled IDs include terminal tokens suppressed from
text output. Token bytes use hexadecimal because a token can contain only part of a UTF-8 character.
Separate commitment events distinguish selected tokens from tokens successfully evaluated in the session.
Generation endings retain cancellation, time limits, resource exhaustion and runtime failures distinctly.
The exact compiled grammar is recorded as its used rules, elements and character ranges. Configured stop
tokens and the exact hexadecimal bytes of stop strings are recorded with every generation. Request and
sampling record images retain all fitted Ada fields, alongside the CLI's structured JSON settings.

Input blocks carry loss mask zero; model selections carry one. Forced reasoning closures carry zero and
are distinct from model output. The next input records their actual retokenized IDs. Each generation is a
separate model decision boundary; never treat the concatenated journal text as a single sampled sequence.
This is not an RL integration: per-policy log probabilities and rollout/trainer provenance are absent.

Text generation is the training-capture scope. Scripted replies have no sampled model IDs and are explicitly
ineligible. Multimodal embedding rows and rolling-context shifts are not represented by this text schema;
those runs retain diagnostic evidence but are marked ineligible rather than silently called exact episodes.

## Validate and export

```text
tests/bin/tests trajectories --episode /absolute/private/captures/episode-1/events.jsonl
tests/bin/tests trajectories --mode export --episode EPISODE --out NEW.json
tests/bin/tests trajectories --mode export --episode EPISODE --out NEW.json --include-content
tests/bin/tests trajectories --mode validate-export --episode NEW.json
```

Validation checks version, bounds, chain, event order, generation boundaries, token IDs and masks,
commitment counts and tool call/result pairing. It rejects missing data, altered records and partial files.
It never replays calls or re-executes mutating tools. Selection is one explicit episode and its bound helper
streams; there is no automatic filesystem sweep or upload. Existing export destinations are refused.

Export without `--include-content` omits prompts, source, tool output and event payloads. It retains counts,
hashes, outcome and any explicitly supplied verification metadata. This redacted form is never training
eligible. Full export is a versioned JSON object with exact root event lines as strings in `events`, preserving
their bytes for digest validation. `children` embeds each bound helper's complete JSON-lines stream and
identities; it does not inherit a successful-demonstration label from the parent. The selected root is the
unit of supervised eligibility. A full export also embeds explicitly supplied verifier result bytes.
`validate-export` checks the embedded streams, helper graph, proof digests, outcomes and eligibility flags
without opening the original capture paths or verifier files. Deleting source artifacts does not prevent
validation of an already completed full export.
Changing or redacting full event payloads breaks capture identity and requires a diagnostic-only derivative.

An agent saying it finished is not an independent grade. Full unverified exports remain diagnostic data.
To attach independent evidence, pass `--verification VERDICT.json`. The external verdict must have:

```json
{
  "schema_version": 1,
  "capture_sha256": "64 lower-case hex digits for the selected event file",
  "independent": true,
  "task_id": "the task identifier",
  "task_family": "repository and related task family",
  "project_revision": "the independently checked project revision",
  "split": "train",
  "expected_outputs": ["src/example.adb"],
  "verifier_sha256": "64 lower-case hex digits identifying the verifier",
  "verifier_result_path": "/absolute/protected/grader-result",
  "verifier_result_sha256": "64 lower-case hex digits for that result artifact",
  "result": "passed"
}
```

Allowed splits are `train`, `validation` and `test`; results are `passed`, `failed`, `refused` and `exhausted`.
The exporter checks capture binding and the actual result artifact digest. The caller supplies the trusted
independent verifier evidence; a JSON assertion of independence is not cryptographic proof. Protect graders
from the agent and qualify them with reference, no-op and known-wrong changes, as the native trial graders do.

Only complete exact captures with complete artifact provenance, explicitly included content, an answered
agent outcome and matching independent success are labeled `supervised_eligible`. Negative outcomes remain
labeled diagnostic/evaluation evidence; they are not converted into successful demonstrations. `rl_ready`
stays false. Export eligibility is a data-integrity gate, not evidence that training will improve the model.

## Dataset contract

Curate only validated, independently graded episodes. Assign entire repository/task families, including
near-duplicate fixes and all helper streams, to one split before selecting examples. Keep final evaluation
families untouched. Do not split retries or seed variants of one task across training and evaluation.
Retain failed/refused/exhausted outcomes separately for evaluation and any future, separately scoped RL work.
Record the selection, capture hashes, grader versions and split policy in the dataset manifest. No dataset
or adapter is automatically trained, published or recommended by capture or export.

The [validation record](trajectory-capture-validation.md) documents native generation, helper bundles,
corruption and limit checks, standalone export validation and capture-disabled performance qualification.
