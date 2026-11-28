# Native single-forward backend baseline

Declared before measurement on 2026-11-24. Measure the same bounded native
forward pass on CPU, shared-host Vulkan and the existing hybrid placement
with a 4 GiB device budget. Use the existing `tests speed` tool, eight CPU
threads, F32 activations/cache, context 128, no requested repacking, no panel
file cache, no drafting, greedy seed one and repetition penalty one.

Each process performs the tool's untimed warmup and one measured repetition.
Run five independent processes for each mode, serially after validation and
the common-engine regression campaign finish. Retain every sample; no retry
or exclusion. Freeze and verify binary, source-manifest, prompt and model
identities. Record load, temperature, processor time and GNU time memory use.
Report median, range and sample standard deviation.

Use raw prompt `Hello` (token 32269) and request one generated token. Both
independent F32 and canonical byte reference captures choose token 11;
the pinned independent tokenizer maps the literal comma to exactly `[11]`.
Require one prompt token, one generated token and the comma's exact FNV-1a
digest in every sample.

One generated token comes from the prompt's logits. Consequently this case
measures one complete network forward pass and sampling, with no subsequent
decoder evaluation. Do not publish its sampling-only decode rate as model
throughput or extrapolate it to long-context performance. The separate
[CPU timing protocol](inkling2-native-benchmark-protocol.md) covers a five-token
prefix and sixteen generated tokens. Neither baseline replaces the larger
context, 128-token decode and long-context memory campaigns in the plan.

Common command from `tests/`, with `MODEL` the verified checkpoint and
`PROMPT` containing exactly `Hello`:

```sh
./bin/tests speed --model "$MODEL" --prompt-file "$PROMPT" \
  --backend cpu --threads 8 --batch-size 1 --arith f32 --kv-cache f32 \
  --repack none --memory-limit 24G --context-size 128 --max-tokens 1 \
  --repeat-penalty 1 --draft-tokens 0 --repeats 1 --wait 5 --device-timeline --no-cache
```

For shared-host Vulkan, replace `--backend cpu` with
`--backend device --device-memory 0`. For hybrid placement use
`--backend device --device-memory 4G`. Keep all other work unchanged.
Bound each process to 600 seconds and the campaign to 3600 seconds.

The existing host-load gate may wait up to five minutes before measuring.
Its quiet-host bound remains unchanged; `--anyway` is not used.

Resource preflight refinement declared before the first measurement: shared-host
Vulkan requires 22 GiB available memory; the private 4 GiB hybrid placement
requires 20 GiB. Record the observed headroom before each mode. A mode below
its guard is deferred before any sample starts; publish no result for it and
mark the overall campaign partial. Other modes may run in the listed order.
Every attempted mode still requires all five exact-output samples. No measured
sample is excluded or retried. This preserves the original shared-host guard.
The existing device timeline is enabled to retain actual GPU work/transfer
measurements; its overhead is part of this instrumented baseline.
