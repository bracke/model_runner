# KV-cache quality baseline

This is the first baseline produced by the same-model cache comparison in
`tests perplexity`. It exists to choose what a candidate low-bit codec should
improve, not to publish speed. The host was heavily loaded and hot throughout
the first baseline; KL, perplexity, agreement and planned bytes are
deterministic, but those arm times are diagnostic only. A later quiet-host,
order-balanced timing is recorded below.

## Method

Date: 2026-11-20. Backend: CPU. Arithmetic: int8. Threads: 8. Context: 128.
Chunks: 1. Scored positions: 63 per run. Corpus:
`tests/fixtures/perplexity-corpus.txt`, SHA-256
`7b7c36e07c9af201caaef1726ac5d65c5f1314ce3a2ab761f3864a85c3900b2f`.
Every candidate was compared with an F16 key/value cache from the same prepared
model and the same tokenized chunk.

The command shape was:

```sh
cd tests
./bin/tests perplexity --model MODEL \
  --text fixtures/perplexity-corpus.txt --chunk 128 --chunks 1 \
  --threads 8 --arith int8 --kv-cache KEYS [--kv-values VALUES] \
  --against-kv-cache f16 --anyway
```

`--anyway` was necessary because one-minute load ranged from 12.70 to 32.07
on a 16-core host and the reported temperature ranged from 92.9 to 95.4 C.
Consequently no timing in this file is a publishable comparison.

## Models

| coverage | model | SHA-256 |
| --- | --- | --- |
| dense multi-head attention | `gpt2-q8_0.gguf` | `9ab5d3c0b9ac838651c2bfd2db2d5b75d40077562557ccd23fca9569bdc2eee0` |
| grouped-query attention | `tinyllama-1.1b-chat-q8_0.gguf` | `a4c9bb1dbaa372f6381a035fa5c02ef087aaa1ff1f843a56a22328114f03fc59` |
| sliding-window attention | `gemma-3-270m-it-Q8_0.gguf` | `0ef57d2c838458a1952664260dcba38e5bdda37494f3af732f06e4add24068e3` |
| learned attention sinks | `gpt-oss-20b-MXFP4.gguf` | `27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901` |

## Results

`q8/q4` means Q8 keys and Q4 values. `q4/q8` means the inverse. Bytes are the
planned KV allocation at the 128-token context. Times are candidate/F16 arm
seconds and are retained only to show that both arms ran.

| model | cache | candidate/F16 perplexity | mean KL | worst KL | top agrees | KV bytes | arm s | load |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| GPT-2 | q4 | 102.8101 / 102.9736 | 0.028898 | 0.1279 | 90.5% | 1,474,560 | 2.20 / 1.36 | 28.55–29.47 |
| GPT-2 | q8 | 103.0519 / 102.9736 | 0.004824 | 0.0724 | 96.8% | 2,359,296 | 1.96 / 1.55 | 31.03–31.99 |
| GPT-2 | q8/q4 | 98.9434 / 102.9736 | 0.009447 | 0.0357 | 95.2% | 1,916,928 | 0.52 / 0.23 | 32.07–32.07 |
| GPT-2 | q4/q8 | 103.1496 / 102.9736 | 0.020940 | 0.1047 | 90.5% | 1,916,928 | 0.43 / 0.26 | 30.46–30.46 |
| TinyLlama | q4 | 71.3207 / 71.5995 | 0.075662 | 0.3746 | 82.5% | 901,120 | 0.53 / 0.46 | 25.72–25.18 |
| TinyLlama | q8 | 72.2367 / 71.5995 | 0.001069 | 0.0036 | 98.4% | 1,441,792 | 0.48 / 0.44 | 23.96–23.96 |
| TinyLlama | q8/q4 | 73.3749 / 71.5995 | 0.006235 | 0.0538 | 96.8% | 1,171,456 | 0.52 / 0.44 | 22.52–22.52 |
| TinyLlama | q4/q8 | 71.4666 / 71.5995 | 0.068737 | 0.5275 | 84.1% | 1,171,456 | 0.50 / 0.42 | 21.28–21.28 |
| Gemma 3 | q4 | 78.5036 / 75.8410 | 0.204586 | 1.2126 | 73.0% | 737,280 | 1.87 / 1.97 | 18.93–19.50 |
| Gemma 3 | q8 | 75.7827 / 75.8410 | 0.018001 | 0.1707 | 90.5% | 1,179,648 | 0.34 / 0.24 | 17.64–17.64 |
| Gemma 3 | q8/q4 | 77.3868 / 75.8410 | 0.035149 | 0.1627 | 85.7% | 958,464 | 1.82 / 1.95 | 17.53–18.92 |
| Gemma 3 | q4/q8 | 79.3653 / 75.8410 | 0.140455 | 0.4625 | 76.2% | 958,464 | 2.05 / 2.18 | 19.32–20.79 |
| GPT-OSS | q4 | 31.8949 / 15.9201 | 0.526224 | 2.2767 | 61.9% | 1,966,080 | 1.84 / 1.53 | 13.41–13.09 |
| GPT-OSS | q8 | 16.1392 / 15.9201 | 0.020713 | 0.0906 | 90.5% | 3,145,728 | 1.83 / 1.57 | 12.77–13.34 |
| GPT-OSS | q8/q4 | 15.9665 / 15.9201 | 0.026108 | 0.1471 | 93.7% | 2,555,904 | 1.85 / 1.59 | 12.92–13.87 |
| GPT-OSS | q4/q8 | 29.9116 / 15.9201 | 0.413738 | 1.4144 | 60.3% | 2,555,904 | 1.88 / 1.66 | 13.04–12.70 |

## Transformed-Q4 candidate

After the host `q4t` session mode was integrated, the same four commands were
repeated with `--kv-cache q4t`. Q4t transforms keys and keeps values in ordinary
Q4, at exactly the existing Q4 byte count. The host was still hot, so these
times remain diagnostic rather than publishable.

| model | candidate/F16 perplexity | mean KL | change from Q4 | worst KL | top agrees | KV bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| GPT-2 | 113.1402 / 102.9736 | 0.022365 | 22.6% lower | 0.1146 | 93.7% | 1,474,560 |
| TinyLlama | 76.8632 / 71.5995 | 0.028792 | 61.9% lower | 0.1771 | 93.7% | 901,120 |
| Gemma 3 | 82.5313 / 75.8410 | 0.136334 | 33.4% lower | 3.7992 | 87.3% | 737,280 |
| GPT-OSS | 17.8090 / 15.9201 | 0.090198 | 82.9% lower | 0.8812 | 85.7% | 1,966,080 |

The unweighted mean KL is 0.069422, 66.8% below ordinary Q4's 0.208843.
Every model's mean improves, and top-token agreement improves by 3.2, 11.2,
14.3 and 23.8 percentage points respectively. This clears the initial byte,
aggregate-mean, per-model-mean and top-agreement gates.

Gemma 3 has one adverse tail result hidden by that better mean: at position
114, F16 assigns the wanted token 12362 log probability -0.005, while q4t
assigns it -3.838 and chooses token 108. An eight-chunk follow-up scored 504
positions: q4t mean KL 0.118210 versus Q4's 0.235519, and top agreement 83.9%
versus 73.4%. Q4t's same position remains its worst at 3.7992; Q4's worst is
3.2640 at a different position. The candidate therefore clears the stated
mean gates but carries a recorded tail-risk investigation into longer-context
testing.

The eight-chunk run was then completed for all four families, 504 scored
positions per model:

| model | q4t mean KL | Q4 mean KL | q4t improvement | q4t/Q4 top agrees | q4t/Q4 worst KL |
| --- | ---: | ---: | ---: | ---: | ---: |
| GPT-2 | 0.042943 | 0.058893 | 27.1% | 87.5% / 84.7% | 1.5848 / 1.3842 |
| TinyLlama | 0.038421 | 0.104069 | 63.1% | 89.7% / 82.1% | 0.5285 / 2.0943 |
| Gemma 3 | 0.118210 | 0.235519 | 49.8% | 83.9% / 73.4% | 3.7992 / 3.2640 |
| GPT-OSS | 0.117506 | 0.908858 | 87.1% | 82.5% / 53.2% | 1.0227 / 5.9872 |

The aggregate mean is 0.079270 for q4t and 0.326835 for Q4, a 75.7%
reduction. Average top-token agreement rises from 73.4% to 85.9%. GPT-2's
slightly larger worst KL does not change its top token at that position; the
wanted token is substantially closer under q4t than F16 there, so the KL is
in the rest of the distribution. Gemma's previously recorded outlier remains
the material tail exception. With that exception visible, the candidate passes
the byte, aggregate, per-model, agreement, sliding-window and attention-sink
quality gates and may proceed to device work.

A depth check then used one 1,024-token Gemma 3 chunk and scored its second
half (511 positions), so cache errors could accumulate instead of resetting
every 128 tokens. Q4t mean KL was 0.126940 versus Q4's 0.304131, a 58.3%
reduction; top agreement was 81.2% versus 74.8%, and worst KL was 2.5002
versus 4.5836. Thus the short-context outlier does not turn into a degraded
long-context mean or tail on this depth check.

## Quiet-host codec timing

After four runaway tests from other sessions were found and terminated, the
host was 96--98% idle and its CPU had cooled from 95 C to 60.5 C. The tool's
load gate then passed without `--anyway`. Each model evaluated eight 128-token
chunks twice, once as `q4t` against `q4` and once in the reverse order, to
remove arm-order bias. The table averages the two reported arm times; model
loading and the load gate's wait are outside those arm times.

| model | q4t arm s | Q4 arm s | q4t host cost |
| --- | ---: | ---: | ---: |
| GPT-2 | 0.785 | 0.645 | 21.7% higher |
| TinyLlama | 2.540 | 2.115 | 20.1% higher |
| Gemma 3 | 1.445 | 1.280 | 12.9% higher |
| GPT-OSS | 9.685 | 8.630 | 12.2% higher |
| combined | 14.455 | 12.670 | 14.1% higher |

The transform therefore buys the recorded quality improvement at unchanged
cache bytes but is not a host-speed improvement. The later device result and
the completed quality sweep, taken together, justify the 2026-11-20 default;
the recorded host cost remains the tradeoff for CPU-only runs.

## Device codec timing

After the device pack, unpack and attention paths passed their byte and decoded-
value checks, Gemma 3 4B Q4_K_M was measured with `--backend device`, paged
cache, automatic drafting disabled (`--draft-tokens 0`) and Q4/Q4t at the same
cache byte count. Disabling drafting matters: the two codecs can accept a
different number of carried proposals, which measures different work rather
than cache speed.

| cached prompt | Q4 generate | q4t generate | Q4 prompt | q4t prompt |
| --- | ---: | ---: | ---: | ---: |
| 1,328 tokens | 23.51 t/s | 23.35 t/s | 696.76 t/s | 674.13 t/s |
| 17,187 tokens | 21.21 t/s | 21.11 t/s | 598.83 t/s | 563.36 t/s |

The generated-token gaps are 0.7% and 0.5%, level at this two-decimal
measurement, and the 17,187-token output digest is identical. Prompt placement
is 3.2% slower at 1,328 and 5.9% at 17,187; it is recorded separately because
the stage-six acceptance target is generation at cache depth. A device timeline
at 1,328 positions put Q4t key placement at 13.5--13.6 microseconds and packed
attention at 61--67 microseconds per layer. Thus the device generation gate
passes. Together with the completed sweep's mean and agreement gains, this is
the evidence for making q4t the default; unnamed incompatible head widths fall
back to f16, while an explicitly named q4t remains strict.

## What this changes in the codec experiment

Across the four models, unweighted mean KL is 0.208843 for Q4, 0.011152 for
Q8, 0.019235 for Q8 keys/Q4 values, and 0.160968 for Q4 keys/Q8 values. At
the identical mixed-cache byte count, preserving keys at Q8 lowers mean KL by
55% on GPT-2, 91% on TinyLlama, 75% on Gemma 3 and 94% on GPT-OSS compared
with preserving values instead.

The first codec experiment should therefore target keys. Q4 values are already
comparatively tolerant; spending the same extra bits on values while leaving
keys at Q4 is consistently the worse allocation. A transformed four-bit key
codec should first be paired with ordinary Q4 values, and its primary gate is
whether it closes the gap from the Q4-key rows toward Q8-key rows at no more
than the present Q4 key byte budget.
