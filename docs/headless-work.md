# Headless Work Contract

`model_runner work` is the versioned, noninteractive adapter over the native
`Model_Runner.Framework.Work` engine. It uses the same model-backed agent,
task lifecycle, permissions, workspace isolation, verification gates,
cancellation, and recovery as interactive `/work`.

All commands require `--format json`. The current `schema_version` is `1`.
Call `model_runner work capabilities --format json` before relying on optional
operations.

## Inspection and execution

Inspect a task before dispatch and retain every returned identity:

```text
model_runner work inspect --project PATH --task TASK-001 --format json
```

Execute only with the exact inspected values:

```text
model_runner work execute --project PATH --task TASK-001 \
  --operation-id qm-execution-000001 \
  --expected-task-revision TASK-FINGERPRINT \
  --expected-project-identity PROJECT-ID \
  --expected-source-fingerprint SOURCE-FINGERPRINT \
  --execution-policy POLICY-FINGERPRINT \
  --timeout-seconds 3600 --noninteractive --format json
```

An operation ID is permanently bound to its canonical, length-framed request.
Repeating the exact request returns the recorded outcome and never starts a
second agent. Reusing the ID with different input is rejected. If a process
stops after recording `invoking` but before recording an outcome, another
execute call reports `reconciling`; it does not guess that a retry is safe.

Use `status --project PATH --operation-id ID`, `cancel` with the same options,
and `recover --project PATH`. `integrate` additionally requires
`--authorization conflict-free`; semantic-conflict acceptance is deliberately
not exposed.

## Result interpretation

`native_task_state` preserves the project-defined state and `core_state`
preserves its declared native mapping. `execution_state` is the adapter's
explicit normalized value: `not_ready`, `ready`, `executing`, `blocked`,
`awaiting_integration`, `verifying`, `completed`, `failed`, `cancelled`, or
`incompatible`. Unknown mappings are never treated as success.

`result: success` means native execution reached `verification` or `complete`.
It does not certify quality or replace independent assessment. The JSON Schema
for emitted documents is [headless-work-v1.schema.json](headless-work-v1.schema.json).

