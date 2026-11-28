# Inkling 2 model metadata and tensor inventory

Status: verified GGUF payload, native structural validation and fixed-loop
text execution, 2026-11-24. The native reader recognizes `inkling2_loop`, validates
all required metadata and maps the 704 tensor roles before preparing weights.
AUnit covers missing/malformed metadata, dimensions, unsupported variants,
quantization compatibility and caller resource limits. See
[verification](inkling2-verification.md) for numerical and release evidence.

The initial file is `bartowski/Inkling-2-Mini-GGUF/Inkling-2-Mini-Q4_K_M.gguf`,
revision `ad66863fd3b7f3236c0b7a0862412c9e00f78a6e`. Header-only inspection
captures 704 tensors in `tests/fixtures/inkling2/q4_k_m-tensors.tsv` and a
metadata summary in `q4_k_m-metadata.txt`. Exact scalar values and complete
architecture arrays are in `q4_k_m-architecture-metadata.json`. Both attention
head-count keys are arrays of 24 int32 values, not scalars: all Q counts are
24, all KV counts eight. The bool window pattern is false at physical layers
5, 11, 17 and 23 and true elsewhere. See [provenance](inkling2-reference.md)
for the range capture and its explicit payload-validation limits. All selected
tensor types are existing native formats; this file has no NVFP4 tensor or
external expert-scale descriptors. Other conversions still require scale audits.

The recorded descriptor set was checked against the independent source's
name/shape rules: 704 unique tensors, every descriptor accounted for exactly
once, comprising five model-level tensors, 439 local-layer tensors, 104
global-attention-layer tensors and 156 loop/controller tensors. The same inventory is enforced by the native loader. Payload integrity is
separately verified by the recorded full-file SHA-256; malformed synthetic
containers exercise the structured rejection paths.

## Configuration snapshot

The [official configuration](https://huggingface.co/thinkingmachines/Inkling-2-Mini/blob/main/config.json)
is captured in [the fixture directory](../tests/fixtures/inkling2/README.md).
Its `model_type` is `inkling2_loop`, architecture class
`Inkling2LoopForConditionalGeneration`; the text configuration type is
`inkling2_loop_text`. These are distinct from GGUF architecture dispatch.
llama.cpp independently confirms GGUF identifier `inkling2_loop`.

| Property | Fixed-checkpoint value |
| --- | --- |
| Stored layers / logical applications | 24 / 48 |
| Core region / visits / controller rank | `[6,18)` / 3 / 64 |
| Variable-loop flag | false |
| Hidden / expert intermediate width | 2304 / 1152 |
| Experts / selected / shared | 128 / 8 / 0 |
| Query heads / KV heads / head width | 24 / 8 / 128 |
| Local window / global relative extent | 1024 / 1024 |
| Relative feature width | 16 per query head |
| Convolution kernel / retained history | 4 / 3 inputs per channel |
| RMS epsilon | 0.000001 |
| Stored / unpadded vocabulary | 201024 / 200058 |
| EOS token | 200006 |
| Model context ceiling | 1048576; runtime budget may permit less |
| Output / gate / up softcaps | 30 / 4 / 25 |
| Route scale | 8 |

The original checkpoint declares ModelOpt NVFP4; that declaration is not a
GGUF tensor-type or scale-layout contract. Decoder position encoding is
relative bias, not the RoPE specified separately for MTP.

## GGUF keys from upstream

The following suffixes are prefixed with `inkling2_loop.`. Names come from
the inspected `llama-arch.cpp` key table and model loader. INK-002 must record
the converter revision and actual values/types, including generic fields.

| Suffix group | Source contract |
| --- | --- |
| `block_count`, `embedding_length`, `context_length` | Physical dimensions and context bound |
| `attention.head_count`, `attention.head_count_kv` | Query and grouped KV heads |
| `attention.key_length`, `attention.value_length` | Per-head widths; do not infer from hidden/head count |
| `expert_count`, `expert_used_count`, `expert_feed_forward_length` | Router and expert dimensions |
| `loop.start`, `loop.end`, `loop.count`, `loop.gate_rank` | Required loop controls; exclusive end |
| `loop.varying` | Optional upstream flag defaulting false; fixed text rejects varying checkpoints |
| `attn_res.block_size` | Six-layer block residual grouping |
| `attention.layer_norm_rms_epsilon`, `attention.qk_clip` | Normalization and Q/K clipping |
| `attention.relative_length`, `attention.relative_extent`, `attention.relative_clip` | Relative bias |
| `attention.log_scale_floor`, `attention.log_scale_alpha` | Global position scaling |
| `attention.sliding_window`, `attention.sliding_window_pattern` | Window size and one physical-layer entry per layer |
| `shortconv.l_cache` | Convolution kernel length, not just past-input count |
| `vocab_size`, `vocab_size_unpadded` | Stored versus tokenizer/output vocabulary |
| `activation.situ_beta`, `activation.situ_linear_beta` | Expert softcap activation parameters |
| `expert_weights_scale`, `final_logit_softcapping` | Optional upstream scale/cap; qualify selected-file values |

The upstream loader requires finite positive normalization, clipping and
activation parameters and nonnegative finite log-scale alpha. Its loop
endpoints align with residual blocks; the start is nonzero, the end does
not exceed physical layers, and the region is nonempty. Fixed looping
requires at least two passes upstream; this initial adapter targets exactly
three passes of the specific 24-layer checkpoint. A generic schedule builder
may represent more configurations than the model adapter permits.

Validate physical and logical counts against configured limits before
expanding session state. Confirm optional defaults against the pinned
loader and actual conversion; do not extrapolate defaults for required keys.
Tokenizer arrays, special token IDs, template and per-tensor types require
their existing independent validation too.

## Tensor names and shapes

Names and ggml dimension order below come from upstream `inkling2.cpp`,
`inkling2-loop.cpp` and `llama-arch.cpp`. Matrix dimension order here is not
the row-major PyTorch order. Let `H=2304`, `Q=24`, `K=8`, `D=128`, `R=16`,
`F=1152`, `E=128`, `C=4`, `G=64`, `V=201024` and `X=1024`.
Every entry has suffix `.weight` except `exp_probs_b.bias`.

| Name | ggml dimensions | Presence |
| --- | --- | --- |
| `token_embd` | H,V | Required |
| `token_embd_norm` | H | Required |
| `output` | H,V | Required, not assumed tied |
| `output_norm`, `output_res_query` | H | Required |
| `blk.p.attn_q`, `blk.p.attn_gate` | H,D*Q | Each physical layer |
| `blk.p.attn_k`, `blk.p.attn_v` | H,D*K | Each physical layer |
| `blk.p.attn_output` | D*Q,H | Each physical layer |
| `blk.p.attn_q_clip` | D,Q | Each physical layer |
| `blk.p.attn_sink_proj` | H,Q | Each physical layer |
| `blk.p.attn_rel` | H,R*Q | Each physical layer |
| `blk.p.attn_rel_bias` | R,X | Each physical layer |
| `blk.p.attn_rel_clip` | R,Q | Each physical layer |
| `blk.p.attn_k_conv`, `blk.p.attn_v_conv` | C,D*K | Each physical layer |
| `blk.p.attn_post_conv`, `blk.p.ffn_post_conv` | C,H | Each physical layer |
| `blk.p.attn_norm` | H | Local layers |
| `blk.p.attn_q_inp_norm`, `blk.p.attn_k_inp_norm`, `blk.p.attn_v_inp_norm` | H | Global layers |
| `blk.p.attn_k_conv_proj`, `blk.p.attn_v_conv_proj` | H,C*K | Global layers |
| `blk.p.attn_res_query` | H,1 local; H,3 global | All physical layers except zero |
| `blk.p.ffn_res_query`, `blk.p.ffn_norm` | H | Each physical layer |
| `blk.p.ffn_gate_inp` | H,E | Each physical layer; router |
| `blk.p.exp_probs_b.bias` | E | Optional upstream correction bias |
| `blk.p.ffn_gate_up_exps` | H,2*F,E | Each physical layer; fused gate then up |
| `blk.p.ffn_down_exps` | F,H,E | Each physical layer |
| `blk.p.loop_msg_query` | H,4 | Core physical layers 6-17 only |
| `blk.p.loop_c_ctrl_down` | 2*H,G | Core layers; c is q, k, v or ffn |
| `blk.p.loop_c_ctrl_gain`, `blk.p.loop_c_ctrl_forget` | G,H | Core layers; all four controllers |

The selected GGUF carries scales inside its existing GGML quantization blocks
and no external expert weight/input scale tensors. Other conversions with
external scales require their own name, shape, default and precision audit;
NVFP4 block support does not settle it. Later-visit descriptors must retain
the same scale references as physical owners. Original mixed-precision
checkpoint compatibility remains a separate open item.

## Required rejection fixtures

Cover missing required metadata/tensors, non-finite values, empty/reversed
or misaligned core regions, wrong fixed visit count, research variants,
head divisibility, wrong pattern length, padded/unpadded vocabulary
inconsistency, invalid expert counts, unsupported layouts, absent required
scales, incompatible tensor formats and logical-state limits. Preparation
must unwind all partial acquisitions. Inspection must work on descriptors
without allocating full weights.

The adapter uses the existing structured metadata, missing-tensor,
tensor-format and tensor-shape errors, including the offending key or tensor.
Unsupported variable loops and unrecognized auxiliary tensors use
`Arch_Unsupported_Feature` with an Inkling-specific feature identifier.
No new parallel diagnostic mechanism is introduced.
