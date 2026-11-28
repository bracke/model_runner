# Shared-host memory allowance adjustment

Declared on 2026-11-25 before the deferred shared-host measurements. The user
authorized an additional 0.5 GiB of memory use. The shared-host preflight now
requires 21.5 GiB available (22,544,384 KiB), previously 22 GiB. The change is
536,870,912 bytes; it changes test orchestration, not production inference code.

Run the existing full-file independent checkpoint comparison first, with
F32 activations/cache, original Q4_K_M weights, no repacking and the existing
4 GiB device budget with host sharing. Preserve the exact numerical tolerances
and expert-ID requirements. Run it without another model, build or audit job.

After it passes, take the five previously unattempted shared-host samples from
[the original backend protocol](inkling2-forward-benchmark-protocol.md), with
all commands and output checks unchanged. Apply the
[operation-count correction](inkling2-benchmark-interpretation.md): one prompt
token and one generated token cause two network evaluations per measured pass.
Keep the original CPU/private-GPU samples and original deferral records.

Use the existing quiet-host gate, untimed warmup and one measured pass per
process. Retain all five samples, with no retry or exclusion. Verify frozen
source, executable, checkpoint and prompt identities. Record actual available
memory and the adjusted guard. If headroom is insufficient, wait before
starting a model; do not increase the allowance beyond the authorized 0.5 GiB.
