# Native batched-prefill measurements

Measured on the Ryzen 7 7840U/Radeon 780M with 32 GB RAM and the existing powersave governor. Original Q4_K_M weights remain quantized; activations and KV are F32. All runs use eight CPU threads, batch 128, greedy seed one, repetition penalty one and no drafting or saved-context reuse. Each reported configuration has five successful samples with exact independent-reference output.

The native CLI host limit is 24 GiB. Outer cgroup limits are 20 GiB for CPU and 16 GiB for private Vulkan, with swap disabled; the latter also uses the existing 4 GiB device budget. Contexts are 640 and 2176 for the longer prompts. These bounds and mixed CPU/device execution are part of the measured configurations.

| Placement | Prompt tokens | Prefill seconds, median (range) | Prefill tokens/s | Decode tokens/s | Peak RSS GiB, median |
| --- | ---: | ---: | ---: | ---: | ---: |
| cpu | 512 | 153.804 (147.162–162.200) | 3.329 | 1.190 | 5.229 |
| vulkan-private-4g | 512 | 126.980 (124.516–131.995) | 4.032 | 1.156 | 15.887 |
| cpu | 2048 | 906.149 (884.370–947.988) | 2.260 | 0.882 | 5.870 |
| vulkan-private-4g | 2048 | 844.079 (800.430–854.577) | 2.426 | 0.781 | 16.503 |

Decode rates count all sixteen native decoder evaluations, including the last generated token. Ranges, sample standard deviations, commands, resource use, outputs and identities are retained in [the evidence](inkling2-batched-prefill-benchmark-evidence.json). Independent external references supply correctness fixtures; their timing is not a matched throughput comparison.

The timeline option automatically runs another complete comparison. The first three CPU 512-token processes include that extra unreported campaign; their reported CPU regions have no GPU timeline instrumentation. Remaining timing omits the flag. All completed samples are retained, with no retry or exclusion. GPU execution is qualified separately with current-binary conformance and a short timeline diagnostic. See the [protocol and operational correction](inkling2-batched-prefill-protocol.md).

## Matched short CPU workload

The five-token France prompt and sixteen-token golden continuation now have a prefill median of 1.788 seconds, versus the preserved 2.805-second batch-one baseline: 36.3% less observed prefill time. Decode median is 9.227 seconds for sixteen evaluations. Every sample reproduces the independent text exactly. These are separate five-run campaigns, with host conditions retained; they are not a paired thermal-control experiment.

## Fresh V3 proof

A fresh normal V3 task completed in 2590.4 seconds through the existing native model, ordinary file tools and required Ada verification. The only source change is `Left - Right` to `Left + Right`; the acceptance script is unchanged and independently passes. Idempotent operation replay preserves invocation records. [Evidence](inkling2-v3-batched-prefill-evidence.json) retains configuration, commands, durable records and verification.

The earlier V3 proof overlapped other validation and is not a controlled latency comparator. These measurements do not qualify the unmeasured 8K/16K/32K matrix or the proposed thirty-task adoption corpus. No default model selection changes.

An initial external-reference preparation caused a host OOM interruption before native timing. It is preserved; reference generation resumed CPU-only under an enforced 20 GiB cap. Native timing and the V3 task then used the caps above. Source and executable integrity were reverified.
