# Harness adapter campaigns

Current implementation, checks and remaining gates are recorded in [the execution report](harness-adapter-execution.md).

`tests agent-campaign` drives the existing `Agent_Trial` workflow. Each attempt opens a real model_runner
session, initializes a fresh project, runs `/work`, preserves its session and diff, and grades the result after
the session has ended. It does not use a substitute agent loop or an external inference runtime.

## Pinned artifacts and resource admission

The published candidate set is pinned in [harness-adapter-artifacts.json](harness-adapter-artifacts.json).
Expected whole-file digests are the upstream LFS digests, not claims of a completed local verification.
[harness-adapter-header-inspection.json](harness-adapter-header-inspection.json) records descriptor inspection
of bounded downloaded prefixes. It does not verify missing tensor bytes or establish that inference works.

The two Q8_0 models have matching tensor descriptors, tokenizer metadata, templates and resolved architecture
configuration. All 256 adapter pairs resolve to the original model's matrices with matching dimensions.
Their architecture is `qwen35`. The original has 26,895,998,464 parameters; an F32 copy of those parameters
alone is 107,583,993,856 bytes. At context 8192, the native q4t session estimate is another 341,169,626 bytes.
That session estimate is not an observed process high-water mark or a complete device admission calculation.

The inspected host has a Ryzen 7 7840U, an integrated Radeon 780M, and 32,814,366,720 bytes of physical memory.
Available memory during the recorded probe was about 22.8 GB. Each original Q8_0 file is 28,595,763,840 bytes,
so its working set fails the resource gate before caches, workspace and an application margin are counted.
The integrated GPU shares RAM. Expanding to F32 is also outside this host's budget.

A possible fallback is to acquire and verify both pinned Q8_0 files, then quantize both with the same native
quantizer, settings and binary. That produces a new local experiment; it is not a reproduction of the BF16
scores. The existing streaming quantizer holds one tensor rather than the whole model. Account for its largest
tensor and decoded copy as well as inference memory before starting. Do not compare an unrelated local
fine-tune with the adapter or silently lower precision in only one arm.

## Header inspection

For complete local files, inspect with:

```text
tests/bin/tests agent-campaign --mode inspect --base BASE.gguf --adapted ADAPTED.gguf \
  --adapter ADAPTER.gguf --out inspection.json
```

For a bounded prefix, additionally give the corresponding advertised complete size with `--base-bytes`,
`--adapted-bytes` or `--adapter-bytes`. Reads still fail if metadata itself is missing. The output always says
`payload_verified: false`. Advertising a length does not manufacture or validate the absent weights.

## CPU attachment checks

The CLI can now execute a separate adapter over a quantized base:

```text
model_runner run BASE.gguf --lora ADAPTER.gguf --lora-mode runtime --prompt "..."
```

This selects CPU and disables drafting by default. The native API is `Llama.Attach_Adapter`; F32 merging
remains the default CLI mode. Dense Llama, Qwen2, Qwen3 and Qwen35 main-layer targets are supported.
Device execution, experts and drafting are refused. A runtime file can contain only supported complete pairs.

For execution instrumentation without a trained adapter, create a bounded artificial rank-two fixture:

```text
tests/bin/tests adapter-fixture --model BASE.gguf --out /tmp/synthetic-lora.gguf \
  --tensor blk.0.ffn_gate.weight
```

This copies architecture and dimensions, not trained values. It cannot establish adapter compatibility by
lineage or a quality gain. The [CPU smoke record](harness-adapter-cpu-smoke.json) reports the exact local model,
fixture, settings and memory observations. The paired campaign below accepts complete model files or a
separate runtime adapter on either model. Shared `--lora` controls are refused.

For wider synthetic timing, add `--rank 32 --all-targets` to the fixture command. It includes every present
supported projection in the main layers, skips absent recurrent-layer attention projections, and excludes
next-layer draft weights. Rank is capped at 64, and encoded matrix data at 128 MiB. Output paths must be new.

Run paired CPU measurements through the existing speed runner:

```text
tests/bin/tests adapter-bench --model BASE.gguf --adapter ADAPTER.gguf \
  --prompt-file tests/fixtures/speed-prompt-110.txt --out timing.json \
  --repeats 5 --max-tokens 16 --threads 4 --batch-size 16 --context-size 512 --include-merge
```

The arms are unadapted quantized base, zero-scale attachment, active runtime attachment, and optional same-base
F32 merging. Each arm reloads the model, runs one untimed full warm-up, then measures one complete generation.
Arm order reverses on alternate repetitions. Every arm must generate exactly the requested count (EOS is
ignored), and zero scale must preserve the base output digest. Sampling is the speed runner's temperature-zero
configuration with seed one; arithmetic is F32, cache precision exact, drafting disabled and panel-file caching
disabled. Model preparation and adapter loading are timed separately from prompt and decode execution.

JSON retains every sample, input/binary SHA-256 digests, adapter rank/count, accounted model/adapter bytes,
host load/temperature and descriptive medians of paired time ratios. RSS is unavailable in this in-process
report and remains null. The model account excludes borrowed mapped pages and must not be read as total
process memory. Benchmark admission limits the base estimate to half of available RAM and decoded adapter
storage to one quarter, with the native attachment limits also enforced.
The default omits F32 merging; `--include-merge` can be expensive for wide adapters.
Synthetic timing does not establish trained-adapter quality, the cost of the released 27B adapter, or the
performance effect of the no-adapter branch relative to a previous executable.

## Paired trials

Run from the tests directory after building both crates:

```text
bin/tests agent-campaign --base /models/base.gguf --adapted /models/adapted.gguf \
  --program ../bin/model_runner --out obj/adapter-pilot --repeats 3 \
  --context-size 8192 --max-seconds 300 \
  --task edit,find,delegate,styled,convention,large,described,delegate-edit,times-negative,subtract,c-boundary,c-multi \
  --options "--backend cpu --threads 8 --kv-cache q4t --temperature 0.8 --top-p 1 --top-k 0 --min-p 0"
```

The four arms are `base-off`, `adapted-off`, `base-on` and `adapted-on`. Arm order reverses by task and repeat.
Seeds match within paired attempts. Drafting is disabled explicitly, inference policy is fixed, carried
knowledge is disabled, and inherited MODEL_RUNNER settings and standing instructions are replaced with a
campaign-owned empty configuration. Shared options cannot override thinking, drafting, context or seeds.
Use an explicit hardware backend; a software Vulkan device is not a measurement of the integrated GPU.

To compare a quantized base against the same base with a separate runtime adapter, use the same model path
in both slots and select the adapter only for the adapted arms:

```text
bin/tests agent-campaign --base /models/base.gguf --adapted /models/base.gguf \
  --adapted-adapter "/models/adapter with spaces.gguf" --adapted-scale 1 \
  --program ../bin/model_runner --out obj/runtime-adapter-pilot --repeats 3 \
  --context-size 8192 --max-seconds 300 --task edit,find,delegate \
  --options "--backend cpu --threads 8 --kv-cache q4t"
```

`--base-adapter` and `--base-scale` independently select the base arms' adapter and scale. Each slot accepts
one runtime adapter; scale defaults to one and must be finite. A non-default scale requires an adapter.
Scales must round-trip exactly through the native CLI's decimal parser; values outside its integer/fraction
range are refused before creating a campaign, rather than rounded into a different scale.
Zero scale is available as an execution control. Adapter paths are passed as individual native arguments,
including paths containing spaces. Runtime-adapter campaigns require an explicit CPU backend in shared
options for both models; native validation still checks architecture, tensors and resource admission.
This campaign path does not select F32 merging or enable device/draft execution.

The default three tasks are smoke checks. The twelve-task pilot includes related variants of the same fix;
they are not twelve independent repository families or a substitute for the frozen confirmation suite.
The last four tasks add negative multiplication, an Ada spec/body change, and C boundary and spec/body changes.

The coding verifiers preserve their test source outside the agent's project. After work ends they rebuild
into trusted storage with `gnatmake` or `cc` and run the preserved test. A changed in-project test is refused.
Campaign execution now requires a working Linux Bubblewrap boundary around the entire session and its
descendants. Only the current project is writable; other attempts and trusted verifier storage are hidden.
Compilation and independent test execution are also confined. A protected Git baseline prevents commits
inside the agent project from hiding unrelated changes. See [the boundary and evidence](campaign-hardening.md).
The mandatory campaign tests qualify every pilot grader with no-op, reference and known-wrong controls,
and reject unrelated source/document changes. Analysis grading reads the final report rather than tool
traces and checks the requested path and declaration line. Documentation grading checks file contents;
it does not prove the quality of every explanation or independently reconstruct which agent wrote a document.

## Records and resume

Version-two `manifest.json` binds exact model, program and campaign-harness SHA-256 digests, source revision, tasks,
options, seed, repeat count and budgets. It also binds each arm's adapter path, whole-file SHA-256, runtime
mode and scale. Adapter files are rehashed before starting each new attached attempt. Files with different
paths or settings require a different output
directory. A process lock protects each campaign; attempt records are atomically published with syncs.
Each attempt is marked `invoking` before work starts and `finished` only after its outcome is recorded.

Repeat the same command to resume. Each finished attempt includes its manifest's SHA-256 and arm identity;
both must match before reuse. A changed manifest is refused. Older records without this binding require a
new campaign directory.
The isolation backend digest is also pinned and checked before each new attempt. A real namespace preflight
must succeed; unavailable confinement starts no attempt. Older schema-one records require a new directory.
An `invoking`, corrupt or mismatched record stops the run for reconciliation. It is not replayed automatically.
Preserve such a record and its project while investigating; use a new output directory for a deliberate rerun.
`--mode check` reads existing records and rebuilds the summary without starting a model. Missing attempts
remain pending; an empty campaign cannot claim completion. Exit zero requires every planned attempt to pass.

Each result records grade, native ending, retained project, elapsed/load/work time, generated tokens, root and
delegated tokens, prompt reads/reuse, compactions and calls. `calls` counts the native root runner's executed
calls; `tool_requests` counts displayed requests, including repeats that may not execute again. Generated
tokens include helpers; `root_generated_tokens` and `delegated_tokens` provide the split. Optional metrics
are JSON null when unavailable. Host peak memory and device residency are currently unavailable, not zero.
Startup time ends at the interactive prompt; lazy weight-page faults can occur during work. It is not a
measurement of all cold weight reads. Elapsed time includes project setup and session shutdown; the separate
independent verification is excluded from that timing.

`resolved_settings` contains an initial `/settings json` snapshot and every fitted root/helper round captured
from the native session. It includes actual context, workers and cache storage, all sampler fields, policy
sources and effective call budgets. `configuration_before` and `configuration_after` retain the complete
resolved project configuration. Successful results require fitted work evidence, matching campaign-owned
seed/context/thinking/attachment controls and an unchanged configuration; missing evidence cannot qualify
a result or resume it. Failed outcomes retain available observations, with absence represented explicitly.

`summary.json` records all outcomes, per-arm medians and paired wins/losses, including a separate cost view
for attempts both models solve. Infrastructure failures and ungraded results remain explicit. Comparisons
are descriptive: uncertainty, non-inferiority and a recommendation are not inferred from a few repeated tasks.
The recommendation remains `inconclusive` until the plan's independently reviewed confirmation gate is met.

## Current execution boundary

The initial Q8_0 memory gate failed. Header checks and campaign tooling have been implemented; a comparison
of the released adapter's behavior requires complete verified files at a precision admitted on this host,
or a host with enough available memory for the pinned Q8_0 pair one model at a time.

Small local-model runs validate the instrumentation and deployed workflow only. Comparing the same local
model in both artifact slots without an active trained adapter is not evidence of adapter transfer.
Numerical CPU adapter execution and per-arm campaign selection are implemented. Device attachment and
complete training trajectory capture remain later stages of
[the plan](plan-harness-adapters.md), with their original correctness and evidence gates.
