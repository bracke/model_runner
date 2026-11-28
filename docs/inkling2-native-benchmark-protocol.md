# Initial native CPU timing protocol

Declared before measurement on 2026-11-24. Use the existing `tests speed`
command, with the verified Q4_K_M checkpoint and qualified F32 activation/cache
profile. This is a short-context baseline; it does not replace the planned
512/2K/8K/16K prefill, 128-token decode or long-context memory campaigns.

Run five independent processes serially, after the V3 task and release tests
finish. Each process performs the tool's existing untimed warmup followed by
one measured pass. Retain every sample, including load, temperature, processor
time and GNU time memory statistics. Report median, range and sample standard
deviation. Do not run another model, build, audit or test job during timing.

Use this command from `tests/`, with `MODEL` identifying the previously
verified file and `PROMPT` containing exactly `The capital of France is`:

```sh
./bin/tests speed --model "$MODEL" --prompt-file "$PROMPT" \
  --backend cpu --threads 8 --batch-size 1 --arith f32 --kv-cache f32 \
  --repack none --memory-limit 24G --context-size 128 --max-tokens 16 \
  --repeat-penalty 1 --draft-tokens 0 --repeats 1 --wait 5 --no-cache
```

Require exactly five prompt tokens and sixteen generated tokens in every
sample. Compute the expected FNV-1a output digest from the independent
`greedy-f32-16.json` text; a mismatch or incomplete process fails the campaign.
The first output token uses prompt logits; fifteen subsequent decoder forward
evaluations occur. Retain the native tool's generated-token rate, and also
report the forward-evaluation rate so it cannot be confused with the reference
tool's evaluation counter.
No failed sample is retried or excluded. Freeze the native test binary hash,
prompt hash, model identity, command, compiler profile and source identity.
Reverify the checkpoint SHA-256 and unchanged binary after measurement.

The original reference benchmark used byte activations and F16 KV storage;
its throughput is not an identical-precision comparison with this F32 profile.
The first process's loading time also follows earlier use of the checkpoint,
so these measurements cannot establish cold-storage load latency.

The existing host-load gate may wait up to five minutes before measuring.
Its quiet-host bound remains unchanged; `--anyway` is not used.
