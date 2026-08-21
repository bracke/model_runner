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

A third is `tests/fixtures/llama32-1b.expect`, against Llama-3.2-1B at
Q4_K_M, which is the first recording of a model whose tokenizer merges by
rank rather than by score:

```
external-model: ok, architecture llama, 147 tensors,
  checked against llama.cpp b1-717dad5, prompt 6 tokens, generated 2,
  deterministic TRUE, thread-stable TRUE,
  tokens-match TRUE, greedy-match TRUE, text-match TRUE,
  logits compared 3
```

The vocabulary-only fixtures could check the tokens and nothing after them,
and two defects lived in that gap: output arriving in the stand-in alphabet
the merges are written in, and a beginning marker being given to a model that
declines one.

That one exists because every recording before it was of a file whose tensors
were all one type. A Q4_K_M file carries Q4_K, Q6_K and F32 tensors together
and the type is read per tensor, which nothing had compared against another
runtime. It agreed on the first attempt, so it found nothing -- which is worth
having written down, because the alternative was not knowing.

`logits compared 0` is not a failure. It says the recording carries no `logit`
directive, and the count is reported so that a recording which never made the
comparison cannot be mistaken for one that did. Getting logits out of the
reference means more than reading what it prints, so the first recordings
asked only about the tokenization and the greedy continuation. Of the three
fixtures, `tinyllama-q4_k.expect` still carries none; `tinyllama-q8_0.expect`
and `llama32-1b.expect` each carry three -- at a tolerance of 0.08 and of 0.2
respectively, each figure arrived at by measurement and explained where it is
written.

These three blocks are copied by hand and nothing checks them, unlike the
conformance figures in the README, which the run itself now verifies. They
cannot be: reproducing them needs a model that is not in this repository and
should not be. They had already drifted from what the runner prints once --
omitting the last field -- and the first of them has drifted again since,
because the three logit directives were added to that fixture after its block
was copied here. Both drifts are the argument for keeping the hand-copied ones
few, and the numbers stand as recorded until somebody with the model runs them
again.

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

Measuring the logits says how far apart they are, and corrects the reading
above. `llama-eval-callback` prints the first three values of `result_output`,
which is the logit vector at the position after the prompt, and the
`logit` directive compares them. For the same prompt and model:

| weights | how far three logits differ |
|---|---|
| BF16 | 0.0044, 0.0072, 0.0079 |
| Q8_0 | 0.0113, 0.0054, 0.0577 |
| Q4_K | 0.0107, 0.0054, 0.0593 |

BF16 was called the control on the grounds that both implementations hold
bit-identical weights there, and that fourteen matching tokens meant nothing
in the forward pass differed. The first half is right and the second was too
strong. The logits differ at BF16 too, by about 0.006, which is the forward
pass itself: this engine accumulates a row product in binary64 and sums its
spans in its own order, and the other does neither. Fourteen tokens matched
because no margin among them was smaller than 0.006, not because nothing
differed.

Decoding a quantized weight widens that by roughly ten times, to about 0.06,
which is the part that is genuinely about the format. For scale, quantization
itself moves a logit far further than either: llama.cpp's own first logit goes
from -7.369 at BF16 to -7.046 at Q4_K, a shift of 0.32, and both
implementations take that shift together.

A fourth size is what makes the other three useful. Measuring SmolLM2 the
same way gave 1.87, two orders of magnitude beyond anything arithmetic
explains, and that was a defect: a beginning-of-text marker was being put in
front of a model that declares it wants none, so the engine was answering a
different question than the reference. It had been showing up as generation
ending after two tokens, which is exactly what a close call between an
end-of-sequence token and a newline would look like, and it was not that at
all. With the marker left out the two agree token for token.

Llama-3.2 at Q4_K_M, measured after the fix and at the position where its
greedy output parts company, differs by 0.016, 0.090 and 0.084, with both
implementations feeding nine prompt tokens. That is the quantized range, so
that divergence is what it appears to be.

The moral is not about markers. Two implementations that differ by hundredths
are doing the same thing differently; two that differ by units are doing
different things, and no amount of comparing tokens will tell you which you
have. Tokens agreed for six steps in one case and two in the other.

So there are three sizes, and it is worth keeping them apart. About 0.006 is
two implementations of the same arithmetic. About 0.06 is two implementations
of the same quantized format. About 0.3 is the format itself. Greedy decoding
parts company when the gap between the two best tokens falls below the first
two, which is why it happens at all and why it happens at a different point
for each format.

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

## Where the chat template parts company

The template a Llama-3.2 file ships with renders here. It asks whether
`strftime_now` is defined before using it, and this engine does not define it,
so the template takes its own fallback and the system block reads
`Today Date: 26 Jul 2024`. A reference runtime that provides `strftime_now`
puts today's date there instead, so the two rendered prompts differ by that
one field and tokenize differently because of it.

This is a choice and not an oversight. Reading the clock would make the same
conversation render differently on two days, which would put a moving part
underneath every recorded prompt and every reproduction of a report. The
template supplies the fallback itself, so taking it is the template's own
answer to the question of what to do without a clock.

Anything comparing rendered prompts against a reference for a model whose
template asks after the date has to account for that field, or compare the
tokens after the system block.

## What is already proven without one

`tests conformance` compares the engine against `Reference_Transformer`, an
independent implementation of the same forward pass in the tests crate. It
decodes binary32 from the file bytes by reconstructing the value from its
fields, computes in `Long_Float` throughout, keeps a full key and value history
instead of a cache, and expands attention heads instead of mapping them. How
closely the two agree is in the README, and `tests conformance` prints the
worst divergence it measured on every run; both are one place rather than a
figure copied here to go stale.

That establishes the *arithmetic* is right.

Both tokenizers have a second reader of their own: `Reference_Tokenizer`,
written from the description in this document rather than from the engine's
code, looking every piece up by scanning where the engine hashes.

For a SentencePiece vocabulary it replaces spaces with the word marker, splits
into UTF-8 characters and merges the best-scoring adjacent pair until none is
left. For a byte-pair one it cuts the text by the rule the vocabulary names,
rewrites each byte as the character that stands for it, and merges by rank
within each piece. The suite runs both readers over a set of strings on
committed fixtures and compares identifier for identifier — for byte-pair,
under all five cutting rules.

The strings were chosen against wrong readers rather than by inspection. Two
of the SentencePiece cases exist because a reader that merged the *leftmost*
pair instead of the best-scoring one agreed with the engine on all the others;
`"abc"` is in the byte-pair set for the same reason, against a reader that
merged by position rather than by rank.

Writing the byte-pair reader is also what found three defects, two of them on
that road, which no test reached because the suite had no byte-pair vocabulary
at all: a buffer too small for the answer was filled as far as it went and
reported success, where the SentencePiece road raises `MR-TOK-0013`; and a
piece the vocabulary could not spell was dropped, deleting part of the caller's
own prompt without saying so. Both are fixed, and the second is what
`MR-TOK-0014` now reports.

The third was the more serious, and it came from having the two readers side by
side: the rule that turns a marker such as `<|im_start|>` or `</s>` into a
single token lived inside the byte-pair road alone. A chat template substitutes
`bos_token` and `eos_token` as their *spelling* before anything is tokenized,
so a SentencePiece model was reading its own template's end marker as a run of
byte tokens on every templated turn — and a model that sees the letters answers
in letters, spelling its end marker out instead of stopping. The rule is now
one rule above both roads. Text holding no marker tokenizes exactly as it did,
which is what the dummy word marker going on the first stretch only is for.

What a reference runtime adds beyond that is agreement on the *conventions* at
a scale a fixture cannot reach: tokenization of real text against a vocabulary
of tens of thousands of pieces, the beginning-token policy, the rotary
configuration of a real model, and the chat template.

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
