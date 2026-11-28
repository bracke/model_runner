# Inkling common-engine regression measurement protocol

Declared on 2026-11-24 before timing. Requalify the existing no-adapter CPU
claim after shared loader, evaluator, kernel, tokenizer and tensor changes.
Follow the unchanged [paired protocol](trajectory-no-adapter-protocol.md)
and [runtime requalification rules](runtime-no-adapter-protocol.md).

Compare historical pre-adapter engine
`a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b` with this Inkling working-tree
implementation. Pin the latter by a complete source-hash manifest and archive;
do not invent a candidate commit ID. Use the unchanged native probe and the
same current dependency archives, with matching release engine switches.
Validate historical sources against the preserved original archive, and record
binary, dependency, model, prompt, source and compiler identities before/after.

Use Qwen3.5-0.8B Q8_0 SHA-256
`37ae482d336108d23516fa35e8e0c4126688d81018b87178a18d752a1357814f`,
and raw prompt SHA-256
`85baa59e937e701288d7ab74d08087de2b1abf34cf1821d98e1cf62666cac54c`.
Each process performs one untimed warm-up, then 100 prompt tokens and sixteen
generated tokens: CPU, four workers, batch 16, context 512, F32 activations,
exact cache, no repacking, adapter, drafting or panel-file cache, greedy seed
one, repeat penalty one and EOS ignored. Unset all generation-capture controls.
Every output digest must equal `c85e719a42725969`.

Run two batches of seven pairs, baseline first in batch one and candidate
first in batch two, alternating arm order for each subsequent pair. Retain
all 28 samples including load, temperature and native counters, with no retry
or exclusion. Stop on infrastructure/fixed-work mismatch. Bound each process
to 180 seconds and the campaign to 1200 seconds. Each batch separately must
pass a median paired candidate/baseline ratio at most 1.05 for both prompt
and decode time. Preserve a failed result as evidence.

Finish builds, tests and the premeasurement audit before timing. Run serially
with no competing build, test, audit or model job. Only a passing campaign
permits updating the active measurement fingerprint. Earlier evidence remains
unchanged. This descriptive local CPU test makes no significance, latency-tail,
Inkling throughput, Vulkan or model-quality claim.
