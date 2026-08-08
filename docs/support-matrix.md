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
| `gpt2` (byte-pair encoding) | Implemented, for the cutting rules below |
| Everything else | Rejected: `MR-TOK-0002` |

A `gpt2` vocabulary also names the rule that cuts text before any merging
happens, in `tokenizer.ggml.pre`. The rules differ in ways that do not show
in the decoded text -- under the original only a space may lead a word, under
the later ones any character that is neither letter nor digit may -- so a
vocabulary naming a rule this does not implement is refused by name rather
than cut by the wrong one.

| `tokenizer.ggml.pre` | State |
| --- | --- |
| absent, `gpt-2`, `starcoder` | Implemented |
| `falcon` | Implemented; leads a run as the original does, groups digits in threes |
| `llama3`, `llama-bpe` | Implemented |
| `qwen2` | Implemented |
| `smollm` | Implemented |
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
| BPE merge tables | Implemented for the `gpt-2`, `falcon`, `starcoder`, `smollm`, `llama3` and `qwen2` cutting rules, in any script; a vocabulary naming another rule is refused by name |

## Chat-template constructs

| Construct | State |
| --- | --- |
| Literal text | Implemented |
| `{{ terms }}` joined by `+` | Implemented |
| `{% for message in LIST %}` | Implemented; the loop variable must be named `message` |
| `{% if %}` / `{% elif %}` / `{% else %}` / `{% endif %}` | Implemented |
| `==`, `!=`, `and`, `or`, `not` | Implemented |
| `bos_token`, `eos_token`, `add_generation_prompt` | Implemented |
| `message['role']`, `message['content']`, dotted forms | Implemented |
| `messages[0]['role']` and its like | Implemented, relative to what `messages` names at that point |
| `{# comments #}` | Implemented |
| `{% set %}` | Implemented for a term expression, `none`, another name, and a front slice such as `messages[1:]` |
| `true`, `false`, `none`, decimal numbers | Implemented |
| `is defined`, `is none`, `is not ...` | Implemented |
| `'field' in message` | Implemented; true for `role` and `content`, false for anything a message here cannot hold |
| Parenthesised conditions | Implemented, to `Max_Depth` |
| `\| trim`, `\| length` | Implemented |
| `loop.first`, `loop.last`, `loop.index`, `loop.index0` | Implemented |
| `{%- -%}` and `{{- -}}` whitespace control | Implemented |
| `macro`, `include`, `import` | Rejected at compile time: `MR-TMPL-0002` |
| Other filters | Refused when evaluated: `MR-TMPL-0007` |
| Function calls, `tojson`, `strftime_now`, `raise_exception`, arithmetic, indexing by anything but a number | Refused when evaluated: `MR-TMPL-0002` |
| Reading a name the template never assigned | Refused when evaluated: `MR-TMPL-0006` |
| More than 32 names, or more variable text than the pool holds | Refused when evaluated: `MR-TMPL-0002` and `MR-TMPL-0011`. A name reassigned in a loop takes its own room back, so building one message's text per turn costs one turn's room |

A statement whose shape cannot be read is refused at compile time, because
nothing after it can be trusted to mean anything. A value that cannot be
computed is refused when it is asked for. Every template shipped with a
current Llama-3 model describes tool calling in branches that a conversation
of plain messages never enters; refusing the template for those branches
refuses the model, and refusing at the point of use refuses only what was
actually asked for. Nothing is approximated either way.

`strftime_now` is not provided, so a template that guards it with
`is defined` -- as the Llama-3.2 template does -- takes its own fallback
date. That is a visible difference from a reference runtime which does
provide it: the rendered system block carries the template's built-in date
rather than today's. Rendering stays reproducible, which is the reason for
the choice.

## Sampling

| Feature | State |
| --- | --- |
| Greedy, with lowest-token tie-breaking and no random draw | Implemented |
| Temperature | Implemented |
| Top-k, top-p, minimum-p | Implemented |
| Repetition penalty with a configurable window | Implemented |
| Frequency and presence penalties | Implemented |
| Built-in chat formats | `llama3` and `chatml`, selected with `--chat-template`; nothing is chosen on a model's behalf |
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
| Backend selection | `--backend NAME`, matched against the backends this build has and refused by name otherwise. There is one, `cpu` |

## Locales

| Locale | State |
| --- | --- |
| `en` | Complete, the default |
| `da` | Partial; every key it does not carry falls back to `en` |
| `qps` | Pseudo-locale generated from `en`, complete |

## Not implemented

Nothing remains from the specification's tooling list: the release checklist is
`tools/bin/check_all` and the archive is `tests package`.

Every format decodes a span and then multiplies it. Nothing is fused. The
multiply was folded into the decode for Q4_0, which was the last format that
did it, and that path is gone rather than left switched off: fusing breaks the
sum at every block so the scale can be applied there, and that costs the flat
inner loop more than the saved multiply is worth. Q4_0 now carries the same
per-element rounding every other format already had. The measurement that
reversed the earlier decision is in the README, with the rest of the kernel
figures.

The kernels are vectorized by the compiler from ordinary Ada, with no
intrinsics, no assembly and no target-specific flags; `-march=native` and
`-march=x86-64-v3` both measured slower than the baseline build, so neither is
used. Weights are not repacked.

Kernel measurements are in the README and only there. They were carried in both
places, and when a measuring fault was found and corrected -- the benchmark was
timing denormal arithmetic and reading about four times too fast -- only one
copy was corrected. A figure worth publishing is worth having one home.

See the README for the full list.
