# Historical Ada transfer evaluation

The [predeclared protocol](ada-transfer-protocol.md) defines six real-source tasks from project_tools,
regexp and versionlib, at two paired seeds, using base Mellum and the unchanged selected merged model.
The tools are native Ada programs in the tests crate. They add no production dependency or model default.

Each snapshot contains the original tracked `src` tree from the parent of its specified historical fix,
the original license, a small compilation main, public checks and a tracked empty object directory.
The Boolean parser task adds a real public API in the specification and body. Matcher tasks operate on
the existing large Regexp implementation. No source is renamed to the old Calc package.

Preparation qualifies unchanged and historical-reference controls against protected independent tests.
These tests include cases absent from public checks. Exact source scopes, unchanged public tests and
forced independent rebuilds prevent an edited test or unrelated patch from earning a pass. Each result
also checks its initial source tree and both protected test hashes against the frozen curriculum.

The actor and independent grader hide the complete original Ada workspace. Only the active project,
model, native executable, configuration and runtime resources are rebound as required. Independent
grader storage is exposed only during grading. Resource checksums, native version lookup and a denied
upstream-source read qualify the runtime boundary before generation.

Normal `alr build` in `tests` builds `ada_transfer_main`. Execute it through `alr exec --` to inherit the
pinned compiler. Set `MODEL_RUNNER_TRANSFER_PROTOCOL_SHA256` to the SHA-256 of the fixed protocol and
`MODEL_RUNNER_CONFIG` to the user's actual configuration. Existing destinations are refused.

```text
alr exec -- ./bin/ada_transfer_main prepare NEW_CURRICULUM ADA_WORKSPACE
alr exec -- ./bin/ada_transfer_main run NEW_EVALUATION CURRICULUM BASE MERGED MODEL_RUNNER
alr exec -- ./bin/ada_transfer_main summarize EVALUATION NEW_RESULTS_JSON
alr exec -- ./bin/ada_transfer_main diagnose EVALUATION NEW_DIAGNOSTICS
```

`run` freezes the manifest before its first model attempt and alternates arm order. An individual child
records its actual native workflow, protected grade, source identities, settings and counters. Task
failures remain results; infrastructure errors stop orchestration and preserve diagnostics. `summarize`
requires every planned record, matching manifest identities, unchanged project configuration, equal
paired inference settings and qualified source identities. Efficiency comparisons use only pairs both
models solve. `diagnose` copies failed submissions unchanged into fresh storage and independently tests
their final source without altering any original workflow grade.

Large snapshots, reference controls, captures, models and frozen binaries stay in the ignored private
`artifacts/ada-transfer-v1/obj/` directory. The merged model and all earlier training artifacts remain in
`artifacts/mellum-learning-v1/obj/`. This study does not retrain, select a different checkpoint, change
the sampling policy or attach the output-only adapter through the unsupported runtime LoRA path.
