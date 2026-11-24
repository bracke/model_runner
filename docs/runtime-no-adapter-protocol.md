# Capture-disabled inference requalification after runtime constraints

Declared 2026-11-24 before timing the runtime-constraint repair. Generation source changes invalidate the
active no-adapter measurement fingerprint. Use the unchanged native No_Adapter_Probe and the existing
[matched protocol](trajectory-no-adapter-protocol.md): historical pre-adapter engine
`a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b` versus runtime repair commit `6e6f0cbc`.

Build both probes serially against the same current dependencies. Verify historical source, identical
probe sources, release engine flags including -O3 and -gnatn, model/prompt identities and static binary
hashes before timing. Finish builds, tests and the premeasurement audit first. The audit's stale speed
fingerprint remains pending until a passing fresh measurement; do not bypass that gate by restamping.

Use exactly the original 0.8B model and raw prompt, four CPU workers, F32, batch 16, context 512, exact cache,
no repacking, adapter, drafting or panel-file cache, greedy seed one and EOS ignored. Each process performs
one untimed warm-up, then reads 100 prompt tokens and generates sixteen tokens. Unset all three capture
environment variables. Require digest c85e719a42725969 for every run.

Run two batches of seven pairs, reversing arm order on successive pairs and the starting arm in batch two.
Retain all 28 fresh samples, load/temperature/counters and any stalls, with no retries or exclusions.
Run serially with no other build, test, audit or model job. Keep the 180-second process and 1,200-second
overall bounds. Stop on infrastructure or fixed-work mismatch. Each batch separately must pass the unchanged
1.05 paired-median candidate/baseline boundary for both prompt and decode time.

Verify frozen binaries, source, dependencies and inputs after timing. Report every sample and both gates,
including a failed gate. Only a passing result updates the active published claim. This local descriptive
check provides no significance, tail-latency, device or trained-adapter-quality conclusion. Preserve the
previous measurement evidence unchanged and link the new evidence separately.
