# model_runner

Local GGUF language-model execution in Ada 2022.

`model_runner` loads a local GGUF model file, validates its container strictly,
prepares a bounded Llama-compatible decoder-only execution plan, tokenizes
prompts, evaluates the model on the CPU, maintains an explicit KV cache, samples
output tokens, decodes them incrementally and streams the generated text.

Inference is local only: no network access, no daemon, no Ollama, no llama.cpp,
no delegation to an external model runtime. The release checklist holds that
one: it reads every production source and fails on a socket API, a name
resolver, or an address to reach — and on process spawning, since a program
that can start another can reach whatever that one reaches. It is the promise
here that a reader cannot check by running the program, and the kind that would
otherwise arrive one convenient dependency at a time.

## Status

The engine and the command-line program work end to end. A list of what is
**not** implemented is at the bottom of this file; nothing here claims a
capability it does not have.

```
$ model_runner inspect tiny-model.gguf
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
  chat template           present and supported
Memory
  model weights           5024
  session at this context 5880

$ model_runner run tiny-model.gguf --raw --prompt "ab" --seed 42 --temperature 0 --max-tokens 6
 bcaaaa
```

## Commands

```
model_runner run MODEL       generate text from a model file
model_runner inspect MODEL   report what a model file contains
model_runner help [COMMAND]  show help for a command
model_runner version         show version information
```

The model path is explicit. No registry, short name, tag or manifest is
resolved.

Run `model_runner help run` for the full option list. Options are validated
with the same typed path as environment variables, repeated options are a usage
error, and `--` ends option processing.

### Streams

| Content | Destination |
| --- | --- |
| generated model text | standard output, byte for byte |
| help, version | standard output |
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
| Quantization | Reference decoders for F32, F16, Q4_0, Q8_0, Q4_K, Q5_K, Q6_K — decoded one block at a time, never a second full copy of the model |
| Kernels | Scalar reference add, multiply, scale, dot, RMS normalization, softmax, SiLU, rotary encoding, with `Wide_Real` accumulation for length-dependent reductions |
| Tokenizer | SentencePiece (`llama`) vocabulary: scores, token types, special tokens, byte fallback, greedy highest-score merge encoding, UTF-8-boundary-safe incremental decoding. A special-token identifier that is absent leaves the token unset; one that names no token refuses the model rather than being ignored |
| Chat templates | Bounded allowlisted engine: `for`, `if`/`elif`/`else`, `+`-joined output, `==`/`!=`/`and`/`or`/`not`, `loop.first`/`last`/`index`, whitespace control. Compiled and validated at load time; `set`, `macro`, `include`, filters, indexing and every function call are rejected |
| Llama profile | Metadata validation in which an absent optional key takes a default and a present-but-unusable one refuses the model, derived-width divisibility, rejection of mixture-of-experts / sliding-window / asymmetric key-value widths / unsupported rotary scaling, tensor resolution and shape validation, tied-output aliasing |
| Execution | Embedding lookup, per-layer RMS norm, Q/K/V projection, rotary encoding, grouped-query causal attention without duplicating key or value heads, output projection, SiLU-gated feed-forward, residuals, raw logits |
| KV cache and session | Explicit cache sized with checked arithmetic, transactional commit, state machine, reset preserving allocations, committed-prefix reuse |
| Sampling | Documented pipeline: vocabulary check, non-finite rejection, masks, repetition penalty, temperature, top-k, top-p, min-p, renormalize, select. Greedy is tie-broken to the lowest token and consumes no random state; xoshiro256++ seeded per session |
| Stops | End-of-sequence, stop tokens, stop strings matched across token boundaries with earliest-then-longest resolution and no leaked bytes |
| Generation | Prefill, decode loop, streaming to an output sink, eight completion reasons, statistics against a monotonic clock, bounded text retention |
| Conversation | Structured roles, bounded history, system-message replacement, turn rollback |
| CLI | `run`, `inspect`, `help`, `version`; typed command parsing separated from execution; end-of-options; repeated, conflicting and out-of-range option detection |
| Interactive | Committed structured history, template rendering per turn, prefix verification against the cache, `/exit` `/reset` `/help` `/settings` `/stats` `/context` `/system`, blank-line submission, no history written to disk. Needs a terminal on both standard input and standard output, whether it is chosen because no prompt was given or asked for with `--interactive` |
| Localization | Every application-authored string through `messages`; 148 diagnostic codes each with a catalog entry; English, a partial Danish translation that inherits per key, and a generated pseudo-locale; locale precedence with an emergency path that cannot recurse |
| Cancellation | An interrupt requests a clean cancellation rather than killing the process; observed between parser sections, tensors, layers and tokens, so a cancelled run releases everything and commits no cache position. The parser, preparation, the single-token pass and the batched pass are each held by a test; generation's own two checks stop the work a batch or a token earlier than the pass below would, which no test of the outcome can distinguish |
| Presentation | `terminal_styles` in the presentation layer only; per-destination automatic styling; severity always carried by a word as well as a colour; generated text never styled |
| CPU backend | Ada worker pool: a protected coordinator, reusable worker tasks, deterministic row partitioning, a single-job bounded queue, worker-failure propagation and clean shutdown. `--threads` selects the count; the result is bit-identical whatever it is |
| Tooling | `tests test`, `tests check`, `tests conformance`, `tests external-model`, `tests docs`, `tests fuzz`, `tests fixtures` — all Ada, all in the tests crate |
| Conformance | An independent reference transformer in the tests crate recomputes the forward pass in a different arithmetic, with its own float decoding, its own full key/value history and expanded rather than mapped attention heads. The engine agrees with it to within 1.3e-6 absolute on the fixture, against tolerances of 1e-4 absolute and 1e-3 relative |

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

I have not reduced that to a single verified command line, and would rather say
so than print one that does not work.

Two things are generated rather than committed, so a clone does not have them
until something makes them:

- **`config/`** holds the configuration project that Alire writes, and both
  project files import it. `alr build` creates it. Calling `gprbuild` directly
  in a fresh clone fails with `imported project file "config/..." not found`,
  which is what that means.
- **`tests/fixtures/tiny-model.gguf`** is written by `tests fixtures`. The test
  suite does not need it -- it builds the same model in memory -- but the
  command-line examples above do.

Development is the default profile here and in every sibling crate, on
purpose: `-Og` with the full validity checks, one profile across every root so
they share object files. Release is for a release -- and for anything you
intend to measure, because the difference is not small: twelve tokens on a 1.1B
model take 2.2 seconds at `--release` and around 14 at the default.

```
alr build --release                        # optimized, what to ship and measure
alr build                                  # debug: -Og, all validity checks
cd tests && ./bin/tests test               # the whole suite
cd tests && ./bin/tests check              # repository and layering checks
cd tests && ./bin/tests conformance        # engine vs independent reference
cd tests && ./bin/tests benchmark          # row kernels and parsing, synthetic
cd tests && ./bin/tests docs               # regenerate docs/error-codes.md
cd tests && ./bin/tests fuzz --seed 1 --cases 2000
cd tests && ./bin/tests fixtures           # write tests/fixtures/tiny-model.gguf
cd tests && ./bin/tests package .. .       # write model_runner-<version>.tar
cd tests && ./bin/tests external-model --model /path/to/your.gguf [--expect FILE]
```

The suite takes a second and a half. It took half a minute until compiling a
template stopped allocating twenty-six megabytes: an instruction carried its
operand and its condition inline, and the program is four thousand of them.

Every test is deterministic, offline, and needs no downloaded model. The
checklist holds both: no test source may name a socket, a resolver or an
address, and nothing in the repository may exceed a megabyte, which is what a
committed model would. What the suite covers:

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
  rotary width, an unsupported rotary scaling, a mixture-of-experts or
  sliding-window model, and an embedding tensor of the wrong shape. A prompt
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
  definite outcome rather than raised on; the conversation keeping its shape under the edits
  interactive mode makes: a system message landing first, replacing rather
  than accumulating, clearing without disturbing the rest, and a cancelled
  turn dropped from the end without going past the beginning; command
  parsing, fifteen distinct usage errors,
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

$ model_runner --locale qps run x.gguf --bogus
⟦model_runner: ⟦éŕŕóŕ⟧: MR-CLI-0003: ⟦úñkñówñ ópŧíóñ: --bogus⟧⟧
```

### Fuzzing

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
conformance: sequences 4, logits compared 64,
             worst absolute 3.93E-07, worst relative 1.96E-06,
             outside tolerance 0
```

Tolerance is 1e-3 relative with a 1e-4 absolute floor; the observed worst case
is three orders of magnitude inside it.

`tests external-model --model PATH [--expect FILE]` runs the same kind of
validation against a model you already have — container, architecture, session,
greedy generation, valid UTF-8, seed reproducibility and worker-count stability
— and, when given a recording from a trusted reference runtime, compares the
tokenization, the greedy token identifiers and any recorded logits against it.
Nothing is downloaded, and a missing file is a skip rather than a failure. See
[docs/reference-runtime.md](docs/reference-runtime.md).

```
$ tests external-model --model /nowhere/x.gguf
external-model: skipped (no model at /nowhere/x.gguf)

$ tests external-model --model tiny-model.gguf --prompt "ab" --threads 4
external-model: ok, architecture llama, 21 tensors, prompt 3 tokens,
                generated 5, deterministic TRUE, thread-stable TRUE
```

### Repository checks

`tests check` performs its checks in Ada: crate structure and declared
dependencies, the version in `alire.toml` against `Model_Runner.Version`,
absence of scripting-language build files, that production code never reaches
AUnit or `project_tools`, that nothing below the presentation layer reaches the
message catalog, terminal styling, the command-line layer or a standard stream,
the 120-character line budget, a catalog entry for every diagnostic code, and
that the generated error-code reference is current. The checks are
negative-tested: injecting a violation makes them fail.

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

- **`--backend`.** There is one backend and no way to select another, so the
  option is **not accepted** rather than accepted as a no-op.
- **Hand-written vector code or intrinsics.** The kernels are ordinary Ada and
  the compiler vectorizes them; nothing is written in assembly, in intrinsics,
  or in a foreign language. The release checklist holds this: a source in
  another language anywhere in the repository fails it, and so does any use of
  machine code. Binding to a host call through `Interfaces.C` is not writing in
  another language and is allowed, which is how `mmap` and `isatty` are
  reached. See below for what that does and does not buy.
- **Repacking.** Weights are consumed in the layout the file stores them in.

## Speed

All figures below are from the release build, on a Ryzen 7 7840U, against
TinyLlama-1.1B-Chat Q8_0. Generating twelve tokens with 14 threads takes
**2.18 s** wall and 16.0 s of processor time.

### Batched prefill

A prompt is evaluated in batches: every token in a batch shares one pass over
the weights, and reading and decoding those weights is what a forward pass
spends its time on. `--batch-size` selects it, the engine caps it at 128
tokens, and a batch produces the same bits as the same tokens evaluated one at
a time — a test asserts exactly that, on the logits and on the cache left
behind, and another asserts it at the kernel level for every quantization
format.

131-token prompt, 14 threads. The last column is a hash of the generated
text, which is the point: `--batch-size` is a performance control and must not
change what the model says.

| `--batch-size` | prompt evaluation | rate | output |
|---|---|---|---|
| 1 (one token at a time) | 12.43 s | 10.5 tokens/s | `e4b53a82d2838b20` |
| 2 | 10.05 s | 13.0 tokens/s | `e4b53a82d2838b20` |
| 4 | 8.49 s | 15.4 tokens/s | `e4b53a82d2838b20` |
| 8 | 7.75 s | 16.9 tokens/s | `e4b53a82d2838b20` |
| 16 | 7.33 s | 17.9 tokens/s | `e4b53a82d2838b20` |
| 32 (default) | 6.93 s | 18.9 tokens/s | `e4b53a82d2838b20` |
| 64 | 6.71 s | 19.5 tokens/s | `e4b53a82d2838b20` |
| 128 (cap) | 6.61 s | 19.8 tokens/s | `e4b53a82d2838b20` |

Most of the benefit arrives by a batch of eight, and it flattens after
thirty-two. Batching amortizes the cost of decoding the weights across the
tokens that share them, so the faster the decode gets the less there is to
amortize: on the unoptimized build the same sweep spanned 3.7x, and here it
spans 1.9x. That is the batching working exactly as described, on a smaller
share of a much smaller total.

### Kernels

Row dot product, nanoseconds per element, release build, every format the
engine supports:

| | | | |
|---|---|---|---|
| Q4_0 | 0.91 | Q5_K | 1.35 |
| Q8_0 | 1.02 | Q6_K | 1.37 |
| Q4_K | 1.11 | F32 | 1.59 |
| | | F16 | 1.79 |

Those figures replace lower ones published earlier, which were wrong. The
benchmark filled its tensors with arbitrary bytes, and bytes read as half
precision are frequently denormal, infinite or not-a-number -- values no real
model contains. It now forces every block scale to a modest normal exponent.
The corrected numbers agree with the end-to-end measurement, which implies
about 1.65 ns per element once attention, normalization and thread hand-off
are counted; the earlier ones never did, and that disagreement should have
been noticed sooner.

The k-quant formats used to sit between five and seven times slower than this,
which mattered because they are what most real models use. Three things fixed
that, in the order they mattered: a sub-block's scale and offset formed once
instead of once per element; the per-element checks suppressed after the block
is bounds-checked at entry; and packed bytes read directly rather than through
a call that read each one three times to decide its sign.

Three things got them there.

Three things got them there.

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

**No target-specific flags.** `-march=native` was measured on a machine with
AVX-512 and made no difference — these loops are limited by the
single-to-double conversions, not by vector width. Shipping `-mavx2`, or the
runtime dispatch needed to use it safely, would have bought nothing and cost
portability. The binary runs on any x86-64.

### Fusing the multiply into the decode

Q4_0 skips the decoded copy: its value is a block scale times a small integer,
so a block's contribution is the scale times the sum of integer times input —
one multiply by the scale per block instead of one per element, and one
rounding fewer per element.

Whether that wins is a per-format question, settled by measuring. Folding the
scale out forces the sum to break at every block, which costs the flat inner
loop the other formats get. It won clearly for Q4_0 and lost for Q8_0, whose
element is already a byte, and for F32, which has no scale to fold at all. The
k-quant formats carry a scale, and two of them an offset, for every sixteen or
thirty-two element sub-block — far more layout to read twice for a saving
spread over 256 elements rather than 32.

So only Q4_0 is fused. `Quantization.Fused_Formats` reports which formats take
which path; it is not otherwise observable, because one test checks every
format against the reference decoder and another checks that the number of
vectors in a call never changes any of them. Deliberately swapping the two
nibbles of the fused Q4_0 path fails the suite.

`tests benchmark` measures the row kernels directly, on synthetic tensors, with
no model file and no network. It exists because reading the code produced two
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
