# Support matrix

A row is *implemented* only when it has production code, structural
validation, runtime execution, structured error handling and AUnit coverage.

## Container

| GGUF version | State |
| --- | --- |
| 1 | Rejected: `MR-GGUF-0003` |
| 2 | Implemented |
| 3 | Implemented |
| 4 and above | Rejected: `MR-GGUF-0003` |

## Tensor formats

| Format | Block | Bytes | State |
| --- | --- | --- | --- |
| F32 | 1 | 4 | Implemented |
| F16 | 1 | 2 | Implemented |
| Q4_0 | 32 | 18 | Implemented |
| Q8_0 | 32 | 34 | Implemented |
| Q4_K | 256 | 144 | Implemented |
| Q5_K | 256 | 176 | Implemented |
| Q6_K | 256 | 210 | Implemented |
| BF16 | 1 | 2 | Implemented; the top half of a binary32 |
| Q2_K | 256 | 84 | Implemented; two bits an element, sixteen sub-blocks |
| Q3_K | 256 | 110 | Implemented; two bits and a shared mask of thirds |
| Q4_1 | 32 | 20 | Implemented; a nibble with a scale and a minimum |
| Q5_0 | 32 | 22 | Implemented; a fifth bit apart, centred by sixteen |
| Q5_1 | 32 | 24 | Implemented; a fifth bit apart, with a minimum |
| Q8_1, Q8_K | — | — | Recognized by the parser, rejected before preparation. Neither is a way weights are stored: both are intermediates ggml builds inside its own dot products |
| Everything else | — | — | Rejected: `MR-GGUF-0017` |

Recognized is not supported. A recognized-but-unimplemented format passes
container validation and is rejected by `Model_Runner.Tensors.Make` with
`MR-TENSOR-0005`.

## Architecture

| Architecture | State |
| --- | --- |
| `llama` | Implemented |
| Everything else | Rejected: `MR-ARCH-0002` |

Explicitly rejected features: mixture of experts, sliding-window attention,
asymmetric key and value widths, and rotary scaling other than `none` and
`linear`.

## Tokenizer

| `tokenizer.ggml.model` | State |
| --- | --- |
| `llama` (SentencePiece) | Implemented, with byte fallback |
| Everything else | Rejected: `MR-TOK-0002` |

## Tokenizer capabilities

| Capability | State |
| --- | --- |
| Vocabulary with scores and token types | Implemented |
| Greedy highest-score adjacent merge | Implemented |
| SentencePiece space substitution and dummy prefix | Implemented |
| Byte fallback through `<0xNN>` tokens | Implemented |
| Special tokens: beginning, end, unknown | Implemented |
| `add_bos_token` / `add_eos_token` policy | Implemented |
| UTF-8-boundary-safe incremental decoding | Implemented |
| BPE merge tables | Implemented for the `gpt-2`, `falcon` and `starcoder` cutting rules, in any script; a vocabulary naming another rule is refused by name |

## Chat-template constructs

| Construct | State |
| --- | --- |
| Literal text | Implemented |
| `{{ terms }}` joined by `+` | Implemented |
| `{% for message in messages %}` | Implemented |
| `{% if %}` / `{% elif %}` / `{% else %}` / `{% endif %}` | Implemented |
| `==`, `!=`, `and`, `or`, `not` | Implemented |
| `bos_token`, `eos_token`, `add_generation_prompt` | Implemented |
| `message['role']`, `message['content']`, dotted forms | Implemented |
| `loop.first`, `loop.last`, `loop.index`, `loop.index0` | Implemented |
| `{%- -%}` and `{{- -}}` whitespace control | Implemented |
| `set`, `macro`, `include`, `import`, `raise_exception` | Rejected: `MR-TMPL-0002` |
| Filters | Rejected: `MR-TMPL-0007` |
| Slicing, message indexing, arithmetic, calls | Rejected: `MR-TMPL-0002` |

## Sampling

| Feature | State |
| --- | --- |
| Greedy, with lowest-token tie-breaking and no random draw | Implemented |
| Temperature | Implemented |
| Top-k, top-p, minimum-p | Implemented |
| Repetition penalty with a configurable window | Implemented |
| Frequency and presence penalties | Implemented |
| Fixed 64-bit seed and entropy-chosen seed reporting | Implemented |
| Forbidden-token masking | Implemented |

## Backend

| Capability | State |
| --- | --- |
| Ada worker pool with reusable tasks | Implemented |
| Deterministic row partitioning | Implemented |
| Single-worker mode | Implemented |
| Bounded work queue | Implemented (one job outstanding) |
| Worker-failure propagation | Implemented |
| Clean shutdown, rejection while closing | Implemented |
| Batched prefill | Implemented, `--batch-size`, capped at 128 tokens |
| Noncontiguous views | Not implemented |
| Backend selection | Not implemented; there is one backend |

## Locales

| Locale | State |
| --- | --- |
| `en` | Complete, the default |
| `da` | Partial; every key it does not carry falls back to `en` |
| `qps` | Pseudo-locale generated from `en`, complete |

## Not implemented

Nothing remains from the specification's tooling list: the release checklist is
`tools/bin/check_all` and the archive is `tests package`.

The multiply is folded into the decode for Q4_0, where it measured faster.
Q8_0, F32, F16 and the k-quant formats decode a span and then multiply, because
fusing them measured slower; see the README. The kernels are vectorized by the compiler from ordinary Ada, with no
intrinsics, no assembly and no target-specific flags; `-march=native` and
`-march=x86-64-v3` both measured slower than the baseline build, so neither is
used. Weights are not repacked.

Kernel measurements are in the README and only there. They were carried in both
places, and when a measuring fault was found and corrected -- the benchmark was
timing denormal arithmetic and reading about four times too fast -- only one
copy was corrected. A figure worth publishing is worth having one home.

See the README for the full list.
