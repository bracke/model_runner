# Comparing against a reference runtime

## What this is

A *reference runtime* is a second, already-trusted inference program — for
example `llama.cpp`, a HuggingFace `transformers` script, or Ollama. You run
the **same GGUF file** through it and through `model_runner`, and check that
they agree.

It is **not** linked into `model_runner` and is never called by it. Delegating
inference to another runtime is exactly what this project does not do. The
reference is run once, by hand, and what it produced is written down in a small
text file that is committed alongside the model's provenance. Later runs
compare against that file, so the reference does not need to be installed to
check the result.

## What has been compared

This has now been done once, against `llama.cpp` `b1-717dad5` and
TinyLlama-1.1B-Chat-v1.0 Q8_0 (Apache-2.0; see
[fixture-provenance.md](fixture-provenance.md)). The recording is
`tests/fixtures/tinyllama-q8_0.expect` and the result was:

```
external-model: ok, architecture llama, 201 tensors,
  checked against llama.cpp b1-717dad5, prompt 6 tokens, generated 2,
  deterministic TRUE, thread-stable TRUE,
  tokens-match TRUE, greedy-match TRUE, text-match TRUE,
  logits compared 0
```

It has since been done a second time, against the same model requantized to
Q4_K_M, recorded in `tests/fixtures/tinyllama-q4_k.expect`:

```
external-model: ok, architecture llama, 201 tensors,
  checked against llama.cpp b1-717dad5, prompt 6 tokens, generated 2,
  deterministic TRUE, thread-stable TRUE,
  tokens-match TRUE, greedy-match TRUE, text-match TRUE,
  logits compared 0
```

That one exists because every recording before it was of a file whose tensors
were all one type. A Q4_K_M file carries Q4_K, Q6_K and F32 tensors together
and the type is read per tensor, which nothing had compared against another
runtime. It agreed on the first attempt, so it found nothing -- which is worth
having written down, because the alternative was not knowing.

`logits compared 0` is not a failure. Neither recording carries a `logit`
directive, because getting logits out of the reference means more than reading
what it prints, and the tokenization and the greedy continuation were what
these were for. The runner reports the count so that a recording with no logit
comparison cannot be mistaken for one that made it.

These two blocks are copied by hand and nothing checks them, unlike the
conformance figures in the README, which the run itself now verifies. They
cannot be: reproducing them needs a model that is not in this repository and
should not be. Both had already drifted from what the runner prints -- they
omitted the last field -- which is the argument for keeping the hand-copied
ones few.

One trap is worth naming, since it cost an hour here. Recent `llama.cpp`
wraps the prompt in the model's chat template unless told not to: pass
`--no-conversation` to `llama-completion`, or it will feed fourteen tokens
where the harness feeds six and the two runtimes will disagree about something
neither of them got wrong.

Neither the runtime nor the model is needed to read that recording, and no
mandatory test touches either. The model is not committed.

The comparison earned its keep immediately: it found that the first generated
token was losing its leading space. The engine agreed with `llama.cpp` on every
token identifier, and still printed `Paris.` where the reference printed
` Paris.`, because the decoder was treating that space as a SentencePiece dummy
prefix. It is one only when decoding a sequence from its beginning; continuing
after a prompt it is text the model produced. `Reset` now distinguishes the two
cases. No amount of self-consistency checking would have surfaced this, because
both sides of every internal check shared the same decoder.

## What is already proven without one

`tests conformance` compares the engine against `Reference_Transformer`, an
independent implementation of the same forward pass in the tests crate. It
decodes binary32 from the file bytes by reconstructing the value from its
fields, computes in `Long_Float` throughout, keeps a full key and value history
instead of a cache, and expands attention heads instead of mapping them. How
closely the two agree is in the README, and `tests conformance` prints the
worst divergence it measured on every run; both are one place rather than a
figure copied here to go stale.

That establishes the *arithmetic* is right. What a reference runtime adds is
agreement on the *conventions*: tokenization of real text, the beginning-token
policy, the rotary configuration of a real model, and the chat template.

## Producing a recording

1. Choose a small GGUF model you may legally use. Record its name, its source
   and its licence in `docs/fixture-provenance.md`. Do not commit the model
   itself unless its licence clearly permits redistribution.

2. Run your reference on it and note:
   - the token identifiers it produces for a chosen prompt,
   - the token identifiers greedy decoding produces after that prompt,
   - optionally a few logits for the position after the prompt.

   With `llama.cpp` the tokenization comes from `llama-tokenize`, and greedy
   decoding is `llama-cli` with `--temp 0` and a fixed seed.

3. Write a file like this:

   ```
   # Recorded by hand; see docs/reference-runtime.md
   runtime llama.cpp b4321
   model TinyLlama-1.1B-Chat-v1.0.Q8_0.gguf
   prompt Explain Ada protected objects.
   tokens 1 12027 20066 9633 3618 29889
   greedy 319 12716 1203 297 27681
   logit 319 18.4213
   tolerance 0.05
   ```

   `runtime` and `model` are required: a recording whose origin is not stated
   is not evidence, and the loader rejects it.

4. Check it:

   ```
   cd tests
   ./bin/tests external-model --model /path/to/model.gguf \
                              --expect /path/to/expected.txt
   ```

   The runner validates the container, the architecture, the tokenizer, session
   allocation, generation, UTF-8 validity, seed reproducibility and worker-count
   stability, and then compares the tokenization, the greedy identifiers and any
   recorded logits against the file. Anything that disagrees fails the run and
   names what differed.

## Why identifiers rather than text

Token identifiers are what both sides can report unambiguously. Comparing
decoded text would fold in each side's decoder conventions — how a leading
space is handled, how a byte-fallback token is rendered — and a difference there
would be reported as a model disagreement when it is not one.

## Without a recording

`tests external-model --model PATH` still runs every self-consistency check and
says `no reference comparison` in its output. It never implies a comparison it
did not make.
