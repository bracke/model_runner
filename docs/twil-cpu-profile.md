# TwIL CPU throughput investigation

The user stopped the adapter pilot after five timeouts and requested a bounded performance investigation.
This follow-up uses the same verified TwIL-8B Q4 base without an adapter. It does not resume that pilot.
[Raw measurements and limits](twil-cpu-profile-evidence.json) retain each configuration and native report.

## Initial measurements

Each native `tests speed` invocation evaluates the same 1,328-token raw prompt and generates exactly 32
tokens, ignoring EOS. It performs one untimed warm-up and one measured pass, with context 8192, CPU integer
arithmetic, native packed rows, seed one, temperature zero and no drafting. Processes run sequentially with
a 180-second limit. No build, test suite or other model job overlaps these measurements.

| Workers | Batch | KV cache | Prompt tokens/s | Generated tokens/s | Output digest |
| ---: | ---: | --- | ---: | ---: | --- |
| 8 | 16 | q4t | 33.87 | 7.52 | `0839f42db257b3c2` |
| 8 | 512 | q4t | 37.63 | 7.60 | `0839f42db257b3c2` |
| 4 | 512 | q4t | 30.39 | 7.26 | `0839f42db257b3c2` |
| 8 | 512 | f16 | 45.95 | 7.84 | `19362db5b6bd6c83` |

The normal batch size improves this sampled prompt's time by about 10% with the same output digest.
F16 reduces the sampled prompt time by a further 18% relative to q4t at batch 512, while changing the output
and increasing KV memory. Single measurements do not establish a confidence bound or a general speed claim.
The F16 configuration therefore needs its own coding check. Global inference defaults remain unchanged.

The separate 99 Hz CPU profile includes loading and warm-up. It records 73,276 samples with none lost.
Q4 panel arithmetic accounts for approximately 50% of sampled cycles, Q6 for 15%, and worker waiting for
8%. Attention dot products, blending and transformed-cache decoding are also visible. Kernel symbol
resolution is unavailable; the observed native user-space hotspots still identify the arithmetic involved.
No speculative assembly change follows from these observations.

## Bounded coding verification

`tests/src/cpu_work_probe.adb` uses the existing `Agent_Trial` workflow, protected independent graders,
Bubblewrap boundary, native settings validation and version-two attempt serialization. It runs only the
base model with thinking off, with up to three fresh edit projects and seeds 42, 43 and 44. Each attempt
retains the original 300-second work budget. It stops after the first failure, missing result or failed
configuration qualification. Results and input hashes remain outside the confined project.

Build this native tool after the normal test build:

```text
cd tests
alr exec -- gprbuild -P tests.gpr cpu_work_probe.adb -j1
```

Run it with `MODEL PROGRAM TEMPLATE NEW_OUTPUT THREADS BATCH CACHE REPEATS`. Existing output directories,
invalid input paths and settings beyond its explicit limits are refused before model execution. The input
manifest hashes the model, program, template and harness. A successful exit requires every planned attempt
to finish and qualify independently. The proposed check uses eight workers, batch 512 and F16 cache.

Coding verification is pending. The cancelled pilot supplies no adapter recommendation, and a successful
base-only check would not by itself establish adapter transfer.
