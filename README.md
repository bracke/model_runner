# model_runner

Local GGUF language-model execution in Ada 2022.

`model_runner` loads a local GGUF model file, validates its container strictly,
prepares a bounded Llama-compatible decoder-only execution plan, tokenizes
prompts, evaluates the model on the CPU, maintains an explicit KV cache, samples
output tokens, decodes them incrementally and streams the generated text.

Inference is local only: no network access, no daemon, no Ollama, no llama.cpp,
no delegation to an external model runtime.

## Status

The engine and the command-line program work end to end. A list of what is
**not** implemented is at the bottom of this file; nothing here claims a
capability it does not have.

```
$ model_runner inspect tiny-model.gguf --threads 4
Container
  path                    tiny-model.gguf
  file size               7648
  GGUF version            3
  data alignment          32
  metadata entries        21
  tensors                 21
  parameters              1256
  tensor formats          F32
  memory mapped           yes
Architecture
  name                    tiny
  architecture            llama
  context length          16
  embedding width         8
  ...
Tokenizer
  tokenizer model         llama
  vocabulary              16
  byte fallback           no
  beginning token         1
  end token               2
  chat template           present and supported
Memory
  model weights           5024
  session at this context 5880
Execution
  backend                 cpu
  worker tasks            4

$ model_runner run tiny-model.gguf --raw --prompt "ab" --seed 42 --temperature 0 --max-tokens 6
 bcaaaa
```

## Commands

```
model_runner run MODEL       generate text from a model file
model_runner embed MODEL     reduce a text to one vector
model_runner inspect MODEL   report what a model file contains
model_runner help [COMMAND]  show help for a command
model_runner version         show version information
```

The model path is explicit. No registry, short name, tag or manifest is
resolved.

Run `model_runner help run` for the full option list. Options are validated
with the same typed path as environment variables, repeated options are a usage
error, and `--` ends option processing.

### Saving a context

Reading a prompt costs what it costs: on this machine prefill runs at about
27 tokens a second, so a thousand-token document is more than half a minute
before the model says anything. Its cache is tens of megabytes. Saving that
and handing it back is the difference between waiting for the model to
re-read a document every time and not.

```
model_runner run MODEL --raw --prompt-file document.txt --max-tokens 0 \
  --save-session document.ctx
model_runner run MODEL --raw --prompt-file question.txt \
  --load-session document.ctx
```

Only the committed positions are written, not the capacity. What is loaded
fills the cache before the prompt is looked at, and the generation keeps
whatever of it the new prompt agrees with and re-reads only the rest -- so a
saved context is worth having when the next prompt extends it, and costs
nothing but a refusal to read the file when it does not.

The file names the model it belongs to, the shape of the cache, the context
capacity and the precision it is held in, and any mismatch is refused rather
than read: one model's attention is not another's. The identifier is the
model's validated shape together with the size of its tensor data, a sample
of its bytes, and a digest of any adapter merged into it -- that identifies a
model file and is not meant to verify one.

The adapter belongs in that identifier because merging one replaces the
weights: a context computed before a merge describes attention the merged
model never had, and nothing about the text that came back would look
wrong. The two were indistinguishable until a test asked, and the test only
asked usefully once it was written against a quantized model -- with
binary32 weights the merge writes into the file's own bytes, which the
identifier already samples, so it appeared to be handled when it was not.

A saved context is untrusted input, and every field of it is range checked.
What cannot be checked is whether the contents mean anything: bytes that
match are read, and what they say the model was thinking is what the model
will think. Loading a file is trusting whoever wrote it with the
conversation.

### Adapters


`--lora` is repeatable and the adapters stack, in the order given: a merge
adds a difference to the weights, so a second one lands on top of the first
rather than replacing it. `--lora-scale` pairs with them positionally -- the
Nth scale belongs to the Nth adapter, and an adapter named without one is the
adapter as it was trained.

A scale of minus one subtracts, which is how an adapter comes off again:
naming the same file twice at plus one and minus one leaves the weights where
they started, to within what binary32 rounding does to a number added and
taken away. Both claims are held by a test that measures how far the logits
move -- a second merge moves them about as far again as the first, and plus
one followed by minus one puts them back within a hundredth of that
distance.

`--lora PATH` merges a low-rank adapter into the weights before anything is
generated. An adapter says what a fine-tune changed, as a pair of small
matrices per weight it touches whose product is the difference; merging adds
that difference, so evaluation afterwards costs exactly what it cost before
and the adapter's own storage goes when its file is closed.

```
model_runner run MODEL --lora adapter.gguf --lora-scale 0.8 --prompt "..."
```

Only binary32 weights can be added to, so naming an adapter selects
`--repack f32` where none was named -- four bytes a weight, the same bargain
that flag already publishes. `--repack bf16` beside an adapter is a usage
error rather than a quiet rounding of every merged weight.

**What merging costs.** It is rank times every weight it touches, once at
load. Measured on this machine: **0.27 ns** an update at rank sixteen, and
4.4 ns at rank one -- the difference is that a rank-one merge reads and
writes each weight for a single update where a rank-sixteen merge amortizes
that over sixteen. TinyLlama-1.1B has about 968 million adaptable weights,
so a rank-sixteen adapter is 15.5 billion updates: **about four seconds**.
`tests benchmark` reports both ranks, because reporting only rank one would
have made a four-second merge look like a minute.

The scale multiplies the difference over and above the adapter's own alpha,
so `1.0` is the fine-tune as trained and `0` is the model without it.
Adapters for `attn_q`, `attn_k`, `attn_v`, `attn_output`, `ffn_gate`,
`ffn_up` and `ffn_down` are merged; a pair naming anything else is refused,
as is half a pair, because half a difference is not a smaller difference.

### Constrained output


`--json-schema TEXT` and `--json-schema-file PATH` take a JSON schema and
turn it into a grammar before anything is generated, so a caller with a
schema does not have to hand-write GBNF and then keep the two in step. It
reads `type`, `properties` with `required`, `items`, `enum` and `const`, and
refuses every other keyword by name rather than ignoring it -- a keyword
ignored produces a grammar that allows more than the schema does, which is a
constraint that quietly is not one.

A property the schema does not require may be absent; one it requires may
not. A schema that names no `required` list requires everything it names,
which is not what JSON Schema says -- there, absent means optional -- and is
the narrow direction this errs in throughout. The first property named must
be one the schema requires: a first property that may be absent makes the
comma before the second conditional on it, and expressing that needs an
alternative for every place the object might start.

Objects come out closed and ordered: exactly the properties named, in the
order named. JSON leaves member order free and a grammar that allowed every
order would grow as the factorial of the property count, so what this
produces is narrower than the schema. Everything it accepts the schema
accepts, and not the reverse; that is the honest direction for a constraint
to err in and it is written where a reader will meet it.

`tests schema SCHEMA` prints the grammar a schema becomes, which is how the
output gets read without running a model.

```
$ model_runner run MODEL --raw --prompt "Describe Paris: " --max-tokens 24 \
    --temperature 0 --json-schema '{"type":"object","properties":{
      "city":{"type":"string"},"population":{"type":"integer"},
      "capital":{"type":"boolean"}}}'
{"city":"Paris","population":100000,"capital":true}
```

`--grammar` holds the generated text to a grammar. At each step every token
whose text cannot continue the grammar is removed from the distribution
before anything is sampled, so what comes out is text the grammar accepts --
not text the model was asked nicely to produce.

```
model_runner run MODEL --raw --prompt "list three colours" \
  --grammar 'root ::= "[" item ("," item){0,4} "]"
             item ::= "\"" [a-z]+ "\""'
```

`--grammar-file` reads it from a file instead; naming both is a usage error.
The notation is GBNF: rules with `::=`, alternatives with `|`, sequences,
`"literals"` with the usual escapes, `[a-z]` and `[^a-z]` sets, `( )`
grouping, `?` `*` `+` and `{n}` `{n,}` `{n,m}` repetition, and `#` comments.
One rule must be called `root`. Sets and literals match code points, not
bytes, so `[a-ø]` means what it says whatever the tokenizer does underneath.

Anything outside that notation is refused where it is met, with the position
in the grammar: there is no construct the parser recognizes and then
declines, so there is no separate diagnostic for one. Every bound -- rules,
elements, ranges, nesting, and how many ways the grammar may be in the middle
of at once -- is a refusal rather than an allocation, because a grammar comes
from a command line or a file and is therefore untrusted.

The end-of-sequence token is masked until the grammar may end, so a run
cannot stop half way through what it was told to produce. A token that
contributes no text at all is masked throughout: it cannot advance a grammar,
and allowing it would let a run produce it forever while the grammar stayed
where it was. If a step leaves nothing at all -- a grammar this model's
vocabulary cannot spell -- the run stops and says so, rather than leaving the
sampler with an empty distribution and reporting that instead.

In a conversation the grammar applies to each reply, and starts again for
each: what a grammar describes is an answer, not a whole conversation.

**What sampling costs.** It runs once per token and over as many candidates
as the model has tokens, which every fixture here has sixteen of. Measured
over 32,000: **0.062 ms** greedy, and **0.18 ms** with top-k 40, top-p 0.95,
min-p 0.05 and a repetition penalty. Against about 85 ms for a token of
TinyLlama-1.1B that is a fifth of a per cent.

It was 2.86 ms -- fifteen times that -- because a top-k of forty was reached
by sorting all thirty-two thousand candidates. A small top-k is now selected
rather than sorted: the order candidates are ranked by is total, the logit
and then the token, so any correct way of taking the first k of it takes the
same k in the same places. A large top-k is still sorted, because keeping k
in order as you go costs more per candidate than sorting does once k is big
enough; where the two cross is a judgement and it is written where it is
made. Both figures come from `tests benchmark`.

**What it costs.** The filter runs over the whole vocabulary at every step,
so it is worth a figure rather than an assurance. Measured on a stand-in
vocabulary of 32,000 short pieces, one token filtered takes **10 ns** where
the grammar allows one character next and **116 ns** inside a run of letters,
where most tokens survive their first character and are matched to the end.
Over 32,000 tokens that is 0.3 ms and 3.7 ms a step, against about 85 ms for
a token of TinyLlama-1.1B: four per cent at worst.

The first version cost 7.4 microseconds a token -- 0.24 s a step, several
times the forward pass -- and the whole difference was copying. A matcher
holds 256 stacks of 64 positions, and both stepping and testing a token were
clearing or copying all of it whether or not it was in use. Now the count
bounds what is copied, nothing is cleared that will not be read, and a token
whose first character no live stack accepts is refused before anything is
copied at all. `tests benchmark` reports both figures.

### Embedding

`embed` prints what the model made of a text rather than what it would say
next: the hidden state after the final normalization, before the projection
that turns a state into a distribution over tokens. That projection is where
the resemblance between two texts is thrown away -- it keeps only how much
each token is favoured -- which is why the state is what an embedding is
pooled from.

```
model_runner embed MODEL --prompt "the text" --pooling mean
```

One component a line, so the usual tools can read it. `--pooling mean`
averages every position and `--pooling last` takes the final one; neither is
chosen on a model's behalf, because which is right depends on how the model
was trained. The vector is scaled to unit length unless `--no-normalize`,
since the usual thing to do with two of them is compare their directions and
that is a dot product only when both have length one.

The prompt is read as written and no chat template is applied. A template
turns a text into a turn of a conversation, and an embedding is of the text.

The text is evaluated in batches, as a prompt is: a matrix product over
thirty-two vectors moves 1.87 times the elements a second that one at a time
does on this machine, and a text to be embedded is exactly that shape.
Pooling needs every position's state, so the batched path is asked for them
-- it is the only one that has them all in hand at once. `--batch-size` sets
how many go through the weights together and does not change the answer.

### Streams

| Content | Destination |
| --- | --- |
| generated model text | standard output, byte for byte |
| help, version | standard output |
| the `inspect` report, including `--metadata` and `--tensors` | standard output |
| diagnostics, warnings, progress, statistics | standard error |
| interactive prompts and command responses | standard error |

So `model_runner run m.gguf --prompt-file p.txt > answer.txt` puts only
generated text in `answer.txt` — no trailing newline, no styling, no prefix.

### Environment

| Variable | Meaning |
| --- | --- |
| `MODEL_RUNNER_LOCALE` | locale for program messages (`en`, `da`, `qps`) |
| `MODEL_RUNNER_COLOR` | `always` or `never` |
| `NO_COLOR` | suppresses automatic styling |
| `LC_ALL` | locale, when `MODEL_RUNNER_LOCALE` is unset |
| `LANG` | locale, when neither of the above is set |

Prompts are never taken from the environment. This table is the whole of what
the program reads: the release checklist fails on a variable read but not
listed here, and on a read from anywhere but the two files that are allowed
one. Both locale variables were read and unlisted until that check was written.

### Exit statuses

`0` success · `2` usage error · `3` model format error · `4` unsupported model
feature · `5` resource failure · `6` input or output failure · `7` cancelled ·
`8` internal failure.

Every diagnostic carries a stable public code such as `MR-GGUF-0023`, derived
mechanically from the error enumeration so a code and its message cannot drift.
`docs/error-codes.md` marks each code raised or reserved: a published ordinal is
never reused, so codes that nothing raises stay listed, and saying which is which
keeps the reference from promising diagnostics the program cannot emit.

## Implemented

| Area | What exists |
| --- | --- |
| GGUF container | Full structural parse and validation of versions 2 and 3; typed metadata accessors separating missing / mistyped / out-of-range keys |
| Untrusted-input defence | Checked arithmetic on every offset, count and size; explicit limits on every count a file controls; UTF-8 validation; tensor range, alignment and non-overlap checks; trailing-data policy |
| Byte sources | Random-access interface; in-memory, file-backed, and POSIX read-only `mmap` with automatic / required / disabled policy and safe fallback |
| Tensors | Read-only views with one documented dimension convention, block-boundary checks, row dot product, row dequantization, row-range matrix-vector |
| Quantization | Reference decoders for F32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q2_K, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL, IQ4_XS — decoded one block at a time, never a second full copy of the model. The two non-linear formats read a nibble as an index into a table of sixteen levels that belongs to the format rather than to any file. Q8_1 and Q8_K are refused: they are intermediates a reference implementation quantizes activations into, not formats weights are stored in |
| Kernels | Scalar reference add, multiply, scale, dot, RMS normalization, softmax, SiLU, rotary encoding, with `Wide_Real` accumulation for length-dependent reductions |
| Tokenizer | SentencePiece (`llama`) vocabulary: scores, token types, special tokens, byte fallback, greedy highest-score merge encoding. Byte-pair (`gpt2`) vocabulary: merge tables by rank, byte-level stand-in alphabet, and six cutting rules named by `tokenizer.ggml.pre`, a vocabulary naming any other being refused by name rather than cut by the wrong one. Both with UTF-8-boundary-safe incremental decoding. A special-token identifier that is absent leaves the token unset; one that names no token refuses the model rather than being ignored |
| Chat templates | Bounded allowlisted engine: `for`, `if`/`elif`/`else`, `set`, comments, `+`-joined output, `==`/`!=`/`and`/`or`/`not` with parentheses, `is defined`/`is none`/`in`, `trim` and `length`, message indexing, front slicing such as `messages[1:]`, `loop.first`/`last`/`index`, whitespace control. Enough that the template a current Llama-3 file ships with renders. Compiled and validated at load time; `macro`, `include` and `import` are rejected there, while a value the engine cannot compute -- a function call, `tojson`, arithmetic -- is refused if the render reaches it, which the tool-calling branches of a plain conversation never do |
| Architecture profile | `llama`, `qwen2`, `qwen3` and `qwen3moe`, each read under its own metadata keys and refused by name otherwise, with the refusal naming every one this build reads. All are the same shape with a difference: qwen2 a bias on each attention projection -- required, not optional -- and the split rotary pairing, element *i* against element *i + rotary/2* rather than against its neighbour; qwen3 no biases and a root-mean-square normalization of every query and key head before the rotation, equally required; qwen3moe that again with the feed-forward block behind a router. Metadata validation in which an absent optional key takes a default and a present-but-unusable one refuses the model, derived-width divisibility, separate key and value head widths read from the file when it states them, rejection of rotary scaling this does not compute, tensor resolution and shape validation, tied-output aliasing. Sliding-window attention is read and applied: each position attends to the window's worth of positions ending at itself, uniformly across layers. A mixture of experts is read and applied: a router a layer, the highest few experts run for each position and summed in proportion to their shares. Rotary scaling is read and applied for `none`, `linear` and `yarn`, together with a `rope_freqs.weight` table of per-dimension divisors when the file carries one |
| Execution | Embedding lookup, per-layer RMS norm, Q/K/V projection, rotary encoding, grouped-query causal attention without duplicating key or value heads, output projection, SiLU-gated feed-forward, residuals, raw logits |
| KV cache and session | Explicit cache sized with checked arithmetic, transactional commit, state machine, reset preserving allocations, committed-prefix reuse. Any number of sessions may be open on one prepared model at once: a model carries no per-evaluation state -- the activations, the normalized copies and the query and key rows all belong to the session -- so a second sequence costs its own cache and nothing else. Held by a test that interleaves two sessions a token at a time and checks each gets what it would have got alone; interleaved rather than sequential, because sequential sessions pass even on a model that does hold such state. Anything that would write to the model is refused while a session is open. `--prompt` asks for several: the model is read once and answers each in turn, which is what the sessions buy |
| Sampling | Documented pipeline: vocabulary check, non-finite rejection, masks, per-token biases, sequence penalty, repetition penalty, frequency and presence penalties, temperature, top-k, tail-free, locally typical, top-p, min-p, exclude-top-choices, renormalize, select. Everything that acts on a token acts on the greedy path too, which is where a caller can check by hand what a penalty did -- they did not, for as long as they have existed. Mirostat v2 replaces the truncation filters rather than joining them and is refused alongside any of them, because two answers to one question is not a configuration. Greedy is tie-broken to the lowest token and consumes no random state; xoshiro256++ seeded per session. `--logit-bias TOKEN=X` nudges a token; `--logprobs N` reports what the model made of each position, from a plain softmax over the raw logits with none of the sampling applied |
| Stops | End-of-sequence, stop tokens, stop strings matched across token boundaries with earliest-then-longest resolution and no leaked bytes |
| Generation | Prefill, decode loop, streaming to an output sink, eight completion reasons, statistics against a monotonic clock, bounded text retention |
| Conversation | Structured roles, bounded history, system-message replacement, turn rollback |
| CLI | `run`, `embed`, `inspect`, `help`, `version`; typed command parsing separated from execution; end-of-options; repeated, conflicting and out-of-range option detection. `--prompt` is repeatable: several prompts are several sequences from one loaded model, each with its own context and its own statistics, and standard error says which is which so that standard output stays nothing but generated text. It is refused together with a saved or restored context, which names one conversation |
| Interactive | Committed structured history, template rendering per turn, prefix verification against the cache, `/exit` `/reset` `/help` `/settings` `/stats` `/context` `/system [TEXT]`, the last removing the system message when no text follows it, blank-line submission, no history written to disk. Needs a terminal on both standard input and standard output, whether it is chosen because no prompt was given or asked for with `--interactive` |
| Localization | Every application-authored string through `messages`; 162 diagnostic codes each with a catalog entry; every catalog key has a reader and every key the code names has an entry, checked both ways; English, a partial Danish translation that inherits per key, and a generated pseudo-locale; locale precedence with an emergency path that cannot recurse |
| Cancellation | An interrupt requests a clean cancellation rather than killing the process; observed between parser sections, tensors, layers and tokens, so a cancelled run releases everything and commits no cache position. The parser, preparation, the single-token pass and the batched pass are each held by a test; generation's own two checks stop the work a batch or a token earlier than the pass below would, which no test of the outcome can distinguish |
| Presentation | `terminal_styles` in the presentation layer only; styling asks whether the stream a line is going to is a terminal, so redirecting one stream and not the other never puts escape sequences in the file — which it did, once the inspection report moved to standard output and the colour decision stayed on standard error; severity always carried by a word as well as a colour; `--color always` colours whatever the destination is, `auto` colours only a stream that is a terminal and honours `NO_COLOR`, and `never` colours nothing; generated text never styled |
| Backends | Three, selected with `--backend`. `cpu`: an Ada worker pool with a protected coordinator, reusable worker tasks, deterministic row partitioning, a single-job bounded queue, worker-failure propagation and clean shutdown; `--threads` selects the count and the result is bit-identical whatever it is. `reference`: one row at a time on the calling task, no pool and no batching, the same logits and about twelve times as long -- see below for the measurement -- for asking a suspicious result again by different code. `device`: the products run on a compute device, reached through the host's Vulkan loader opened by name at the moment it is asked for, from a shader compiled into the binary. The shader decodes every one of the fifteen formats this program reads, from the bytes the file holds, and takes a batch of eight vectors per invocation, so no model needs repacking to reach a device and a prompt is one reading of the weights rather than one a token. Each matrix is uploaded once and stays on the device. Measured faster than the pool on this machine, at the same generated text. A machine with no device is told so rather than quietly given another backend |
| Tooling | `tests test`, `tests check`, `tests conformance`, `tests fuzz`, `tests speed`, `tests benchmark`, `tests external-model`, `tests tokenize`, `tests docs`, `tests shader`, `tests schema`, `tests fixtures`, `tests package`, `tests pristine` — all Ada, all in the tests crate, and the set is a registry the checklist holds the dispatch and this row against, because two hand-kept copies of it had already drifted apart. `tests <command>` with no command lists them with what each takes. `tests check` is the gate: it runs the suite, the repository checks, the conformance comparison and a short fuzzing campaign, and fails when a test is written and registered by nothing or when the suite has shrunk. The public operations the program itself never calls are listed in `Library_Surface` with the reason for each, and the list is held in both directions: this is a library as well as a command, so the interface is wider than the command uses, and how much wider is a thing somebody chose rather than a thing that happened. The separate commands are for looking closer |
| Conformance | An independent reference transformer in the tests crate recomputes the forward pass in a different arithmetic, with its own float decoding, its own full key/value history and expanded rather than mapped attention heads. It implements both architectures, each with its own rotary pairing and its own attention bias, so the two agree by arriving at the same numbers rather than by sharing the code that produces them. The engine agrees to within 1.3e-6 absolute on the fixtures, against tolerances of 1e-4 absolute and 1e-3 relative, and `tests check` runs the comparison rather than leaving it to be remembered |

## Building and testing

Needs [Alire](https://alire.ada.dev) and a GNAT toolchain.

`model_runner` depends on sibling crates that are not in the Alire community
index. As the rest of this family does, `alire.toml` pins them **by path**, so
they have to sit beside this one:

```
Ada/
├── model_runner/       <- this crate
├── terminal_styles/    pinned here
├── messages/           pinned here
└── project_tools/      pinned by the tests crate
```

Those pins are transitive, and the closure is deeper than it looks: `messages`
pins `i18n`, and sub-crates inside `i18n` and `awklib` pin further crates
again. A bare clone of this repository alone will not build -- `alr` reports
that a pin path is not a valid directory and names the crate it wanted, one at
a time.

The reliable way to materialise the closure is the composite action this family
uses in CI, which walks the pins for you:

```yaml
- uses: bracke/project_tools/.github/actions/checkout-ada-siblings@main
  with:
    root: model_runner
```

By hand, clone each crate `alr` asks for into the same parent directory until
it stops asking, then:

```
cd model_runner
alr update                                 # regenerates config/ with the
                                           # dependency withs; a fresh clone
                                           # needs this before it will compile
alr build --release
cd tests && alr build && ./bin/tests test
```

I have not reduced that to a single verified command line for a reader
starting from nothing, and would rather say so than print one that does not
work. From a tree that already has the siblings, `tests pristine` is that
command: it clones what git carries beside them -- so every path pin resolves
without copying or linking -- resolves the pins, builds, and runs the suite
and the repository checks in the clone, in about twenty seconds. It removes
the clone when it passes and leaves it where it says when it does not.

That is the only arrangement in which the repository is what a reader gets,
and it is the arrangement in which the suite failed for forty consecutive
pushes while passing here. Run it before a release. It is not part of the
release checklist, because it clones from git and therefore sees only what is
committed -- a checklist run before the commit would be answering about the
previous one.

Two things are generated rather than committed, so a clone does not have them
until something makes them:

- **`config/`** holds the configuration project that Alire writes, and both
  project files import it. `alr build` creates it. Calling `gprbuild` directly
  in a fresh clone fails with `imported project file "config/..." not found`,
  which is what that means.
- **`tests/fixtures/tiny-model.gguf`** is written by `tests fixtures`, and by
  the suite itself: three tests read a model from that path and write it
  first, through one operation that also names it. This paragraph used to say
  the suite did not need it -- that it built the same model in memory -- and
  that was the belief behind forty consecutive red CI runs. The file is
  ignored by git, because a model file is not committed unless its licence
  plainly allows it; it was present on the machine where the suite was run
  and on no clean checkout, so the suite passed here and failed there with
  `inspect does not print the published line "Container"`.

Development is the default profile here and in every sibling crate, on
purpose: `-Og` with the full validity checks, one profile across every root so
they share object files. Release is for a release -- and for anything you
intend to measure, because the difference is not small: twelve tokens on a 1.1B
model take 2.2 seconds at `--release` and around 14 at the default.

```
alr build --release                        # optimized, what to ship and measure
alr build                                  # debug: -Og, all validity checks
cd tests && ./bin/tests test               # the whole suite
cd tests && ./bin/tests check              # the gate: the suite, repository
                                           # checks, conformance, a fuzz run
cd tests && ./bin/tests conformance        # engine vs independent reference
cd tests && ./bin/tests benchmark          # row kernels and parsing, synthetic
cd tests && ./bin/tests benchmark --wait 30 # the same, once the machine is quiet
cd tests && ./bin/tests docs               # regenerate docs/error-codes.md
cd tests && ./bin/tests shader ../src/shaders/row_product.comp out.spv
                                           # after recompiling a shader
cd tests && ./bin/tests fuzz --seed 1 --cases 2000
cd tests && ./bin/tests fixtures           # write tests/fixtures/tiny-model.gguf
cd tests && ./bin/tests package .. .       # write model_runner-<version>.tar
cd tests && ./bin/tests external-model --model /path/to/your.gguf [--expect FILE]
```

The suite takes a second and a half. It took half a minute until compiling a
template stopped allocating twenty-six megabytes: an instruction carried its
operand and its condition inline, and the program is four thousand of them.

Every test is deterministic, offline, and needs no downloaded model. The
checklist holds the second of those: nothing in the repository may exceed a
megabyte, which is what a committed model would. What the suite covers:

- **GGUF** — truncation at *every* byte offset of a valid file, corrupt
  magic, unsupported versions, excessive counts, duplicate metadata keys,
  duplicate tensor names, invalid UTF-8, quantization block misalignment,
  out-of-bounds tensor ranges, trailing-data policy, typed accessors, a
  450-case mutation corpus that must produce only controlled outcomes, the
  fused dot product agreeing with the reference decoder for every format, the
  number of vectors in one kernel call changing none of them, and nothing a
  model file says -- metadata value, metadata key or tensor name -- reaching
  the terminal unescaped, five hundred generated containers read back through
  the accessors the engine uses and compared with what was written -- strings,
  signed and unsigned integers of two widths, booleans, array elements and the
  tensor descriptors -- so a disagreement between the writer and the reader
  cannot look like agreement, the UTF-8 validator refusing overlong encodings,
  surrogates and code points past U+10FFFF while accepting each length at its
  boundaries, a hostile vocabulary, whose special-token
  identifiers name tokens that do not exist, being unable to make the
  tokenizer reach outside itself, and the structural refusals -- an unnamed
  metadata key or tensor, an alignment that is not a power of two, a string
  past the length limit -- each reporting the code that names it, and the
  tokenizer's own refusals doing the same: no tokenizer model, a model this
  engine does not implement, no token list, input that is not UTF-8, and a
  buffer too small for the tokens. The architecture profile likewise: a file
  naming no architecture or another one, widths that do not divide, an odd
  rotary width, a rotary scaling this does not compute, an expert count with
  no used count and one asking for more experts than the model has, a shared
  expert, a sliding window of no positions, and an embedding tensor of the
  wrong shape. A prompt
  file that is absent, a directory, past the size limit or not UTF-8 likewise,
  with a sound one read. A file that ends inside a field is truncated, a rank
  past the limit is an invalid rank, and an extent of zero is an invalid
  dimension -- three answers a reader could give as one. What a caller can be
  wrong about is checked the same way: a request for no tokens or no batch, a
  prompt longer than the context, a message with no content, and generating
  from a model that was never prepared, a conversation past its bound, a model
  released while a session still holds it, and a sampler with every token
  forbidden. Refusals that cannot be built into a
  container are edited into one: an undefined value, array-element or tensor
  type, an array of arrays, a tensor off its alignment, and two tensors over
  the same bytes. The builder records where it wrote each field and the test
  asks by name, so no test carries a table of byte offsets. A tensor view
  refuses each impossible shape by name too: no rows or columns, a quantized
  row that is not whole blocks, a format this build cannot decode, a shape
  past its buffer, and an operand that does not match.
- **Inference** — every piece the streaming decoder hands out being whole
  UTF-8, checked over a vocabulary built so that a character spans three
  tokens, which the fixture model's all-ASCII vocabulary cannot express;
  preparation, finite logits, run-to-run determinism,
  cancellation leaving the cache uncommitted, a batch refused at the same
  context boundary a single token is -- filling it exactly accepted, one past
  refused, and a refused batch leaving the cache where it was; a cancellation
  asked for while
  the model is still loading stopping the load, context exhaustion and reset,
  out-of-range token rejection, tokenizer round trip, an interrupt reaching the
  cancellation token through a real signal, agreement with the independent
  reference implementation, and a batch producing the same bits as the same
  tokens evaluated one at a time, down to the cache it leaves behind.
- **Sampling, stops, kernels and templates** — a fixed seed producing a token
  sequence written down rather than only compared with itself, so the claim
  that the generator produces the same stream on every host is checked on
  every host the suite runs on; the stop-string matcher
  compared against the rule written out the slow way, over two thousand
  generated sets and buffers, so a disagreement is a fault in one of them
  rather than a restatement of the other; two thousand generated
  configurations, every setting varied together over logits that include what
  a broken model produces, each returning a token inside the vocabulary or
  saying it cannot; the kernels answering
  degenerate input rather than trapping on it: a layer of zeros normalized
  without dividing by its own scale, a length mismatch leaving the target
  zeroed, and softmax refusing to turn values that are not finite into a
  distribution; greedy maximum and tie-breaking, greedy
  entropy independence, fixed-seed reproducibility, top-k, min-p, repetition
  penalty, NaN and infinity rejection, stop-string earliest-then-longest
  matching, stop bounds, exact template rendering, branches and whitespace
  control, rejection of unsupported constructs, and automatic seeding varying
  between runs without falling back to the fixed seed.
- **CLI and generation** — four thousand generated command lines, built from
  options in impossible orders, values where flags go, empty arguments, text
  that is not UTF-8 and numbers too long to be numbers, each answered with a
  definite outcome rather than raised on; interactive mode, which needs a
  terminal at both ends and so was driven by nothing at all until its loop was
  made to read redirected input -- the loop running a conversation to its end,
  a turn accumulating across lines and submitting on a blank one, a turn past
  its bound refused whole rather than truncated, a slash on a later line being
  the text it looks like, every command word read as itself, and the
  conversation keeping its shape under the edits the loop makes: a system
  message landing first, replacing rather than accumulating, clearing without
  disturbing the rest, and a cancelled turn dropped from the end without going
  past the beginning; every backend this build has named on the command line
  and one it does not have refused; command parsing, fifteen distinct usage
  errors,
  end-of-options, pre-parse scans, reproducible generation, stop strings across
  token boundaries with no leak, stop tokens producing no text, closed output
  as a normal end, context budget checked before evaluation, retained text
  matching what was streamed, the end token ending a run without any of it
  reaching the output, the reference comparison accepting a match while
  rejecting a mismatch and a recording with no stated origin, a prompt read
  from standard input bounded and refused plainly rather than truncated, the
  diagnostics never quoting the prompt or the system message, and a seed
  covering the whole unsigned range in parsing, storage and display.
- **Catalog** — every diagnostic code resolves, every enumeration-derived
  key resolves, every interface key exists, protocol tokens untranslated,
  emergency path, locale fallback, escaped parameters, the pseudo-locale
  differing everywhere while keeping every placeholder, a partial second locale
  translating and inheriting per key, and POSIX host-locale normalization.
- **Chat template** — two thousand generated templates, mostly balanced so
  that rendering rather than compiling is what is examined, one in four broken
  on purpose, rendered into buffers small enough to overrun: none raises, and
  every render that fails reports writing nothing, which is what stops a
  caller emitting the previous turn's bytes; an ordinary template compiling
  and rendering, every
  documented compile-time refusal reported by its own code rather than merely
  as an error, and all five bounds driven to their edge and one past it: size,
  instruction count, nesting depth, output size and iterations.
- **Arithmetic, memory, clocks, text and packaging** — numbers rendering the
  way a reader sees them, with fractions keeping their leading zeros and a
  value too large for a fixed-point image saying so rather than raising inside
  a diagnostic; the release archive carrying
  every file a distribution needs under its versioned prefix, with the program
  executable and the documents not, and refusing to write anything at all when
  one input is missing; the byte readers decoding little-endian
  from any offset and refusing a field that runs past the end, returning zero
  when they do; checked arithmetic carrying overflow
  rather than raising or wrapping, invalidity absorbing through further
  operations, alignment refusing a non-power of two, narrowing to Natural
  reporting range loss and zeroing its result; an allocation past the budget
  refused
  before it is attempted, mapped bytes not counted as allocated, a plan that
  cannot be represented refused rather than wrapped, a clock that goes
  backwards yielding no elapsed time, and a file mapping reading back what is
  in it while refusing a read past the end.
- **CPU backend** — the partition covers every row exactly once for every
  worker count, a parallel product equals the serial one **exactly**, more
  workers than rows still produces a complete result, a closed pool rejects
  work, one pool serves many jobs, a pool that is never used still terminates,
  capabilities advertise only what is implemented.

### Locales

`en` is complete. `da` is a partial translation of the command surface and the
common diagnostics, and every other key falls back to English per key, so
nothing reaches the emergency form. `qps` is a pseudo-locale
generated from the English entries: every letter outside a `{placeholder}` or a
protocol token is accented and the message is bracketed, so an untranslated
string, a lost placeholder or a truncated line is visible at a glance.

```
$ model_runner --locale da run x.gguf --bogus
model_runner: fejl: MR-CLI-0003: ukendt tilvalg: --bogus
model_runner: kør 'model_runner help' for at se brugen

$ model_runner --locale qps run x.gguf --bogus
⟦model_runner: ⟦éŕŕóŕ⟧: MR-CLI-0003: ⟦úñkñówñ ópŧíóñ: --bogus⟧⟧
⟦model_runner: ⟦ŕúñ 'model_runner héĺp' fóŕ úßágé⟧⟧
```

Two lines, not one: the diagnostic and the hint that follows it. Both are
translated, and the second is the one that shows a locale is complete enough
to be useful rather than merely present -- a run that told a Danish reader
what went wrong and then advised them in English would be the interesting
failure, and would not have been visible here while the example showed only
the first line.

### Fuzzing

`tests fuzz` runs two campaigns: one over model files, one over the text a
caller supplies. Both are seeded, so a failure replays exactly.

#### Text

The second is `Text_Fuzzing`, and it exists because everything fuzzed before
it was a container. A prompt file, standard input and a command-line value are
untrusted too, and they reach `Model_Runner.Tokenizer.Encode` whole. A case
fails when the call raises, when it reports a code the interface does not
document, when it says it succeeded and hands back a token the vocabulary does
not hold, or when it takes longer than the limit for text of its size — which
is 50 ms plus 20 µs a character, roughly a hundred times what encoding
actually costs.

The clock is there because the defect that prompted this could not have been
found any other way. `Encode` looks for a control token wherever the text
opens a bracket, and the scan reached the longest token the format allows —
1024 bytes — at every one of them. Sixty thousand brackets, well inside the
documented input limit, took **25.5 seconds** where the same length of
ordinary text took a fortieth of a second. Nothing was wrong with the answer.
The scan is now bounded by the longest marker the vocabulary actually holds,
which for the fixture is four bytes and for a real vocabulary about
seventeen.

`tests benchmark` times both cases now, at a load of 1.12: **0.0098 s** for
sixty thousand ordinary characters and **0.0127 s** for sixty thousand
brackets, so the hostile text costs about a third more rather than six
hundred times more. Those are lower than the 0.039 and 0.045 this used to
quote, and the reason is what they measure: the older pair came from timing
a whole `model_runner run` in the shell -- parsing the model, loading the
vocabulary, encoding, and refusing the prompt for length -- while these are
the encode. The 25.5 s is history and needs the commit before the bound; it
is quoted as the reason the bound exists rather than as something to
reproduce.

The longest cases are drawn from an alphabet where one character in two is a
bracket, because a cost paid per bracket is invisible in text where one
character in twenty is one, and drawing that shape by chance would need a
campaign far longer than the release gate can afford. Against the unbounded
scan the gate reports forty slow cases and a worst of 7054 ms; against the
bounded one, none and 16 ms.

#### Model files

`tests fuzz` mutates the synthetic container — truncation at an arbitrary
offset, single-bit flips, 64-bit and 32-bit field overwrites, and byte-run
splices — and feeds it to the whole load path: the parser, the tokenizer, the
chat-template compiler and model preparation. Only four outcomes are accepted:
loaded, structurally rejected, rejected against a resource limit, or cancelled.
Every accepted container is also rendered as `inspect` would render it, and a
control character surviving that is counted as an invalid acceptance: a file
that could steer a terminal has been accepted into a state it should not have
reached. One of the mutations writes control bytes deliberately, because a bit
flip reaches one only by chance.

Each campaign also reports how far its files got: of two thousand mutated
files, about twelve hundred prepare a model and nearly as many run a forward
pass. A campaign where none reached the engine fails, because clean totals
from files that all stopped at the parser would say nothing about everything
past it.

A campaign also fails on an internal invariant violation. That code means the
program found a state it believes impossible, and a file deciding when that
happens is a fault however it arrives — but it arrives as a refusal, so a
campaign counting refusals will not notice. Twenty-six cases in two thousand
were doing exactly that.

An escaped exception or an invalid container accepted into a usable state is a
failure. Each case is derived from the seed and the case number alone, so a
failure replays exactly.

### Conformance

`tests conformance` computes the same logits twice, by different routes, and
compares them. `Reference_Transformer` in the tests crate is written from the
architecture description and shares no arithmetic with the engine: it decodes
binary32 from the file bytes by reconstructing the value from its fields rather
than reinterpreting the host representation, computes in `Long_Float`
throughout, keeps the whole key and value history instead of a
reserved-and-committed cache, and expands key and value heads instead of
mapping query heads onto them. A mistake in cache indexing or head grouping
therefore cannot be common to both.

```
conformance: sequences 8145, logits compared 112320,
             worst absolute 2.24055356401465E-05,
             worst relative 5.39566401500295E-03,
             rounded logits compared 10800,
             rounded worst absolute 1.36861269753309E-01,
             rounded worst relative 1.83560177726357E+00,
             cached logits compared 7200,
             cached worst absolute 3.26576544071315E-02,
             cached worst relative 2.00700080641696E-01,
             outside tolerance 0
```

Three architectures -- `llama`, `qwen2` and `qwen3` -- in each of the five
shapes a supported model comes in: dense, sliding-window, a mixture of
experts, a stretched rotation, and heads wider than the embedding implies with
keys and values different widths again. The processor and the binary64 backends, every evaluation path -- a token at a
time, a whole prompt in one pass, and a prompt handed over in several --
serial and across a worker pool, every repacking mode, and every one of the
fifteen weight formats the engine decodes: binary32, F16, BF16, Q4_0, Q4_1,
Q5_0, Q5_1, Q8_0, Q2_K, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL and IQ4_XS. The fixture writes each of
them and the reference reads each of them, both worked out from the layouts
rather than by calling the engine, so a packing mistake cannot be common to
the two sides. Tolerance is 1e-3 relative with a 1e-4 absolute floor, and nothing is
outside it.

The device backend is compared separately rather than crossed with the rest,
and it is compared in all fifteen formats: the shader has a branch for each,
so each is a transcription of a bit layout that could be wrong on its own.
That is what this crossing is for. A shift by the wrong amount, a sub-block
scale read from the wrong byte or a level table off by one produces an answer
that is merely wrong, and nothing downstream can tell a slightly wrong weight
from a right one. It runs each of the three architectures in each of the
fifteen formats, through both evaluation paths, against the same independent
implementation; on a machine with no device it runs nothing and says so by
the count. Its arithmetic is
where the worst relative figure above comes from -- the shader accumulates a
row in binary32 where the processor's kernels accumulate in binary64 and
round once -- and it is a relative figure on a logit near zero: the worst
absolute difference is 2.2e-05, which is under the absolute floor.

The reference runs once for each fixture and sequence rather than once for
each comparison. It reads the file and the tokens and nothing else -- it does
not know which backend it is being compared against, and cannot, because it
has none -- so the eight comparisons that differ only in backend, repacking,
batching or pooling all check against one answer. That is 780 forward passes
where there were 6435, and it took the sweep from nine minutes to two and a
half without dropping a comparison: every figure above is what the eight-fold
version reported, to the last digit.

Two combinations are left out of that sweep, and the reason for both is a
measurement. Repacking to brain floats halves the mantissa, and both a sliding
window and a mixture sharpen what that perturbation reaches: a window makes the
attention softmax sharper, so a difference full attention would average away
moves a logit instead, and a mixture puts a softmax on the router, where the
same difference moves the shares the experts are summed with and, where two
experts score nearly the same, moves which of them runs at all. Against the
reference, worst absolute over this sweep:

| model | `--repack bf16` |
|---|---|
| dense, no window | 0.137 |
| window 6 | 0.137 |
| window 5 | 0.517 |
| window 4 | 0.517 |
| window 3 | 1.677 |
| experts, four of four used | 0.330 |
| experts, two of four used | 0.509 |
| yarn, with a divisor table | 0.325 |
| key heads 2x, value heads 3x | 0.707 |

against a lossy tolerance of 0.3. The two expert rows are what separate the
mixture's two causes: running every expert leaves no choice to flip, so 0.330
is what the shares alone cost, and the rest of the way to 0.509 is the route
changing. The exact repacking modes agree everywhere in that table -- 2.2e-05
at a window of three and on the mixture, against 3.5e-06 dense -- so none of
this says the window or the routing is wrong, and all of it says what
`--repack bf16` costs on those models. Comparing them in the sweep would mean
asserting a tolerance nobody has grounds for. Four of the five shapes sit outside that
tolerance, which is worth saying plainly rather than burying in a table:
**0.137 is what `--repack bf16` costs a dense model with full attention and
heads the width its embedding implies, and it does not carry over to a model
that does anything else**. The last row needs no theory -- wider heads mean
more terms in every dot product to accumulate eight mantissa bits of error
over. Use `--repack
f32`, which is exact and costs memory instead.

The cached figures are `--kv-cache f16`, which stores what a session has
committed as binary16 rather than binary32: half the memory for the context,
and **0.0327** worst absolute on these fixtures against 2.2e-05 for the exact
cache. That is measured with and without a sliding window; without one it is
0.0218, and a window raises it for the reason a window raises everything
lossy here -- it sharpens the softmax, so a rounded value moves a logit
further. That is three orders of magnitude worse than exact and six times better
than rounding the weights, which is what one would expect from where each
rounding happens -- a weight is rounded once and read into every product, a
key is rounded once and read back by every later position. Both evaluation
paths are compared, because the two storages are two procedures.

The rounded figures are `--repack bf16`, counted apart because mixing them in
would let the lossy path's error hide the exact path's. They are the number
that flag never had: rounding every weight to eight mantissa bits moves a
logit **on these fixtures** by up to **0.137**, and a logit close to zero moves
by almost all of itself, which is what the relative figure says.

On this fixture is not a small qualification. Rounding error accumulates with
the length of a dot product and the depth of the stack, and the widest fixture is
256 wide and two deep where a small real model is two thousand wide and
twenty-two deep. The figure has read 0.032, 0.064, 0.090, 0.254 and now 0.137 as the fixtures
changed -- which is the shape of the thing rather than a number to trust to
three places: wider means more terms means more accumulated rounding, coarser
weights mean a rounding step that matters more, and halving the feed-forward
width of the widest fixtures brought it down again. What it says is that the
flag costs a tenth of a logit or so on a model this size, and that a model of
a useful size is where the question actually gets answered. The figure bounds what was measured, not what the flag does
to a model you have. What exists for real models is behaviour rather than
logits: sixty greedy tokens from TinyLlama Q8_0 and forty from Q4_K come out
identical either way, which is worth knowing and is not a bound.
`tests external-model --model PATH --repack bf16` runs a model you have both
ways and says whether the identifiers still match. `--repack f32`
is in the first set, where it belongs: it lands exactly where the stored
layout does. The bound the rounded path is held to is 5e-2 relative with a
1e-1 absolute floor -- what it measures, rounded up -- rather than the exact
one, which would only restate that rounding rounds.

A prompt longer than `--batch-size` is evaluated in several calls, and the
seam between them -- where the cache position carries from one call to the
next -- is where an off-by-one would live. Eight tokens three at a time is
two of those seams, and every comparison used to hand the whole sequence over
at once. What decides where the seams fall is the loop in `Generation`, and
that loop is checked against the engine itself: a test asserts that a batch
produces the same bits as the same tokens one at a time. So the seam is
compared independently and the arithmetic that chooses it is not, which is
the honest division here.

The partitioned path is compared for the same reason the batched one is: a
run uses it and only the engine had ever read what it produced. Row
partitioning is where a boundary error would live, and the two checks that
exercise a pool -- worker-count stability here and in `tests external-model`
-- compare the engine against itself, so a partition that is wrong the same
way at every worker count passes both.

The batched path is compared because it is the one a prompt goes through, and
it was checked only against the engine's own single-token results: the
strongest statement here -- that the arithmetic agrees with an implementation
written from the architecture description -- was being made about the decode
path alone. The reference backend takes a token at a time by design, so the
batched half of the sweep runs on the backend that batches, which the sweep
asks rather than assumes.

Running the reference backend through the same comparison is worth the
seconds it costs: that the two backends agree with each other says the fast
path's partitioning and batching change nothing, and that both agree with an
independently written forward pass says the arithmetic is right. The second
is the stronger statement and it used to be made about only one of them.

The relative figure is dominated by one logit that is very close to zero,
where a difference of six ten-millionths is a large fraction of a small
number. Measured apart, `llama` reaches 1.22e-06 absolute and 1.22e-05
relative, and `qwen2` reaches 6.08e-07 absolute and 8.27e-04 relative -- so
the architecture with the larger relative figure is the one whose two
implementations agree more closely in absolute terms. That is worth saying
because the relative number moved seventy-fold when `qwen2` was added and it
would otherwise read as a regression.

Those digits are what the run prints, and `tests conformance` checks that this
file still quotes them. It had gone stale twice before that check existed: the
counts here read 4 and 64 while the run had grown to 8 and 128, and the worst
divergence was quoted six times smaller than it is. A figure worth publishing
is worth failing the release checklist over.

`tests external-model --model PATH [--expect FILE]` runs the same kind of
validation against a model you already have — container, architecture, session,
greedy generation, valid UTF-8, seed reproducibility and worker-count stability
— and, when given a recording from a trusted reference runtime, compares the
tokenization, the greedy token identifiers and any recorded logits against it.
Nothing is downloaded, and a missing file is a skip rather than a failure. See
[docs/reference-runtime.md](docs/reference-runtime.md).

`--backend NAME` points it at any backend this build has, which is what makes
it a validation of a backend on somebody's own model rather than of the
processor path alone. `--draft-model PATH` runs the model again with that one
proposing for it and checks that the text is identical, which is the claim
drafting makes and the only place it can be checked against a model anybody
cares about; the summary reports how many proposals were made and taken.

What this runner generates is what the command generates from the same
inputs, and a test holds that by running both and comparing a digest of the
text. It samples greedily and seeds itself with forty-two, which is a choice
rather than the command's default, so the test gives the command those
settings explicitly. `tests benchmark` has no such counterpart and needs
none: it measures kernels on synthetic tensors it builds itself, so there is
no command it could differ from. A backend that does not partition rows is not asked
whether the worker count changes its answer, and says so rather than
reporting an unrun check as one that held; a machine with no device is a skip
for the same reason a missing model is.

```
$ tests external-model --model /nowhere/x.gguf
external-model: skipped (no model at /nowhere/x.gguf)

$ tests external-model --model fixtures/tiny-model.gguf --prompt "ab" \
      --threads 4 --max-tokens 8
external-model: ok, architecture llama, 21 tensors, no reference comparison,
                prompt 3 tokens, generated 8, backend cpu,
                deterministic TRUE, thread-stable TRUE

$ tests external-model --model fixtures/tiny-model.gguf --prompt "ab"
external-model: FAILED (generation failed: MR-GEN-0002)
```

The third is worth showing. The committed fixture holds sixteen tokens of
context and the runner asks for sixteen tokens by default, so a three-token
prompt leaves no room and the engine refuses before generating anything. The
failure names the code it refused with, which is how anyone reading it can
tell an unusable request from a broken engine without reproducing the run by
hand. It printed only "generation failed" until this was written down, and
this example was published for two years as though it had succeeded.

### Repository checks

`tests check` performs its checks in Ada: crate structure and declared
dependencies, the version in `alire.toml` against `Model_Runner.Version`,
absence of scripting-language build files, that production code never reaches
AUnit or `project_tools`, that nothing below the presentation layer reaches the
message catalog, terminal styling, the command-line layer or a standard stream,
the 120-character line budget, a catalog entry for every diagnostic code, and
that the generated error-code reference is current.

Diagnostics are held in three states, not two. `Reserved_Codes` names the
codes nothing raises; `Unreached_Codes` names the codes the program raises
that no test names, each with why — naming is the proxy for reaching, and it
errs towards calling a code reached, so the list going empty would not mean
every refusal has been made to happen. Seventeen codes were in that third state
with nothing saying so — a refusal written and never made to happen is a
promise the program has not been asked to keep, and the check that every code
is *produced somewhere* counts a raise nobody reaches exactly as it counts a
raise everybody reaches. Ten of the seventeen are now reached; the rest are on
the list with a reason. Both lists are held in both directions. The checks are
negative-tested: injecting a violation makes them fail, and they run on every
host the project supports rather than on the one they were written on.

They also hold the changelog against git — no commit touching the library, the
message catalog or the release gate may be newer than the newest commit
touching `CHANGELOG.md`, so a change and its entry arrive together — and the
release checklist ends by running `check_all_selftest`, which requires the
checklist to refuse a directory that is not a model_runner tree, and to refuse
it for that reason rather than by failing somewhere else.

They also compile every host body, not only the two a build uses — in the
tests crate as well as the library, which has its own per-host directories and
had been left out of the walk. And a host call may only be bound by name from
one of those directories: anywhere else in the tests crate is one directory
built for whatever machine you are on, so a POSIX-spelled import links there
and nowhere else.
`src/platform` holds five directories and a Linux build uses `linux` and
`posix`; the other three are production code no compiler here would otherwise
see, and reading them as text is not compiling them. The sibling `hostkit`
crate shipped a Windows body holding `('\\')` where Ada spells a backslash,
found by building on Windows and nowhere else. `gcc -gnatc` stops before code
generation but after analysis, so profiles are checked against the spec all
five share and names are resolved — and nothing here needs the host's own
libraries, because these bodies reach their host through `Interfaces.C`, whose
declarations are the same everywhere. That is what makes the question askable
from a machine of the wrong kind.

They also check that each host gets exactly one body for each platform spec.
Compiling a body says it is well formed and says nothing about whether the
host that needs it has one; the project file builds `linux` with `posix`,
`macos` with `posix`, `windows` alone and `unsupported` alone, so a spec whose
bodies were written for some of those and not the rest fails to link on the
others — on that host and nowhere else.

## Layering

CLI and presentation sit above command execution, which sits above generation,
the conversation and template layer, the tokenizer, the model and session
interfaces, the architecture implementation, the tensor layer and the platform
abstractions. No package below the presentation layer writes to standard
output or standard error, depends on the message catalog, or depends on
terminal styling.

## Security posture

Every GGUF file is untrusted input. Counts are checked against explicit limits
before they size a loop or an allocation; offsets, element counts and byte sizes
are derived with checked arithmetic that reports overflow instead of wrapping;
strings are validated as UTF-8; tensor ranges are checked against the file and
against each other. Embedded chat templates are compiled into a bounded
allowlisted form that has no operation capable of reaching a file, a process,
the environment or the network. Metadata values are escaped before they reach a
terminal, and so is message text from the catalog, which is a file beside the
executable rather than part of the program. Model files are opened read-only
and are never modified, which a
test holds by comparing the file's bytes and its modification time across a
run. The units that interpret what a container holds -- the template engine,
the tokenizer, the metadata accessors, the engine itself -- may not name a
file, a stream, a directory, the environment or the command line at all, and
the release checklist fails if one of them does.

Generated text is passed through as the model produced it. It is never styled
and never escaped: a model that generates a terminal escape sequence has
generated one, and rewriting it would corrupt output a reader asked for. The
line is between what the program says about a file — keys, names, values,
diagnostics, all escaped — and what it hands back. Redirect to a file, or
filter, if the model is one you do not trust with your terminal.

Prompt text given with `--prompt` may be visible to other local processes. Use
`--prompt-file` or standard input for sensitive text.

## Not implemented

Named in the specification, absent here:

- **Hand-written vector code or intrinsics.** The kernels are ordinary Ada and
  the compiler vectorizes them; there is no assembly in this repository. That
  is a fact about the code and not a rule: machine code insertions are an Ada
  feature and a check used to refuse them, which guarded this sentence rather
  than anything about the program. What the release checklist does hold is
  that no source in another language lives here, which is a different
  question -- and one `src/shaders/row_product.comp` answers with a yes: it is
  GLSL, because a compute shader has to be written in a language a graphics
  driver's compiler reads. What the checklist refuses is compiled code in
  another language -- C, C++, assembly -- and it holds the shader to something
  stricter instead: the source's digest is recorded beside the compiled form,
  so a shader edited and not recompiled fails the checklist rather than going
  on running the old one.

## Speed

All figures below are from the release build, on a Ryzen 7 7840U -- eight
cores -- against TinyLlama-1.1B-Chat Q8_0, at the worker count the program
chooses for itself. From the six-token prompt in
`tests/fixtures/speed-prompt-short.txt`, twelve tokens take **1.88 s** --
0.39 s evaluating the prompt and 1.49 s generating -- and 10.4 s of processor
time, the median of three runs, taken at a load of 1.28 rising to 1.82. The figure this replaces was
1.37 s, and the load it was taken under was not recorded, which is why it is
replaced rather than compared with: a third of a second between two runs of
the same code is exactly the range this machine moves through, and the older
figure cannot say where in it it sat. The processor-time figure that stood
beside it -- 9.3 s -- came from the operating system's timing tool; the
10.4 s above comes from this one. Loading the model costs a further 0.6 s of
wall that this figure does not include, because the two are worth
separating: one is the model, the other is the disk.

The run is

```
model_runner run MODEL --raw --prompt-file tests/fixtures/speed-prompt-short.txt \
  --seed 1 --temperature 0 --max-tokens 12 --show-stats
```

and `tests speed --model MODEL` takes the same measurement three times and
reports the median, so the figure above is a command rather than a memory.
It reports the processor time as well now, taken around the same region as
the wall time so that the two answer about the same work. That used to be the
one number here the tool did not produce -- the reasoning was that totalling
processor time across the worker tasks needs a host call this crate would
have to bind per platform, and `/usr/bin/time` already gives it. What it
actually needs is the same file the load comes from, which this reads
already; and a figure from the shell is a figure with no load beside it,
which is the thing this section spent a week learning to care about.

This paragraph used to say 2.07 s, about 1.1 s of it evaluating the prompt,
and 14.2 s of processor time, from "a short prompt" that was never named.
Neither the prompt nor the figure could be recovered: the repository's own
long prompt gives four times the number, and a short one gives a quarter of
the stated prompt-evaluation time. What made 1.1 s plausible was the chat
template, which turns a six-word prompt into twenty-eight tokens -- but a
templated run of this model stops at its end-of-sequence token after seven
tokens, so it is not a twelve-token measurement at all. The figures above
are `--raw`, which is why they are lower and why they can be taken again.

The worker count is what that processor figure is about. The same run at
fourteen threads takes **1.54 s** of wall against **1.88 s** at seven, and
16.1 s of processor time against 10.4 s, both at a load of about 1.25.

That is eighteen per cent off the wall for fifty-five per cent more processor
time, and it is worth saying plainly that it is not what this paragraph used
to say. The figures here were 2.29 s against 2.43 s and 17.3 s against
10.1 s -- six per cent of the wall for seventy per cent more energy -- taken
with the shell's timer, on runs whose load nobody recorded, and including the
model load that these exclude. Six per cent for seventy is a bad bargain that
argues for itself. Eighteen for fifty-five is a real trade, and the default
of one worker per core rests on the energy alone: the same tokens for two
thirds of the processor time, on a fifteen-watt part where that is heat and
battery rather than an abstraction. A caller who wants the wall and has the
power can ask for `--threads 14` and will get it.

A job is cut into one more piece than the pool has workers, because the task
that submits it takes the last piece rather than waiting; the figures below
count those pieces, and so does the benchmark. Eight of them is this machine
fully occupied, since it has eight cores -- reported as sixteen processors,
which is not the same thing. Eight shares take 2.43 s for 10.1 s of processor
time and sixteen take 2.26 s for 17.5 s: the second worker on a core shares
the first one's execution units, so it buys a fourteenth of the wall and
costs seventy per cent more processor time. There are only 2015 matrix products in a run this size, so
handing each of them out costs milliseconds in total; what the pool does with
them, however, mattered a great deal, and is the next paragraph.

One core was being wasted, and finding out why took pinning the process to one
processor per core so it had nowhere to hide. On this machine that is

```
taskset -c 0-7 tests benchmark
```

because its siblings are *n* and *n + 8* --
`/sys/devices/system/cpu/cpu0/topology/thread_siblings_list` says `0,8` --
so processors 0 to 7 are eight distinct cores. The list is per machine and
the file is where to read it. That command was not written down until after
the figures below had been published, which left the one measurement here
that a reader could not take again. Pinned, seven shares reached
5.0x and eight fell to 3.7x -- adding a worker made it slower. The task that
submits a matrix product used to wait for the workers to finish
it, so with one worker per core there was always one more runnable task than
there were cores, the operating system took a core from a worker, and the
whole job waited for that worker because a job is not done until its slowest
share is. It now takes the last share itself instead of waiting. Pinned, eight
shares went from 9326 Me/s to 14182. Taken again with the command above at a
load of 1.03, eight shares reads 10122 Me/s against seven at 10713 -- so with
one vector a pass eight still falls a little below seven, by six per cent
where it used to fall by a quarter. Batched it does not: thirty-two vectors a
pass reads 21234 at eight against 21035 at seven. What the change was for was
the quarter, and that is gone. The 9326 is history: it needs the commit
before the change, and it is quoted here as the reason rather than as
something a reader can reproduce.

Unpinned the gain is small, six per cent, because the spare task could take a
processor on a core that already had one and that is cheap. Pinned is what a
container with a processor budget looks like, so it is the case worth being
right about.

The default therefore asks for one worker fewer than the machine has cores --
the submitting task is the last one -- and follows the core count rather than
the processor count, where the host will say what that is. Linux publishes it
and macOS answers sysctl; Windows would answer too, but through a walk over
variable-length
records that has not been written because it cannot be run here, so a
Windows host still defaults to the processor count as every host did before. There is
one body per host for this, beside the ones for mapping and signals, and a
host that cannot answer says so rather than guessing. `--threads` overrides it
everywhere and still accepts any number the backend allows.

What is left over is not the memory. Measured on its own, away from the model,
the matrix product reaches about 4.9x on eight shares against its own serial
rate, and reaches it whether one vector is passed or thirty-two -- 2231 to
10122 Me/s in the first case and 4317 to 21234 in the second, medians of three
runs, pinned, at a load of 1.03 rising to 2.68. The one-vector case peaks at
seven shares rather than eight, 10713 Me/s against 10122, which the batched
case does not do.
If memory were the wall those two would part company, because the second reads
each weight byte once for thirty-two multiplies and the first reads it once
for one. At eight shares the product moves 13.2 GB/s, which this machine is
not troubled by. What does change is the clock: 4927 MHz with one core busy
and 3926 with eight, sampled from the host while running. That ratio alone
caps eight cores at 6.4x, and the rest is cache and hand-off. It is a 15 W
part doing what a 15 W part does.

Nor is there redundant traffic to remove. Each share reads only its own rows,
each weight byte is read once per pass, and the span buffer that looks like
waste when one vector is passed is what makes the loops vectorizable --
decoding straight into the sum was written and measured at 44 per cent slower.

Moving fewer bytes per weight was the last idea, and measuring it twice is
what settled it. Before the submitting task took a share, the four-bit format
ran sixteen per cent faster than the eight-bit one at eight-way parallelism
while being level with it serially, and three to five per cent faster end to
end. That gap was the contention, not the bytes: with the contention gone the
four-bit format is within a few per cent of the eight-bit one either way --
8636 Me/s against 10122 at eight shares with one vector, 22332 against 21234
with thirty-two, 2451 against 2231 serially -- and end to end the two are
indistinguishable, 2.06 and 2.18 s against 2.06 and 2.26. Which of the two
leads changes with the case and with the run: four-bit is ahead serially and
batched and behind at eight shares with one vector, and it was the other way
round in the sitting before this one. That is the finding -- they are level,
and a gap either way at one shape is the machine rather than the format.

It is worth keeping as a lesson rather than a result. A measurement taken
while something else is the bottleneck measures that other thing, and the way
to find out is to fix the bottleneck and measure again.

(That file was requantized from the eight-bit one rather than built from the
original weights, which is not how a model should be made. It is here to move
fewer bytes, not to answer well, though it answers "Name three colours"
exactly as the eight-bit one does.)

The largest cost left is not in the row product at all. Softmax costs about
five nanoseconds an element and the feed-forward activation about four, nearly
all of it the exponential, against half a nanosecond for a quantized row
product -- and both run once per layer per token. Replacing that exponential
with arithmetic was tried and is slower. The usual branchless series, a power
of two taken from the exponent field times a polynomial in what is left, cost
softmax about ten per cent, and the same in single precision, which halves the
work and doubles the lanes, still lost. The call is not what it looks like:
the mathematics library resolves it at load time to an implementation chosen
for the processor it finds, so it runs AVX2 code, while this crate is compiled
for baseline x86-64 and measured slower when it was not. A call into
hand-written wide code beats inline narrow code, even counting the call.
Getting past it needs either wider instructions than the build allows or an
approximation loose enough to change what models say, and the second is a
decision rather than an optimization.

### The reference backend

`--backend reference` computes the same logits by different code, and the
question a caller asks before running it is what that costs. Both sides of
the answer are one command now:

```
tests speed --model MODEL --backend cpu       --max-tokens 4
tests speed --model MODEL --backend reference --max-tokens 4
```

Four tokens from the short prompt, medians of three, taken at a load of 1.10
to 1.74 and 1.25 to 1.57: `cpu` spends 0.415 s evaluating the prompt and
0.512 s generating; `reference` spends 6.144 s and 4.288 s. That is
**eleven times** the work in total, fifteen times on the prompt and eight
times on the generation, and the two print the same digest.
The prompt suffers more because that is where the batching goes: `cpu` shares
one reading of the weights between the tokens of a batch and `reference`
declines to, which is one of the things it exists to be without -- so the
comparison hands it a batch size of one, as the command does.

Four tokens rather than twelve, because ten times is a long time to wait for
a figure whose shape is already clear at four.

This number was published as forty times for as long as the backend has
existed, taken by hand and never checked; then as twelve and a half, taken by
hand again. `tests benchmark` measures the algorithmic part on synthetic
tensors -- serial against serial, no pool on either side -- and reports 2.3x
for q8_0, 2.4x for q4_k and 3.1x for f32. The rest of the thirteen is the worker
pool and the batching, which is the honest way to read the figure:
`reference` is between two and three times slower than the same loop written
for speed, and the remaining factor is the parallelism it has none of.

### The device backend

`--backend device` runs the products on a compute device. On this machine --
an integrated Radeon sharing a fifteen-watt budget with the processor it
would otherwise be helping -- against the same TinyLlama-1.1B Q8_0 as
everything above, median of three runs, with the same command that produces
every other figure here:

```
tests speed --model MODEL --backend cpu
tests speed --model MODEL --backend device
```

| Run | `cpu`, 7 workers | `device` |
| --- | --- | --- |
| 6-token prompt, 12 generated | 1.777 s | **1.262 s** |
| -- evaluating the prompt | 0.355 s | 0.174 s |
| -- generating | 1.398 s | 1.062 s |
| 110-token prompt, nothing generated | 6.295 s | **2.504 s** |

Both backends print the same digest of what they generated -- `5abff916` for
the short run and `cbf29ce4` for the long one -- so this is the same text,
not a faster answer to a different question.

The long run moved from 3.824 s to 2.504 s when the shader was given a branch
for every format, which was not the point of that change and is not claimed
as its result: these were taken at a load of 1.6 and the earlier pair at a
higher one, and the loads are the first thing to suspect. What the pair does
say is that the shader did not get slower for carrying fifteen branches
instead of three, which was the risk worth measuring.

Read the left column with the caveat it deserves. This machine had other work
on it, and the two columns are not equally hurt by that: the processor column
competes for the cores it is using and the device column does not. Over eight
pairs taken across two days the processor's short run ranged from 1.42 to
2.17 s and the device's from 1.21 to 1.80, with the device below the
processor in seven of the eight. So its advantage on the short run is real
and smaller than any single pair suggests; on the long run it has never been
close. Each pair was taken together, which is what makes the two columns
comparable at all.

The earlier pairs are not listed here any more, and the reason is that they
were not comparable with these. Until this was written the tool differed from
the command it publishes figures for in three ways: it read the prompt file
including the final newline the command drops, it sampled with the greedy
configuration where the command keeps its defaults, and it handed a batch
size to backends that refuse batches. All three are fixed, a test now
compares the two runs token for token and digest for digest, and the figures
above are the first taken with the tool running what the command runs.

Every figure in this section now carries the load average the tool read
before and after taking it, which is what `tests speed` prints at the end of
its summary. These were taken starting from a load of 1.0; the pairs are
adjacent, which is what makes the two columns comparable.

Read those numbers knowing what they include: the tool is itself the work, so
a run of measurements raises the load it reports. A figure taken at 0.4 and
one taken at 3.0 in the same burst differ mostly in how many measurements
came before them, not in what else the machine was doing.

Two things make that possible and neither is the device being fast.

The shader decodes the weights itself, in every format the program reads.
They are read from the bytes the file holds, block scale and all, so a
quantized model goes to the device as it is stored: a gigabyte for this model
rather than the four that `--repack f32` would make of it. It decoded three
of the fifteen until recently and the other twelve reached a device only by
being repacked -- a pass over the whole model at load, and four bytes a
weight afterwards, which for a four-bit model is eight times what it was
quantized down to. What decoding costs on a device is a handful of arithmetic
per element; what not decoding costs is a pass over the whole model per
token.

The shader takes a batch. One invocation carries eight vectors and reads each
weight once for all of them, so a prompt is one reading of the model rather
than one per token. That is where the long-prompt figure comes from, and it
is the whole difference between this backend and the first version of it,
which declined to batch and evaluated a five-token prompt as five passes over
every matrix -- 1.5 tokens a second against the processor's 43.2.

Each matrix is uploaded once and stays on the device, up to three quarters of
the largest heap the device reports. Past that the matrix wanted longest ago
goes back to make room for the one wanted now, which is correct and slower:
what does not fit is uploaded again every time a token needs it. A run says
which device it used, how many matrices are on it and how many have been
given back, so a model that does not fit is a number rather than a mystery,
and a model whose matrices are larger than that share is refused as it loads
rather than discovered a token at a time.

```
  backend                 device
  device                  AMD Radeon 780M Graphics (RADV PHOENIX)
  matrices on the device  155
  read where they lie     0
  bytes on the device     1099071488
  matrices given back     0
```

`--device-memory SIZE` says how much of the device's own memory the weights
may take, and naming it says the caller knows what the device has: a model
larger than the number is then run rather than refused. `--device-memory 0`
means none of it, and the weights are read where they already are -- the
device is handed a pointer into this process's memory instead of a copy,
where the device shares the host's memory and will take one.

`--device-patience N` says how many seconds to wait for one product before
giving up on the device. The default is a minute, which is far longer than
any product on any machine this has run on -- and that is a guess about
hardware, which is exactly the kind of guess the caller with different
hardware has to be able to correct. A model wide enough on a device slow
enough can take longer than a minute for one product, and before this that
caller had no way to say so and got a refusal instead. A device that does
exceed the bound is given up on rather than waited for further: its buffers
are still its own and there is no way to take work back off it, so the engine
stops rather than recording over a buffer the device may still be reading.
How often the wait asks whether you want to stop is not an option and stays
at twenty milliseconds; that is a responsiveness number rather than a
hardware one.

That is a memory decision and never a speed one, which is the opposite of
what it was written expecting. The same model and prompt, three ways:

| Where the weights are | Generation |
| --- | --- |
| copied to the device, all of them | 11.53 tokens/s |
| a fifth copied, the rest uploaded again as wanted | 2.22 tokens/s |
| read where they lie, none copied | 0.78 tokens/s |

So giving matrices back and uploading them again beats reading the host's
memory by three to one, and reading where they lie is worth asking for only
when the machine cannot hold the model twice -- which for a seven-billion
parameter model at eight bits is fourteen gigabytes against seven. The
statistics say which of the three happened.

Under the model, one product at a time, `tests benchmark` measures where that
leaves each format. It prints the machine's load at both ends of its run --
1.25 rising to 3.34 for the figures below -- and **refuses to measure at all
above a load of 1.5**, because a ratio of a device against a processor is not
equally exposed to whatever else is running: the processor side competes with
it and the device side mostly waits on a fence, so other work moves the ratio
and a ratio that moves with the machine is a figure about the machine.
`--anyway` measures regardless, for a reader who wants the shape of an answer
rather than a figure to publish, and `--wait MINUTES` waits for the machine
instead of refusing it -- which is what a caller who wants figures rather
than an answer now actually wants, and which `tests speed` takes too. Every
figure in this file retaken this week came through a loop outside the
repository that polled the load and started the tool when it fell; that loop
belongs here. For the same reason the device rows are the
best of their rounds rather than the middle one -- the least interrupted
round is the closest the two sides get to being measured on the same machine
-- while every other figure here stays a median, being a whole-run time on
one side only, where a middle round is what a caller would see.

That is not a formality. Taking the figures again that way moved the
single-vector rows and left the batched ones where they were:

| Per pass | At load 2.34-3.11 | At load 1.36-2.96 |
| --- | --- | --- |
| q8_0, one vector | 0.74 | 0.81 |
| q4_0, one vector | 0.83 | 0.97 |
| f32, one vector | 1.33 | 1.42 |
| q8_0, eight vectors | 0.27 | 0.24 |
| q8_0, thirty-two vectors | 0.104 | 0.105 |

Which is what the bias predicted: the single-vector cases are the close ones,
where a processor slowed by other work is most of the difference, and the
batched cases are so far in the device's favour that the machine around them
barely shows.

All fifteen formats are measured now, one vector a pass and eight, which
they were not while the shader decoded three of them: twelve branches
arrived with nothing timing them, and a format can be perfectly correct and
four times slower than the one beside it with nothing to say so. A 512 by
2048 matrix, resident, against the serial processor path -- the device's time
as a fraction of it, so below one is faster there, taken in one run at a load
of 1.25 rising to 3.34:

| Format | One vector | Eight | | Format | One vector | Eight |
| --- | --- | --- | --- | --- | --- | --- |
| IQ4_NL | 0.24 | 0.15 | | Q3_K | 0.66 | 0.22 |
| Q5_0 | 0.30 | 0.16 | | Q4_1 | 0.67 | 0.24 |
| Q5_1 | 0.30 | 0.16 | | Q8_0 | 0.75 | 0.21 |
| IQ4_XS | 0.34 | 0.18 | | Q4_0 | 0.80 | 0.24 |
| Q2_K | 0.42 | 0.18 | | Q4_K | 0.84 | 0.25 |
| F16 | 0.65 | 0.23 | | Q5_K | 0.86 | 0.22 |
| | | | | Q6_K | 0.96 | 0.25 |
| | | | | F32 | 1.39 | 0.26 |
| | | | | BF16 | 1.41 | 0.29 |

and q8_0 at thirty-two vectors a pass, which is 0.104.

Read the one-vector column as a statement about the processor as much as
about the device, because that is what it is. The formats the device wins hardest on
are exactly the ones the processor's own kernels are worst at, and for
reasons already written down in the Kernels section: Q5_0 and Q5_1 keep the
fifth bit at a varying place in a thirty-two bit word, so the shift amount
varies with the element and baseline x86-64 cannot vectorize that loop;
IQ4_NL and IQ4_XS index a table of sixteen levels, which is a gather and does
not vectorize either. A device does not care about either -- it has lanes
that shift by their own amount and lanes that gather -- so it wins by four to
one where the processor is crippled and by a quarter where the processor is
at its best. The order of that column is nearly the reverse of the
per-element table under Kernels, which is the same fact said twice.

Binary32 is the one format the device is clearly slower at with a single
vector, and that is the finding rather than a disappointment: it is four
bytes a weight where q8_0 is one, so the vector-per-pass case is bus-bound
and the decoding the shader does is what buys the other rows. BF16 is the
same story at half the bytes.

The eight-vector column is where the argument that was standing in for a
measurement turns out to have been wrong. Only q8_0 was batched here, on the
reasoning that a batch buys the same arithmetic for every format and
measuring all fifteen would say what one says. It does not. Batching
compresses the whole spread: nine to one across the formats with one vector,
two to one with eight. The formats the device was worst at gain most --
binary32 goes from 1.39 to 0.26, from slower than the processor to four times
faster -- because a batch reads each weight once for eight vectors, so the
bus stops being the wall and what is left is arithmetic, which is what a
device has. Every format lands between 0.15 and 0.29, and the ordering is
still the processor's: the two five-bit formats and the two non-linear ones
stay ahead because the processor is still bad at them, only now by a sixth
rather than by four times.

Thirty-two vectors a pass costs a tenth of the processor's time, so the curve
is still bending at eight.

A single-vector ratio is the noisiest figure in this file. The f32 row has
read 1.33, 1.39, 1.42, 1.49 and 1.98 across five runs at different loads --
it is the row where the least work is done per byte moved, so it is the row
the machine around it moves most. The batched rows are steady to a few per
cent.

The arithmetic is not the processor's: the shader accumulates a row in
binary32 where the kernels accumulate in binary64 and round once. What that
costs is measured in the conformance section above, over every architecture
and every one of the fifteen formats the device reads.

### Drafting

`--draft-model PATH` gives the run a second, smaller model to propose what
comes next. The real model then reads several proposals in one pass and says
what it would have said at each of those positions; the proposals it agrees
with are what the run produces. Because this runs only at temperature zero, a
proposal either is the model's own choice or it is not, so the text is
exactly what the model would have produced alone -- held by a test that runs
the same prompt with and without a draft and compares.

What it saves is passes over the big model's weights: however many proposals
are accepted, they cost one pass. What it costs is the draft model's own
passes, one per proposal, and the output projection once per checked position
rather than once per token.

So a draft earns its keep only when it is much faster than the model and
usually right. Whether a particular one is can be worked out from three
measurements, and `tests speed` takes all three. Its summary ends with the machine's load
average before and after the run, because the processor side of every
comparison here has moved by forty per cent between otherwise identical
measurements and a figure that carries its own conditions can be compared
with another:

```
tests speed --model MODEL
tests speed --model DRAFT
tests speed --model MODEL --draft-model DRAFT --draft-tokens 4
```

All three at a load of 1.2 to 2.5, medians of three:

| | Twelve tokens | |
| --- | --- | --- |
| TinyLlama-1.1B at eight bits | 1.869 s | 156 ms a token |
| the same model at two bits | 2.660 s | 222 ms a token |
| the first, drafted by the second | 5.705 s | 16 proposed, 9 accepted |

The two-bit file is a third of the size on disk and more than twice the cost
to run, because what it saves in bytes it spends unpacking them. A smaller
file is not a faster model, and that alone decides this pair: a draft costing
more per token than the model it drafts for cannot win at any acceptance
rate.

The arithmetic, from the same three figures. Four rounds of four proposals
cost 5.705 s, of which the draft's own sixteen passes are 16 × 222 ms =
3.55 s, leaving 2.16 s for four checks -- **540 ms to check five positions**,
against 156 ms for one token generated normally. A batch is one pass over the
weights and the extra work is the output projection per position, which is
why five positions cost about four tokens rather than five.

So a round of K proposals costs `K × d + 540 ms` and yields `1 + a` tokens,
against `(1 + a) × 156 ms` without a draft. At the acceptance measured here,
2.25 of four, that wants a draft under 44 ms a token -- under a third of the
model's cost. With four proposals a round the check alone costs nearly as
much as the four tokens it can save, so on this machine and at this
acceptance rate no draft would pay.

Not with a grammar, and not above temperature zero. Both are refused rather
than ignored, and the difference matters: a draft is a second model file, so
a run that accepts the option and then never asks the draft anything has
spent the loading and the memory to produce exactly what it would have
produced without it. `--draft-tokens` without a draft model is a note instead
-- nothing was loaded, so nothing was wasted, and the only thing missing is
the telling.

The reason for the restrictions is the guarantee. Above temperature zero,
keeping it needs an acceptance test written against the sampler's own
distribution, which this does not have; a grammar constrains what may be
produced in a way the proposals know nothing about.

### Repacking

`--repack MODE` decodes every weight matrix once at load and evaluates from
that copy, instead of decoding a span of it on every pass. `f32` writes four
bytes a weight and cannot change what the model says: the values written are
the ones the decoder produces, in the order the kernels read them, and a test
holds the logits to the bit. `bf16` writes two, rounding each value to the
nearest brain float, which keeps eight mantissa bits where binary32 keeps
twenty-three — so it can change what the model says, and is the faster of the
two. A matrix already in the target format is left alone, and when nothing is
left pointing into the file's own bytes they are released.

Twelve tokens from the short prompt, generation only, medians of three:

| weights | as stored | `f32` | `bf16` |
|---|---|---|---|
| Q8_0 | 1.68 s | 1.57 s | **1.40 s** |
| Q4_K | 1.44 s | 1.55 s | **1.40 s** |
| Q2_K | 2.19 s | 1.53 s | **1.30 s** |

So `f32` is worth it only for Q2_K, and `bf16` is worth it everywhere: seven
per cent on Q8_0, fifteen on Q4_K, thirty-eight on Q2_K, at half the memory
`f32` needs. The kernels explain both halves of that. A binary32 row product
is the fastest per element — 0.26 ns against 0.31 for BF16, 0.37 for Q8_0 and
0.69 for Q2_K — but those are measured on a 64 MB matrix, and a repacked
model is 4.4 GB in binary32 against 2.2 in BF16. At that size the product
waits for memory, and the format that moves fewer bytes wins even though it
costs more per element to decode.

The decoding itself is handed to as many tasks as the run has workers, since
the matrices are independent and each writes its own region: thirteen seconds
became three for a one-gigabyte model. `inspect` reports the peak the copy
needs, which is the file and the copy at once, because both exist while the
second is written.

### A context that rolls

`--context-shift N` says what to do when the context fills: drop the oldest
N positions, slide the rest down, and carry on. It applies to a drafted run
as well, where both the model's context and the draft's are shifted together
-- a draft proposing from a context the model no longer has proposes badly,
which costs speed rather than correctness and would go unnoticed. `--context-keep N` says how
many at the front to leave in place -- the beginning-of-text marker, by
default. Without it a run that fills its context ends there, which is where
it ended before this existed.

The keys move with the text. A key was rotated for the position it was
written at, so each moved key is turned back by the angle those N positions
stand for; without that the cache would describe positions the text no longer
has, and a model reading it produces fluent text about nothing in particular
and no error at all. That identity -- turning back by N is rotating N
earlier -- is held at the kernel level for every pairing and every stretch,
because it is the one place the fault would be silent. Writing that test
found two wrong versions of it: one that applied the stretch's attenuation
twice and one that divided it out.

What a shift loses is more than the tokens it drops. The keys and values that
stay were computed while the dropped tokens were still there; moving them
renumbers their positions without recomputing them. So a rolling context is
an approximation of the same text read afresh, not an equivalent -- a good
one, which is why every runtime that offers this offers this, and still an
approximation. The exact alternative is to re-read what is kept, which costs
a prefill; neither happens on its own, because which one a run wants is the
caller's to say.

`--show-stats` reports how many times it happened.

### Batched prefill

A prompt is evaluated in batches: every token in a batch shares one pass over
the weights, and reading and decoding those weights is what a forward pass
spends its time on. `--batch-size` selects it, the engine caps it at 128
tokens, and a batch produces the same bits as the same tokens evaluated one at
a time — a test asserts exactly that, on the logits and on the cache left
behind, and another asserts it at the kernel level for every quantization
format.

`tests/fixtures/speed-prompt.txt` at the chosen worker count, `--raw`, which
makes it 110 tokens: 109 of prompt and the beginning-of-text marker.

There is no column of digests here any more, and the reason is worth writing
down. There used to be one, identical down every row, standing for the claim
that `--batch-size` is a performance control and must not change what the
model says. It was measured through a tool that read this file including its
final newline, and with that newline the model has something to say; without
it -- which is what the command does -- this model answers the prompt with
its end-of-sequence token and generates nothing at all. So the column would
now be the digest of the empty string eight times, which stands for nothing.
The claim it stood for is held by the conformance sweep instead, which
compares batched evaluation against a token at a time over every format,
every architecture and both evaluation paths.

```
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt.txt \
  --max-tokens 4 --batch-size N
```

| `--batch-size` | prompt evaluation | rate |
|---|---|---|
| 1 (one token at a time) | 12.24 s | 9.0 tokens/s |
| 2 | 9.20 s | 12.0 tokens/s |
| 4 | 7.71 s | 14.3 tokens/s |
| 8 | 7.02 s | 15.7 tokens/s |
| 16 | 6.25 s | 17.6 tokens/s |
| 32 (default) | 6.06 s | 18.2 tokens/s |
| 64 | 5.82 s | 18.9 tokens/s |
| 128 (cap) | 5.62 s | 19.6 tokens/s |

This table used to be measured through the chat template while the figure at
the top of the section was measured raw, and neither said which. That is
where its old caption's "131-token prompt" came from -- the file is 110
tokens and the template wraps it to 131 -- so a reader who took the command
printed above and pointed it at this prompt got numbers about a quarter
lower than the table and nothing to explain the gap. Both are raw now. The
templated numbers were 13.16 s down to 6.45 s across the same sweep; they
were not wrong, they were answering a question the caption did not ask.

Most of the benefit arrives by a batch of eight, and it flattens after
thirty-two. Batching amortizes the cost of decoding the weights across the
tokens that share them, so the faster the decode gets the less there is to
amortize: on the unoptimized build the same sweep spanned 3.7x, and here it
spans 2.0x. That is the batching working exactly as described, on a smaller
share of a much smaller total.

### Kernels

Row dot product, nanoseconds per element, release build, every format the
engine supports:

| Format | ns/element | Format | ns/element |
|---|---|---|---|
| F32 | 0.28 | Q3_K | 0.52 |
| Q4_0 | 0.33 | F16 | 0.59 |
| BF16 | 0.35 | Q2_K | 0.79 |
| Q4_K | 0.40 | IQ4_XS | 0.95 |
| Q6_K | 0.40 | Q5_0 | 1.10 |
| Q8_0 | 0.40 | Q5_1 | 1.14 |
| Q5_K | 0.44 | IQ4_NL | 1.44 |
| Q4_1 | 0.45 | | |

The two five-bit legacy formats are outliers, and the reason is where they
keep the fifth bit: bit *j* of a thirty-two bit word rather than a fixed place
in a byte already being read. The shift amount therefore varies with the
element, and an instruction set without a per-lane shift cannot vectorize that
loop. Baseline x86-64 has none, and building for a host that does measured
slower everywhere else.

The two non-linear formats are the other outliers, and for a different
reason: a nibble there is an index into a table of sixteen levels rather than
a number, so every element costs a load from that table at an address the
element decides. That is a gather, and it does not vectorize either. IQ4_XS
comes out faster than IQ4_NL despite doing more per element -- a sub-block
scale to form as well as the lookup -- because its block is 256 elements
against 32, so the per-block work is spread eight times thinner. The table is
what these formats buy their accuracy with, and this is what it costs.

Medians of three rounds, which `tests benchmark` now takes itself: it reports
the median of three half-second rounds per measurement, and `--rounds` and
`--seconds` change either. It used to report a single pass while every figure
it feeds was published as a median of three, and the last step was left to
whoever remembered it. That is not a rounding matter on a 15 W part -- the
same number came out 11136, 12574 and 12944 Me/s on three consecutive runs,
so a single pass read against a published median is worth about a tenth
either way, in whichever direction flatters or alarms.

What every measured figure in this section was taken
against is recorded in
[docs/measured-figures.txt](docs/measured-figures.txt), which names each group
of figures and the sources it depends on. `tests check` fails when those
sources change without the figures being taken again, and says which figures
those are -- this table came to be two to four times wrong once before, and
the checklist is a better place to remember than a person is.

The benchmark forces every block scale to a modest normal exponent before it
times anything. It used to fill its tensors with arbitrary bytes, and bytes
read as half precision are frequently denormal, infinite or not-a-number --
values no real model contains, and ones the processor is slow with. Figures
published before that was noticed were wrong and were replaced.

These agree with the end-to-end measurement. Evaluating the 131-token prompt
above at a batch of 128 takes about sixty seconds of processor time, and the
prompt puts 131 tokens through 1.10e9 parameters, which is 1.44e11 element
products, or about 0.42 ns each against the 0.38 measured here for the format
that model uses. That check is the reason to publish both.

The figures hold to about half a percent when repeated in one sitting and
drift much further between sittings, so a change is worth believing only when
the two versions were run against each other, alternating, in one of them.

The k-quant formats used to decode several times slower than the others, which
mattered because they are what most real models use. Three things fixed that,
in the order they mattered: a sub-block's scale and offset formed once instead
of once per element; the per-element checks suppressed after the block is
bounds-checked at entry; and packed bytes read directly rather than through a
call that read each one three times to decide its sign.

Q6_K needed a fourth, later. Its inner loop produced four elements per
iteration and wrote them thirty-two apart, so sixteen iterations touched four
separate places in the output; split into four runs that each read sixteen
adjacent bytes and write sixteen adjacent elements, the same arithmetic against
contiguous memory decodes four times faster.

Three things got them there.

**No profile reached the compiler.** Both project files set
`Compiler.Default_Switches` without including the generated configuration
project's switches, which silently discards them — so every profile compiled at
`-O0`, and `--release` changed nothing. Every sibling crate gets this right;
model_runner was the one that did not. Fixing it took twelve tokens from 14.0 s
to 2.18 s, and it means any measurement taken before the fix was comparing
unoptimized builds against each other.

**Vectorization, from ordinary Ada.** Nothing is written in assembly, in
intrinsics, or in a foreign language. What unlocked it was removing Ada's
per-element runtime checks from the innermost unpacking and accumulation loops:
each check is a call the optimizer must treat as touching memory, so it cannot
prove the iterations independent, and nothing vectorized with them in place.
The ranges are validated once per span instead, and `Accumulate_Dot` now checks
its input vectors itself rather than trusting its callers, which it did not do
before. That trade is written up in [SECURITY.md](SECURITY.md), because it is
the one place where a validation mistake would become memory unsafety rather
than a clean exception.

Results are bit-identical: the four accumulator chains are independent, so the
compiler packs them into vectors without reassociating anything. Conformance
against the independent reference implementation is unchanged to the last
digit, and generated text is byte-identical.

**No target-specific flags.** `-march=native` and `-march=x86-64-v3` were both
measured on a machine with AVX-512, alternating against the baseline build in
one sitting, and both are **slower**: the f32 row product loses 37 per cent and
Q8_0 14 per cent. Whatever the wider instructions buy, the code the compiler
generates around them costs more. Shipping `-mavx2`, or the runtime dispatch
needed to use it safely, would cost portability to buy a regression.

Reaching a specific instruction was tried as well, and the same answer came
back. GNAT will import a compiler builtin as an intrinsic against a vector
type, which is neither assembly nor a foreign language, and the processor's own
half-precision conversion widens eight values in one instruction. Wired into
the F16 decode it moved that kernel by about one per cent, because the
conversion was never what the loop was spending its time on: the compiler was
emitting a call per element to a conversion function in another unit, and an
`Inline` aspect on that function was worth 2.6x. Reading the generated code
found in an afternoon what three attempts at vector width did not.

The binary runs on any x86-64.

### Fusing the multiply into the decode, and unfusing it again

Q4_0 used to skip the decoded copy: its value is a block scale times a small
integer, so a block's contribution is the scale times the sum of integer times
input — one multiply by the scale per block instead of one per element, and one
rounding fewer per element. It was the only format that did, and it measured
faster that way when it was written.

It does not any more. Folding the scale out forces the sum to break at every
block, which costs the flat inner loop the other formats get, and that inner
loop has been improved since — the per-element checks lifted out, the packed
bytes read once, the half-precision conversion inlined. Measured now,
alternating, fusing costs Q4_0 **1.79 times**: 1746 against 3128 million
elements a second. Unfused it decodes at 0.31 ns an element, which makes it
the fastest format in the table above rather than the slowest.

So nothing is fused now, and the fused path is gone rather than left switched
off. Every format takes one route, and Q4_0 gained the rounding per element
that every other format already had. What is left of the idea is this section
and the note above `Accumulate_Dot`, because a measurement that reversed is
worth more written down than deleted: it did win once, and what changed was
not the arithmetic but everything around it.

`tests benchmark` measures the row kernels directly, on synthetic tensors, with
no model file and no network. The tests crate builds the library at the release
profile so that it measures what ships: at the development profile the same
kernels read three times slower, and tuning against those numbers would tune
the wrong compilation. It exists because reading the code produced two
confident wrong answers about where the time went.

It also measures parsing a metadata-heavy container, because loading is the
first thing a run spends time on and nothing was watching it. A change to the
reader cost a fifth of that path and the suite was entirely happy: every test
passed, and it took a throwaway measurement to notice.

That measurement is quoted against a memory copy timed in the same round, and
the cost against the copy is the figure to keep. An absolute rate is worth
little on its own: it moves with the machine, its load and its clock, so a
number from one host says nothing about a number from another, and comparing
across hosts is exactly what noticing a regression needs. Copying is what
parsing mostly is, so the two move together and dividing takes the machine
back out. Each round times the copy and the parse next to each other and the
best round is kept, which is what stops a busy half-second from being reported
as slow code.

It resolves a change of about a sixth from a single run. The reader change
above reads 820 to 900 times the cost of a copied byte, where the reader
before it read 700 to 760, and those do not overlap across five runs of each.
Anything smaller than that needs the comparison run several times.

This is still a scalar-source implementation compiled for a portable baseline,
and it is slower than a runtime built around hand-written vector code. It is
not trying to compete with one; it is trying to be a correct and readable one.

## License

MIT. See [LICENSE](LICENSE).
