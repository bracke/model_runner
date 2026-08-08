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

## Where greedy decoding parts company

Greedy output agrees with `llama.cpp` for the first several tokens and then
diverges, on every quantized model tried. TinyLlama at Q4_K agrees for six
tokens -- " Paris.", a blank line, "2.", "B.", "C." -- and then takes "D."
where the reference takes "The capital". Llama-3.2-1B at Q4_K_M agrees for
three and then takes " E" where the reference takes " capital".

Two things are worth saying about that. It is not particular to a model or a
tokenizer: the same shape appears on a SentencePiece model and a byte-pair
one. And the recordings in this file cannot see it, because both compare two
generated tokens, which is fewer than any divergence found so far.

It is the quantization, and the same model at three precisions says so. The
same prompt, fourteen tokens, greedy, against `llama.cpp`:

| weights | agreement |
|---|---|
| BF16 | identical, all fourteen tokens |
| Q8_0 | parts company after about four |
| Q4_K | parts company after about six |

BF16 is the control. Widening one of those is a shift and nothing else, so
both implementations hold bit-identical weights, and fourteen tokens of a full
forward pass -- attention, normalization, softmax, the sampler -- come back
the same. Whatever differs cannot be in that path.

What differs is decoding a quantized weight, where a value is a small integer
times a scale, and the two implementations apply that scale and sum the
products in different orders. The last bits of a logit differ, and a token
chosen by a close margin flips. That is why the divergence appears at all and
why it appears at a different point for each format rather than at a
consistent one.

So: exact weights are exact, and quantized weights agree until they meet a
near-tie. The engine's output is reproducible under a fixed seed and unchanged
by the worker count either way. It is not bit-identical to another
implementation on quantized weights beyond the first few tokens, and no
implementation of these formats is bit-identical to another for the same
reason.

## The tokenizer, compared the same way

`tests tokenize --model PATH --prompt TEXT` prints the identifiers a
vocabulary makes of a prompt, which `llama-tokenize -m PATH -p TEXT --ids`
prints for the same file. Setting the two beside each other is how the
byte-pair implementation was checked, and it is how the next one should be.

    $ tests tokenize --model ggml-vocab-gpt-2.gguf --prompt "hello world"
    [31373, 995]
    $ llama-tokenize -m ggml-vocab-gpt-2.gguf -p "hello world" --ids
    [31373, 995]

What was compared: forty-five strings against the five vocabularies
`llama.cpp` ships for its own tokenizer tests -- gpt-2, falcon, starcoder,
llama-bpe and qwen2 -- covering Latin, Cyrillic, Greek, CJK, emoji, runs of
spaces, tabs, newlines, contractions, punctuation, an address and dates. All
forty-five agree. A vocabulary that adds a beginning-of-text marker differs by
that marker, which `tests tokenize` does not add.

Two differences were found this way and neither would have been found by
reading the patterns. A tab joins the word after it under some rules and
stands alone under others, which no string without a tab can show. Digits
group in threes under `falcon`, which no run shorter than four digits can
show, and `falcon` had been cut by the wrong rule until one was tried.

Those files are not committed here and are not needed unless the comparison is
being run again.

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
