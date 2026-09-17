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

Agreement, not speed. What each runtime costs for the same file is a separate
question and is answered in the README's `### Against llama.cpp`, with the
runs and the loads recorded in `docs/measured-figures.txt`; nothing on this
page is a timing.

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

## The embedding models, against the same runtime

The three recordings above are of language models and compare tokens and a
greedy continuation. The two embedding architectures are compared on the
thing they produce -- a pooled vector -- and the comparison is recorded in
`tests/fixtures/all-minilm-embedding.expect` and
`tests/fixtures/nomic-embed-embedding.expect`, which `tests external-model`
reads and checks rather than merely holding for a reader.

It is the only comparison in this repository that does not rest on a reading
of a description made here. The engine, the fixture and
`Reference_Transformer` were written from one such reading, so all three
agreed with each other about two things that were wrong, through 857,184
sweep comparisons and a fixture check that moves every tensor:

- A WordPiece text is wrapped in `[CLS]` and `[SEP]` by construction. A
  published all-MiniLM states the two identifiers and neither flag, and
  absent was read as "the model does not say", so six tokens went in where
  the model was trained on eight. Cosine 0.994 against the other runtime.
- `nomic-bert` splits its rotation. It had been written pairing element *i*
  with its neighbour, from a recollection rather than from anything. Cosine
  0.947.

With both corrected, the two implementations agree on F16 weights to
**8.1e-05** and **8.8e-05** worst absolute -- five significant figures, which
is accumulation order and nothing else.

On Q8_0 weights they differ by 0.0026 and 0.0048, and that difference
belongs to the other runtime rather than to this one. ggml quantizes the
activations to eight bits before every dot product against a quantized
weight, and evaluates GELU through a table indexed and stored in f16 whose
own worst error is 0.002 an activation. This engine decodes a weight and
multiplies in binary32 accumulating in binary64. The gap scales with depth,
six layers against twelve, which is what compounding a per-matmul
approximation looks like -- and the F16 agreement is what licenses saying so
rather than merely preferring our own arithmetic.

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

What was compared, the first time: forty-five strings against the five
vocabularies `llama.cpp` ships for its own tokenizer tests -- gpt-2, falcon,
starcoder, llama-bpe and qwen2 -- covering Latin, Cyrillic, Greek, CJK, emoji,
runs of spaces, tabs, newlines, contractions, punctuation, an address and
dates. All forty-five agree. A vocabulary that adds a beginning-of-text marker
differs by that marker, which `tests tokenize` does not add.

Two differences were found that way and neither would have been found by
reading the patterns. A tab joins the word after it under some rules and
stands alone under others, which no string without a tab can show. Digits
group in threes under `falcon`, which no run shorter than four digits can
show, and `falcon` had been cut by the wrong rule until one was tried.

What was compared the second time: sixty-two strings against twenty-eight
vocabularies -- the fifteen `llama.cpp` ships that this build can read, and
the thirteen models in the collection this repository is developed against. Five more
differences came out of it, and again none of them was visible from the
patterns alone:

- `starcoder` was on the original rule and belongs on smollm's.
- An absent `tokenizer.ggml.pre` is a rule of its own and was read as the
  original one. Aquila and GPT-NeoX name no rule; each disagreed on seven or
  eight of the sixty-two.
- `falcon` cuts punctuation out of the text before anything else looks at it,
  which takes its contractions apart and leaves a space standing before a
  full stop, and it keeps a space on a run of one or two digits and not on a
  longer one. Its own vocabulary holds no piece that shows any of this; the
  aquila one does.
- `tokenizer.ggml.add_space_prefix` was not read, and gemma2 and gemma3 state
  it false.
- A marker was looked for only where the text opened a bracket. GPT-NeoX
  files its runs of spaces as its author's own pieces and they were not seen.
- A published jina-bert-v2 states `cls_token_id` and `seperator_token_id` and
  neither `bos_token_id` nor `eos_token_id`, which were the only two read, so
  its text came back wrapped in nothing. `tests tokenize --special` was added
  for this: without it the two runtimes differ by exactly the markers the
  tool declines to add, which hides the case where the engine adds none.

The thirty-second is the one `t5` vocabulary in that set -- 250,048 pieces
and a quarter-megabyte normalization table, which is the whole of what a
published unigram file adds to what a fixture can carry. All sixty-two
agree, the table included, which is what settles that the trie is walked the
way the format writes it rather than the way it was guessed.

The pattern in all eight is the same and is worth stating plainly: a rule
tells two vocabularies apart only if one of them holds a piece that spans the
difference. Four of these are invisible on the very file that names the rule
they belong to, and were found only because thirty other files were read as
well.

Those files are not committed here and are not needed unless the comparison is
being run again.

### The cutting rules, against the splitter itself

What was compared the third time was not vocabularies but the cut. Twenty
rules arrived at once, each a transcription of the other runtime's list of
expressions, and no published vocabulary for most of them was to hand. What
was to hand was the other runtime's source, and the cut is a function in it:
`unicode_regex_split` in `src/unicode.cpp` takes a text and a list of
expressions and answers the pieces, with its hand-written cutters for the
rules it has them for. A harness of thirty lines links that file and prints
each piece's length in bytes; `tests cut --pre NAME --texts PATH` prints the
same list from this engine, the texts one a line and hex-encoded so a line
end inside one is a byte; and the expression list for each name is read out
of `llama-vocab.cpp` by the script that drives both.

    // split.cpp, built with
    //   g++ -std=c++17 -I llama.cpp/src split.cpp llama.cpp/src/unicode.cpp \
    //       llama.cpp/src/unicode-data.cpp -o split
    #include "unicode.h"
    #include <iostream>
    #include <string>
    #include <vector>
    static std::string unhex(const std::string& h) {
        std::string s;
        for (size_t i = 0; i + 1 < h.size(); i += 2)
            s.push_back((char) std::stoi(h.substr(i, 2), nullptr, 16));
        return s;
    }
    int main(int argc, char** argv) {
        std::vector<std::string> exprs(argv + 1, argv + argc);
        std::string line;
        while (std::getline(std::cin, line)) {
            auto pieces = unicode_regex_split(unhex(line), exprs, false);
            bool first = true;
            for (auto& p : pieces) {
                if (p.empty()) continue;   // a zero-width match, a boundary
                std::cout << (first ? "" : " ") << p.size();
                first = false;
            }
            std::cout << "\n";
        }
    }

Three thousand texts a name, made of the things the rules disagree about --
letters of both cases and of several scripts, marks, digits of two kinds,
runs of spaces and line ends, punctuation and symbols, contractions,
ideographs, Hangul, the literal tokens two rules look for. **Sixty-three of
the hundred names agree with the other runtime's splitter on every one of
their three thousand texts**, the fifty-odd that map onto the original six
rules included, and so do minicpm5, jais-2, bailingmoe, seed-coder, laguna,
exaone-moe, deepseek-llm, deepseek-coder, deepseek-v3, hunyuan-dense,
joyai-llm, bloom, poro-chat, gpt3-finnish, viking, superbpe, chameleon and
granite-embed-multi-97m.

The rest differ, and each difference is one this build chose:

- `tekken`, `gpt-4o`, `llama4`, `kanana2`, `talkie`, `minimax-m2`, `youtu`,
  `kimi-k2`, `tiny_aya`, `cohere2moe`: the models' own expressions cut a
  word where its case changes, by the Unicode case categories, with the
  combining marks in the word. The other runtime approximates the case
  classes with ASCII where it can and loses them entirely where it runs
  the expression over a text with every letter collapsed to one byte, and
  it leaves the marks out; its hand-written cutter for kimi-k2 does not cut
  at case at all. On texts of ASCII letters without marks, all of these
  agree; the differences are a capital or a small letter outside ASCII
  beside one inside, or a mark, or a change of case where the other
  runtime cannot see one. What is carried here is the model's own
  expression, because the model was trained on it.
- `afmoe`, `tiny_aya`, `cohere2moe`: the other runtime's hand-written
  digit pass glues whatever precedes a run of digits onto the run's first
  group -- a chunk of `€     1` where the expression it stands for makes
  `€     ` and `1` -- and the expression is what is carried.

The difference the harness found before it found any of those: it printed
the pieces as the other runtime hands them to its merge loop, in the
stand-in alphabet where every byte above ASCII is two, and disagreed on
every text with a non-ASCII character in it. `unicode_regex_split` takes a
flag for that.

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

## The chat template, against the implementation it was written for

`tests render --model PATH --system TEXT --prompt TEXT [--assistant TEXT]
[--calls JSON] [--tool TEXT] [--tools JSON] [--template PATH]
[--generation-prompt]` prints what a model's own template makes of a
conversation. The turns are taken in the order they are written, so the
conversation being compared is one the caller chose rather than one this
command arranges; `--calls` attaches the calls a reply asked for to it, and
`--template` reads a template from a file instead of from the model, which
is how a divergence is narrowed to one branch of a four-kilobyte template
without editing a model file. The templates models ship are written for one implementation --
Python's `jinja2` -- and the way to know this engine agrees with it is to set
the two answers beside each other, because a rendering worked out from this
engine's own reading of a template agrees with this engine by construction.

    $ tests render --model qwen3.gguf --system 'S.' --prompt 'P.' \
        --generation-prompt
    <|im_start|>system
    S.<|im_end|>
    <|im_start|>user
    P.<|im_end|>
    <|im_start|>assistant

What was compared: seventy-eight conversations against the template published
with Qwen3 -- with and without a system message, with and without an
assistant turn, with and without the generation prompt, and with replies that
carry a reasoning block and replies that do not. Seventy-six agree byte for
byte. The two that do not are the empty conversation, which `jinja2` raises
on -- the template asks for `messages[0]` before it asks whether there is one
-- and which this engine answers instead.

And the template a published mixture ships, which is not the same template:
forty-eight conversations against the one Qwen3-30B-A3B carries -- twenty-four
rendered with and without a generation prompt -- every byte agreeing. It is
written in a larger subset than the dense model's, and until this it was
refused rather than rendered: a loop over the conversation that calls its
variable something other than `message`, brackets round part of a sum, a
choice written on one line, cuts at a position rather than at a marker, and a
filter saying which end of a cut is wanted. The same forty-eight were run
against the templates Qwen3-0.6B, Qwen3-8B and Qwen2-0.5B ship, all agreeing,
because a subset grown for one file has to leave the files that already
rendered where they were.

And the four chat formats this build carries, each against `jinja2` reading
its own source: forty-eight conversations apiece, every byte agreeing. They
are ordinary templates written in the subset rather than a second mechanism,
so setting them beside the implementation they are written for is the same
check as for a template that arrives in a model file -- and the format for
Gemma, whose turns are called something else, is the one that could be wrong
without the output showing it.

And the two carried formats that were written to stand in for a model's own
template, `qwen3-coder` and `minicpm`, each against `jinja2` reading *the
model's own template* rather than its own source -- which is the check that
matters for a stand-in, since the point of one is to be the bytes the model
was trained on. `tests cross --model PATH --format NAME` renders the
carried format with the model's own tokens and hands the same conversation
to `jinja2` with the model's template, `trim_blocks` and `lstrip_blocks`
on and `tojson` as `transformers` defines it. The Python that asks jinja2
is carried inside the command, as text, so a checkout runs the crossing
rather than a script somebody once had; a machine without python3 or
jinja2 skips it. Sixteen conversations, byte for byte: with and without a
system turn, tools offered -- with enums, defaults, nested items, required
lists and a return -- a call turn with text and one without, two calls
answered by two tool turns, a reply with no generation prompt, reasoning
kept in the exchange in progress and dropped from an earlier one, a call
whose arguments nest mappings and lists -- which found the carried
`qwen3-coder` format spelling those as JSON where the model spells them
as Python -- a user turn wrapped in a tool answer's markers, two
system turns, and a developer turn -- the role gpt-oss's and Qwen3.6's
templates read instructions from, which `run --developer TEXT` and
`tests render --developer TEXT` hand a template -- and a user turn whose
content is a list of parts, a picture and words, which `run --prompt-parts
JSON` and `tests render --prompt-parts JSON` hand a template, and which
Gemma 3's walks, MiniCPM's writes nothing for, and Qwen3-Coder's and
gpt-oss's refuse on both sides, a text and a list added together -- and
which, given a `"path"` and `run --mmproj PATH`, is a picture the model
sees: decoded, resampled and encoded by `Model_Runner.Vision` -- Gemma
3's projector or Qwen3.5's -- crossed with the reference runtime by the
two scripts under `tests/fixtures/vision-crossing/` (see "The pictures,
crossed" below) -- its rows read where the template's marker stands: for Gemma 3 the marker set between the reference processor's two
line breaks before the prompt is tokenized, and with `--pan-and-scan`
among its words too, whole and then in crops; for Qwen3.5 the one
`<|image_pad|>` replaced by one a row, each turned by its row and column -- a reply given as parts and a
tool's answer given as parts, which Gemma 3's template walks, MiniCPM's
writes as nothing and as JSON, and Qwen3-Coder's refuses -- with
the caller's `--think` and `--no-think` each where the template
reads them; `--without-tools` and `--without-reasoning` leave out the
shapes a carried format was never meant to match, which is how the
`gemma` and `qwen3-coder` formats -- which write reasoning as Qwen3.5's
template does, where their models' say nothing -- are crossed; the
three filters the carried `qwen3-coder` and `minicpm` formats stand on,
`qwen_tool`, `qwen_params` and `params`, are said in Python inside the
harness, the first by running Qwen3-Coder's own macro through jinja2, so
every carried format crosses whole. `tests records --model PATH` writes
the nine records the suite compares against afresh. `tests cross --model PATH` alone sets the model's own template
beside jinja2 reading the same text, which every model file on this
machine passes: TinyLlama, Qwen2, Qwen3 in three sizes, Qwen3-MoE,
Qwen3.5 in two sizes, Qwen3.6, Qwen3-Coder, MiniCPM, Phi-3 and Gemma 3 --
whose template refuses a tool turn, on both sides -- and, from a file,
gpt-oss's harmony template, which walks every tool's schema through a
recursive macro into TypeScript. `--expressions` runs twelve one-line
suites, one construct of the support matrix after another, the same way.
The own templates of Qwen3-Coder, MiniCPM, Gemma 3, Qwen3.6 and gpt-oss
are fixtures, and what jinja2 rendered from each -- `tests cross
--record FILE --bos '<s>' --eos '</s>'`, the tokens the suite renders
with, one record a conversation and thinking choice, the day it was
recorded on the first line so a template writing the date compares on
another day -- lies beside each as a `.render` file. The suite renders
every case of every record and compares the bytes, so the crossing is
made on every run of the suite, on a machine with no Python and no
model file; the first three are rendered beside their carried formats
as well, and a conversation jinja2 refused is one this engine must
refuse. It found the carried `gemma` format
writing a turn's content untrimmed where the model's template trims it. Five faults came out of it: the line break after a block
tag, which
the engine takes off as `trim_blocks` does, was where the model's template
had written one as an expression, so `<tools>` and the first tool ran
together -- `+%}` keeps it now, as the language spells that; a tool was
offered as JSON where the Qwen3-Coder model reads a `<function>` element
with its parameters walked out of the schema, which the `qwen_tool` filter
writes now; a call turn's text was written untrimmed and followed by one
line break where the model trims it and writes two; MiniCPM's run of tool
answers had a line break after each where the model has one before; and an
argument that is not a string was spelled as JSON spells it where both
models' templates spell it as Python does, `True` and `None`.

The template TinyLlama-1.1B-Chat ships was the file that said the whitespace
rule was missing: forty-eight conversations, none of them agreeing, every
divergence a line break this engine kept and `jinja2` did not. Forty-eight
agree now.

And what a tool conversation makes of it: forty-eight more, twenty-four
conversations rendered with and without a generation prompt, every byte
agreeing. A call with text before it and one without, two calls in one turn,
a run of tool answers folded into one turn, arguments carrying quotes and
backslashes, a reasoning block in an earlier reply, and a user turn that
itself contains the words the template looks for. Three faults came out of
it, and none of them was visible in a conversation of plain messages: a turn's
calls were kept as the model's own text and re-sent in the model's own
spelling rather than the template's; `{% set a = b %}` copied where a value
was rather than what it said, so a name written down inside a loop followed
the loop afterwards; and `+` between two numbers ran them together, which is
how that template asks whether the next turn is another tool answer.

It found what the token counts could not. The whitespace control was right,
the loops were right, and a counting loop advanced its position twice: once
where the instruction said to and once more from a line that belonged to the
instruction beside it. Every iteration after the first began one instruction
late, and everything after the loop was skipped. A comparison of token counts
called that a difference of eight; the rendered text said which eight.

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

## The pictures, crossed

What a picture becomes in the prompt and in the model was set beside
`transformers` 5.17 on 2026-09-16, by the two scripts under
`tests/fixtures/vision-crossing/`, which a checkout with `transformers`,
`torch` and `Pillow` reruns. None of it is a mandatory test: the reference
is two gigabytes of download and a Python runtime this repository does not
carry.

`gemma3.py` loads the Gemma 3 processor and compares its prompt tokens for a
picture and a question, whole and with pan-and-scan, against the template's
text rewritten as this build rewrites it. On a 1920 by 1080 poster and a
1000 by 1333 photograph, both ways, the tokens are the reference's, token
for token: 278 whole, 817 with three tiles.

`qwen35.py` loads Qwen3.5-0.8B and compares three things. The prompt: the
reference's tokens are the template's with the one `<|image_pad|>`
replicated, one a row -- 1327 for the photograph, as this build counts. The
encoder: on the same pixels, the reference vision tower's rows and the rows
`tests see --dump` wrote agree to a cosine of 0.9999996 at worst over the
photograph's 1302 rows and 0.9999997 over the poster's 2040, the worst row
apart by a thousandth of the median norm, which is the projector's f16
weights. The positions: the reference's `get_rope_index` places every row
of the picture at (start, start + row, start + column) and the text after
it at start plus the grid's longer side, which is the rule
`Model_Runner.Llama` marks by; its rope delta for the photograph's prompt is
-1260, which is 46 - 1306. And the first token's distribution after the
photograph's prompt: the reference's five likeliest are ` A` -0.56, ` a`
-1.54, `A` -2.81, ` An` -3.73, ` It` -3.73; this build's, on the Q8_0 text
weights, ` A` -0.61, ` a` -1.36, `A` -3.11, ` It` -3.67, ` An` -3.88.

What the scripts found is also held without them: `tests/fixtures/
vision-crossing/qwen35-0.8b.expect` records three rows the reference tower
makes of the small picture beside it -- the first, the middle and the last
of seventy-seven -- and `tests see --mmproj MMPROJ --image plaza.png --expect
qwen35-0.8b.expect` compares this build's rows against them, each within a
hundredth of its norm; they sit within a few millionths on the host and
with `--device` alike, since the encoder holds the device's products and
attention to binary32. `record.py`
there writes the file afresh from the reference. A checkout with the
projector file, and no Python, reruns that much of the crossing; without
the projector file the command says `see: skipped (no projector at ...)`
and exits well, as `tests external-model` does without its model, so a
gate may name it on every machine and mean it on the ones that have the
file. `gemma3-4b.expect` beside it records the same for Gemma 3's
projector, from the vision tower and projector of google/gemma-3-4b-it
alone.

The pixels are the one place the two references part. The processor the
model was trained through, and llama.cpp, resize with PIL: bicubic with
a = -0.5, in two passes of 22-bit fixed point, each rounded to a byte.
`transformers` 5's default processor is a torchvision backend, which
resizes with a = -0.75 in floating point, up to two levels a pixel apart.
This build resamples as PIL does, to the bit -- `Model_Runner.Images.Resample`
was checked against `Image.resize` on both pictures, both filters, no pixel
differing -- because a handful of windows of the Qwen encoder turn a level
into rows a third apart, and the two references agree on everything but
this.

