# Adaptive expert-cache A/B campaign

This is the reproducible decision record for enabling adaptive MoE expert
residency. It measures every compatible MoE artifact available locally; it is
not a claim about models or devices that were not present.

## Decision

Keep `--expert-cache` at zero unless an exact, locally qualified registry entry
exists or the user selects it explicitly. No tested configuration passed the
promotion gates:

1. generated output must have the same digest as the zero-cache control; and
2. median end-to-end inference time must improve by at least five per cent.

Most cache configurations were slower. Mellum's 512 MiB cache improved the
homogeneous prompt's median wall time by 9.3%, but changed the generated-output
digest and therefore fails the correctness gate. Qwen3-30B Q4_K_M also changed
output at 1 GiB on the homogeneous prompt. A cache that changes the selected
tokens is not a performance optimization of the same computation.

The original results below were taken on 2026-11-18 with
`llvmpipe (LLVM 20.1.2, 256 bits)`, a software Vulkan device. A second campaign
on the host's AMD Radeon 780M and a final ABBA campaign are recorded below.
Neither produced an eligible cache size. The qualification runner rejected
every comparison that exceeded either the host-load or idle-GPU bound instead
of silently accepting contaminated timing figures.

## Method

Each cell is the median of three runs. Runs used four processor workers, a
2,048-token context, eight generated tokens, greedy deterministic sampling,
`--ignore-eos`, the device backend, and a fixed per-model device-memory budget.
The homogeneous workload was `tests/fixtures/speed-prompt-long.txt`; the
mixed-domain workload was `tests/fixtures/expert-cache-diverse.txt`.

Cache reserves were 0, 256, 512 and 1,024 MiB. The homogeneous sweep ran in
ascending order and the diverse sweep in descending order to expose simple
order effects. Every nonzero configuration performed physical device expert
runs and reported bounded residency. An intermittent device-open refusal was
discarded because it produced no inference result. One visibly throttled
Qwen3-Coder diverse 512 MiB cell was repeated; the coherent repeat is reported.

The command shape was:

```sh
tests/bin/tests speed --model MODEL --prompt-file PROMPT \
  --max-tokens 8 --threads 4 --backend device \
  --device-memory BUDGET --expert-cache BYTES --repeats 3 \
  --budget --context-size 2048 --ignore-eos --anyway
```

The repository now owns the complete matrix command. It adds a zero-cache
control, records cold and warm timings, captures the chosen and top eight token
log probabilities, verifies physical cache work, hashes the model, classifies
divergence and emits JSON:

```sh
tests/bin/tests speed --model MODEL \
  --prompt-file tests/fixtures/speed-prompt-long.txt \
  --turns tests/fixtures/expert-cache-turns \
  --max-tokens 32 --threads 4 --context-size 2048 \
  --device-memory BUDGET --repeats 3 \
  --expert-cache-sweep 268435456,536870912,1073741824 \
  --report REPORT.json --min-improvement 5 \
  --logit-tolerance 0.001 --max-leg-drift 10 --wait 10
```

The current protocol takes each candidate in A1,B1,B2,A2 order: control,
candidate, candidate, control. Both control legs and both candidate legs must
agree numerically and pass the load gates. This prevents a cache from being
promoted because it happened always to run after warm-up or before thermal
drift. A control- or candidate-leg drift above 10% rejects the timing. Host
background work is sampled immediately before and after each pass.
The AMD kernel interface is also sampled while the benchmark itself is idle;
more than 5% device activity, or an unavailable idle-utilization instrument,
disqualifies the timing. High device activity *during* generation is reported
separately and is expected.

Several artifacts can be run with one command. The manifest contains a model
path and its qualification device budget separated by a tab; blank and `#`
lines are ignored:

```text
/models/qwen3moe.gguf	9663676416
/models/mellum.gguf	6442450944
```

```sh
tests/bin/tests speed \
  --expert-cache-models expert-cache-models.tsv \
  --prompt-file tests/fixtures/speed-prompt-long.txt \
  --turns tests/fixtures/expert-cache-turns \
  --max-tokens 32 --repeats 3 \
  --expert-cache-sweep 268435456,536870912,1073741824 \
  --report expert-cache-matrix.json
```

The aggregate uses schema `expert-cache-matrix/2` and embeds every model's
complete `expert-cache-bench/1` record. A successful candidate is installed in
the local recommendation registry atomically. A failed later qualification
revokes the matching entry. Runtime lookup is fail-closed and requires the
exact artifact SHA-256, inference body versions, device name and device-memory
budget. Explicit `--expert-cache` always wins; `expert-cache-auto = false`
disables lookup, and `expert-cache-recommendations = PATH` selects another
registry. An invalid or stale registry enables nothing.

The turn workload is cumulative instruction refinement: each file is appended
to those before it, while the previous generated reply is rewound. It measures
prefix reuse and repeated generation over a growing logical task; it is not an
assistant-inclusive chat transcript.

The tested artifacts were:

| Artifact | Architecture | Experts active/total | Size | Device budget |
| --- | --- | ---: | ---: | ---: |
| `qwen3moe.gguf` | qwen3moe | 8/128 | 10.5 GiB | 9 GiB |
| `Qwen3-Coder-30B-A3B-Q2_K.gguf` | qwen3moe | 8/128 | 10.5 GiB | 9 GiB |
| `Qwen3-30B-A3B-Q4_K_M.gguf` | qwen3moe | 8/128 | 17.3 GiB | 12 GiB |
| `Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf` | Mellum MoE | 8/64 | 7.5 GiB | 6 GiB |
| `Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf` | qwen35moe | 8/256 | 13.1 GiB | 10 GiB |

Artifact fingerprints, in the table's order:

- `sha256:db3ce897ccc9e7d9dbf17fe083cae7880a2092aa473b45eba8b77715aa9ca170`
- `sha256:6db9853d31fdb928a731666c9d44e8cdebf52f62f4810cb0908c6c677e6c84b5`
- `sha256:0d003f6662faee786ed5da3e31b29c978de5ae5d275c8794c606a7f3c01aa8f5`
- `sha256:ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755`
- `sha256:36f9ec0e4c775f6efd3a61c1ea76f0875128469c3d012e3d9e2495a90e7a7150`

## Results

Each value is `wall seconds / prompt tokens per second / generated tokens per
second`. A dagger means the generated-output digest differed from that model
and workload's zero-cache control.

### Homogeneous workload

| Model | 0 MiB | 256 MiB | 512 MiB | 1,024 MiB |
| --- | ---: | ---: | ---: | ---: |
| qwen3moe | 2.729 / 522.81 / 30.50 | 3.545 / 452.10 / 11.66 | 4.444 / 383.54 / 7.40 | 4.738 / 366.54 / 6.54 |
| Qwen3-Coder Q2_K | 2.858 / 505.18 / 26.27 | 3.699 / 447.03 / 9.85 | 4.670 / 385.68 / 6.18 | 4.909 / 374.27 / 5.47 |
| Qwen3 Q4_K_M | 3.976 / 401.41 / 10.20 | 5.588 / 304.20 / 5.93 | 7.738 / 229.72 / 3.76 | 15.310 / 150.45 / 1.35 † |
| Mellum | 3.451 / 429.94 / 29.43 | 4.373 / 370.86 / 11.62† | 3.129 / 508.55 / 14.60† | 4.264 / 401.33 / 9.31† |
| Qwen3.6 IQ3_XXS | 3.135 / 457.64 / 31.26 | 3.609 / 433.10 / 14.26 | 3.756 / 428.39 / 11.86 | 3.882 / 422.22 / 10.51 |

### Mixed-domain workload

| Model | 0 MiB | 256 MiB | 512 MiB | 1,024 MiB |
| --- | ---: | ---: | ---: | ---: |
| qwen3moe | 1.597 / 444.11 / 37.51 | 3.309 / 240.81 / 10.46 | 4.316 / 196.90 / 6.69 | 4.681 / 184.88 / 5.93 |
| Qwen3-Coder Q2_K | 1.853 / 391.43 / 28.29 | 3.308 / 260.66 / 8.41 | 5.773 / 160.64 / 4.28 | 4.825 / 190.69 / 4.96 |
| Qwen3 Q4_K_M | 2.416 / 337.67 / 14.06 | 3.592 / 239.19 / 7.74 | 6.033 / 140.35 / 4.81 | 16.459 / 48.90 / 2.04 |
| Mellum Q4_K_M | 2.811 / 296.85 / 13.58 | 2.917 / 284.03 / 13.44 | 3.794 / 216.40 / 9.58 | 5.528 / 134.55 / 10.42 |
| Qwen3.6 IQ3_XXS | 2.332 / 342.31 / 16.57 | 6.252 / 143.67 / 4.47 | 4.979 / 192.36 / 4.76 | 5.194 / 187.00 / 4.46 |

All mixed-domain digests matched their controls. Homogeneous cached digests
also matched except for the daggered cells. Physical counters increased with
the reserve on the Qwen models. Mellum used only 21–70 MiB despite larger
reserves, showing that its eligible source-layout expert slices, rather than
the named reserve, constrained residency in these runs.

## Initial Radeon hardware campaign

The automated sweep ran the same five artifacts on
`AMD Radeon 780M Graphics (RADV PHOENIX)`. Each point generated 32 tokens from
the long prompt three times after an untimed cold pass, then ran four cumulative
instruction turns. A candidate had to satisfy all of these gates:

1. exact generated-output digests for the long prompt and turns;
2. identical chosen and top-eight token identities, with maximum log-probability
   delta at most 0.001;
3. at least 5% lower combined warm wall time;
4. observed device expert runs and bounded resident bytes;
5. a hardware device and background load within the repository's publishing
   bound for both control and candidate.

The table shows combined warm-time improvement relative to zero; negative is
slower. The divergence column names the earliest failed numerical gate.

| Model | 256 MiB | 512 MiB | 1,024 MiB |
| --- | ---: | ---: | ---: |
| qwen3moe | -137.0%, multi-turn output | -289.0%, multi-turn output | -308.8%, multi-turn output |
| Qwen3-Coder Q2_K | -78.4%, top-logit set | -160.2%, multi-turn output | -196.1%, multi-turn output |
| Qwen3 Q4_K_M | -24.9%, prompt output | -50.3%, top-logit set | -97.7%, top-logit set |
| Mellum Q4_K_M | -51.0%, top-logit set | -263.0%, top-logit set | -167.9%, top-logit set; no physical work |
| Qwen3.6 IQ3_XXS | -93.9%, top-logit set | -110.1%, top-logit set | -126.4%, top-logit set |

Background activity exceeded 0.80 busy processors during at least the control
or candidate side of every comparison. Those rows therefore cannot establish
precise speed ratios, but none is close to the promotion threshold and the
independent correctness gates also reject every candidate. The compact
machine-readable record is
[`expert-cache-ab-radeon.json`](expert-cache-ab-radeon.json).

The divergence investigation explains the earlier digest changes. A cached
expert executes on the device while the zero-cache expert executes on the host;
the two arithmetic paths are not numerically identical. The first long prompt
can select the same tokens while its top alternatives already differ. Repeated
turns then accumulate that distribution difference until a selected token may
change. The exact size at which this crosses a token boundary is device- and
artifact-dependent: Qwen3 Q4_K_M diverged at 1 GiB on llvmpipe but at 256 MiB
on the Radeon. This is why digest equality alone is too weak and why no result
may be generalized from a model family name.

## ABBA qualification campaign

The final 2026-11-18 campaign used the production matrix runner, 32 generated
tokens, the cumulative turn workload, three prompt repeats, A1/B1/B2/A2
interleaving, a 5% minimum improvement and a 10% maximum leg drift. It ran all
five local artifacts in one invocation. The table reports `improvement / leg
drift / first numerical divergence`; negative improvement means slower.

| Model | 256 MiB | 512 MiB | 1,024 MiB |
| --- | ---: | ---: | ---: |
| qwen3moe | -132.2% / 0.7% / multi-turn output | -285.1% / 42.9% / multi-turn output | -254.6% / 4.2% / multi-turn output |
| Qwen3-Coder Q2_K | -136.8% / 31.1% / top-logit set | -203.4% / 1.7% / multi-turn output | -237.3% / 2.4% / multi-turn output |
| Qwen3 Q4_K_M | -6.4% / 1.6% / prompt output | -25.3% / 1.7% / top-logit set | -30.1% / 15.2% / top-logit set |
| Mellum Q4_K_M | -24.8% / 12.7% / top-logit set | -56.9% / 3.7% / top-logit set | -105.3% / 11.6% / top-logit set |
| Qwen3.6 IQ3_XXS | -19.4% / 161.9% / top-logit set | -126.0% / 3.7% / top-logit set | -287.1% / 122.1% / top-logit set |

No row passed. Every cache size was slower and failed a numerical-equivalence
gate. Some rows also exceeded the timing-drift limit. The integrated Radeon is
the display device: idle samples reached 43--46% for four artifacts and 6--10%
for Qwen3 Q4_K_M, above the strict 5% contention bound. Host background peaks
also exceeded the publication limit in several legs. Thus the speed ratios are
retained as diagnostic evidence, but none is load-qualified and no automatic
recommendation was stored. The complete record, including all four legs,
environment samples, physical-work counters and artifact hashes, is
[`expert-cache-ab-radeon-abba.json`](expert-cache-ab-radeon-abba.json).

## Activation rule

Do not infer a cache size from model family alone. A future automatic policy
must qualify the tuple of model artifact, runtime build, device and workload.
It may enable a reserve only after the same-output gate passes and repeated,
alternated measurements show a material improvement. Otherwise zero remains
the safe value. The cache statistics printed by `tests speed` and
`tests external-model` are required evidence that a nonzero option actually
performed physical work.
