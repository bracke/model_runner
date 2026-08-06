# Changelog

All notable changes to model_runner are recorded here. The format follows
Keep a Changelog and the project uses semantic versioning.

## [Unreleased]

### Added

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
- Localization through `messages`, with a catalog entry for all 148 diagnostic
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

### Performance

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

### Added

- `tests benchmark` measures the row kernels on synthetic tensors, with no
  model file and no network. It was written because reading the code produced
  two confident wrong answers about where the time went.

### Added

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

### Added

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

### Changed

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
