# Independent precision profiles

All profiles pin llama.cpp b12600 at
`29b52d398b294509746ec0a3f28948a3107c0213` and the verified Q4_K_M
checkpoint SHA-256
`ed38ac618a24ee65142c27073783a80aa3b100546a21212d59690c9081945a9b`.
Every capture manifest retains executable, library, patch and input identities.
No reference patch is linked into production model_runner.

## Original quantized activation profile

`q4_k_m-cpu-hello` and `q4_k_m-cpu-prefix` preserve original reference
activation quantization. `GGML_LLAMAFILE=OFF` is the canonical build:
all 834 final-token tensors agree byte-for-byte between prefill and decode.
The optimized ON build's 0.400331 logit discrepancy is retained as a failed
reference self-comparison. The native row-major CPU integer profile now
matches all 834 captured tensors exactly for Hello and the directly addressable
`q4_k_m-int8-prefix` five-token capture, including grouped versus sequential
expert execution. The recorded host supplies AVX-512; GPU integer arithmetic
and interleaved weight rows are not qualified by these results. Q4T CPU integer
attention and cache lifecycle also pass the 17-token checkpoint test.
See [current evidence](../../../docs/inkling2-integer-native-evidence.json).

## F32 activations and F32 cache

`reference-f32-activations.patch` supplies test-only scalar F32 activation
products for Q8_0, Q5_0, Q4_K, Q5_K and Q6_K weights. It uses the original
GGUF dequantizers, accumulates their dot products in F64, returns F32, and
leaves the architecture graph unchanged. Runtime type traits and tiled
shortcuts both honor the override. Enable it with
`INKLING_F32_ACTIVATIONS=1`; without that variable the original implementation
runs. The patch does not convert or replace the checkpoint's weights.

`q4_k_m-f32-hello` and `q4_k_m-f32-prefix` cover 834 tensors and 1,352,826
values per captured token: all 48 logical visits, intermediate attention and
residual/message values, routing IDs/weights, and 200,058 output logits.
The prefix tokens are exactly `[371,151451,149879,151194,149884]`.
Native comparisons require exact routing IDs and per-element floating error
at most `1e-5 + 2e-5 * abs(reference)`. The CPU and Vulkan F32 activation
paths have passed these comparisons. The observer also compares an unwatched
pooled-expert run bit-for-bit with watched final logits.

## F32 activations and F16 stored cache

`reference-f16-attention.patch` extends the override to F16 cache products,
keeping query/probability activations F32. The F16 storage encoder remains
installed: removing it caused an invalid diagnostic capture, which is not
used as a fixture. `q4_k_m-f16-dot-half-prefix` preserves the earlier valid
reference with implicit F16 query/probability conversion; it is a different
arithmetic contract and does not qualify native F32 activations.

`q4_k_m-f32-half-prefix` uses the corrected F32 attention contract and F16
stored keys/values. Its independent precision envelope compares that capture
with the independent F32-cache capture before consulting native output.
For each observed tensor, freeze the maximum-absolute and RMS reference
precision deltas. The budgets are `1e-5 + 2 * delta`, retaining the F32
relative allowance; routing IDs and greedy output remain exact. The factor
two allows two rounding-error contributions measured against the F32 anchor.
It is an empirical profile, not a rigorous analytical bound. The manifest
stores every per-tensor budget, so a new capture cannot silently change it.

The independent profiles differ by at most 0.0066814423, with RMS
0.0002408357423 for the largest affected tensor. The native F16-cache
comparison passes its full profile with maximum difference 0.00106144
and RMS 0.0000558668. The original strict F32-cache tolerance is unchanged.
Do not compare these figures as if the cache/activation contracts were equal.

## Long-context capture

`reference-last-token-capture.patch` suppresses earlier dump writes while
keeping graph callbacks and execution intact. With
`INKLING_STEPWISE=1 INKLING_CAPTURE_LAST_ONLY=1`, it permits a bounded
final-token capture after 2200 tokens. The synthetic F32 full-batch and
incremental final-token captures are byte-identical. Its native comparison
uses the unchanged F32-cache tolerance and exercises actual local eviction.

The Q5_0 expert down projections require the same Q8_0 half activation
scales as Q8_0 weight products, as pinned `ggml-cpu.c` declares. The adapter
now selects that contract for Q5_0 too. A serial/pooled primitive test uses
the independent Q8_0 block-nine capture: a Q5_0 row of ones must return
`-11.298828125` exactly. This fixes the omitted scale rule but does not
qualify the complete integer checkpoint path: that earlier strict comparison
differed first at `ffn_out-1` and selected different experts at visit 8.
Its tolerance is unchanged and the default Inkling activation profile stays F32.

## Packed views and integer-input sensitivity

Both rebuilt row panels and mapped panel-cache views must preserve the
`Reference_Activations` contract. The independent synthetic Q8 decoder
regression fails without that preservation (maximum difference 0.154113)
and passes afterward (2.38419e-6), including an anonymous build, a cache
write and a verified cache mapping. Existing architecture role handling is
unchanged by this fix.

`q4_k_m-int8-prefix` packages all 834 canonical byte-activation tensors at
the last position of the five-token prefix. Every packaged payload is
byte-identical between the original independent prefill and decode captures.
Only raw final-token slicing, concatenation and hash/offset updates are used.
The older `q4_k_m-cpu-prefix` manifest describes a comparison between modes;
it is not a tensor-capture manifest accepted by the optional native test.

The earlier full checkpoint still failed strict integer conformance after
preserving the packed-view contract. A diagnostic capture found a maximum difference
of 5.24521e-6 in the layer-1 normalized expert input. Applying the same pinned
independent optimized Q8_K quantizer to the native and reference inputs
changes one quantized byte, at position 1966, from -34 to -33. This confirms
one sensitivity mechanism; it does not establish the cause of every remaining
difference. Exact routing and the original numerical bounds remain required.
See [diagnostic provenance](../../../docs/inkling2-integer-diagnostics.json).

## Native integer qualification, 2026-11-26

The corrected profile preserves the reference's binary32 FMA lanes and fold
order for Q8_0, Q5_0, Q4_K, Q5_K, Q6_K and F32 products; convolution uses
fused accumulation, while dynamic terms retain their explicit multiply/add
stages. Uncompressed-cache attention uses the reference vector exponential and padded
value-dot reduction; Q4T uses its existing independently checked fused packed
attention kernels. Routing, learned residual softmax, loop gates, SiTU and logit caps
retain the reference's precision stages. Q5_0 dispatch now reaches its native
row-major kernel. The expert batch packer records rounding and half-scale
contracts and refuses incompatible reuse. Other models retain their default
arithmetic dispatch.

A real binary16 conversion defect also affected a Q8 attention scale:
5.8277002779050235e-8 was converted to zero but must round to the smallest
subnormal, 5.960464477539063e-8. The scalar converter now includes exponent
-25; vector conversion uses the matching hardware nearest-even result. An
independent Q8 packing fixture and 6144 positive/negative IEEE subnormal
midpoint samples cover the correction. All 86 GGUF container cases pass.
Earlier failed captures and comparisons are preserved with the current evidence;
no golden values or tolerances were changed.
