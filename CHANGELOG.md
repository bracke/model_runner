# Changelog

All notable changes to model_runner are recorded here. The format follows
Keep a Changelog and the project uses semantic versioning.

## [Unreleased]

### Fixed

- The CPU backend said it does not batch, while every prefill went through
  its `Dispatch_Batch`. `Capabilities` is a table the code publishes about
  the code and nothing in the program consults it -- `Describe` has no caller
  outside the checklist -- so the two could disagree indefinitely without
  anything going wrong. It is now checked: the formats it claims must be the
  formats the decoder decodes, and the flags that name an operation must
  match whether the operation is there.

- The chat-template section of the support matrix is checked against the
  code. It was the last hand-maintained registry -- a table of claims beside
  the engine rather than about it -- and it said `set` and the filters were
  rejected for as long as they had been implemented.

  Every row now has a worked example carrying its label. The example is
  compiled and rendered, and where it ends must be the verdict the row gives.
  A row added without an example fails, an example left behind by a deleted
  row fails, a row that calls an implemented construct rejected fails, and so
  does a construct that stops working while its row still claims it.

  No check can invent a row for a construct somebody adds. What this one does
  is stop a row outliving what it says.

- The interactive loop is tested. Nothing drove it for as long as it existed:
  the driver refuses interactive mode unless both descriptors are terminals,
  so the loop could only be reached by hand, and everything it decides went
  unchecked. That is how a command word came to be compared with its argument
  still attached.

  What a line of input does to a turn is now a unit of its own -- accumulate,
  submit, refuse, or run a command -- and the loop itself runs over redirected
  input against a fixture model. A line is read into a fixed buffer rather
  than onto the stack, which the comment there said would be required if
  interactive mode ever accepted input that was not a terminal.

  Generated text is not what the loop test reads. It goes to standard output
  as raw bytes, past Text_IO and past any redirection this process can
  perform. The test asks the loop whether a turn completed instead, which is
  a question the program already answers.

- `/system` with no text removes the system message. It was matched as the
  eight characters `"/system "` -- with the space -- so a bare `/system` was
  not a command missing its argument but an unknown command, and a session
  had no way back to holding no system message at all: `--system` sets one
  before the first turn and `/system TEXT` replaces it, and nothing removed
  it. The conversation layer has removed one on an empty string all along;
  the interactive loop simply could not reach that.

  Reading a line as a command is now separate from acting on it, and tested.
  The loop needs a terminal at both ends and no test drives it, which is how
  the command word came to be compared with its argument still attached.

- The README said the engine decodes seven formats. It decodes thirteen: the
  row had not been touched since BF16, Q4_1, Q5_0, Q5_1, Q2_K and Q3_K were
  implemented. The support matrix still said the multiply was folded into the
  decode for Q4_0, after that had been measured 1.79 times slower and taken
  out -- a claim about performance that the source's own note contradicts.

  The release checklist now asks the code which formats it decodes, through
  `Is_Decodable`, and fails when the matrix or the README's quantization row
  does not name one. The README is checked against that row and not the whole
  file, because every one of the six missing formats was named somewhere else
  in it, and a check that reads the whole file would have passed.

- The support matrix said the tokenizer accepts `llama` and rejects
  everything else, which stopped being true when byte-pair encoding was
  implemented. A row further down the same file described its six cutting
  rules. A reader who trusted the table would have concluded their model was
  unsupported. It now names `gpt2` and every `tokenizer.ggml.pre` rule,
  including `llama-bpe`, which was written nowhere at all.

  The release checklist now reads those names out of the tokenizer and fails
  when the matrix does not carry one. Listing them in the check instead would
  be the same table again, going stale the same way, one file further from
  the code.

### Added

- Model preparation asks the backend, per tensor, whether it can read the
  format, and refuses the model with `MR-BACKEND-0002` naming the backend,
  the format and the tensor when it cannot. `--backend` reaches this too, so
  the choice decides what will load and not only what will run.

  No shipped configuration refuses anything: the one backend claims exactly
  the formats the decoder decodes. The point is the seam. `Capabilities` was
  a record the code published about the code that nothing read -- `Supports`
  had no caller anywhere -- and a description nobody consults is one that can
  be wrong for a year, which is what happened to `Supports_Batched`.

- `--backend NAME` names the backend to evaluate the model on. There is one,
  `cpu`, and the option exists anyway: a name this build does not have is
  refused by name and exits as the usage error it is, where before the option
  itself was unknown and a caller learned nothing about what was available.
  The names come from the backend enumeration, in the help as well as in the
  matching, so neither can list one that is not there. Running goes through
  the choice rather than around it, on a case with no `others`: a kind added
  to the enumeration stops the program compiling until something answers for
  it, which is the only way a second backend can arrive without the flag that
  selects it quietly doing nothing.

  `Backend_Unknown` was on the list of diagnostics this program declares and
  never produces, with the reason "there is no --backend to be invalid".

- The chat template a current Llama-3 file ships with now renders. It needed
  variable assignment, list slicing, comments, `is defined`, `none`, the
  `trim` and `length` filters, parenthesised conditions and `'x' in message`,
  all of which are now in the supported subset -- and it also needed
  `strftime_now`, `tojson` and `raise_exception`, which are not and will not
  be.

  The way both are true at once is where a construct is refused. A statement
  whose shape cannot be read is still refused at compile time, because
  nothing after it can be trusted to mean anything. A value that cannot be
  computed is now carried through compilation and refused at the point it is
  asked for. Every one of those templates describes tool calling in branches
  that a conversation of plain messages never enters, so refusing the
  template for them refused the model; refusing at the point of use refuses
  only what was actually asked for. Nothing is approximated either way, and
  a render that reaches one of them ends with `MR-TMPL-0002` naming the
  construct rather than producing a prompt that is nearly right.

  `--chat-template` stays, for the models this still cannot read.

- Template errors that name a variable or a filter now say which one.

- `MR-TMPL-0011` reports a template whose variables need more room than the
  render has for them. It was reported as the rendered prompt being too
  large, which is a true sentence about the wrong subject.

- `--chat-template NAME` uses a chat format this build carries -- `llama3` or
  `chatml` -- in place of the model's own. Some models ship a template that
  assigns variables, slices lists, calls functions and formats dates, most of
  it to describe tool calling, and interpreting that on text from a model file
  is a larger and more exposed thing than formatting a conversation. The
  reference implementation carries named formats for the same reason. Nothing
  is chosen on a model's behalf: a chat format applied to the wrong model
  produces output that looks entirely reasonable and is not what the model was
  trained on.

- Chat templates may name a message by position -- `messages[0]['role']` --
  which is how a template asks whether a conversation already opens with a
  system message before adding one. It was the only construct standing
  between this engine and the templates modern models ship.

- A marker such as `<|im_start|>` is encoded as the token it is rather than
  the dozen its spelling merges into. A template writes markers into the text
  it renders, and a model shown their letters answers in letters: it ended its
  turn by spelling the marker out instead of stopping.

- Q4_1, Q5_0 and Q5_1 tensors are decoded rather than refused. Q4_1 is a
  nibble with a scale and a minimum instead of a fixed bias; the two five-bit
  formats hold each element's fifth bit in a thirty-two bit word beside the
  nibbles, centring by sixteen or carrying a minimum. Each was checked against
  a model quantized to it, and each matches the reference runtime's greedy
  output exactly.

  The five-bit pair costs about two and a half times what the four-bit ones
  do, because the fifth bit for element j is bit j of a word, so the shift
  varies with the element and the loop will not vectorize without a per-lane
  shift instruction. The README says so where the figures are.

  Q8_1 and Q8_K stay refused. Neither is a way weights are stored: both are
  intermediates ggml builds inside its own dot products.

- Q3_K tensors are decoded rather than refused, at 0.48 nanoseconds an
  element. Three bits in two pieces: the low two packed four to a byte, the
  third in a mask shared by the whole block whose absence subtracts four, and
  sixteen six-bit sub-block scales packed across twelve bytes. With this and
  Q2_K, a model quantized to Q2_K by the usual mixed recipe -- F32, Q2_K,
  Q3_K, Q4_K and Q6_K together -- loads and generates, and its greedy output
  matches the reference runtime exactly.

- Q2_K tensors are decoded rather than refused. Two bits an element, sixteen
  sub-blocks of sixteen, each with a four-bit scale and a four-bit minimum
  sharing one byte, and the two half-precision factors at the end rather than
  the start. It is the slowest format in the table at 0.72 nanoseconds an
  element, which is what carrying sixteen sub-blocks per 256 elements costs.
  Verified against a model requantized to pure Q2_K, whose greedy output
  matches the reference runtime exactly.

- BF16 tensors are decoded rather than refused. A brain float is the top half
  of a binary32 -- same sign, same eight exponent bits, mantissa cut to seven
  -- so widening one is a shift with no bias to undo and no case for infinity
  or not-a-number, and it is the only format here that cannot round. Verified
  against a 2.2 GB model requantized to BF16, which agrees with the reference
  runtime on tokens, greedy output and text.

- Byte-pair tokenization, for vocabularies declaring the `gpt2` model. The
  merge table is read from the file and applied by rank, every byte is
  rewritten as the printable character that stands for it, and the text is cut
  into pieces first so that no merge joins one word to the next. Checked
  against `llama.cpp` on its own tokenizer fixtures: gpt-2, qwen2, falcon and
  starcoder agree exactly on twenty-one strings, llama-bpe agrees on the
  tokens and differs only by the beginning-of-text marker it adds.

  Any script, not only ASCII: a letter is told from a symbol by its Unicode
  category, which the standard library knows, so a CJK ideograph cuts as a
  letter and a CJK comma does not. Twenty-seven strings across Latin,
  Cyrillic, Greek, CJK, emoji and punctuation agree with the reference.

  What is refused is a vocabulary naming a cutting rule this does not
  implement. The later rules let any single character that is neither letter
  nor digit lead a word, where the original lets only a space, so a tab
  between two words is three pieces under one rule and two under the other.
  Six rules are implemented and verified against the reference on
  fifty-six strings: `gpt-2`, `falcon`, `starcoder`, `smollm`, `llama3` and
  `qwen2`.
  They differ in what may lead a run -- a space under the first, any
  non-letter under the last two, nothing at all before digits there -- and in
  how digits group: without limit, in threes, or one at a time. A vocabulary
  naming a rule that is not among these is refused by name.

- `tests tokenize --model PATH --prompt TEXT` prints the identifiers a
  vocabulary produces, which is what makes this comparable with another
  implementation.

- Frequency and presence penalties, as `--frequency-penalty` and
  `--presence-penalty`. Both act on the same recent-token window as the
  repetition penalty and compose with it. Frequency is subtracted once for
  every occurrence of a token in the window, presence once for a token that
  occurs at all; a negative value is accepted and encourages repetition, and a
  magnitude large enough to make every logit in the window infinite is
  refused. Neither applies to greedy selection, which no penalty does.

- A benchmark for the vector kernels each token passes through -- softmax,
  normalization, the activation and the plain dot product -- which nothing had
  been measuring, and one for how the matrix product scales across shares,
  counted against its own serial rate.

- Benchmark rows for decoding f16 and q4_k without a dot product on top.
  Separating decode from the product is what located the half-precision
  defect below; the row product hid it.

- `Model_Runner.Platform.Core_Count`, and a body per host behind it, so the
  worker default can follow cores rather than processors. Linux reads the
  topology the kernel publishes and macOS asks sysctl; a host that cannot say
  returns the processor count rather than guessing.

- A reference recording for a Q4_K_M model, which carries Q4_K, Q6_K and F32
  tensors together and is read per tensor. Every recording before it was of a
  file whose tensors were all one type.

- A sweep over all 65 536 half-precision bit patterns, compared against the
  format's definition computed in binary64 rather than against another bit
  trick.

- Element-wise reference decoders for BF16, Q4_1, Q5_0, Q5_1, Q2_K and Q3_K,
  comparing every element of a block of arbitrary bytes against a reading that
  starts from the element rather than walking the block. The hand-built blocks
  those formats also carry are worth less than they look: the three-bit one
  passed four wrong decoders before its values were chosen so that a wrong
  answer differs from a right one.

- Element-wise reference decoders for the four-bit, five-bit and six-bit block
  formats, comparing all 256 elements of a block of arbitrary bytes against a
  reading that starts from an element index and asks where its bits are.

- A test that a malformed request is refused by the range procedures rather
  than raising, which is what makes the failure handlers in the pool a net and
  not a path.

- The render step bound is a field in the model limits rather than a constant
  in the engine, so a caller rendering untrusted templates can tighten it.

- Release checks that no source in another language and no machine code enters
  the repository, and a test that `--backend` is refused rather than ignored.

- The fuzzing campaign reports how many mutated files prepared a model and ran
  a forward pass, and fails if none did.

- The container fuzzer now renders every accepted container the way `inspect`
  does and requires that nothing a terminal would act on comes back, and it
  writes control bytes into the image on purpose so that the case arises.

- A differential test for UTF-8 validation: every string of up to three bytes,
  compared against the standard's table of well-formed sequences written out
  separately.

- A release check that nothing in the repository is large enough to be a model.

- A release check that no unit interpreting a model's contents can reach a
  file, a stream, a directory, the environment or the command line.

- A release check that the environment surface is the one the README lists,
  and that only two files read it at all.

- A benchmark for parsing a metadata-heavy container, alongside the row
  kernels. Loading is the first thing a run spends time on and nothing was
  measuring it. Reported as a cost against a memory copy timed in the same
  round, so that one run on one machine can be compared with another.

- A differential test for stop-string matching: the earliest-then-longest rule
  written out the slow, obvious way in the test and compared against the
  engine's single-pass matcher over generated sets and buffers.


- A property test over the chat-template engine: two thousand generated
  templates, built balanced so that most compile, one in four then broken, and
  rendered against conversations of varying shape into buffers small enough to
  overrun. It holds that neither compiling nor rendering raises, and that a
  failed render reports writing nothing.


- A property test over the command-line parser: four thousand generated
  argument vectors, each derived from its case number so a failure replays,
  asserting only what the parser owes every caller -- that it returns with a
  definite outcome and does not raise. The hand-written cases check which
  outcome; this checks that there is one for vectors nobody thought to write.


- Tests for the chat template engine's bounds: template size, instruction
  count, nesting depth at and past the documented limit, output size at and
  past the buffer, and the iteration bound. The engine already refused
  malformed and unsupported templates, and a test covered that; what none
  covered was the five numeric bounds, and the refusal codes were checked
  only for being errors rather than for being the documented ones.

- Checked 64-bit arithmetic with overflow propagation.
- UTF-8 validation and boundary-safe incremental prefix length.
- Structured errors: 14 domains, stable `MR-DOMAIN-NNNN` codes derived
  mechanically from the code enumeration, typed parameters, and centralized
  exit-status mapping.
- Explicit model and session resource limits.
- Random-access byte sources: in-memory, file-backed, and POSIX read-only
  memory mapping with automatic, required and disabled policies.
- GGUF container parsing and structural validation for versions 2 and 3.
- Typed metadata accessors separating missing, mistyped and out-of-range keys.
- Read-only tensor views with one documented dimension convention.
- Reference decoders for F32, F16, Q4_0, Q8_0, Q4_K, Q5_K and Q6_K.
- Scalar reference kernels with documented accumulation formats.
- SentencePiece tokenizer with byte fallback and an incremental decoder.
- Llama-compatible architecture validation, tensor resolution and preparation.
- Transactional KV cache, session state machine and single-token forward pass.
- Memory accounting and overflow-safe model and session plans.
- AUnit suites for the GGUF container and for inference, all offline.

- Sampling pipeline: greedy, temperature, top-k, top-p, minimum-p, repetition
  penalty, forbidden-token masks, and a session-local xoshiro256++ generator.
- Stop tokens and stop strings, matched across token boundaries with
  earliest-then-longest resolution.
- Bounded allowlisted chat-template engine, compiled and validated at load time.
- Structured conversation history with system-message replacement and turn
  rollback.
- Generation coordinator: prefill, decode loop, streaming to an output sink,
  eight completion reasons, statistics against a monotonic clock, committed
  prefix reuse.
- Commands `run`, `inspect`, `help` and `version`, with typed parsing separated
  from execution.
- Interactive conversation with committed history, per-turn template rendering,
  cache-prefix verification and the stable `/` command set.
- Localization through `messages`, with a catalog entry for all 149 diagnostic
  codes and an emergency path that cannot recurse.
- Terminal presentation through `terminal_styles`, confined to the presentation
  layer, with per-destination automatic styling.
- A deterministic offline test suite and a `tests fixtures` command.

- CPU backend with an Ada worker pool: protected coordinator, reusable worker
  tasks, deterministic partitioning, bounded queue, failure propagation and
  clean shutdown, selected with `--threads`.
- `tests fuzz`, a reproducible GGUF mutation campaign.
- `tests check`: repository, dependency-boundary and layering checks.
- `tests docs`, generating `docs/error-codes.md` from the error registry.
- Interrupt-driven cancellation: SIGINT requests a clean cancellation instead of
  terminating the process mid-token.
- A partial Danish locale and a generated pseudo-locale, with per-key fallback.
- `Reference_Transformer`, an independent implementation of the forward pass in
  the tests crate, and `tests conformance` comparing the engine against it.
- `tests external-model`, validating a user-supplied model without downloading
  anything; a missing file is a skip.
- A recording format for values produced by a trusted reference runtime, with
  required provenance, and `--expect` to compare against it.

- `tests benchmark` measures the row kernels on synthetic tensors, with no
  model file and no network. It was written because reading the code produced
  two confident wrong answers about where the time went.

- `tests package` assembles the distributable archive: the executable, the
  message catalog it looks for beside itself, and the documents that say what
  the program is and what it does not do. The layout inside is the layout
  `alr install` writes, so unpacking it over a prefix gives a working
  installation -- verified by unpacking and running it from the filesystem
  root, where it resolves its catalog and renders Danish.
- The archive sets the executable's mode rather than taking tarlib's default,
  which is 0644 for every regular file. An archive whose program unpacks
  without the execute bit is not a distribution, and that failure would appear
  on someone else's machine rather than here.
- It refuses rather than guesses: every input is checked before anything is
  written, so a missing file names itself and leaves no half-made archive.
  Nothing is built and nothing is fetched.
- `inspect --metadata` shows each entry's type and value, not just its key.
  Strings are escaped and shortened on a code-point boundary, with an explicit
  mark, so a prefix is never mistaken for the whole and no invalid UTF-8
  reaches the terminal. Arrays are described rather than dumped: a tokenizer
  vocabulary is a metadata array of tens of thousands of strings, and nobody
  asking to see the metadata asked for that.
- Windows memory mapping, over CreateFileMapping and MapViewOfFile. The
  platform-specific bodies now sit one per host under `src/platform`, chosen by
  the project file the way hostkit chooses its own, with a body for hosts
  covered by neither that reports mapping unavailable rather than pretending.
  Read-only throughout: the file is opened for reading, shared for reading and
  mapped for reading, so the model cannot be modified through it.
- `hostkit` is a dependency, for the things that exist only because operating
  systems differ. `Platform.Host_Name` asks it which host this is, and
  `Executable_Directory` asks it where the running program is rather than
  reading `/proc/self/exe` directly -- that is Linux and not even macOS, so on
  every other host the installed layout could not be found and the catalog
  silently fell back. `Hostkit.Host.Executable_Path` was added upstream for
  this.

- Memory accounting and the monotonic clock had no tests at all. Seven now
  cover them: an allocation past the budget refused before any allocator runs,
  totals following allocation and release, a peak that does not fall when
  memory is freed and reallocated, mapped bytes counted apart from allocated
  ones, a plan that cannot be represented refused rather than wrapped, a plan
  totalling what will actually be resident, a clock that goes backwards
  yielding no duration, and a rate over no elapsed time reading zero rather
  than infinite.
- `tests conformance` runs on quantized weights as well as binary32: eight
  sequences and 128 logits rather than four and 64. Nothing offline had
  compared quantized inference against an independent implementation before;
  the only check on it was two tokens recorded from another runtime, against a
  model that is not committed. `Reference_Transformer` gained its own Q8_0
  decoder, working the half-precision scale out from its sign, exponent and
  mantissa rather than reusing the engine's conversion, so a fault there cannot
  hide by being made twice. Shifting the engine's Q8_0 decode by one element
  puts 64 logits outside tolerance.
- `Fixtures.Encode_Q8_0` quantizes to blocks the way the format's producers do,
  and the fixture widens to thirty-two and sixty-four when quantized, because a
  quantized row is a whole number of thirty-two element blocks and the narrow
  model cannot hold one.

### Performance

- Q4_0 decodes 1.79 times faster, and is now the fastest format rather than
  the slowest: 0.31 nanoseconds an element against 0.57. It was the one format
  whose multiply was folded into its decode, which measured faster when it was
  written and measures slower now that the loop it competes with has been
  improved. The fused path is removed rather than switched off, so every
  format takes one route.

- Brain floats decode 3.9 times faster than they first did, at 0.32
  nanoseconds an element, which puts them second in the table. Decoding one is
  a shift and a reinterpretation, and the reinterpretation was a call across a
  unit boundary until it was inlined.

- Six-bit blocks decode about four times faster. The inner loop produced four
  elements per iteration and wrote them thirty-two apart; split into four runs
  that each read sixteen adjacent bytes and write sixteen adjacent elements,
  the same arithmetic runs against contiguous memory.

- Half precision decodes about 2.6 times faster, and the row product about the
  same. The conversion was being called once per element across a unit
  boundary; it is inlined now, and computes without branching.

- Softmax is about a third faster. Its finiteness test was a call per element
  for the same reason.

- A binary32 weight is read as a binary32 where the byte order and alignment
  allow it, rather than assembled a byte at a time.

- The task that submits a matrix product takes a share of it instead of
  waiting for the workers. With one worker per core the waiting task was one
  more runnable task than there were cores, and a job is not finished until
  its slowest share is. Pinned to one processor per core, eight shares went
  from 9326 to 14132 Me/s; unpinned and end to end it is about six per cent.

All figures are from the release build, on a Ryzen 7 7840U, against
TinyLlama-1.1B-Chat Q8_0. Generating twelve tokens with 14 threads takes 2.18 s
wall and 16.0 s of processor time.

- **No build profile reached the compiler.** Both project files set
  `Compiler.Default_Switches` without including the switches from the generated
  configuration project, which silently discards them: every profile compiled
  at `-O0`, and `--release` changed nothing. Every sibling crate includes them;
  model_runner was the one that did not. Fixing it took twelve tokens from
  14.0 s to 2.18 s, and means any measurement taken before the fix compared
  unoptimized builds against each other.
- `[build-profiles] "*" = "development"` stays, as in every sibling: one
  profile across every root so they share object files, and `-Og` with full
  validity checks is what development should build. Release is for a release.
- `tests.gpr` did not reference its own configuration project at all, and used
  one object directory for every profile, so objects built at one optimization
  level could be linked into a binary built at another. Both fixed.
- Batched prefill. A prompt is evaluated in batches rather than one token at a
  time, so every token in a batch shares one pass over the weights.
  `--batch-size` selects it and the engine caps it at 128 tokens. On a
  131-token prompt with 14 threads, prompt evaluation went from 12.91 s at a
  batch of one to 6.58 s at a batch of 128.
- A batch is exact, not an approximation: each token produces the same bits it
  produces alone, and leaves the same key-value cache. `Mat_Vec_Range` is the
  batched kernel with one input vector, so the two cannot drift apart. One test
  asserts the equality end to end, on the logits and on the cache; another
  asserts it at the kernel level for every quantization format, because the
  synthetic fixture is entirely F32 and could not have caught a divergence in a
  quantized one.
- The kernels are vectorized by the compiler, from ordinary Ada. Nothing is
  written in assembly, in intrinsics or in a foreign language. What unlocked it
  was removing Ada's per-element runtime checks from the innermost unpacking
  and accumulation loops: each check is a call the optimizer must treat as
  touching memory, so it cannot prove the iterations independent, and nothing
  vectorized with them in place. The ranges are validated once per span
  instead, and `Accumulate_Dot` now checks its input vectors itself rather than
  relying on its callers, which it did not do before. The trade is documented
  in SECURITY.md.
- Results are bit-identical. The four accumulator chains are independent, so
  the compiler packs them into vectors without reassociating anything:
  conformance against the independent reference implementation is unchanged to
  the last digit, and generated text is byte-identical.
- No target-specific flags are used. `-march=native` was measured on a machine
  with AVX-512 and made no difference: these loops are limited by the
  single-to-double conversions, not by vector width.
- The multiply is folded into the decode for Q4_0, whose value is a block scale
  times a small integer, so a block's contribution is the scale times the sum
  of integer times input. Applied per format on measurement, not on principle:
  it lost for Q8_0, whose element is already a byte, and for F32, which has no
  scale to fold. `Quantization.Fused_Formats` reports which formats take which
  path, and a test checks the fused kernel against the reference decoder for
  every format.
- Quantized weights are decoded a span of blocks at a time instead of a block
  at a time, with the format decided once per span. A Q8_0 block is thirty-two
  elements, so the per-block decision, its bounds check and the call around it
  cost more than the arithmetic they guarded; F32, whose block is a single
  element, paid that cost for every float.
- The row dot product keeps four running sums rather than one, so products no
  longer wait on the previous addition to retire. They are combined in a fixed
  order, so results stay reproducible.
- `Decode_Block` no longer zeroes its whole 256-element buffer on every call.
- The k-quant decoders were six times slower per element than the formats
  unpacked inline. A sub-block's scale and offset are now formed once rather
  than once per element -- they were four multiplies and four conversions per
  element that never changed within the sub-block -- packed bytes are read
  directly instead of through a call, and the per-element checks are suppressed
  after the block is bounds-checked at entry. Q4_K went from 6.68 ns to 1.12 ns
  per element; Q5_K and Q6_K have the same three changes.
- The k-quant path also decoded into a scratch block and copied 256 elements
  out of it. It decodes into the destination now, though measurement showed
  the copy was not what made it slow.
- Q6_K formed its four sub-block scales for every element rather than once per
  half, and Signed read each byte three times to decide its sign. Both fixed:
  Q6_K went from 2.24 ns to 1.37 ns per element, and every caller of Signed
  gained from the second.
- Row dot per element, release build, every supported format: Q4_0 0.91 ns,
  Q8_0 1.02, Q4_K 1.11, Q5_K 1.35, Q6_K 1.37, F32 1.59, F16 1.79. The
  benchmark now measures all seven rather than four, which is how the k-quant
  gap was found in the first place. These replace lower figures published earlier, which were
  measured on tensors filled with arbitrary bytes: read as half precision those
  are frequently denormal, infinite or not-a-number, which no real model
  contains. The benchmark now forces every block scale to a normal exponent,
  and the corrected numbers agree with the end-to-end timing where the earlier
  ones did not.

### Changed

- Q4_0 rounds each weight to single precision on the way past, as every other
  format already did. Folding its scale into the sum avoided that rounding and
  is no longer worth what it costs. Results for Q4_0 models change in the last
  bits.

- The default worker count follows the number of cores rather than the number
  of processors, and asks for one fewer than that because the submitting task
  takes the last share. On an eight-core machine reporting sixteen
  processors, twelve tokens took the same wall time for 14.6 s of processor
  time instead of 27.4 s. `--threads` overrides it as before.

- A test replays the transcripts the README publishes and compares them with
  what the program prints: the inspection of the committed fixture, the two
  locale examples, which are held to showing every line the program wrote and
  not merely lines it wrote, and the three external-model runs, whose wrapped
  summaries are joined and required back exactly.

- The external-model summary line is formatted in one place, `Summary`, rather
  than at the point it is printed, so that the published copy of it cannot
  agree with a second copy while disagreeing with the runner.

- `tests check` fails when the sources behind a published performance figure
  change without the figure being measured again. The figures cannot be
  checked by value -- they move between runs and further between machines --
  so what is checked is a fingerprint of the sources each group depends on,
  recorded in `docs/measured-figures.txt`.

- `tests conformance` checks that the README still quotes the numbers it
  prints, and fails the release checklist when it does not. The counts there
  had drifted to 4 and 64 while the run had grown to 8 and 128, and the worst
  divergence was published six times smaller than it had become.

- The speed figures in the README are quoted at the worker count the program
  chooses rather than at fourteen threads, which is more than this machine can
  use and is no longer what it picks. The batch-size sweep is re-measured at
  that setting and its prompt is committed, so the table can be reproduced
  rather than believed.

- Kernel figures in the README are re-measured and were between two and four
  times too slow. The support matrix names the README as their only home,
  which makes keeping them current a duty rather than a courtesy.

- Both the README and the support matrix said `-march=native` measured no
  difference. It measures 37 per cent slower for the f32 row product and 14
  per cent for Q8_0. The conclusion drawn from it was right; the reason given
  was not.

- The benchmark says what its numbers are worth: comparable within one sitting
  and not across two, since the same binary has reported 785 and 598 Me/s for
  one kernel hours apart.

- Paths are built through `hostkit` rather than by concatenating a separator
  here, and the directory holding the executable is asked of it rather than
  derived from the executable's path. What goes between two path segments is
  the host's business: Windows writes a backslash and accepts both, so a path
  built with the wrong one works through every file call and shows itself only
  when someone reads it.


- Terminal detection is asked of `hostkit` rather than by importing `isatty`
  here. That C name is spelled `_isatty` on Windows, where the console is
  asked about through `GetConsoleMode` instead, so the import was a POSIX
  assumption that looked portable. `hostkit` keeps one body per host and this
  crate keeps none for it.


- `docs/error-codes.md` marks every code raised or reserved. Thirty-six of the
  148 are declared, carry a message in every locale and are raised nowhere;
  read as a reference the document promised diagnostics the program cannot
  emit. The list lives in one place, the repository checks verify it against
  the sources, and the document renders it, so the three cannot disagree.

- `tests fuzz` now drives the whole load path rather than stopping at the
  parser: a mutated container goes through the parser, the tokenizer, the
  chat-template compiler and model preparation. The campaign's own contract
  names an invalid model reaching an executable state as a failure, and
  preparation is the gate that decides it, so the campaign stopped short of the
  thing it said it checked. The template compiler had never been driven by a
  mutated template at all, which is the most program-like thing a model file
  carries. A case now costs about ten times what it did; the case count is the
  knob.

- A fuzz case that runs past five seconds is reported and fails the run. The
  contract already said a wall-clock bound caught a loop that failed to
  terminate, and there was no clock anywhere in the fuzzer. A stage that never
  returns at all still cannot be interrupted from the single task a run uses,
  and the contract now says so instead of claiming otherwise.

- Architecture metadata that is present and wrong now stops preparation
  instead of falling back to a default. `attention.head_count_kv`,
  `rope.dimension_count`, `rope.freq_base`, `rope.scaling.factor`,
  `attention.layer_norm_rms_epsilon` and the key and value widths are all
  optional, and an absent one still takes the default -- not every model states
  its rotary width. One that is present and names a value the profile cannot
  use built a model of a different shape than the file described and said
  nothing about it. The key and value widths mattered most: an unreadable one
  skipped the asymmetric-width comparison, which is the check that exists to
  catch exactly that file.

- A tokenizer special-token identifier that is present but names no token now
  refuses the model instead of being ignored, as does a present-but-mistyped
  `add_bos_token` or `add_eos_token`. A missing key still leaves the identifier
  unset, because not every model declares every special token, and `-1` is
  accepted as an explicit absence. Previously all three cases were treated
  alike, so a file declaring token 999999 tokenized as though it had declared
  nothing: the prompt the model saw changed and nothing said so. The container
  accessors have always separated missing from mistyped from out-of-range; the
  tokenizer was discarding that distinction.

### Fixed

- A beginning-of-text marker is added only when the vocabulary asks for one,
  and a mandatory test holds it: two fixtures differing in that one
  declaration, the same prompt through the command line, and the token counts
  must differ by exactly one.
  A request could ask for one and get it regardless, so every model declaring
  that it wants none was fed a sequence no other implementation would produce.
  On such a model it moved a logit by nearly two -- against the hundredths
  that separate two honest implementations -- and ended generation after two
  tokens where the reference ran on. With it fixed the two agree token for
  token.

- Byte-pair output is decoded back to bytes. A vocabulary of that kind writes
  its token text in stand-in characters, one per byte, and the decoder was
  passing them through, so a model's output arrived as those stand-ins -- a
  space reading as the character that stands for one. Encoding, generation and
  the tokens themselves were right; only the way back was wrong, and no
  vocabulary-only fixture could show it because none of them generate.

- A container with no tensors is read rather than refused as truncated. Such a
  file ends at its metadata, and the reader required room for the padding that
  would precede a data section which is not there. Every vocabulary-only
  container was rejected, which is every file a tokenizer would be tested
  against.

- A truncated model file says what is wrong instead of printing the name of
  the message that would have said it. The message reads "ends inside a field
  at offset {offset}" and the reader recorded the offset as technical context
  rather than as a value the message could name, so the catalog could not
  render it and fell back to `<error.gguf.truncated>`. That is the commonest
  way a model file is wrong.

- The external-model runner reports the code a refused generation was refused
  with, instead of "generation failed" and nothing else. The README published
  an invocation of it that cannot succeed -- the committed fixture holds
  sixteen tokens of context and the runner asks for sixteen by default -- and
  the message said nothing worth chasing, so nobody chased it. The example is
  corrected and a test holds the reporting.

- `Model_Runner.CLI` described the command-line interface, the sampler, the
  generation coordinator, the template engine and the presentation layer as
  not implemented. All of them work. The rule against describing planned work
  as finished cuts both ways.

- The processor-time figure published for a twelve-token run was wrong when it
  was written. Building the commit that published it and running it again
  gives the same number this build gives, so nothing had regressed.

- The rest of the metadata parsing slowdown is gone. A run within the copy
  bound is read into a buffer and placed, and a string's encoding is checked
  from that buffer rather than from the pool.

- A container declaring a length or count above `Long_Long_Integer'Last` was
  refused correctly and then raised while saying so, because the diagnostic
  carried the number as a signed value. The value saturates now.

- Reading a float a file supplied no longer raises under validity checking in
  the development build. A not-a-number is possible input, and the finiteness
  guards are what refuse it; the checks fired first and reported the program
  as having a defect in itself.

- A chat template with a second `else`, or an `elif` after an `else`, crashed
  the compiler into an internal invariant violation instead of being refused.
  Both close a branch that has already been closed, and the code that patches
  the pending jump indexed instruction zero.

- Compiling a chat template no longer allocates twenty-six megabytes. An
  instruction named its operand and condition rather than carrying them, so a
  compiled program is about a hundred kilobytes and the tables holding the
  rest are as long as the template needs.

- Most of the metadata parsing slowdown introduced with the truncation fix is
  gone: a run within the copy bound is read into a buffer and placed, rather
  than written through a slice of the pool.

- Message text from the catalog is escaped before it is returned. Values
  substituted into a message were escaped because they come from a model file;
  the message itself was not, so a replaced catalog could send an escape
  sequence to the terminal.

- The environment table in the README now lists `LC_ALL` and `LANG`, which the
  program reads to choose a locale and which it did not mention.

- A container no longer sizes storage from a length it has not read. A file
  could declare a metadata array of four million elements, or a string of
  eight megabytes, and the reader would create storage of that size before
  reading a single byte of it -- so a file of a hundred bytes was enough to
  exhaust the stack. The failure surfaced as an internal invariant violation,
  which is the diagnostic reserved for a defect in the program rather than a
  fault in the file, and it was accurate: this was one. Runs of both kinds are
  now checked against the end of the file first and copied in fixed-size
  pieces, and such a file is refused as truncated.

- Long metadata strings are now checked for well-formed UTF-8 a window at a
  time rather than as one object, since the string limit allows sixteen
  megabytes. A code point lying across a window edge is judged whole.

- A byte source no longer zeroes the caller's buffer before filling it, only
  on the paths that return without filling it. Zeroing first writes every byte
  twice, which a caller reading straight into a large buffer pays for the
  whole of it.

- The host locale is asked of `hostkit` when the environment does not answer.
  Reading only `LC_ALL` and `LANG` is a POSIX convention: neither is set on
  Windows, so a Windows user's own locale was never looked for and the program
  always fell through to English. The environment still wins where it is set,
  because a variable somebody set is a statement about what they want.


- Sampling raised instead of reporting when the transformations it applies
  overflowed. The logits are checked for being finite when they arrive, but a
  large finite logit divided by a small temperature, or multiplied by a
  repetition penalty below one, produces a value that is not finite, and
  storing it trapped. It is now reported as a non-finite logit, which is what
  the same condition on arrival has always been. Found by a property test over
  generated configurations, on its first run.


- A directory given to `--prompt-file` was reported as unreadable rather than
  as not a file, which sends the reader to inspect a file that is not the
  problem. The model file reader has always made that distinction; the prompt
  file reader now does too.

- Three more diagnostics that were declared and never produced now are. A
  tokenizer score or token-type table that is present but does not match the
  vocabulary is refused rather than silently dropped -- scores decide which
  merge wins, so a short table tokenized the same text differently and said
  nothing. A chat template using a filter is reported as using a filter
  instead of as an unsupported expression. And a `MODEL_RUNNER_COLOR` set to
  something the program has no name for is refused, as `--color=bogus` always
  was: the same value should not be an error on the command line and ignored
  in the environment.

- `--interactive` no longer starts a session without a terminal to hold it.
  Interactive mode chosen implicitly, when no prompt source was given, was
  already conditional on standard input and standard output both being
  terminals; asked for by name it was not checked at all, so a redirected
  session drew prompts nobody saw and consumed a file as though someone were
  typing it. It now reports `MR-CLI-0019`, which was declared and catalogued
  from the start with nothing producing it.

- An option that takes no value accepted one and dropped it. `--verbose=5`,
  `--raw=yes` and eleven others parsed as though the value had not been
  written, so a mistake in a command line was silently ignored rather than
  reported. All thirteen now refuse, under `MR-CLI-0005`, which was declared
  and catalogued from the start with nothing producing it.

- A verbose run printed its last progress line twice: the last token produced
  and the end of generation carried identical wording, so the reader saw a
  stutter rather than two things happening. The completion line now says so.

- A verbose run with more than one worker hung, about two runs in three. The
  seed is an unsigned 64-bit value and the whole range is generated, but the
  statistics converted it to a signed type to print it, which raises for every
  seed above `Long_Long_Integer'Last`. With one worker the run ended as an
  internal failure; with several, the exception left the block holding the
  worker pool before the workers had been told to stop, and leaving that block
  waits for them to terminate, so the program stopped responding instead of
  reporting anything. Measured at thirteen hangs in twenty runs before the fix
  and none in twenty-five after.

  Three things were wrong and all three are fixed: the seed is formatted
  through a new unsigned image, the pool is closed before an exception leaves
  its block so a failure is reported rather than hung, and `--seed` now parses
  the whole unsigned range. That last one was its own defect: a run whose seed
  came from the upper half of the range could not be reproduced, which is what
  the option is for. Interactive mode's `/settings` had the same conversion.

- A prompt read from standard input was read without a bound. Input that was
  one very long line was placed on the stack in a single piece, and the
  resulting `Storage_Error` was reported as `MR-IO-0002`, a failure to read;
  the same volume of text as short lines ended as `MR-INTERNAL-0002`, an
  internal failure. Neither said that the prompt was simply too large. The
  reader now fills a bounded buffer, refuses input past the limit rather than
  shortening it silently, and reports the new `MR-IO-0009`. Standard input is
  the one prompt source whose size is not known in advance, and it was the one
  that did not check.

- Diagnostics about standard input rendered as bare message keys, such as
  `<error.io.read_failed>`, telling the reader nothing. The messages are
  written for files and ask for a path, standard input has none, and a message
  whose argument is missing falls back to naming itself. Those diagnostics now
  pass the localized name for standard input and read as sentences.

- Prompt reading and diagnostics now use the current input and current error
  files rather than the standard ones. They are the same files unless a
  program redirects them, which this one does not, so behaviour is unchanged;
  it is what allows a test to supply input and read back the diagnostic.

- `Finalize_Plan` said it summed a plan's components. It does not, and should
  not: file-backed bytes are excluded because a mapped model lives in the
  operating system's pages, and a safety margin is added on top. Writing the
  test against the documented behaviour is what surfaced the difference; the
  specification now describes what the code does and why.

- The quantized decoders had no test of the values they produce. Every other
  check compared them against themselves -- the fused kernel against the
  decoder it mirrors, one batch width against another -- and for the k-quant
  formats the fused path is the decoder, so that check said nothing at all
  about them. Conformance runs on an F32 model. Three of these decoders had
  just been rewritten. Golden vectors now check each format against
  expectations derived by hand from its documented layout; planting a wrong
  bias in Q6_K or Q4_0 fails them.
- Four formats had two implementations, and only one was reachable. An error
  injected into the unused copy of Q4_0 changed nothing and no test noticed.
  Decode_Block is now Decode_Blocks with a count of one, so there is a single
  implementation per format, as the package always claimed.

- `Numerics.To_Real` and the tensor kernels raised on a not-a-number instead of
  producing one. Half precision has infinities and not-a-numbers, a model file
  may carry either as a block scale, and reporting that is what `Is_Finite` and
  `All_Finite` are for -- but validity checking fires on the value before any
  caller can look at it. Suppressed where such a value is inspected, as in the
  sampler; bounds and range checking are untouched.

- `Backend.CPU.Partition` underflowed the unsigned element count when a worker
  had no rows, which the partition-coverage test found.
- Generated text acquired a trailing newline from `Ada.Text_IO` closing a
  partially written line; it is now written through the raw stream.
- The chat-template renderer and the command layer declared render buffers the
  size of the configured limit on the stack.
- The generation coordinator sized its token buffer to the context rather than
  to the prompt, reporting "buffer too small" instead of "prompt too long".
- `Localization.Open` discarded the requested locale when a single probe key was
  missing, which would have made every partial translation useless.
- Field padding counted bytes rather than characters, misaligning every label
  containing a non-ASCII character.
- A worker pool that was created but never used never terminated, hanging any
  command that failed before its first matrix product.
- Automatic seeding raised on every run that did not pass `--seed`. The host
  source measured the span from the real-time epoch as a `Duration` in its
  declarative part; that conversion overflows on this platform, and a value
  computed in a declarative part propagates past the subprogram's own handler,
  so a contained failure became an internal error. Every test pinned a seed for
  determinism, which is exactly why nothing covered the default path.
- The first generated token lost its leading space: the decoder treated it as a
  SentencePiece dummy prefix, which it is only when decoding a sequence from its
  beginning. Continuing after a prompt, that space is text the model produced,
  and deleting it made prompt and continuation run together. Found by comparing
  against a reference runtime.
- Reading a prompt file of more than about two megabytes reported that the file
  could not be read, when the file was fine and the copy onto the stack was not.
  The documented sixteen-megabyte limit is now actually usable, and exhausting
  memory is no longer reported as an I/O failure.
- `Tokenizer.Encode` built its working text on the stack at three times the
  length of the input, and leaked the symbol array when it failed. Oversized
  input is now rejected on its code point count before anything is allocated.

### Not yet implemented

The release checklist is implemented, as `tools/bin/check_all`, following the
sibling crates: it drives the repository, dependency and layering checks, the
test suite, the conformance run and a 2000-case fuzzing campaign, and fails on
any non-empty stderr log in a build tree.

Quantized weights are decoded into a buffer and then multiplied; the multiply
is not fused into the decode, there is no repacking, and there is no
hand-written vector code. That is the largest remaining difference against a
runtime built around the machine's vector instructions.

The comparison against a reference runtime has now been performed: `llama.cpp`
`b1-717dad5` against TinyLlama-1.1B-Chat-v1.0 Q8_0, matching on tokenization,
greedy token identifiers and generated text. See
[docs/reference-runtime.md](docs/reference-runtime.md).
