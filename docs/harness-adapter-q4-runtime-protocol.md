# Trained Pi adapter over the pinned Q4 base

Protocol frozen on 2026-11-23, before inference. This is a local runtime-attachment experiment.
It compares the same Q4_K_M base with and without the released trained F16 adapter. It does not reproduce
the merged-Q8 experiment or the publisher's BF16 Pi scores. No model default changes from a screening result.

## Artifacts and lineage

Both arms use `ggml-org/Qwen3.8-27B-GGUF` at
`c1869413dece09109e55b7dcc2c77ef382b0d0bd`, file `Qwen3.8-27B-Q4_K_M.gguf`:
19,403,684,480 bytes, expected SHA-256
`d15d4b6de55f662ac40e867702d31afe738d032fa06b829b2b1a21a49d4a48ee`.
The repository's pinned `.src_sha` records primary source revision
`37561816e66b5b9153b1b64c10968c18c1e6f4a0` of `Qwen/Qwen3.8-27B`.

Only adapted arms attach `harness-hub/Qwen3.8-27B-pi-adapted-GGUF` at
`19980ce556b41c7b73818083c9adf4b3fa0c72e5`, file `Qwen3.8-27B-pi-lora-F16.gguf`:
318,802,304 bytes, expected SHA-256
`a64f91844f19e67da500d8628bdf9383aa334e61b7ab687805802e7d272d7b67`.
The adapter has rank 32, alpha 64 and 256 projection pairs. Runtime scale is one.

The [pinned base card][base] identifies the original Qwen base and automatic GGUF conversion.
The [pinned adapter card][adapter] explicitly permits attaching this adapter to that base's GGUF and
notes the greater quantization drift at Q4_K_M. Dimensions alone are not the lineage argument.
Neither card provides a GGUF quality measurement for this experiment.
The original PEFT source at `7d42b119e2d4d475fa11270634b1ef98d1cd5aee` also names `Qwen/Qwen3.8-27B`,
rank 32 and alpha 64, without DoRA or transposed weights. Its base-weight revision is null. This corroborates
the declared model lineage; it does not establish the exact BF16 training-weight revision or reproduce that run.

[base]: https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF/tree/c1869413dece09109e55b7dcc2c77ef382b0d0bd
[adapter]: https://huggingface.co/harness-hub/Qwen3.8-27B-pi-adapted-GGUF/tree/19980ce556b41c7b73818083c9adf4b3fa0c72e5

## Admission and smoke gate

Whole-file size and SHA-256 must match both pinned artifacts before inference. Existing Q8 fragments and
synthetic adapter fixtures cannot satisfy this gate. Header inspection must resolve all trained pairs.

The host has 32,814,366,720 bytes of physical RAM and an integrated GPU sharing that RAM. Use CPU execution.
Budget the 19.4 GB mapped weights as resident despite the native allocation account excluding borrowed pages.
Decoded adapter matrices need 637,534,208 bytes before descriptors. The context-8192 q4t session estimate is
341,169,626 bytes before adapter scratch and other workspace. Reserve another 2 GiB for workspace and host
margin, and recheck available RAM before loading. These are admission estimates, not measured peak RSS.
There is no F32 merge, device execution or draft model.

Run deterministic bounded generation first on base, zero-scale attachment and active attachment, with
CPU, eight workers, context 8192, batch size 16, q4t cache, integer arithmetic, memory mapping and no repack.
Use temperature zero, seed one and drafting disabled. Compare the base and zero-scale output exactly;
retain active output without requiring it to differ. Record complete command, binary hashes, output,
exit status, elapsed time and observed maximum RSS. Start with eight generated tokens and a 15-minute
process bound per arm. Refusal, invalid output or excessive resource use stops quality interpretation.

Then exercise the existing confined native `/work` edit task across all four arms with one repeat and
300 seconds of work per attempt. This is a tool-contract and feasibility screen, not the twelve-task pilot.
Require actual native settings, valid tool execution and an independent verifier result before declaring
the tool contract qualified. Timeouts remain outcomes; they do not qualify successful editing.

In the absence of a user-selected compute budget, use at most two hours of inference for this initial
feasibility screen. Acquisition time is separate. Do not extend that into an unattended confirmation run.
If a bounded screen fails before useful work, record its concrete limiting prerequisite rather than
running hundreds of indistinguishable timeouts or claiming a transfer result.

## Pilot and decision

If admission and the tool-contract screen pass, run the twelve-task, three-repeat, four-arm pilot described
in [the campaign guide](harness-adapter-campaign.md), within the selected compute budget. Use a fresh output
directory and freeze its manifest before any attempt. Base and adapted paths are identical; only adapted
arms receive the trained adapter. Preserve settings and seeds within pairs and reverse arm order as the
campaign driver specifies. No carried knowledge or drafting; fixed inference policy and OS isolation.

Hold CPU, eight workers, context 8192, batch size 16, q4t cache, integer arithmetic, no repack, memory mapping,
temperature 0.8, top-p 1, top-k 0 and min-p 0 fixed across the pilot. Use 300 seconds of work per attempt.
The manifest captures all remaining sampler controls and actual native resolved settings. Pin the executable
and harness bytes, and do not rebuild them during execution. Keep model failures distinct from infrastructure
errors. Report unavailable measurements as null and avoid significance claims for descriptive pilot medians.

A promising pilot leads to a separately frozen confirmation suite of at least thirty independent tasks,
five attempts per arm and an explicit compute budget. Related variants in the pilot are not independent
confirmation tasks. The acceptance rule remains the original plan's credible completion gain at acceptable
latency, or at least 10% lower median work time with completion loss bounded by five percentage points.
Both need uncertainty clustered by task. An unresolved margin is inconclusive; token savings alone do not pass.
