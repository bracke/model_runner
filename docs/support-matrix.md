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
| `qwen2` | Implemented: the same shape with a bias on each attention projection and the split rotary pairing. The biases are required, not optional |
| `qwen3` | Implemented: the same shape again, with no biases and a root-mean-square normalization of every query head and every key head before the rotation -- one gain per element of a head, shared across the heads, required rather than taken if present. Its head widths come from `attention.key_length` and `attention.value_length`, which need not be the embedding divided by the head count |
| `qwen3moe` | Implemented: `qwen3` with its feed-forward block behind a router, which is a metadata prefix and nothing else -- the mixture is read from the expert keys under that prefix. Compared against the independent implementation on its own rather than in the sweep, because crossing a prefix with every format and path buys one string comparison |
| Everything else | Rejected: `MR-ARCH-0002`, which names every architecture this build does read |

`llama`, `qwen2` and `qwen3` are compared against an independent
implementation by `tests conformance`, in every shape a model comes in.

| Sliding-window attention | Implemented: a model naming `<arch>.attention.sliding_window` has each position attend to that many positions ending at itself, uniformly across layers, on every evaluation path and both backends. The cache still holds the whole context -- the window narrows what may be read, not what is kept -- so this buys the model's answer and not the model's memory. An architecture that alternates windowed and full layers needs a per-layer pattern this does not have and is not claimed |

| Mixture of experts | Implemented: a model naming `<arch>.expert_count` and `<arch>.expert_used_count` carries a router beside each layer's feed-forward block and a stack of expert matrices instead of one. The router scores every expert for the position being computed, a softmax turns the scores into shares, the highest few run, and their outputs are summed in proportion to those shares renormalized over that few. Ties go to the lower-numbered expert. One expert's width comes from `<arch>.expert_feed_forward_length` when the file states it and from `feed_forward_length` otherwise. Because the route is decided per position, this is the one block a batch runs a token at a time; everything else about a batch is still one matrix against many vectors. A shared expert, a gate that is not a softmax, and unnormalized expert weights are each refused by name |

| Rotary scaling | Implemented for `none`, `linear` and `yarn`, named by `<arch>.rope.scaling.type` and refused by name otherwise. Linear divides every position by `<arch>.rope.scaling.factor`. Yarn divides only the frequencies slow enough that a long context needs them, ramping across the band between `beta_fast` and `beta_slow` turns over `original_context_length`, and scales the rotated vector by the method's own correction times `attn_factor`. A `rope_freqs.weight` table of per-dimension divisors is applied when the file carries one, which is how a file states a schedule that is not one number. `rope_factors_long.weight` and `rope_factors_short.weight` are refused, by the tensors as well as by the name: choosing between two tables by prompt length makes the rotation depend on the sequence rather than on the position |

| Head widths | Implemented: `<arch>.attention.key_length` and `<arch>.attention.value_length` are read when the file states them, and neither has to be the embedding width divided by the head count nor equal to the other. A file that states neither has both derived from the embedding width, which then has to divide exactly. The key cache and the value cache are sized separately, and the attention output projection reads the heads' worth of value width rather than the embedding width |

Nothing in the architecture profile is rejected as a feature any more; what
remains rejected is a file that describes a model this arithmetic cannot
express, and an architecture identifier this build does not carry.

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
| BPE merge tables | Implemented for the `gpt-2`, `falcon`, `starcoder`, `smollm`, `llama3` and `qwen2` cutting rules, in any script -- a letter is told from a symbol by its Unicode category, not by whether it is ASCII; a vocabulary naming another rule is refused by name |
| BPE byte-to-character mapping, both ways | Implemented; encoding rewrites each byte as the character that stands for it and decoding undoes that, which the suite checks by round trip |
| Markers such as `<|im_start|>` or `</s>` written into the text | Implemented on both roads; the longest piece the vocabulary calls a control or user-defined token wins, so a rendered chat template reaches the model as the tokens it meant. A template substitutes `bos_token` and `eos_token` as their spelling before anything is tokenized, which is why this matters on every templated turn. The rule used to be inside the byte-pair road alone, so a SentencePiece model read its own template's end marker as a run of bytes |

What the byte-pair cut carries is a rule per vocabulary rather than a general
engine for the expressions those pre-tokenizers are written as. Two limits
follow: the contractions are the seven the original names, matched as written
and so in lower case only; and a run of line endings is a run of whitespace
rather than a run of its own. The suite settles that the engine cuts as this
says, and that a reader written independently from this description agrees.
What it cannot settle is the description -- that needs a second runtime and a
real vocabulary, which is what `docs/reference-runtime.md` is about.

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
| `version` reporting the build's reach | Tensor formats, backends and chat formats, listed from the code |
| Built-in chat formats | `llama3` and `chatml`, selected with `--chat-template` and named from the same enumeration the help and the matching read; a name this build does not carry is refused by name. Nothing is chosen on a model's behalf |
| Fixed 64-bit seed and entropy-chosen seed reporting | Implemented |
| Forbidden-token masking | Implemented |

## Backend

Two, selected with `--backend`. The rows below say which of them each
capability belongs to, because most of them belong to one: a worker pool and
a partition are what `cpu` has and what `reference` deliberately has not.

| Backend | State |
| --- | --- |
| `cpu` | Worker pool, partitioned rows, batched prefill, span decoding. The default |
| `reference` | One row at a time, decoded whole, multiplied element by element, summed wide, on the calling task. No pool, no partition, no batching. Produces the same logits as `cpu` and takes about twelve times as long, measured; it exists so that a suspicious result on a caller's own model can be asked again by different code |

| Capability | Backend | State |
| --- | --- | --- |
| Ada worker pool with reusable tasks | `cpu` | Implemented |
| Deterministic row partitioning | `cpu` | Implemented |
| Single-worker mode | `cpu` | Implemented |
| Bounded work queue | `cpu` | Implemented (one job outstanding) |
| Worker-failure propagation | `cpu` | Implemented |
| Clean shutdown, rejection while closing | `cpu` | Implemented |
| Batched prefill | `cpu` | Implemented, `--batch-size`, capped at 128 tokens |
| Evaluation on the calling task, no pool | `reference` | Implemented |
| One reading of the weights per vector | `reference` | Implemented; `--batch-size` is clamped to one and said so under `--verbose` |
| Noncontiguous views | both | Not implemented |
| Repacking | both | Implemented, `--repack f32|bf16`: every weight matrix decoded once at load. `f32` is exact and holds the logits to the bit; `bf16` rounds to eight mantissa bits and is faster, seven to thirty-eight per cent depending on the format it replaces, at two bytes a weight. A matrix already in the target format is left alone and the file's own bytes are released when nothing points at them. Decoded by as many tasks as the run has workers |
| Replaced-file detection | The file is asked whether it changed before its tensors are read; a size that differs from the one validated is refused with `MR-GGUF-0002`. An in-place edit of the same length is not detected |
| Memory accounting | Every category is charged: weights, converted weights, KV cache, activations, logits, sampling workspace, token buffers, template buffers, metadata and vocabulary storage. `--memory-limit` bounds the model and the session |
| Capability checking | Every field of the backend's `Capabilities` is asked by something: the formats and the alignment per tensor while a model loads, matrix-vector once when it is prepared, batching when a batch is evaluated, and the worker count when the pool is sized. The `reference` backend declines two of them outright, which is what made the machinery answer for itself; disclaiming any of the others refuses, naming the capability. Five fields that could only ever hold one value were removed rather than wired |
| Backend selection | `--backend NAME`, matched against the backends this build has and refused by name otherwise: `cpu` and `reference` |
| Backend reporting | `inspect` names the backend a run would use and the worker count it would take; `--show-stats` names the backend the run did use and the workers it had. Reported rather than inferred from the command line: a backend that does not run in parallel takes one worker whatever `--threads` said |

## Locales

| Locale | State |
| --- | --- |
| `en` | Complete, the default |
| `da` | Partial; every key it does not carry falls back to `en` |
| `qps` | Pseudo-locale generated from `en`, complete |

A locale this build does not carry falls back to `en`. When it was named on the command line that is reported, at any verbosity: a request that was not honoured is not progress chatter. A locale taken from the environment reports only under `--verbose`.

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
