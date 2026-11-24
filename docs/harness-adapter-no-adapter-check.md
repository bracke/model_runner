# Before/after execution without adapters

This campaign checks the CPU cost added to ordinary inference by the adapter implementation. It compares
the pre-adapter engine at commit `a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b` against the current working tree.
It does not measure trained-adapter quality, device execution, or an adapter's active arithmetic overhead.

## Runtime-constraint requalification

The runtime grammar and continuation changes were requalified on 2026-11-24 using a
[predeclared protocol](runtime-no-adapter-protocol.md) and [28 fresh samples](runtime-no-adapter-evidence.json).
Both batches pass the unchanged 1.05 paired-median boundary:

| Batch | Pairs | Prompt time change | Decode time change |
| --- | ---: | ---: | ---: |
| 1 | 7 | -0.27% | +0.49% |
| 2 | 7 | +0.64% | +0.37% |

Every run reads 100 prompt tokens, generates sixteen tokens and produces digest `c85e719a42725969`.
Original sources match their historical commit; actual release compiler arguments match, including
`-O3 -gnatn`. Frozen binaries, normalized source archive, current dependency archives, model and prompt
remain unchanged through the 317.768-second campaign. Capture is disabled in both arms. No build, test,
audit or other model job runs alongside timing; all samples are retained without retries or exclusions.
The full runtime-repair suite passes **1,002/1,002**. This qualifies the local descriptive boundary and
provides no significance, tail-latency or trained-adapter-quality conclusion. Earlier evidence below remains
historical and unchanged.

## Capture-disabled requalification

The trajectory generation hooks were requalified on 2026-11-23 using the
[frozen protocol](trajectory-no-adapter-protocol.md) and
[28 fresh samples](trajectory-no-adapter-evidence.json). Capture was disabled in both arms.
Every sample read 100 prompt tokens, generated sixteen tokens and produced digest `c85e719a42725969`.
Both batches pass the unchanged 1.05 paired-median boundary:

| Batch | Pairs | Prompt time change | Decode time change |
| --- | ---: | ---: | ---: |
| 1 | 7 | +0.02% | -0.01% |
| 2 | 7 | +0.04% | +0.32% |

The original engine sources match their baseline commit. Both final binders use release engine objects,
with identical actual engine compiler arguments including `-O3 -gnatn`. A development-profile candidate
was detected and discarded before timing. The source archive, frozen binaries, dependency archives and
model/prompt identities remain unchanged after all 28 runs. No builds, tests, audits, retries or sample
exclusions occurred during the 325.491-second campaign. All raw native metrics are retained in the evidence.
This qualifies the local descriptive boundary; it establishes no significance or tail-latency guarantee.
The complete native suite passes **982/982**. Earlier checkpoint results below remain historical evidence.

## Granite and template-override requalification

The final Granite attachment and custom-template tool-syntax changes were requalified on 2026-11-23.
[The new evidence](harness-adapter-no-adapter-twil-evidence.json) retains all 28 fresh native samples.
Every sample read 100 prompt tokens, generated sixteen tokens and produced digest `c85e719a42725969`.
Both batches pass the unchanged 1.05 paired-median boundary:

| Batch | Pairs | Prompt time change | Decode time change |
| --- | ---: | ---: | ---: |
| 1 | 7 | -1.5% | -2.0% |
| 2 | 7 | -0.6% | +0.3% |

Baseline engine sources again match an archive of `a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b`.
Both probes were built against the same current dependency archives, and actual engine compiler arguments
match exactly. The suite subsequently rebuilt six dependency archives; timing uses the preserved statically
linked probes. Their hashes and the normalized candidate source archive remain unchanged through timing.
No builds or validation campaigns ran alongside timed samples.

The final full suite passes **969/969**. Large wall-time stalls remain in both arms: candidate/baseline
decode ratios span about 0.13 to 5.12. No sample was excluded. These observations qualify the declared local
median boundary and provide no tail-latency guarantee or claimed speed improvement. The earlier results below
describe their original checkpoint and remain available unchanged.

## Measurement protocol

The same `tests/src/no_adapter_probe.adb` main is compiled against both engine trees. It calls each tree's
existing `Speed_Run.Run` with the common interface. The baseline engine and build-policy sources are checked
against an archive of the original commit; they are not edited to implement the probe. Generated root and
test configuration files are copied from the current environment so both builds use the same development
profile, compiler switches and dependency environment. The engine uses the test crate's declared release
profile (`-O3`, `-gnatn`); the small probe and speed harness retain their development profile. Only the
baseline test configuration's import of its
own model project needs an explicit relative path. Both probe sources must have the same SHA-256.

The fixed controls are CPU execution, F32 arithmetic, no repacking, exact key/value cache, no panel-file cache,
seed one, temperature zero, repeat penalty one, no drafting and no adapter. EOS is ignored so each accepted
sample must produce the requested token count. Every process loads once, runs one full untimed generation,
resets its session, then times one generation. Loading, process startup and warm-up are outside prompt/decode
times. The generated-text digest and prompt/generated token counts must agree across every sample.

The declared campaign uses two batches of seven pairs on the local Qwen3.5 0.8B Q8_0 model, four workers,
batch size sixteen, context 512 and sixteen generated tokens. The saved prompt is
`tests/fixtures/speed-prompt-110.txt`; token count is measured rather than inferred from its filename.
Order alternates within each batch; the second batch reverses the starting arm. No builds or validation campaigns run
during timing. Load and temperature before/after each sample are retained with all samples and outliers.

For each pair, the candidate's prompt and decode times are divided by its baseline's. The local material
regression threshold is a paired median time ratio above 1.05 for either phase in either batch. This is a
declared descriptive gate, not a confidence bound or significance test. A passing result applies to this
model, build profile and machine; it does not prove zero overhead for every model or configuration.
RSS remains unavailable and is recorded as null. No before/after memory claim follows from this campaign.

The initial development-engine probe was stopped after two pairs when its profile was checked against the
existing performance suite's release-engine policy. Both pairs remain in
[the exploratory record](harness-adapter-no-adapter-development-smoke.json), with all load/temperature readings.
They are incomplete exploratory data and do not contribute to the declared regression gate.

## Results

[The complete evidence](harness-adapter-no-adapter-evidence.json) retains fourteen release-engine pairs
(28 measured runs) and all controls, timings, CPU totals, load/temperature readings and artifact digests.
Every run read 100 prompt tokens, generated sixteen tokens and produced digest `c85e719a42725969`.

| Batch | Pairs | Paired median prompt time change | Paired median decode time change | Local gate |
| --- | ---: | ---: | ---: | --- |
| 1 | 7 | +0.6% | +1.1% | pass |
| 2 | 7 | -1.9% | -0.9% | pass |

These are medians of per-pair time ratios, not ratios of independent arm medians. Both batches remain below
the declared +5% boundary for both phases. No material slowdown was observed in this measured configuration.
The second batch's smaller ratios are not a claimed speed improvement.

The host produced large wall-time stalls in both arms. One candidate decode was about 7.4 times its paired
baseline; another pair's candidate prompt was about 0.45 times its baseline. Neither pair was excluded.
These observations limit interpretation of the descriptive median gate and establish no tail-latency guarantee.
The result applies to this model, CPU settings and release engine, with a development-built speed harness.

The probe sources match each other, the baseline engine matches its original commit, and the timed
speed-harness section is identical.
Engine compiler flags matched exactly, shared dependency archive checksums did not change between builds,
and model/prompt/probe/binary digests and the candidate source archive were unchanged after measurement.
The original generated development configuration is restored after validation; the measurement archive
retains the exact temporary release configuration.

## Running the probe

From the tests crate, build the extra main explicitly:

```text
alr exec -- gprbuild -P tests.gpr no_adapter_probe.adb -j1
bin/no_adapter_probe /models/model.gguf fixtures/speed-prompt-110.txt 16 4 16 512
```

Verify the actual engine profile before timing: the engine ALI files must carry `-O3` and `-gnatn`, and
the probe's binder exchange file must link the engine objects from `obj/release`. A prior standalone root
build can leave generated development configuration in place despite the test manifest's release policy.
The probe and speed-harness objects remain in the tests crate's development directory.

Its six positional arguments are model, raw prompt file, generated tokens, workers, batch and context.
The probe emits one JSON object on success and exits nonzero for invalid bounds or unsuccessful fixed work.
Limits are 256 generated tokens, 64 workers, batch 256, context 16..32768 and a 64 KiB prompt file.
The model file must fit within half of reported available RAM, in addition to native loading/session limits.
This conservative file-size check is not a total process-memory estimate.

For a historical build, unpack the original commit into a separate directory, copy the generated `config`
and `tests/config` directories, adjust the latter's model-project import to `../../model_runner.gpr`, and
copy only the identical probe source into its tests source directory. Use the current tests crate's Alire
environment to build that isolated project's probe, so dependencies resolve to the same solution:

```text
alr exec -- gprbuild -P /tmp/model-runner-harness-baseline/tests/tests.gpr no_adapter_probe.adb -j1
```

Build serially: the local pinned dependencies share archive paths. Finish both builds before measuring.
If Alire cannot resolve a changed transitive pin, the already-resolved GPR project paths and GNAT toolchain
can build both probes directly. Keep the dependency archives unchanged across the two builds and retain
their checksum manifest. The measurement campaign encountered an external database/Cryptolib pin conflict;
it did not modify the external manifest or adopt a different Cryptolib for one arm.
Both targets built through that direct GPR route. Normal Alire builds were blocked at that checkpoint.
At that measurement checkpoint, the mandatory full suite passed **965/965**, with no failed assertions or
unexpected errors; its log is
`/tmp/model-runner-no-adapter-full-suite.log`. The original generated configuration files are restored.
The audit reports 53 failures: 19 existing findings and 34 consequences of the pin conflict (33 blocked
host-body compilations and their compiler-health failure). Those portability checks still require a rerun
after dependency resolution is repaired.
The subsequent [repository repair](repository-audit-repair.md) fixes that dependency conflict; the build
limitations and audit counts above describe the original measurement checkpoint.
Retain exact binary, model, prompt and probe-source SHA-256 digests, compiler/profile details, raw JSON
samples and the execution order. Historical documentation and benchmark fingerprints are not restamped by
this check.
