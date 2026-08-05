# Changelog

All notable changes to model_runner are recorded here. The format follows
Keep a Changelog and the project uses semantic versioning.

## [Unreleased]

### Added

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
- AUnit suites: 12 GGUF container tests and 7 inference tests, all offline.

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
- Localization through `messages`, with a catalog entry for all 147 diagnostic
  codes and an emergency path that cannot recurse.
- Terminal presentation through `terminal_styles`, confined to the presentation
  layer, with per-destination automatic styling.
- 49 deterministic offline tests and a `tests fixtures` command.

- CPU backend with an Ada worker pool: protected coordinator, reusable worker
  tasks, deterministic partitioning, bounded queue, failure propagation and
  clean shutdown, selected with `--threads`.
- `tests fuzz`, a reproducible GGUF mutation campaign.
- `tests check`, 467 repository, dependency-boundary and layering checks.
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
- Row dot per element, release build: Q8_0 0.39 ns, Q4_0 0.59 ns, Q4_K 0.77 ns,
  F32 1.26 ns.

### Added

- `tests benchmark` measures the row kernels on synthetic tensors, with no
  model file and no network. It was written because reading the code produced
  two confident wrong answers about where the time went.

### Fixed

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

A `package` command. Nothing produces a distributable archive.

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
