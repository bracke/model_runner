# Cache and session baseline

Measured 2026-11-13 at commit `0c36f3e5`, on Qwen3 0.6B Instruct Q8_0,
the CPU backend with seven workers, and a machine with 30 GiB of RAM.

Five identical five-turn campaigns produced the same output digest. Of 191
cumulative prompt tokens, 132 were reused and 59 evaluated: a 69% hit rate.
Median wall time was 0.735 s and median prompt evaluation time was 0.135 s.

The context sweep kept the same output:

| context | peak RSS | wall | prompt evaluation |
|---:|---:|---:|---:|
| 4,096 | 840 MiB | 0.442 s | 0.138 s |
| 8,192 | 840 MiB | 0.440 s | 0.137 s |
| 16,384 | 843 MiB | 0.456 s | 0.150 s |
| 40,960 | 851 MiB | 0.476 s | 0.171 s |

RSS reflects the 55 positions touched, not a full cache. Inspection prices a
full 40,960-position session at 4.6 GiB. Use an 8,192-position context and one
helper at a time on this machine unless a workload needs more.

A filled-context follow-up on Qwen3 8B Q4_K_M processed 11,142 prompt tokens
in a 20,000-position CPU session. Prompt evaluation took 476.258 s (23.39
tokens/s), peak RSS was 9.68 GiB, and the process used no swap. The one-token
answer had digest `09243e07b5b927d0`. This replaces the short-prompt RSS sweep
as the capacity observation: an actually filled production session is large
enough that helper parallelism should remain one on a 30 GiB host.

On the `find` agent trial, fixed and adaptive routing each completed 5/5.
Fixed had a 13 s median against adaptive's 15 s and made fewer tokens at the
median (621 against 666). A classifier is not warranted; routing and all
permission decisions remain deterministic.

The previously stalled delegation trial was completed with Qwen3 8B at an
8,192-token context. It completed in 184 s, generated 712 tokens, held at most
2,843 context tokens, and spent 72.0 s in its helper. One retained helper is
therefore sufficient for the measured task; increasing concurrency would add
session memory without shortening this serial dependency.

Investigate when `/task audit` shows any `rewind_failed`, or when cache-hit
rate falls by 10 percentage points, evaluated tokens rise by 20%, or prompt
time rises by 20% against this baseline. Re-measure after changing the model,
backend, context construction, cache arithmetic, or session ownership.

`tests speed` can enforce those limits directly. From the repository root,
with the baseline model available, run:

```sh
./tests/bin/tests speed --model /path/to/qwen3-0.6b-q8_0.gguf \
  --prompt-file tests/fixtures/cache-turns/01.txt \
  --turns tests/fixtures/cache-turns --max-tokens 8 --threads 7 \
  --backend cpu --context-size 8192 --anyway --warmup \
  --cache-hit-min 59.1 --evaluated-max 71 \
  --prompt-seconds-max 0.162 --expect-digest 99c5d8c2f9ccaffc
```

The command exits unsuccessfully on any rewind failure or threshold/digest
regression, so a model-bearing scheduled runner can use it without parsing
human-readable output.
