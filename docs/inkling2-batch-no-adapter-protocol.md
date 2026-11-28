# Batched Inkling common-engine regression protocol

Declared on 2026-11-25 before measurement. Requalify the unchanged no-adapter
claim after Inkling's evaluator gains layer-major batched prefill and prefix
replay. Existing architectures retain their existing execution branch.

Repeat the unchanged [paired common-engine protocol](inkling2-no-adapter-protocol.md):
two seven-pair batches, the original historical engine and unchanged native
probe, identical release compiler arguments, fixed Qwen inputs and exact output
digests. Each batch must pass both 1.05 median paired prompt/decode ratio gates.
Finish builds, functional/reference tests and the premeasurement source audit
first. Run serially without a competing build, validation or model job. Retain
all samples and failures without retry or timing-based exclusion. Freeze and
reverify source, executable, dependency and input identities.

Preserve the previous memory-limit campaign as
`inkling2-no-adapter-speed-limits-evidence.json` and retain its raw directory.
Write this campaign to `artifacts/inkling2/obj/no-adapter-batched-prefill/`.
Only a passing result permits replacing active evidence and running the normal
measurement restamp command. No precision or regression gate is weakened.
