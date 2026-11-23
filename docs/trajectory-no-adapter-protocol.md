# Capture-disabled inference requalification

Frozen before generation on 2026-11-23. Adding generation capture hooks changes the sources behind the
active no-adapter timing claim. Requalify that existing claim; do not restamp it from semantic tests alone.

Use the unchanged native `No_Adapter_Probe` main, compiled against the original pre-adapter engine
`a0522e83cf42fe2b8cf95e5e73759c0d7aa5087b` and the completed trajectory implementation. Build both
serially against the same current dependency archives. Preserve the static binaries before measuring.
Verify the original engine sources and both release engine compiler argument sets, including `-O3 -gnatn`.

The existing Qwen3.5-0.8B Q8_0 model has SHA-256
`37ae482d336108d23516fa35e8e0c4126688d81018b87178a18d752a1357814f`.
The existing raw prompt has SHA-256
`85baa59e937e701288d7ab74d08087de2b1abf34cf1821d98e1cf62666cac54c`.
Each measured run reads 100 prompt tokens and generates sixteen tokens, with one native warm-up pass.
Use CPU, four workers, batch 16, context 512, exact cache, F32 arithmetic, no repacking, no adapter,
no drafting, seed one, greedy sampling, repeat penalty one, EOS ignored and panel file cache off.
Unset capture directory and capture limit environment variables for both arms.

Run two batches of seven fresh pairs. Batch one starts with baseline then candidate; batch two starts
with candidate then baseline. Reverse order on each successive pair. Keep all 28 samples, including stalls,
with binary/source/model/prompt identities and native load/temperature/counter records. There are no retries,
outlier removals or changed settings based on the result. Stop on invalid fixed work or infrastructure error.

Every output digest must match the original fixed-work digest `c85e719a42725969`. Each batch must separately
pass the existing candidate/baseline paired-median boundary of 1.05 for both prompt and decode time.
Report every pair and both batch summaries, including a failed gate. Do not infer significance or tail
latency from this small descriptive comparison. It does not evaluate trained-adapter quality.

Finish all builds, tests and audits before timing. Run samples sequentially with no competing model job.
Apply a 180-second per-process bound and 1,200-second overall study bound. Verify frozen binary and source
identities after execution. Only a passing fresh check may replace the active measurement fingerprint.
The cancelled coding-adapter pilot remains cancelled and no model default changes.
