# Reference CPU baseline

These are five-run measurements of the uninstrumented reference, not native
model_runner performance. The source is llama.cpp b12600,
`29b52d398b294509746ec0a3f28948a3107c0213`, built with GCC 13.3 Release,
`GGML_NATIVE=ON`, `GGML_VULKAN=ON`, `GGML_LLAMAFILE=OFF`. Source archive and
checkpoint hashes are recorded in [the reference contract](../../../../docs/inkling2-reference.md).
The JSON build reports `unknown` because the pinned source came from an archive;
the revision above supplies the missing identity.

Hardware: Ryzen 7 7840U, 8 cores/16 threads, 32,814,366,720 bytes system RAM,
Tuxedo 24.04.5, Linux 7.0.0-111030-tuxedo. Both measurements used seven CPU
threads, zero GPU layers, F16 key/value caches, batch 32, microbatch 8, flash
attention disabled and weight repacking disabled. Vulkan was compiled in but
was not used for inference. Measurements ran serially without compilation or
another inference job. File pages were warm after full-file hash verification.

| Measurement | Median tokens/s | Range tokens/s | Sample standard deviation |
| --- | ---: | ---: | ---: |
| Prompt, 512 tokens | 21.4122 | 21.3037–21.5604 | 0.113654 |
| Decode, 128 tokens after depth 512 | 7.88467 | 7.86273–7.91933 | 0.021973 |

Commands, with `REF` denoting the pinned build directory and `MODEL` the verified
Q4_K_M file:

```sh
"$REF/bin/llama-bench" -m "$MODEL" -p 512 -n 0 -r 5 -t 7 -b 32 -ub 8 \
  -ctk f16 -ctv f16 -ngl 0 -fa off --repack 0 -o json --progress
"$REF/bin/llama-bench" -m "$MODEL" -p 0 -n 128 -d 512 -r 5 -t 7 -b 32 -ub 8 \
  -ctk f16 -ctv f16 -ngl 0 -fa off --repack 0 -o json --progress
```

The raw JSON preserves every sample and backend option. GNU time files report
whole-command resource use, including loading, warmup and depth preparation;
their elapsed time is not timed decode duration. Larger contexts, load latency,
Vulkan/hybrid and native comparisons still require separate measurements.
