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
| IQ4_NL | 32 | 18 | Non-linear four-bit: a nibble indexes a table of sixteen levels rather than naming a number, spaced finely near zero. Nibble layout as Q4_0 |
| IQ4_XS | 256 | 136 | The same levels over a super-block, with a six-bit scale for each sub-block of 32 split between a nibble and a two-bit field and signed by an offset of 32 |
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
| `qwen3moe` | Implemented, and read from a file somebody else published -- Qwen3-30B-A3B, 579 tensors and 30.5 billion parameters, loaded, generated from, deterministic and thread-stable, its tensor names agreeing with the fixture written here name for name. `qwen3` with its feed-forward block behind a router, which is a metadata prefix and nothing else -- the mixture is read from the expert keys under that prefix. Compared against the independent implementation on its own rather than in the sweep, because crossing a prefix with every format and path buys one string comparison. `inspect` names the mixture -- how many experts a layer holds, how many run for a position and how wide one is -- because the feed-forward width such a file states describes the dense block it has not got |
| `gemma` | Implemented: this shape with three differences, each of which produces a plausible wrong answer rather than a refusal when it is missed. The normalization gain is one plus the stored weight, because the weights are trained around zero; the embedding row is multiplied by the square root of the embedding width before the first layer; the feed-forward gate is a Gaussian error unit in its hyperbolic-tangent form rather than a logistic one. Crossed with every format and both evaluation paths against the independent implementation, because the three touch every part of a pass rather than a prefix. Not implemented: the second and third generations, which add attention and final logit softcapping, alternating window widths and a second pair of norms a block |
| `gemma2` | Implemented: `gemma` and four more differences. A normalization after each sublayer as well as before it, required where the architecture states them; a bound on the attention scores and another on the logits, each applied as the scaled hyperbolic tangent the architecture states, before the softmax reads a score and after the last projection produces a logit; and a sliding window on every other layer, starting with the first, rather than on all of them. Crossed with every format and both evaluation paths. Not implemented: the third generation, which drops the bounds, normalizes query and key heads, and windows five layers in six |
| `gemma3` | Implemented: `gemma2`'s two normalizations a block without its two bounds, query and key head normalization as `qwen3` has it, a sliding window on five layers in six rather than every other one, and a rotation base of their own for those five -- so a layer's base depends on where it sits in the pattern, which is the first architecture here where one model turns on two bases. Crossed with every format and both evaluation paths, and built with six blocks where every other architecture is built with two, because the sixth is the one that sees everything: with two, the layer that attends to the whole context and the base it turns on were described in the engine, described again in the independent implementation, and compared by nothing. Not implemented: the per-layer attention scalar some of its sizes state, and multimodal input, which this program has none of for any architecture |
| `phi3` | Implemented: this shape with its projections written fused -- queries, keys and values in one tensor, gate and up projection in another. A part is a view at a row offset rather than a copy, which works because a row is a whole number of blocks in every format this reads, so a part begins on a block boundary; repacking then rewrites each part as its own tensor, and a repacked phi3 model is no longer fused at all. Crossed with every format and both evaluation paths. Not implemented: nothing this architecture states that this does not read |
| `falcon` | Implemented: one normalization a block rather than two. Attention and the feed-forward both read what the block normalized on the way in, and both add to the same residual, so the two sublayers run beside each other rather than one after the other. The normalization subtracts the mean and divides by the standard deviation and carries a bias beside its gain, which is a different computation from the root-mean-square form the other architectures here use rather than a parameter of it; both norm biases are required, and a file without them is refused. The feed-forward has no gate: one projection up, a Gaussian error unit, one projection down -- and the absence of the gate tensor is what says so, so an architecture added later with the same arrangement needs nothing new. Queries, keys and values are written fused as `phi3` writes them and are taken out the same way. Crossed with every format and both evaluation paths |
| `phi2` | Implemented: `falcon`'s arrangement -- one normalization a block, attention and the feed-forward reading it in parallel, a centred normalization with a bias, no gate -- with a bias on every projection rather than on none. The queries, keys and values carry theirs in one vector as their matrices are in one tensor, taken at the same offsets; attention's output, both sides of the feed-forward, and the output projection carry one each, so a logit is biased twice on its way out. The bias on the output projection is added where the bound on the logits is applied, in one place all three paths that produce logits call, rather than beside each of them. Crossed with every format and both evaluation paths |
| `gpt2` | Implemented: the oldest shape here and the only one that does not rotate. It learns where a token is -- one row a position in `position_embd.weight`, added to the token's row before the first layer -- and states `rope.dimension_count` as zero, which this build refused until gpt2 arrived because the key was read with a minimum of one. Otherwise it is `phi2`'s detail with `phi2`'s biases on every projection and a centred normalization, and llama's arrangement: two normalizations a block rather than one, because its sublayers run one after the other. Its feed-forward has no gate. Crossed with every format and both evaluation paths, in every shape but the mixture -- a router in front of experts a gateless architecture has not got describes no model anyone publishes |
| `bert` | Implemented, and read from a file somebody else published -- all-MiniLM-L6-v2, which is what found the two things the synthetic fixture had invented: a rotary width defaulted from the head size on a file that states none, and the vocabulary convention above. The first architecture here that does not generate. It reads a whole text at once and produces a state for every position of it, and three things follow. Its attention is bidirectional -- a position sees the positions after it as well as the ones before -- which is not a parameter of attention but a fact about what the model was trained to be: a bert read causally answers, and answers with an embedding that is quietly the wrong one. Which way it attends is read from `<arch>.attention.causal` where the file states it, as a published all-MiniLM does, and taken from the architecture where it does not. It normalizes after the residual add rather than before the sublayer, `LN(x + Attn(x))` where `gemma2` computes `x + LN(Attn(x))`, which is a third arrangement beside the two already here rather than a flag on one of them. And it learns three embeddings rather than one -- a row for the token, a row for where the token is, and a row for which segment it belongs to -- summed and normalized before the first layer; the position row is `gpt2`'s, which is why there is no rotation anywhere in the model. Its normalization centres and carries a shift, as `falcon`'s and `phi2`'s do, and its feed-forward has no gate. It carries no projection from a state to a token and ties none to its embedding table, so `run` is refused by name and `embed` is what it is for. Crossed with every format and compared against the independent implementation on every position's state rather than on a distribution it has not got. Not implemented: `nomic-bert`, which is this shape with a rotation, a gated feed-forward and its normalizations back on the way in |
| `nomic-bert` | Implemented, and read from a file somebody else published -- nomic-embed-text-v1.5. `bert`'s arrangement with three of its parts replaced, each read off a real file rather than taken from a description: it rotates where `bert` learns a row for the position, so it carries no position table at all and states `rope.freq_base` instead; its queries, keys and values are written fused as `phi3` writes them; and its feed-forward is gated, by the sigmoid-weighted unit rather than the Gaussian one `bert` uses -- two architectures of one shape need not share that. It carries no bias on any projection: only the two normalizations a block and the one over the embedding have one, which is why every bias in this profile is asked for by architecture rather than taken if present. What it keeps is what makes `bert` what it is -- attention both ways, a normalization after each residual add, a segment row beside the token's, and no projection to a distribution. It splits its rotation as everything since `llama` does -- element *i* against element *i + rotary/2* -- which was written the other way round first, from a recollection rather than from anything, and cost a cosine of 0.947 against a second runtime until that runtime was asked. Crossed with every format against the independent implementation, in the shapes it can hold: it rotates, so a stretched rotation means something to it, and it has a gate, so a router has experts to route to; a window does not, for the reason no bidirectional model has one |
| `jina-bert-v2` | Implemented, and read from a file somebody else published -- jina-embeddings-v2-base-en. `bert`'s arrangement again, with the positions taken away entirely: it neither rotates nor learns a row for where a token is, and is told instead by a fall-off in the attention scores. One slope a head, taken off after the scale by one over the root of the head width and before the softmax, and unsigned -- a position is as far from what follows it as from what came before, which is the bidirectional form and not the one a generating model uses. The ladder of slopes has two branches and the second is only reached where the head count is not a power of two: twelve heads take eight rungs of one and four of the other, and a ladder written as the first branch alone answers with a plausible embedding for the other four. The number the ladder is built from is eight, which no published file of this architecture states and the other runtime carries in its own source; a file stating another is refused rather than cut to eight. Its feed-forward is gated by the Gaussian unit -- `nomic-bert` gates by the sigmoid-weighted one, so the two differ there as well as in the positions -- and it shifts what it projects down and nothing else. It biases the three attention projections and the one out of attention. Not implemented and refused by name: the code variant's third normalization inside the attention sublayer and its query and key normalizations, which are three tensors this does not compute and would otherwise be read as a model with three normalizations missing. Crossed with every format against the independent implementation, in the shapes it can hold: it rotates nothing, so a stretched rotation is meaningless, and a window is meaningless for the reason no bidirectional model has one; its gate gives a router experts to route to |
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
| `bert` (WordPiece) | Implemented. Neither merges nor ranks: it changes the text first -- lower-cased, accents off, punctuation and ideographs cut loose from the words around them -- and then spells each word from the front with the longest piece the vocabulary carries. A piece that starts a word carries a leading U+2581 and one that continues a word is written bare, which is the reverse of the two-hash convention the architecture's papers describe and is what a converted vocabulary holds: of the thirty thousand pieces in a published all-MiniLM not one begins with the hashes and twenty-four thousand begin with the marker. A word no run of pieces spells is one unknown token and not the pieces that did match, because half a word spelled is a different word. A file stating `tokenizer.ggml.do_lower_case` as false is refused rather than folded anyway: a vocabulary cut without folding carries pieces with capitals in them, and folding the text before looking those up would find none of them and answer in unknowns, which is an answer and not an error |
| `t5` (unigram) | Implemented, and read from a vocabulary somebody else published. Neither merges nor spells: it chooses, out of every way the text could be cut into pieces the vocabulary holds, the one whose scores sum highest -- the scores being log probabilities, which is why they are summed rather than compared. That is a different answer from the `llama` road's and not a better-computed one: merging the best-scoring adjacent pair first can foreclose a split that would have scored higher whole, and a piece that lies on the best path but never appears as the join of two survivors is unreachable by merging at all. A character no piece spells is an edge of its own at the lowest score in the vocabulary less ten, which is the only thing keeping the lattice connected; a run of them is one unknown token and not one each. A file without scores, or without an unknown token, is refused rather than read as a vocabulary of equals. The text is normalized first, through the table the file itself carries in `tokenizer.ggml.precompiled_charsmap` -- a compressed trie from an input prefix to what replaces it, read rather than worked out here, because it is the model's own table and no two files need agree about it |
| Everything else | Rejected: `MR-TOK-0002` |

A `gpt2` vocabulary also names the rule that cuts text before any merging
happens, in `tokenizer.ggml.pre`. The rules differ in ways that do not show
in the decoded text -- under the original only a space may lead a word, under
some of the later ones any character that is neither letter nor digit may,
and two of them cut every run of punctuation out of the text before anything
else looks at it -- so a vocabulary naming a rule this does not implement is
refused by name rather than cut by the wrong one.

Six rules, and many names for them: the rule a name asks for is what decides,
and a great many of these names ask for the same one. The grouping is the
other runtime's own, which files these names under six blocks of expressions
between them.

| `tokenizer.ggml.pre` | State |
| --- | --- |
| absent, `default` | Implemented. What a vocabulary naming no rule is cut by, and not the original rule: it cuts punctuation out of the text first, so a contraction is two pieces and a space before a full stop stands alone, and it groups digits in threes with nothing before them. Reading an absent key as the original rule spelled every prompt to a published GPT-NeoX and a published Aquila differently from the way those models were trained |
| `gpt-2`, `mpt`, `olmo`, `jais`, `trillion`, `granite-docling`, `phi-2`, `gigachat`, `a.x-4.0`, `mellum`, `modern-bert`, `roberta-bpe`, `exaone4`, `jina-es`, `jina-de`, `jina-v1-en`, `jina-v2-es`, `jina-v2-de`, `jina-v2-code` | Implemented; the original rule |
| `falcon` | Implemented; leads a run as the original does, cuts punctuation out of the text first, and groups digits in threes, which shows on a run of three or more. Its punctuation class holds the grave accent where the default's does not, and that one character is the whole difference between the two |
| `smollm`, `starcoder`, `refact`, `command-r`, `codeshell`, `exaone`, `minerva-7b`, `mellum2` | Implemented; leads a run as the original does and takes digits one at a time with nothing before them. `starcoder` belongs here and was on the original rule until a published vocabulary was read: the two are one block in the other runtime, and starcoder's own vocabulary cannot tell them apart, because no piece of it spans a digit and anything else |
| `llama3`, `llama-v3`, `llama-bpe`, `falcon3`, `falcon-h1`, `pixtral`, `midm-2.0`, `lfm2`, `jina-v5-nano`, `dbrx`, `smaug-bpe`, `glm4`, `chatglm-bpe` | Implemented; any character that is neither letter, digit nor line ending may lead a word, so a tab joins the word after it, and digits group in threes with nothing before them |
| `qwen2`, `stablelm2`, `deepseek-r1-qwen`, `kormo`, `f2llmv2`, `megrez`, `hunyuan`, `grok-2`, `solar-open` | Implemented; leads a run as `llama3` does and takes digits one at a time |
| Everything else | Rejected: `MR-TOK-0002` |

## Tokenizer capabilities

| Capability | State |
| --- | --- |
| Vocabulary with scores and token types | Implemented |
| Greedy highest-score adjacent merge | Implemented |
| Best-path segmentation over log probabilities | Implemented for `t5`, and read by a second implementation written from this description rather than from the engine's code. Not driven by a model: no architecture this build reads ships a `t5` vocabulary, so this road is exercised by the vocabulary alone -- against a published one through `tests tokenize` and against the independent reader through a fixture -- and not through a session, a generated token or the conformance sweep. The engine bounds how far a piece may reach by the longest one the vocabulary holds and looks each candidate up in a hash; the reader asks every piece of the vocabulary at every boundary, which is the same question answered the slow obvious way. The fixture they are compared on is one where merging and the best path give different answers, because a fixture where they agree would let a reader that took the wrong road pass |
| The normalization table a unigram file carries | Implemented: the four-byte length, the compressed trie, and the pool of replacements it points into. A piece the file's author wrote in by hand is passed through the table untouched, and a byte sequence that is no character at all becomes the replacement character one byte at a time rather than failing the encode. `tokenizer.ggml.remove_extra_whitespaces` decides whether a run of spaces becomes one marker or one each |
| SentencePiece space substitution and dummy prefix | Implemented, and the prefix is written only where the file asks for it. `tokenizer.ggml.add_space_prefix` had not been read at all, and gemma2 and gemma3 state it false: both were given every prompt with a marker in front of it that they were never trained to see, so each answered a question spelled differently from the one asked |
| Byte fallback through `<0xNN>` tokens | Implemented |
| Special tokens: beginning, end, unknown | Implemented. On the WordPiece road the three are what the road carries -- 101, 102 and 100 -- before any key is read, because that road wraps its text by construction; a file overrides them by `bos_token_id`, `eos_token_id` or `seperator_token_id`, spelled as the format spells it. A published jina-bert-v2 states the separator and the classifier and neither of the first two, and read for the first two alone it wrapped its text in nothing |
| `add_bos_token` / `add_eos_token` policy | Implemented |
| UTF-8-boundary-safe incremental decoding | Implemented |
| BPE merge tables | Implemented for six cutting rules, which the fifty names in the table above and an absent key name between them, in any script -- a letter is told from a symbol by its Unicode category, not by whether it is ASCII, and punctuation is told from symbol by it too, which is why a space stays on a currency sign and leaves a dash; a vocabulary naming another rule is refused by name |
| BPE byte-to-character mapping, both ways | Implemented; encoding rewrites each byte as the character that stands for it and decoding undoes that, which the suite checks by round trip |
| WordPiece folding and spelling | Implemented, and read by a second implementation written from this description rather than from the engine's code. The accents come off with the standard library's basic-character mapping and any combining mark left over is dropped, which is what a canonical decomposition followed by dropping the marks arrives at for Latin text; a syllable that decomposes into pieces which are not marks -- Hangul is the case -- stays whole here where a decomposing implementation would take it apart. What a round trip gives back is the folded text and not the caller's, which is a property of the vocabulary rather than of the decoder |
| Markers such as `<|im_start|>` or `</s>` written into the text | Implemented on both roads, and at any character a marker may begin with rather than only where the text opens a bracket. The longest piece the vocabulary calls a control or user-defined token wins, so a rendered chat template reaches the model as the tokens it meant. A template substitutes `bos_token` and `eos_token` as their spelling before anything is tokenized, which is why this matters on every templated turn. The rule used to be inside the byte-pair road alone, so a SentencePiece model read its own template's end marker as a run of bytes |

What the byte-pair cut carries is a rule per vocabulary rather than a general
engine for the expressions those pre-tokenizers are written as. Two limits
follow: the contractions are the seven the original names, matched as written
and so in lower case only, and on the two rules that cut punctuation out of
the text first they never match at all; and a run of line endings is a run of
whitespace rather than a run of its own. The suite settles that the engine
cuts as this says, and that a reader written independently from this
description agrees. What it cannot settle is the description -- that needs a
second runtime and a real vocabulary, which is what
`docs/reference-runtime.md` is about, and which is what corrected `starcoder`,
the absent key, falcon's space before a long run of digits, the contractions
on those two rules, and the space prefix on gemma2 and gemma3.

## Chat-template constructs

| Construct | State |
| --- | --- |
| Literal text | Implemented |
| `{{ terms }}` joined by `+` | Implemented |
| `{% for message in LIST %}` | Implemented, and the variable may be named anything. What the name decides is whether the loop binds: `message` is the name a turn's fields are read through and the name an assignment binds, so a loop calling its variable that binds each turn to it, and a loop calling it something else walks the same list and leaves the name alone -- which is what a template that walks the conversation backwards relies on, because it names its variable to be unused and says which turn it means with a `set` of its own. A field read off a name that is not `message` is refused where it is read rather than answered with the turn the loop happens to be on |
| `{% for name in range(a, b, c) %}` | Implemented, counting rather than walking a list, with a step that may count down -- which is how a template finds the last question asked, and which no list of messages can express. The three are term expressions; one argument means from zero, two mean a step of one |
| `{% if %}` / `{% elif %}` / `{% else %}` / `{% endif %}` | Implemented |
| `==`, `!=`, `and`, `or`, `not` | Implemented |
| `<`, `<=`, `>`, `>=` | Implemented, reading both sides as whole numbers. A side that is not one reads as zero rather than refusing: a template comparing a name it never assigned is asking about nothing |
| A bare operand as a condition | Implemented; the empty string, `none`, `false` and a name never assigned are false. A name the template never assigned is nothing when a condition asks about it -- `{% if tools %}` is written to find out whether there are any -- and an error when the output asks for it |
| `bos_token`, `eos_token`, `add_generation_prompt` | Implemented |
| `message['role']`, `message['content']`, dotted forms | Implemented |
| `messages[0]['role']` and its like | Implemented, relative to what `messages` names at that point, with the position written or worked out -- `messages[loop.index0 - 1].role` -- and the field named either way round |
| `{# comments #}` | Implemented |
| `{% set %}` | Implemented for a term expression, `none`, another name, a front slice such as `messages[1:]`, one message of a list such as `messages[index]`, `namespace(a=x, b=y)`, and a choice written on one line -- `A if C else B`, which compiles to what the block form compiles to because it is the block form said in one line. A template writes it where a turn may not carry the field it is after |
| `namespace()` and its fields | Implemented. A namespace exists in that language because a name assigned inside a loop does not outlive it; names here outlive everything already, so `ns.field` is a name like any other spelled with a dot -- and what tells it from `message.role`, which is spelled the same way and is not a name, is that `ns` was made a namespace |
| `-` between terms | Implemented, reading both sides as whole numbers. `+` runs text together, unless every term of the operand is a number by construction -- a bare number, a loop counter, a length -- and then it adds, which is the rule the language it is written in has and what `messages[loop.index0 + 1]` means. Two pieces of text joined with a `+` are still run together. A sum answers as a number wherever it stands: assigned, compared or printed, because a template that works a position out in a `set` and prints the same expression elsewhere means the same thing in both places |
| Brackets round part of a sum | Implemented, to `Max_Depth`, which is how a template counts back from the end of a conversation: `(messages\|length - 1) - loop.index0`. A group is spliced into the sum around it -- one joined by `-` has each of its own joins turned round, which is what taking a sum away comes to -- and brackets round a single value are that value, so what is written after them applies to it |
| `true`, `false`, `none`, decimal numbers | Implemented |
| `is defined`, `is none`, `is true`, `is false`, `is string`, `is not ...` | Implemented. Everything held here is text, so `is string` answers whether the name holds anything at all |
| `'x' in TEXT`, `'x' not in TEXT` | Implemented; whether the left side occurs in the right. The same word as the test below and a different question, told apart by what follows it |
| `.strip(S)`, `.lstrip(S)`, `.rstrip(S)`, `.split(S)[0]`, `.split(S)[-1]` | Implemented, and up to four of them may follow one another, each on what the one before it answered. That is how a template takes a reply apart at the marker its reasoning is in, and there is no reading such a reply back into a conversation without it |
| `TEXT[a:b]`, `TEXT[a:]`, `TEXT[:b]` | Implemented, either end optional, either counted from the end where it is negative and neither reaching further than the text goes. A template writes the pair of them to ask whether a turn begins and ends with the markers a tool's answer is wrapped in, which is a question about the two ends of a text and not about anything in it |
| `\| first`, `\| last` | Implemented on a cut, saying which end of it is wanted -- `.split(S)\|last` and `.split(S)[-1]` are the same question. Written after anything else they ask for one end of a list this engine has not got, and are refused. A cut that says neither end refuses where it is read rather than being given the end this engine could most easily answer with |
| `'field' in message` | Implemented; true for `role` and `content`, true for `tool_calls` on a turn that asked for one, and false for anything a message here cannot hold |
| Parenthesised conditions | Implemented, to `Max_Depth` |
| `\| trim`, `\| length` | Implemented |
| `loop.first`, `loop.last`, `loop.index`, `loop.index0` | Implemented |
| `{%- -%}` and `{{- -}}` whitespace control | Implemented |
| The line a block tag stands on | Implemented: the spaces and tabs between the start of a line and a `{% %}` or `{# #}` tag are taken off, and so is the line break that ends such a tag -- neither where something other than whitespace shares that line, and neither for `{{ }}`, which stands where its text is wanted. That is `trim_blocks` and `lstrip_blocks`, which the implementation these templates are written for turns on, so a template indented to be read reaches the model as the text it meant rather than with its own shape in it. `{%+` keeps the line its tag stands on, for a template that means the indentation |
| `{% for name in tools %}` | Implemented, walking the tools a caller offered. What it binds has no text of its own: it is written with `\| tojson` and refused anywhere else, and a loop inside it is refused, because there is one place to keep where a loop over the tools has got to |
| `{% for tool_call in message.tool_calls %}` | Implemented, walking the calls one turn asked for. The loop variable must be named `tool_call` for the reason the list loop's must be named `message`: what can be read from what it binds are a call's fields |
| `message.tool_calls`, `tool_call.name`, `tool_call.arguments` | Implemented. The first is a question and not text -- a condition asks whether the turn called anything, and the output may not print a list of calls -- and the other two are read from whichever call the loop has bound. A turn's calls are held beside its text rather than in it, so what the template writes is what that model was trained to read rather than what it happened to spell |
| `\| tojson` | Implemented for a tool, which is written as the definitions hold it, and for text, which becomes a JSON string. Anything else is a value this engine has no JSON for and is refused rather than given a spelling of this engine's choosing |
| `macro`, `include`, `import` | Rejected at compile time: `MR-TMPL-0002` |
| Other filters | Refused when evaluated: `MR-TMPL-0007` |
| Date formatting | Refused when evaluated: `MR-TMPL-0002`. Templates describe it in branches a conversation of plain messages never enters, so the refusal happens where the construct is used rather than where the template is read -- refusing a whole template for a branch nobody takes refuses the model |
| Function calls, `strftime_now`, `raise_exception`, arithmetic, indexing by anything but a number | Refused when evaluated: `MR-TMPL-0002` |
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
| Tail-free and locally typical filtering | Implemented, `--tail-free` and `--typical`. Both ask a different question from top-k and top-p: tail-free cuts where the sorted curve stops falling steeply, measured by its second differences, rather than at a cumulative share, and locally typical keeps the candidates whose surprise is closest to the distribution's own entropy |
| Exclude-top-choices | Implemented, `--xtc-probability` and `--xtc-threshold`. The opposite of every filter above: with that probability, every candidate over the threshold but the least probable of them is removed. A chance rather than a rule, so a sentence that needs its obvious word can still have it |
| Sequence repetition penalty | Implemented, `--dry-multiplier`, `--dry-base` and `--dry-allowed-length`. The repetition penalties above act on tokens; this acts on sequences, penalizing the next step along a path already walked, and the base is raised to the power of how far past the allowed length the repeat runs |
| Mirostat | Implemented for version two, `--mirostat 2` with `--mirostat-tau` and `--mirostat-eta`. It keeps the candidates whose surprise is under a running target and moves that target by how surprising the token it chose turned out to be. It replaces the truncation filters rather than joining them and is refused alongside any of them, because two answers to one question is not a configuration. Version one is refused by name rather than quietly treated as two |
| Per-token bias | Implemented, `--logit-bias TOKEN=X` |
| Reported probabilities | Implemented, `--logprobs N` reports what the model made of each position, from a plain softmax over the raw logits with none of the sampling applied |
| `version` reporting the build's reach | Tensor formats, backends and chat formats, listed from the code |
| Weights read where the file put them | Implemented: a model opened from a mapped file is not copied. The tensor section is the mapping's own pages, every view refers into it by address, and the pages are faulted in as they are touched -- so loading costs 0.065 s rather than 0.55 s on a one-gigabyte model, a resident set holds what was read rather than what was opened, and a model larger than memory runs. On Qwen3-30B-A3B twelve tokens from a cold cache take 15.84 s where loading alone took 38.684 s, and the resident peak is 4.6 GB against an arena of 11.25 GB, because a mixture routes to eight experts of a hundred and twenty-eight and never reads the rest. Mapped bytes are counted as mapped rather than as memory this program holds, and are not charged against `--memory-limit`, because a read-only mapping costs address space rather than pages. A source that cannot be mapped is read into an arena as before, and so is a model whose weights a device was asked to take: this driver will not import a file's pages, so `--device-memory 0` and mapping are exclusive and the caller's request wins. `--show-stats` says which of the two a run got. Nothing writes to a borrowed span -- merging an adapter requires the binary32 repacking, which is a copy of its own |
| Decoders compiled twice | Implemented: `Model_Runner.Quantization.Decoders` is a generic instantiated as `.Plain` and `.Wide`, one source and two compilations, the second built for `x86-64-v3` with floating-point contraction off so a decoded block is the same bits either way. Four formats are sent to it -- Q5_0 and Q5_1, whose fifth bit sits at a varying place in a thirty-two bit word, and IQ4_NL and IQ4_XS, whose nibble is an index into a table -- because a per-lane shift and a gather are what those two shapes want and baseline x86-64 has neither. They read 1.36, 1.02, 1.06 and 0.90 ns an element before and 0.63, 0.54, 0.57 and 0.50 after. The other eleven formats stay on the baseline compilation, where they are between seven and forty-two per cent faster than they would be built wide, and only the decode is compiled wide because the accumulation after it is shared by every format and is slower that way. Whether the host has the instructions is read from the host: `Model_Runner.Platform.Wide_Vectors` asks, the CPU backend asks it once at elaboration and tells the decoders, and the decoders never ask -- they interpret what a model file holds and a unit that does that may not reach a host. A host that says no, or that cannot be asked, runs every format on the baseline as before. A test decodes eight formats both ways and requires the same bits |
| Built-in chat formats | `llama3`, `chatml`, `gemma`, `phi3` and `qwen3-coder`, selected with `--chat-template` and named from the same enumeration the help and the matching read; a name this build does not carry is refused by name. Nothing is chosen on a model's behalf. They are ordinary templates written in the subset rather than a second mechanism, and each is set beside Python's jinja2 reading its own source: forty-eight conversations apiece, every byte agreeing. `qwen3-coder` is the one carried because the model's own template will not compile rather than because the model ships none -- it opens with a macro -- and it is the same bytes as that template for every conversation without tools in it, checked against it across thirty-two. What it does not carry is that template's tool half, which writes a tool's parameters and a call's arguments one element per pair of a mapping: nothing here walks a mapping. Offering tools to it is refused before a prompt is built, and a turn carrying calls is refused where the call would have been written rather than rendered as a turn that said nothing |
| Fixed 64-bit seed and entropy-chosen seed reporting | Implemented |
| Forbidden-token masking | Implemented |

## Generation

| Feature | State |
| --- | --- |
| Speculative decoding | Implemented: `--draft-model PATH` loads a second, smaller model to propose `--draft-tokens` continuations, which the real model checks in one pass. Only at temperature zero and without a grammar -- both refused rather than ignored, because keeping the guarantee that the text is what the model would have said alone needs an acceptance test against the sampler's own distribution, which this has not got. `--draft-tokens` without a draft model is a note rather than a refusal: nothing was loaded, so nothing was wasted |
| Pooling | Implemented, `--pooling mean|last|cls`. Where the caller names none and the file states one -- which a bert file does, in `<arch>.pooling_type`, and a decoder does not -- the model's own is used; where neither says, the mean. A model stating ranked pooling is refused by name: that names a scoring head this program has not got rather than a way of reducing a text to a vector |
| A text read whole | Implemented as a refusal, `MR-ARCH-0017`. A model that attends both ways reads a whole text in one call, into an empty cache. A second batch would attend to what is already there and be invisible to it, so the first half would have been computed without the second -- and what comes back from that is an embedding, plausible in every respect, of a text the model never read whole. `--batch-size` has nothing to say about such a model: the batch is the text and the bound is the context |
| Generation from a model with no head | Refused by name, `MR-ARCH-0016`, where a distribution is asked for -- at the command, before a session and a cache are built, and again in the library for a caller who reaches past it. A row of zeros and the embedding table read backwards are both answers, and neither is the model's |
| Rolling context | Implemented: `--context-shift N` drops the oldest N positions when the context fills and slides the rest down, `--context-keep N` leaves that many at the front in place. The keys move with the text -- each moved key is turned back by the angle those N positions stand for -- and a drafted run shifts both contexts together. What stays was computed while the dropped tokens were still there, so a rolling context is an approximation of the same text read afresh rather than an equivalent. Without the option a run that fills its context ends there |

## Backend

Three, selected with `--backend`. The rows below say which of them each
capability belongs to, because most of them belong to one: a worker pool and
a partition are what `cpu` has and what `reference` deliberately has not.

| Backend | State |
| --- | --- |
| `cpu` | Worker pool, partitioned rows, batched prefill, span decoding. The default |
| `reference` | One row at a time, decoded whole, multiplied element by element, summed wide, on the calling task. No pool, no partition, no batching. Produces the same logits as `cpu` and takes about twelve times as long, measured; it exists so that a suspicious result on a caller's own model can be asked again by different code |
| `device` | The products and the attention run on a compute device, reached through the host's Vulkan loader and shaders compiled into the binary. The product shader decodes every one of the fifteen formats this program reads from the bytes the file holds, so no model needs repacking to reach a device. It carries eight vectors per invocation, so a prompt is one reading of the weights rather than one a token. Attention is computed there as well, on both evaluation paths: the cache is reserved on the device and written a position at a time, so a call sends that position's queries and receives its blend rather than the whole history, and a batch of positions attends in one call rather than one call each. A layer's attention and the projection that reads its blend are recorded into one command buffer, so the blend never comes back only to be sent again -- a call costs 82.7 microseconds before it computes anything, and a generating run was paying that twice a layer. What is still computed here is the rotation of the queries and the keys and values written into that cache; what reads them is not. Every matrix is uploaded once and stays there, up to three quarters of the largest heap the device reports; past that the one wanted longest ago is given back and uploaded again when it is next needed, and a model larger than that share is refused as it loads rather than discovered a token at a time. A run reports the device, the matrices on it, the bytes they take, how many were read where they lie and how many were given back. `--device-memory SIZE` names the share; naming it also runs a model larger than the number rather than refusing it, and `--device-memory 0` reads the weights where they already are -- the device is handed a pointer into this process's memory, which holds the model once instead of twice and runs at a fourteenth of the rate. No pool. Produces the same text as `cpu` on the models measured, and measured faster than the pool on this machine; the arithmetic differs where binary32 accumulation differs from binary64. One matrix reaches the shader as one buffer, so a product is bounded by what the device says a storage buffer may hold -- 4 GiB on the part measured here, 128 MiB on the software renderer beside it -- and a product past that is refused naming both numbers rather than run. That bound used to be a number chosen here, 268 million elements, described as smaller than any device's own and smaller than several: it refused every model whose output projection is wider, which is Falcon-7B, every Qwen3 above the smallest and every published mixture, and it refused them as a missing capability. A machine with no device is refused by name rather than quietly given another backend |

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
| Noncontiguous views | all three | Not implemented |
| Repacking | all three | Implemented, `--repack f32|bf16`: every weight matrix decoded once at load. `f32` is exact and holds the logits to the bit; `bf16` rounds to eight mantissa bits and is faster, seven to thirty-eight per cent depending on the format it replaces, at two bytes a weight. A matrix already in the target format is left alone and the file's own bytes are released when nothing points at them. Decoded by as many tasks as the run has workers |
| Key-value cache precision | `--kv-cache f32` (the default) stores what a session commits as the engine computes it; `--kv-cache f16` stores it as binary16, halving the context's memory; `--kv-cache q8` stores it as one byte an element with a scale for each row -- a row being one position's keys, or its values, for one layer -- which is a quarter of it. Lossy and measured: 0.0327 worst absolute against the independent implementation over the conformance sweep -- 0.0218 without a sliding window and more with one -- where the exact cache reads 2.1e-05. The cache is the larger half of a session at a long context, and it is the one part of it that grows with the context | `inspect --kv-cache MODE` reports what a session would take in each: on TinyLlama-1.1B-Chat Q8_0 at 2048 tokens, 97,251,904 bytes exact, 48,807,695 halved and 24,585,588 in bytes. The byte storage is measured at 0.303 worst absolute over the sweep against 0.0092 for the halved one, and it is the only storage here whose output differs from the exact one on a real model at twelve tokens. Not implemented: a precision below eight bits, and rounding keys differently from values though attention reads them differently
| Replaced-file detection | The file is asked whether it changed before its tensors are read; a size that differs from the one validated is refused with `MR-GGUF-0002`. An in-place edit of the same length is not detected |
| Memory accounting | Every category is charged: weights, converted weights, KV cache, activations, logits, sampling workspace, token buffers, template buffers, metadata and vocabulary storage. `--memory-limit` bounds the model and the session |
| Capability checking | Every field of the backend's `Capabilities` is asked by something: the formats and the alignment per tensor while a model loads, matrix-vector once when it is prepared, batching when a batch is evaluated, and the worker count when the pool is sized. The `reference` backend declines two of them outright, which is what made the machinery answer for itself; disclaiming any of the others refuses, naming the capability. Five fields that could only ever hold one value were removed rather than wired |
| Device discovery | Implemented: the host's Vulkan loader is opened by name when first asked for, and `version` reports the devices it names and whether each has its own memory. A host with no loader, no driver or no device reports none and nothing else changes. A device can also be opened -- a queue that accepts compute, and the memory kinds an upload goes through, preferring one both the processor and the device reach -- and computes matrix-vector products and attention from shaders compiled into the binary, decoding every format this program reads itself and carrying eight vectors of a batch per invocation. Checked against the processor: agreement to under a ten-millionth over 128 terms, which is what binary32 accumulation carries against binary64. It is the backend `--backend device` selects |
| Backend selection | `--backend NAME`, matched against the backends this build has and refused by name otherwise: `cpu`, `reference` and `device` |
| Saved contexts | Implemented: `--save-session PATH` writes what a session has committed and `--load-session PATH` fills a session from one before the prompt is read, after which the generation reuses whatever prefix the prompt agrees with. Committed positions only, not the capacity. The bytes name the model, the cache shape, the context capacity and the precision, and any mismatch is refused; the model is identified by its validated shape plus the size and a sample of its tensor data, which identifies a file rather than verifying one. The engine produces and consumes bytes -- the file is the caller's, because units that interpret what a model says may not reach the filesystem |
| Low-rank adapters | Implemented: `--lora PATH` merges the pair of matrices an adapter carries into the weights, scaled by the file's own alpha and by `--lora-scale`. Merged rather than carried alongside, so evaluation costs what it did before. Requires binary32 weights, which naming an adapter selects; brain floats beside one are refused. Adapters on the seven attention and feed-forward projections are merged; half a pair, or a pair naming a weight this profile does not adapt, is refused by name |
| Output grammars | Implemented in GBNF: rules, alternatives, sequences, literals with escapes, code-point sets and their complement, grouping, `?` `*` `+`, `{n}` `{n,}` `{n,m}`, and comments. One rule must be `root`. Every token whose text cannot continue the grammar leaves the distribution before sampling; the end token is masked until the grammar may end, and a token contributing no text is masked throughout. Anything outside the notation is refused where it is met, with its position. Rules, elements, ranges, nesting depth and simultaneous parses are all bounded and each bound refuses rather than allocates |
| `embed` | Implemented: prints the hidden state of a text, pooled over its positions with `--pooling mean`, `--pooling last` or `--pooling cls`, at unit length unless `--no-normalize`. One component a line. The prompt is read as written; no chat template is applied and none would be right -- though a model that reads whole texts gets the end marker its file asks for, because it was trained with one at each end and its states are what they are because of them. Evaluated in batches, as a prompt is, with every position's state asked of the batched path. `--batch-size` sets how many go through the weights at once and does not change the answer for a model that generates; for one that attends both ways the batch is the whole text and the option has nothing to say |
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
