# model_runner

Local GGUF language-model execution in Ada 2022.

`model_runner` loads a local GGUF model file, validates its container strictly,
prepares a bounded Llama-compatible decoder-only execution plan, tokenizes
prompts, evaluates the model on the processor or on a compute device, maintains
an explicit KV cache, samples output tokens, decodes them incrementally and
streams the generated text.

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

**Tools.** `--tools` offers the model tools, as the JSON a caller already
holds; `--tools-file` reads them from a file. They reach the model through
its own chat template, so a model whose template says nothing about tools is
refused rather than told nothing and asked anyway. What comes back is a
reply, and what the reply asks for is read out of it and reported on standard
error, by name, so standard output stays what the model wrote.

Nothing here runs anything. This program starts no process, opens no socket
and loads no library, so a tool call is text the model wrote and a tool
result is text you hand back. The loop closes outside this program:

```
$ model_runner run MODEL --tools-file tools.json \
    --prompt "What is the weather in Paris?" > reply.txt
model_runner: tool call: get_weather {"city": "Paris"}

$ model_runner run MODEL --tools-file tools.json \
    --prompt "What is the weather in Paris?" \
    --assistant-file reply.txt \
    --tool-result '{"temperature_c": 18, "sky": "clear"}'
The current weather in Paris is clear with a temperature of 18°C.
```

The turns follow the prompt in the order they are written -- `--assistant`,
`--tool-result`, another reply, another answer -- because which reply an
answer follows is the shape of the loop. The reply is handed back as it was
printed and the calls are read out of it here, so what reaches the model is
the call as that model's template writes one rather than as the model
happened to spell it. Interactively the same loop is `/tools` to see what is
on offer and `/tool TEXT` to hand an answer back.

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
| Tokenizer | SentencePiece (`llama`) vocabulary: scores, token types, special tokens, byte fallback, greedy highest-score merge encoding. Byte-pair (`gpt2`) vocabulary: merge tables by rank, byte-level stand-in alphabet, and five cutting rules named by `tokenizer.ggml.pre` -- eight values of that key select between them, since an absent key cuts as `gpt-2` does, `starcoder` with it, and `llama-bpe` as `llama3` does -- a vocabulary naming any other being refused by name rather than cut by the wrong one. WordPiece (`bert`) vocabulary: the text folded before anything is looked up -- lower-cased, accents off, punctuation and ideographs cut loose -- and each word then spelled from the front with the longest piece the vocabulary carries, a piece that starts a word carrying a leading U+2581 and one that continues it written bare, and a word no run of pieces spells given back as one unknown rather than as the pieces that did match. All three with UTF-8-boundary-safe incremental decoding. A special-token identifier that is absent leaves the token unset; one that names no token refuses the model rather than being ignored |
| Chat templates | Bounded allowlisted engine: `for`, `if`/`elif`/`else`, `set`, comments, `+`-joined output, `==`/`!=`/`and`/`or`/`not` with parentheses, `is defined`/`is none`/`in`, `trim`, `length` and `tojson`, message indexing, front slicing such as `messages[1:]`, cuts at a position such as `content[:n]` and `content[n:]`, brackets round part of a sum, a choice written on one line -- `A if C else B` -- `loop.first`/`last`/`index`, whitespace control -- `{%- -%}`, `{{- -}}`, `{%+`, and the line a block tag stands on, whose indentation and closing line break are the template's own shape rather than text the model was trained to see -- counting loops, namespaces, the string methods a reasoning model's template takes its own reply apart with together with the `first` and `last` filters that say which end of a cut is wanted, and the tool-calling branch: the tools a caller offered, walked and written with `tojson`, and the calls a turn asked for, walked and written field by field. A loop over the conversation may name its variable anything; `message` is the name a turn's fields are read through, so a loop calling its variable something else walks the list and leaves that name alone, which is what a template that walks the conversation backwards relies on. `+` runs text together and adds numbers, which is the rule the language it is written in has and what `messages[loop.index0 + 1]` means, and a sum answers as a number whether it is assigned, compared or printed. Enough that the templates current Llama-3, Qwen3 and Qwen3-MoE files ship with render, each of the last two checked against Python's jinja2 conversation for conversation. Where a model's own template is outside the subset, this build carries the format itself -- `--chat-template llama3`, `chatml`, `gemma`, `phi3` or `qwen3-coder`, the last being Qwen3-Coder's template said in the subset because that one opens with a macro, and the same bytes as it for every conversation that has no tools in it. Compiled and validated at load time; `macro`, `include` and `import` are rejected there, while a value the engine cannot compute -- a function call, date formatting, arithmetic on things that are not numbers -- is refused if the render reaches it |
| Architecture profile | `llama`, `qwen2`, `qwen3`, `qwen3moe`, `gemma`, `gemma2`, `gemma3`, `phi3`, `falcon`, `phi2`, `gpt2`, `bert`, `nomic-bert` and `jina-bert-v2`, each read under its own metadata keys and refused by name otherwise, with the refusal naming every one this build reads. All are the same shape with a difference: qwen2 a bias on each attention projection -- required, not optional -- and the split rotary pairing, element *i* against element *i + rotary/2* rather than against its neighbour; qwen3 no biases and a root-mean-square normalization of every query and key head before the rotation, equally required; qwen3moe that again with the feed-forward block behind a router; gemma three differences of its own -- the normalization gain is one plus the stored weight rather than the weight, because its weights are trained around zero; the embedding row is multiplied by the square root of the embedding width before the first layer; and the feed-forward gate is a Gaussian error unit rather than a logistic one. Each of the three produces a plausible wrong answer rather than a refusal when it is missed, which is why each is crossed against the independent implementation rather than checked once; gemma2 those three and four more -- a normalization after each sublayer as well as before it, a bound on the attention scores and another on the logits, both applied as a scaled hyperbolic tangent, and a sliding window on every other layer rather than on all of them; gemma3 keeps the two normalizations, drops the two bounds, normalizes query and key heads as qwen3 does, windows five layers in six, and turns those five on a rotation base of their own; phi3 nothing at all in its arithmetic and everything in where its weights are -- the queries, keys and values in one tensor and the gate and up projection in another, taken out as views at a row offset rather than copied; falcon a different block rather than a different detail -- one normalization a block instead of two, with attention and the feed-forward both reading it and both adding to the same residual, a normalization that subtracts the mean and carries a bias rather than the root-mean-square form every other architecture here uses, and a feed-forward with no gate at all: one projection up, a Gaussian error unit, one projection down; and phi2 that arrangement with a bias on every projection instead of on none. Bert is the one that is not a decoder at all: it reads a whole text and produces a state for every position of it, attending both ways, normalizing after each residual add rather than before each sublayer, and learning a row for the token, a row for its position and a row for its segment where every other architecture here learns one. It carries no projection from a state to a token, so `run` is refused by name and `embed` is what it is for. nomic-bert is that arrangement with three parts swapped -- it rotates rather than learning a row for the position, writes its queries, keys and values fused, and gates its feed-forward -- and carries no bias on any projection at all -- the three attention biases in one vector as their matrices are in one tensor, one on the way out of attention, one on each side of the feed-forward, and one on the output projection itself, which is added to every logit. jina-bert-v2 is that arrangement again with the positions taken away entirely: it neither rotates nor learns a row for where a token is, and is told instead by a fall-off in the attention scores, one slope a head, taken off after the scale and before the softmax and unsigned -- a position is as far from what follows it as from what came before. Its ladder of slopes has two branches and the second is only reached where the head count is not a power of two, which twelve heads is; it gates its feed-forward by the Gaussian unit where nomic-bert gates by the sigmoid-weighted one, and shifts what it projects down and nothing else. Metadata validation in which an absent optional key takes a default and a present-but-unusable one refuses the model, derived-width divisibility, separate key and value head widths read from the file when it states them, rejection of rotary scaling this does not compute, tensor resolution and shape validation, tied-output aliasing. Sliding-window attention is read and applied: each position attends to the window's worth of positions ending at itself, uniformly across layers. A mixture of experts is read and applied: a router a layer, the highest few experts run for each position and summed in proportion to their shares. Rotary scaling is read and applied for `none`, `linear` and `yarn`, together with a `rope_freqs.weight` table of per-dimension divisors when the file carries one |
| Execution | Embedding lookup, per-layer RMS norm, Q/K/V projection, rotary encoding, grouped-query causal attention without duplicating key or value heads, output projection, SiLU-gated feed-forward, residuals, raw logits |
| KV cache and session | Explicit cache sized with checked arithmetic, transactional commit, state machine, reset preserving allocations, committed-prefix reuse. Any number of sessions may be open on one prepared model at once: a model carries no per-evaluation state -- the activations, the normalized copies and the query and key rows all belong to the session -- so a second sequence costs its own cache and nothing else. Held by a test that interleaves two sessions a token at a time and checks each gets what it would have got alone; interleaved rather than sequential, because sequential sessions pass even on a model that does hold such state. Anything that would write to the model is refused while a session is open. `--prompt` asks for several: the model is read once and answers each in turn, which is what the sessions buy |
| Sampling | Documented pipeline: vocabulary check, non-finite rejection, masks, per-token biases, sequence penalty, repetition penalty, frequency and presence penalties, temperature, top-k, tail-free, locally typical, top-p, min-p, exclude-top-choices, renormalize, select. Everything that acts on a token acts on the greedy path too, which is where a caller can check by hand what a penalty did -- they did not, for as long as they have existed. Mirostat v2 replaces the truncation filters rather than joining them and is refused alongside any of them, because two answers to one question is not a configuration. Greedy is tie-broken to the lowest token and consumes no random state; xoshiro256++ seeded per session. `--logit-bias TOKEN=X` nudges a token; `--logprobs N` reports what the model made of each position, from a plain softmax over the raw logits with none of the sampling applied |
| Stops | End-of-sequence, stop tokens, stop strings matched across token boundaries with earliest-then-longest resolution and no leaked bytes |
| Generation | Prefill, decode loop, streaming to an output sink, eight completion reasons, statistics against a monotonic clock, bounded text retention |
| Conversation | Structured roles, bounded history, system-message replacement, turn rollback, and the tool calls a turn asked for held beside its text rather than inside it -- so the next prompt carries the call as that model's own template writes one, not as the model happened to spell it |
| CLI | `run`, `embed`, `inspect`, `help`, `version`; typed command parsing separated from execution; end-of-options; repeated, conflicting and out-of-range option detection. `--prompt` is repeatable: several prompts are several sequences from one loaded model, each with its own context and its own statistics, and standard error says which is which so that standard output stays nothing but generated text. It is refused together with a saved or restored context, which names one conversation. `--tools` offers the model tools and the calls it writes back are read out of the reply and reported; `--assistant` and `--tool-result` put the earlier turns back, in the order they are written, which is how one run closes the loop another opened |
| Interactive | Committed structured history, template rendering per turn, prefix verification against the cache, `/exit` `/reset` `/help` `/settings` `/stats` `/context` `/system [TEXT]` `/tools` `/tool TEXT`, `/system` removing the system message when no text follows it and `/tool` handing back what a tool answered as a turn of its own, blank-line submission, no history written to disk. Needs a terminal on both standard input and standard output, whether it is chosen because no prompt was given or asked for with `--interactive` |
| Localization | Every application-authored string through `messages`; 174 diagnostic codes each with a catalog entry; every catalog key has a reader and every key the code names has an entry, checked both ways; English, a partial Danish translation that inherits per key, and a generated pseudo-locale; locale precedence with an emergency path that cannot recurse |
| Cancellation | An interrupt requests a clean cancellation rather than killing the process; observed between parser sections, tensors, layers and tokens, so a cancelled run releases everything and commits no cache position. The parser, preparation, the single-token pass and the batched pass are each held by a test; generation's own two checks stop the work a batch or a token earlier than the pass below would, which no test of the outcome can distinguish |
| Presentation | `terminal_styles` in the presentation layer only; styling asks whether the stream a line is going to is a terminal, so redirecting one stream and not the other never puts escape sequences in the file — which it did, once the inspection report moved to standard output and the colour decision stayed on standard error; severity always carried by a word as well as a colour; `--color always` colours whatever the destination is, `auto` colours only a stream that is a terminal and honours `NO_COLOR`, and `never` colours nothing; generated text never styled |
| Backends | Three, selected with `--backend`. `cpu`: an Ada worker pool with a protected coordinator, reusable worker tasks, deterministic row partitioning, a single-job bounded queue, worker-failure propagation and clean shutdown; `--threads` selects the count and the result is bit-identical whatever it is. `reference`: one row at a time on the calling task, no pool and no batching, the same logits and about twelve times as long -- see below for the measurement -- for asking a suspicious result again by different code. `device`: the products run on a compute device, reached through the host's Vulkan loader opened by name at the moment it is asked for, from a shader compiled into the binary. The shader decodes every one of the fifteen formats this program reads, from the bytes the file holds, and takes a batch of eight vectors per invocation, so no model needs repacking to reach a device and a prompt is one reading of the weights rather than one a token. A second shader computes a batch as a matrix product instead, through `VK_KHR_cooperative_matrix` where the device offers it -- 413.5 tokens a second on a prompt against 207.9, and a `Q5_K_M` file 1.368 s against 0.305 -- and every device without it runs what it ran before. It is compiled twice, once for the six formats a published model is usually made of and once for the eight others, because a pipeline pays for every branch compiled into it whether or not the branch is taken; between the two it decodes every format but binary32, which it refuses on purpose because its operand is half precision. The engine binds whichever of the two decodes the weights it was handed. Each matrix is uploaded once and stays on the device. Measured faster than the pool on this machine, at the same generated text. A machine with no device is told so rather than quietly given another backend |
| Tooling | `tests test`, `tests check`, `tests conformance`, `tests fuzz`, `tests speed`, `tests benchmark`, `tests external-model`, `tests fixture-likeness`, `tests slow`, `tests device-bench`, `tests tokenize`, `tests render`, `tests docs`, `tests shader`, `tests schema`, `tests fixtures`, `tests fixture-check`, `tests package`, `tests pristine` — all Ada, all in the tests crate, and the set is a registry the checklist holds the dispatch and this row against, because two hand-kept copies of it had already drifted apart. `tests <command>` with no command lists them with what each takes. `tests check` is the gate: it runs the suite, the repository checks, the conformance comparison, the fixture check and a short fuzzing campaign, and fails when a test is written and registered by nothing or when the suite has shrunk. The fixture check moves every tensor of every architecture's fixture in turn and requires an answer to move with it -- a logit, or for the architecture that has no distribution to give, what the model made of every position: a tensor nothing reads makes every comparison over that fixture weaker than its count suggests, and one that was written twice made two correct readers disagree about every logit before anything here asked. Each architecture is built in every shape it can hold and five formats and read by four combinations of backend and evaluation path, which is what makes the question specific: a tensor only the batched path reads, or only the shader, is a different tensor from the one every path reads. A shape an architecture cannot hold is built anyway and required to refuse, because a skip nothing needs any more is a skip costing comparisons; and a reading an architecture has not got -- a model that attends both ways has no token at a time, and so no run on the backend that declines batching -- is counted rather than asked, because asking produced a refusal that read as a fault. It also reports what it moved quietly: a tensor whose logits answer by less than a comparison would call a disagreement is read, but a mistake of that size in it would pass the sweep unremarked, and that is the measure the sweep cannot take of itself. The public operations the program itself never calls are listed in `Library_Surface` with the reason for each, and the list is held in both directions: this is a library as well as a command, so the interface is wider than the command uses, and how much wider is a thing somebody chose rather than a thing that happened. The separate commands are for looking closer |
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
cd tests && ./bin/tests shader ../src/shaders/row_product.comp out.spv \
                             [SOURCE.comp OUT.spv ...] [ROOT]
                                           # after recompiling a shader, and
                                           # naming every one of the nine:
                                           # the package is written whole.
                                           # Five compile with
                                           # `glslangValidator -V`; the
                                           # matrix product needs
                                           # `--target-env vulkan1.3`,
                                           # because it is SPIR-V 1.6.
                                           # The matrix product is compiled
                                           # again with `-DMORE_FORMATS`,
                                           # the row product with
                                           # `-DSINGLE`, and attention twice
                                           # more with `--target-env
                                           # vulkan1.1 -DSUBGROUPS` and the
                                           # same plus `-DQUERY_TILE`. A
                                           # constant is named for the
                                           # compiled file, so they arrive
                                           # as Matrix_Product and
                                           # Matrix_Extra, Row_Product and
                                           # Row_Single, Attention,
                                           # Attention_Subgroups and
                                           # Attention_Tiled.
cd tests && ./bin/tests fuzz --seed 1 --cases 2000
cd tests && ./bin/tests fixtures           # write tests/fixtures/tiny-model.gguf
cd tests && ./bin/tests package .. .       # write model_runner-<version>.tar
cd tests && ./bin/tests external-model --model /path/to/your.gguf [--expect FILE]
cd tests && ./bin/tests fixture-likeness --model /path/to/your.gguf [--names]
cd tests && ./bin/tests render --model /path/to/your.gguf --system S --prompt P
                                           # the model's own chat template
cd tests && ./bin/tests slow                # where the suite's time goes
cd tests && ./bin/tests device-bench        # what an attention call costs,
                                           # and what one vector costs a
                                           # row product in each format
```

`fixture-likeness` asks the question the rest of the suite cannot. Everything
else compares two implementations that were written together, against a
fixture written to suit them; where the fixture and the engine share a wrong
idea about what a model carries, both agree and nothing is said. This folds
layer indices together and compares a published file's tensor list against the
fixture this repository builds for its architecture, reporting what each side
has that the other does not. Pointed at a published `gpt2` the first time it
ran, it named `blk.*.ffn_norm.bias` -- a tensor every gpt2 carries, that the
fixture did not write and the engine did not read.

The suite takes eight seconds, and took twenty-eight minutes until one test
was moved out of it. That test ran the whole conformance sweep -- the same
`Conformance.Run` the gate runs as a stage of its own -- so the gate did it
twice, 948 s inside the suite and 650 s again beside it. Ninety-nine and a
half per cent of the suite was one routine.

It read "a second and a half" here for a long time after that had stopped
being true, and the wrong figure cost a day: the gate timed every stage except
the suite, AUnit prints nothing until it has finished, and a timeout set from
a stale number looks exactly like a hang. The gate says `took: suite` now, and
`tests slow` says where a suite's time goes.

Compiling a template took half a minute until it stopped allocating
twenty-six megabytes: an instruction carried its operand and its condition
inline, and the program is four thousand of them.

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
found any other way. `Encode` looks for a control token at every position
whose byte some piece of the vocabulary begins with, and the scan reached the
longest token the format allows — 1024 bytes — at every one of them. Sixty thousand brackets, well inside the
documented input limit, took **25.5 seconds** where the same length of
ordinary text took a fortieth of a second. Nothing was wrong with the answer.
The scan is now bounded by the longest marker the vocabulary actually holds,
which for the fixture is four bytes and for a real vocabulary about
seventeen; a position whose byte begins no piece costs one array read and no
lookup at all.

`tests benchmark` times both cases now, at a load of 1.11: **0.0139 s** for
sixty thousand ordinary characters and **0.0156 s** for sixty thousand
brackets, so the hostile text costs about an eighth more rather than six
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
conformance: sequences 28344, logits compared 1112976,
             worst absolute 1.75187297983825E-05,
             worst relative 7.44797973352015E-02,
             rounded logits compared 156888,
             rounded worst absolute 1.34238864580048E-01,
             rounded worst relative 1.99697513302233E+00,
             cached logits compared 66720,
             cached worst absolute 9.22560479118539E-03,
             cached worst relative 1.47315387090204E+00,
             quantized logits compared 1248,
             quantized worst absolute 9.12536402497361E-02,
             quantized worst relative 1.92312833924665E+00,
             byte logits compared 66720,
             byte worst absolute 3.02788895569006E-01,
             byte worst relative 1.99904175677735E+00,
             outside tolerance 0, unlearned 0
```

Five buckets, because five things are being compared and mixing them would
let the loosest hide the tightest. The first is the exact path and answers to
1.0E-3 relative and 1.0E-4 absolute; the rounded, cached and byte ones are
`--repack bf16`, an f16 context and a q8 context, each with a measured pair
of its own; the quantized one is `--arith int8`, the arithmetic a run uses by
default, held to 5.0E-2 and 5.0E-1. A count of zero in any of them would say
the sweep ran none of that kind -- which is what a mode that quietly fell
back to another path would look like, and is the reason the counts are
published rather than only the worst differences.

The run above crossed 13 architectures, in 15 formats and 5 shapes,
of which 1248 ran on a device -- which is the same claim the paragraph below makes in
words, and is checked against the run rather than kept by hand.

Thirteen architectures -- `llama`, `qwen2`, `qwen3`, `gemma`, `gemma2`, `gemma3`, `phi3`, `falcon`, `phi2`,
`gpt2`, `bert`, `nomic-bert` and `jina-bert-v2`, each of which has also been read from a file somebody else published -- in each of the five shapes a supported model comes in: dense, sliding-window, a mixture of
experts, a stretched rotation, and heads wider than the embedding implies with
keys and values different widths again. Ten of the thirteen are compared on the
last position's logits and in every shape they can hold; the three that
produce states rather than a distribution are compared on
what the model made of every position, which is the only answer they have and a
stronger one -- a logit is the last state through one more matrix, and these
are every state before that matrix. `bert` holds two of the five shapes: a
mixture wants a gate it has not got, a stretched rotation wants a rotation it
has not got, and a window is a bound on how far back a position may look,
which a model that looks both ways has not got. `nomic-bert` rotates and
gates, so it holds all but the window; `jina-bert-v2` gates but rotates
nothing at all, so it holds all but the window and the stretch. They answer fewer of the
sweep's asks for the same reason -- there is no evaluating a position of one
before the text it reads exists, so a token at a time and a text in pieces are
both refused -- and the ones they decline are counted rather than quietly
missing. The processor and the binary64 backends, every evaluation path -- a token at a
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

One thing to know before taking any of these figures again: `tests speed`
and the `run` command do not count a prompt's tokens the same way. The
checked-in long prompt is 110 tokens as the tool counts it and 130 as the
command reports it, because the command counts what a chat run adds and the
tool counts what the figure describes. Every prompt length quoted here is the
tool's count.

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

`--kv-cache q8` stores it in one byte an element instead, with a scale for
each row -- a row being one position's keys, or its values, for one layer,
which is the unit the evaluator already writes and reads whole. A quarter of
the memory the exact cache takes, and **0.303** worst absolute on these
fixtures, which is thirty times what the halved cache costs and four
thousand times the exact one. The bound this sweep holds it to is 0.4,
measured over every architecture, shape and format it crosses and rounded up.
It is the coarsest thing this program does to a number it will read back,
and it is offered for the case the halved cache does not fit rather than as
a default: nothing chooses it unless asked.

What it saves is now a number the program will tell you rather than one this
document works out: `inspect --kv-cache` reports what a session would take in
each storage, and on TinyLlama-1.1B-Chat Q8_0 at its full 2048-token context
that is **97,251,904** bytes exact, **48,807,695** halved and **24,585,588**
in bytes -- a little under a quarter, the difference being the buffers a
session holds whatever it stores its context in, and the scales.

On the device it is the same story and worth stating separately, because a
storage that halves what crosses to a device might have been expected to pay
there: twelve tokens read **1.169 s** with the byte cache against **1.151 s**
without, which is inside the spread between two runs. What the device reads
back is a row it decodes on the host either way, so there is nothing here for
it to save.

What it costs in time is nothing this machine can measure: twelve tokens of
TinyLlama-1.1B Q8_0 take **1.912 s** with the byte cache against **1.871 s**
with the exact one, and two runs of the same figure an hour apart on this
machine differ by more than that. Packing a row is one pass over what a
projection had just written hundreds of products into, and unpacking is a
multiply where a read used to be, so this is what one would expect rather
than a surprise -- but it was arithmetic about memory until it was a
measurement about time, and those are different claims.

What it costs in what the model says is not nothing. The same twelve tokens
come out as a different digest -- `7d3e2df2d776ba62` against
`5abff916f9d83ca6` -- so at eleven hundred million parameters and twelve
tokens the byte cache has already changed the text. The exact and halved
caches agree with each other on that run; this one does not agree with
either. A storage offered for the case the halved cache does not fit is a
storage whose output is its own.

A rolling context in that storage loses a little more of what it keeps every
time it rolls. `Shift` turns the surviving keys back by the angle it dropped,
which means decoding a row that was already rounded and rounding it again --
the price of the storage rather than a fault in the shift, and worth knowing
before running a long conversation on it.

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
chooses for itself and at the arithmetic it chooses for itself. From the
six-token prompt in `tests/fixtures/speed-prompt-short.txt`, twelve tokens
take **0.437 s** -- 0.066 s evaluating the prompt and 0.371 s generating --
and **1.59 s** of processor time, the median of three runs. Loading the model
costs a further **0.066 s** of wall that this figure does not include, and it
used to cost 0.6 s: the weights are the file's own pages now rather than a
copy of them, so what loading does is open a mapping and what reading them
costs is paid as they are touched.

The arithmetic is half of that. `--arith int8` is the default and rounds the
vector a product multiplies to a byte an element; the same run at `--arith
f32`, taken back to back in the same sitting, is **1.487 s** for 9.00 s of
processor time. What that costs is measured and bounded in `### Quantized
activations` below, and it is why every figure in this section is worth
reading twice: once as a time, and once as a statement about which of the two
arithmetics it was taken in.

The figure this replaces was 3.743 s for 21.11 s of processor time, and the
one before that 1.88 s for 10.4 s. Neither was wrong when it was taken. The
3.743 was a machine carrying somebody else's virtual machine at two thirds of
a processor, which that entry said at the time; the machine is its own again
and the whole section was taken again on it in one sitting, so the figures
below can be read against each other. That they now sit below the quiet-host
1.88 as well is the program rather than the machine, and it is the only part
of this paragraph that is about the program at all. Every run prints the
digest it always has.

The run is

```
model_runner run MODEL --raw --prompt-file tests/fixtures/speed-prompt-short.txt \
  --seed 1 --temperature 0 --max-tokens 12 --show-stats
```

`--show-stats` says which of the two a run got, because the difference is
large enough to explain a figure on its own: **weights -- the file's own
pages, read as they are touched**, or **read into memory at load**. A model
this program did not copy costs nothing to load and only the pages it
touches; on Qwen3-30B-A3B, twelve tokens from a cold cache take 15.84 s
against something over forty seconds before, and the resident set peaks at
4.6 GB against an arena of 11.25 GB -- a mixture routes to eight experts of a
hundred and twenty-eight, so most of that file is never read at all.

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

The worker count is what that processor figure is about. Taken back to back
in the same sitting, the same run at fifteen threads takes **0.497 s** of
wall against **0.437 s** at seven, and 1.86 s of processor time against
1.59 s.

That is fourteen per cent *worse* on the wall for seventeen per cent more
processor time, where the sitting before read eight per cent worse for
fifteen per cent more, the one before ten per cent worse for seventeen per
cent more, the one before that two per cent worse for fifteen per cent
more, the one before four per cent *off* the wall for ten per cent more and
the one before that one per cent off for sixteen. All three
are inside what this pair resolves, and the honest summary after ten
readings is that **the second worker on a core buys nothing either way** --
the readings have landed on both signs and keep changing which. The sequence is still the story:
eighteen per cent off the wall for fifty-five per cent more when the host was
quiet and the kernels were slow; eleven per cent worse for twenty-nine per
cent more while the host was sharing two thirds of a processor with somebody
else; seven per cent worse for ninety-seven; nothing at all for
ninety-seven; one per cent better for seventy-eight; four per cent worse for
fifteen; one per cent better for sixteen; four per cent better for ten; five
per cent worse for seventeen; and two per cent worse for fifteen.

The processor times in that pair are also far below what this paragraph used
to record -- 1.88 and 1.63 against 4.75 and 2.71 -- and that is not one
change but several kernels: the two figures were carried through restampings
without being taken again, and they are taken again here.

What moved it back is the arithmetic. A second thread on a core cannot fetch
memory the first one is already waiting for, which is why the middle three
readings were what they were -- and a product that multiplies bytes rather
than widening them into binary64 waits on memory less and on execution units
more, so there is something for the second thread to do again. The default
stays one worker per core: one per cent of wall for seventy-eight per cent
more energy is not a bargain on a part sharing fifteen watts with a device, and
`--threads 14` is there for a caller who wants the other side of it.

An older version of this paragraph gave 2.29 s against 2.43 s and 17.3 s
against 10.1 s, taken with the shell's timer, on runs whose load nobody
recorded, and including the model load that these exclude. Every number in it
was replaced rather than corrected. Through all three readings the default of
one worker per core is the one to keep, and it has never been a close call in
energy; on this host it wins on energy by nearly half and gives up one
per cent of the wall to do it. A caller who wants to try the other way can still ask for
`--threads 14`, and should measure it on their own machine rather than trust
any of the figures here.

A job is cut into one more piece than the pool has workers, because the task
that submits it takes the last piece rather than waiting; the figures below
count those pieces, and so does the benchmark. Eight of them is this machine
fully occupied, since it has eight cores -- reported as sixteen processors,
which is not the same thing. Eight shares take 0.437 s for 1.59 s of processor
time and fifteen take 0.497 s for 1.86 s: the second worker on a core shares
the first one's execution units, and what is left over for it to use is
small enough that the pair keeps changing sign. Fourteen per cent *slower*
for seventeen per cent more processor time, where the reading before this one
was eight per cent slower for fifteen, the one before ten per cent slower for
seventeen, the one before five per cent slower for
seventeen, the one before that
four per cent *faster* for ten per cent more, the one before that eight
per cent slower for fourteen, and the ones before those bought nothing for
eighty-one per cent more, three per cent for eighty-four, and eleven per
cent for seventy-six. The denser the kernel, the less its sibling finds spare, and
a share that finds nothing spare is a share that costs a hand-off. There are only 2015 matrix products in a run this size, so
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
shares went from 9326 Me/s to 14182. Taken again with the command above,
eight shares reads 13635 Me/s against seven at 12445 -- so with one vector a
pass eight is *above* seven, by nine and a half per cent, where the sitting
before read it one per cent below, the one before three and a half below, the
one before that nine above, and it used to fall by a quarter and then by six.
Batched it is below: thirty-two vectors a pass reads 23330 at eight against
23922 at seven, by two and a half per cent. What the change was for was the
quarter, and the quarter is gone: what is left flaps around zero by a few
per cent and changes sign between sittings, which is the honest reading of
five of them. The 9326 is history: it needs the commit before the change, and it is
quoted here as the reason rather than as something a reader can reproduce.

Unpinned, eight is above seven batched -- 24407 against 22539, eight per
cent -- and is below it with one vector a pass, 11021 against 12031, by
eight. That is the reading this paragraph was written around returning: it
used to fall below with one vector by four per cent, then rose above by
seven, then sat two below, then six above, then five below, then three above,
and is eight below again, at a level about a tenth under the sitting before
across every share count and on both compilations of the kernel, which is
what says the level is the sitting and the sign is the shape. unpinned, the spare task can take a processor
on a core that already has one, which is cheap but is not free, and the
narrower the work per share the more the sharing shows. What removed the
last of it is not the pool but the work each share now does between
hand-offs. Pinned is still the case worth being right about, because it is
what a container with a processor budget looks like, and the eighth share
pays in both.

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
the matrix product reaches about 5.2x on eight shares against its own serial
rate, and reaches it whether one vector is passed or thirty-two -- 2491 to
13635 Me/s in the first case, 5.5x, and 4654 to 23330 in the second, 5.0x,
medians of three runs, pinned. The batched case peaks at eight shares when
pinned and the one-vector case at seven; which of the two peaks where has
changed between sittings, and that is the reading that moves rather than the
shape of the curve.
If memory were the wall those two would part company, because the second reads
each weight byte once for thirty-two multiplies and the first reads it once
for one. At eight shares the product moves about 17 GB/s, which this machine is
not troubled by. What does change is the clock: 4927 MHz with one core busy
and 3926 with eight, sampled from the host while running -- and **how hot
the part already is**, which is the same thing arriving by another route and
was found by accident. The load gate stopped waiting for a load average to
decay, and the wait it removed had been serving as a cool-down nobody had
noticed. The same benchmark on a part at 47 degrees and on one that had just
finished another benchmark:

| | settled, 47 C | straight after, 81 C |
| --- | ---: | ---: |
| q8_0 `Row_Dot` | **2739** | 2399 |
| q4_k `Row_Dot` | **2688** | 2400 |
| one share | **2602** | 2380 |
| eight shares | 14030 | 13681 |

**The serial rows lose a tenth and the eight-share row loses two per cent**,
which is the whole story in one table: a hot part gives up single-core boost
first, and the all-core figure is already at the sustained clock where there
is nothing left to give up. Every figure in this section is a serial rate or
a ratio against one, so every one of them is boost-sensitive. They are taken
on a part that has stopped cooling -- two readings twenty seconds apart
within a degree -- and both runs quoted here started at 56 and 58 degrees,
warmer than the 47 to 50 of the sittings before, for the reason `### A
slower day, measured on both sides` gives. That ratio alone
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
13505 Me/s against 13635 at eight shares with one vector, 21968 against 23330
with thirty-two, and 2515 against 2491 serially. Which of the two leads
changes with the case and with the run: four-bit one per cent behind with one
vector here, six per cent behind batched, one per cent ahead serially -- level
on all three -- where the nine sittings before read it level, level, level,
level, ahead by ten with one vector, ahead by two, behind by two, level, and
behind.
Read eleven times, the pair is level and the sitting is the spread.
That is the finding -- they are level, and a gap either way at one shape is the
machine rather than the format. End to end they are level too, and the two
files have to be read a token at a time to see it: alternating the two round
by round, four-bit generates at 86.8 and 92.4 ms a token against eight-bit at
92.7 and 89.3, which is two readings each that bracket one another. The wall
times themselves -- 1.133 and 1.199 s against 1.400 and 1.364 -- say nothing
about the formats, because the four-bit file answers this prompt in ten tokens
and the eight-bit one in twelve. The pair this replaces, 2.06 and 2.18 s
against 2.06 and 2.26, was quoted as a wall time and had the same ten against
twelve inside it, unnoticed.

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

Four tokens from the short prompt, medians of three, taken back to back at a
`cpu` spends 0.065 s evaluating the prompt and
0.127 s generating; `reference` spends 5.834 s and 3.891 s. That is
**fifty-one times** the work in total, ninety times on the prompt
and thirty-one times on the generation, and the two print the same digest.

The ratio doubled when the default arithmetic changed, and it is worth being
clear that only one side moved: `reference` computes what it always did.
Comparing the two at `--arith f32` gives fifteen times, and the ratio at
the default has grown again with the arithmetic: the byte dot product moved the `cpu`
side and `reference` still computes what it always did.
The prompt suffers more because that is where the batching goes: `cpu` shares
one reading of the weights between the tokens of a batch and `reference`
declines to, which is one of the things it exists to be without -- so the
comparison hands it a batch size of one, as the command does.

Four tokens rather than twelve, because ten times is a long time to wait for
a figure whose shape is already clear at four.

This number was published as forty times for as long as the backend has
existed, taken by hand and never checked; then as twelve and a half, taken by
hand again; then as nine, on a host sharing two thirds of a processor with
somebody else, where the `cpu` side had less to lose than the serial one.
`tests benchmark` measures the algorithmic part on synthetic tensors --
serial against serial, no pool on either side -- and reports 2.37x for q8_0,
2.31x for q4_k and 3.08x for f32. The rest of the fifteen is the worker pool
and the batching, which is the honest way to read the figure: `reference` is
between two and three times slower than the same loop written for speed, and
the remaining factor is the parallelism it has none of. The generation ratio
moved most across these readings, from under five to twelve to thirty-one,
and in the direction the same explanation predicts: what got faster this year is
the kernel the pool runs, and the reference declines the pool.

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
| 6-token prompt, 12 generated | 0.449 s | **0.350 s** |
| -- evaluating the prompt | 0.068 s | 0.059 s |
| -- generating | 0.380 s | **0.291 s** |
| -- processor time | 1.60 s | **0.03 s** |
| 110-token prompt, nothing generated | **0.465 s** | 0.162 s |
| -- processor time | 2.51 s | 0.16 s |

All six cells were taken in one sitting on 2026-08-28, back to back, each
waiting for the machine to fall below 1.20 before it started -- so the two
columns are comparable, which they were not in the version of this table
before last. The generating row is where the last change landed: it read
0.378 s until `### The batch that was not there` below.

**The device wins both runs now, and spends a fortieth of the processor's
time doing it.** Six changes took its 110-token prompt from 1.951 s to
0.280 s -- the default batch, the results a product reads back, the
activation it writes, the kind of memory those results are read out of, the
width of a workgroup, and -- last and largest -- the batch computed as a
matrix product through the device's own matrix instruction rather than as a
row product repeated, which `### The matrix instruction` below is about and
which is worth 0.527 s against 0.280 on its own. The workgroup width is the
one that finally moved the short run, and it is the only one inside the
shader that a generated token feels: a row is computed by eight invocations
rather than one.

That last one is worth reading twice, because it was nearly thrown away. On
a prompt it is a wash -- 0.531 s at one lane a row against 0.537 at eight,
which is inside the spread -- and on that evidence it was going to be
reverted. Generating it is 2.099 s against 2.973, better in each of three
rounds and steadier than the row it replaces.

The reason is arithmetic about the part rather than about the program. A
2048-row product dispatched 256 invocations to a group is eight workgroups,
and this device has twelve compute units: a third of it had nothing to do
for every token generated. Reading a prompt hides that, because a prompt is
sixteen dispatches deep and the second fills what the first left idle; a
token is one dispatch and there is nothing behind it. Eight lanes to a row
makes the same work sixty-four workgroups.

So it is the first change here aimed at a part that was measurably idle
rather than at an operation that looked expensive, and it is worth more than
any of the arithmetic ones: **twenty-nine per cent of a generated token**,
where quantizing the activations bought twice that on the processor and
everything since has bought three to five per cent.

The last of those was an open question on this page for a day, and the
answer is worth keeping because the question looked like a hardware mood.
The same run read 0.608 s in one sitting and 1.70 s in the next with the
code between them unchanged, and the difference was all processor time: 1.04
s against 0.11 s. The explanation published here first was that attention
had fallen back off the device, and that was a guess about a number nobody
could see -- so the engine was taught to report it. `--show-stats` says
**bytes of context on the device**, and it said the context was there:
92274688 bytes of it, under a smaller `--device-memory` as well as the
default. With the processor fallback compiled out entirely, so that it could
not run at all, the run still took 1.692 s. Attention was on the device
throughout.

What it was: a buffer the processor reads was being allocated out of memory
the device owns. This engine asked for one kind of memory for everything it
shares with the device -- the first kind that is host-visible, coherent and
the device's own, which is the right answer for what the device reads and
the wrong one for what the processor does. Reading it back is uncached and
uncombined, around a tenth of the bandwidth writing it gets, and a 110-token
prompt reads about ninety megabytes of results. That is the missing second.
A result buffer is allocated out of a cached kind now, and uploads and the
cache still come from the device's own memory, which is what they want.

Once a bisect could run -- every commit in the range builds, which is a
property that has to be maintained deliberately -- it said the slowdown was
in none of them. That is what turned the search from the program's history
to the machine underneath it.

The processor row is still the argument for the backend where it holds:
0.04 s against 3.05 s on the short run, which is a seventy-sixth.

The load each run printed is in `docs/measured-figures.txt`. Note that a
`cpu` run's load-after is mostly its own doing: seven workers for a second is
eight seconds of processor time, so that column ends above where it started
whatever else the machine is doing, and it is the load before a run that says
whether the machine was quiet when it started.

Both backends print the same digest of what they read -- `cbf29ce4` for the
110-token prompt -- so this is the same text, not a faster answer to a
different question. The short run's two digests differ, and what they say is
which arithmetic ran rather than which backend: `--arith int8` is the
processor's default and the device computes in binary32, and asking the
processor for `--arith f32` brings back the device's own `5abff916`. It
costs 1.170 s that way against 0.509 s, which is the quantized activations
measured from the other end.

Both rows are the device attending for itself. The short run generates, and
generating goes a position at a time, so its 1.262 s became 1.098 s when each
position started attending where its matrices already are instead of coming
back here for a blend.

The long run generates nothing and is a batch of 110 positions, and it took
two changes rather than one. Attending a position at a time made it worse,
2.504 s to 2.894 s, because a call to a device costs something before it
computes anything and a 110-token prompt over twenty-two layers is 2420 of
them. `tests device-bench` says what that is: the whole triangle submitted a
position at a time is 0.489 s in 2420 calls, 202 microseconds each, against a
floor of 128 microseconds measured at a shape whose arithmetic runs at 0.03
Gflop/s and is therefore almost entirely the call itself.

The same triangle submitted a call a layer is 0.110 s in 22 calls, because
the positions of a batch read the same cache and write their own blends and
so never need each other. That is what the kernel now does -- a workgroup a
head of a position, where it was a workgroup a head -- and the row went to
2.621 s, past the 2.504 s it started at. Two readings, 2.371 s and 2.621 s,
both at a load of about 1.45; the slower is published.

The agreement this was in aid of is not optional, whichever way the figure
had gone: a drafted run checks its proposals through the batched evaluator
and generates through the other, so a device wired into one and not the other
makes the two say different things, which is what the suite caught.

A layer's attention and the matrix that reads its blend are named together
now, so they go over as one command buffer and the blend never comes back to
be sent again. It saves nothing, and the way that was established is worth
more than the result.

Measured first as two blocks of two hundred rounds -- all the apart ones,
then all the together ones -- it read 0.456, 0.553 and 0.848 ms saved across
three runs. Measured again the same way later, on the same binary, it read
1.036, 0.307 and 0.589 ms **lost**. Whatever moved on this machine between
one block and the next landed entirely on whichever arm ran second, and the
sign of the answer followed it.

Alternating the two arms round by round puts the same drift through both.
Done that way, four runs agree: on an idle device the joined pair costs
0.836, 0.695, 0.933 and 1.104 ms, and with a layer's other submissions
around it the difference is -0.005, +0.184, +0.254 and +0.390 ms -- nothing,
either way. A submission costs waiting, and a device that already has work
queued is not idle to be waited on.

That agrees with the end-to-end figures, which is the point of taking both.
Three readings of the generating run before the change and three after:
1.019, 1.081 and 1.098 s against 0.976, 1.067 and 1.088 s -- no movement
where 264 crossings at half a millisecond would have been 130 ms. The
half-millisecond was never there. The pair stays named together because the
engine's case is the layer one, where it costs nothing either; it is not
claimed to earn anything.

Read the left column with the caveat it deserves. The two columns are not
equally exposed to whatever else is running: the processor column competes for
the cores it is using and the device column mostly waits on a fence. That is
why the left column has moved twice in this table's life and the right one has
barely moved at all. Over eight pairs taken on an earlier and quieter machine
the processor's short run ranged from 1.42 to 2.17 s and the device's from
1.21 to 1.80, with the device below the processor in seven of the eight; the
processor's short run is 1.198 s now, below the whole of that range, which is
the program rather than the machine. The device's short run is where it has
always been. On the long run the device has never been close and still is
not.

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
its summary. These four were taken starting from loads of 1.30, 1.30, 1.19 and
1.50; the pairs are adjacent, which is what makes the two columns comparable.

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

Three things that ought to have made the prompt faster do not, and the
readings are here because the next person to look will think of the same
three. The 110-token prompt takes **1.937 s** on the device as this shader
stands.

- **Dividing a row's blocks between the lanes.** One row per invocation means
  lane *j* of a wave reads row *j*, which for a Q8_0 row of 2048 is 2176
  bytes between one lane's first byte and the next lane's. Giving a row to a
  workgroup slot and its blocks to the lanes, with a tree reduction at the
  end, was written and measured at every shape that fits: 4.300 s with
  sixty-four lanes to a row, 1.994 with sixteen, 1.834 to 2.205 with eight,
  2.181 with four. The best of those is the figure it already had. A row of
  2048 columns is sixty-four blocks, so at sixty-four lanes each lane decodes
  one block and then pays six barriers to add up eight accumulators, which is
  most of what the dispatch does.
- **Reading the quants a word at a time.** `byte_at` issues one 32-bit load
  per byte, so a Q8_0 block costs thirty-two loads where eight would do.
  Alternating a word-wide Q8_0 decode against the byte-wide one, three rounds
  each: 3.695, 3.622 and 3.381 s of generation against 3.744, 3.616 and
  4.595. They bracket each other. On the prompt it read 2.018 s against
  1.937.
- **Anything about the memory.** Fourteen passes over 1.09 GiB in 1.95 s is
  7.8 GB/s on a part with something near ninety, so the shader is not waiting
  on the bus and moving fewer bytes was never going to help.

What that leaves is what is in flight rather than what is read: 2048 rows at
one invocation each is thirty-two workgroups of sixty-four, which barely
fills the part, and each invocation walks a whole row of dependent scalar
loads with nothing to interleave against it. llama.cpp reaches 1657 tokens a
second on this same device, so the hardware has thirty times more in it; what
this section can say is that three plausible explanations for the gap are not
it.

One thing worth keeping from the attempt, though the code is not: a
write-back that gives each vector of the batch to one lane silently drops
vectors when there are fewer lanes than the batch is wide. It answered a
fifth of a prompt and left the rest at zero, and the tests caught it, and it
would not have existed at all if the write-back had strided instead of
assuming a ratio between two constants that are free to move.

The shader takes a batch. One invocation carries eight vectors and reads each
weight once for all of them, so a prompt is one reading of the model rather
than one per token. That is where the long-prompt figure comes from, and it
is the whole difference between this backend and the first version of it,
which declined to batch and evaluated a five-token prompt as five passes over
every matrix -- 1.5 tokens a second against the processor's 43.2.

Two more that ought to have helped, measured after the batch did. The
110-token prompt on the device reads 1.054 s and sixty-four generated tokens
4.541 s as this shader stands.

- **Carrying more vectors in one dispatch.** A dispatch holds `GROUP`
  vectors, so a prompt passes over the whole model `ceil(N/8)` times; sixteen
  would halve that. It does not help, and the shape of the curve says why it
  cannot: the prompt reads 3.471 s at two vectors a dispatch, 2.451 s at
  four, **1.054 s at eight** and 1.219 s at sixteen. If the weights were what
  the shader waited for, sixteen would have won by halving them. Generating
  at sixteen reads 13.246 s against 4.541 -- generating is one vector, and a
  group of sixteen multiplies every weight of the model sixteen times to
  produce one number and throws fifteen of them away.
- **Not doing that.** Bounding the accumulation by the vectors a dispatch was
  actually given rather than by `GROUP` removes exactly that waste, and it is
  the worst change measured here: the prompt goes to 9.470 s and generating
  to 27.198 s. A constant bound is what lets the accumulators and offsets
  stay in registers; a bound read from a push constant puts both arrays in
  memory, and the arithmetic saved is a fraction of what the spilling costs.
  The comment above `GROUP` in the shader has said so since it was written,
  and now it has numbers.

What is left is not the submissions, and the arithmetic that said it was
deserves recording as a warning. Sixty-four tokens generated on the device
take 2.649 s, which is 41 ms a token; a token is 22 layers of three
submissions each; 41 divided by 66 is 0.63 ms, which lands inside the 0.6 to
2.3 ms a call the batch measurement bracketed. From that this file used to
conclude that device generation was very nearly all host round-trip, and that
collapsing a layer into one recording was the next thing worth doing.

**It was built, and it is slower.** A fourth shader does the normalizations
and the residual additions on the device, so a layer's second half goes over
as one submission, and a second version carries that submission on through
the next layer's projections as well -- sixty-six submissions a token, then
forty-four, then twenty-two. Three rounds, alternated, every digest identical:

| A token of 64, generated | median |
| --- | ---: |
| three submissions a layer | **2.650 s** |
| two -- the block in one recording | 2.767 s |
| one -- the whole layer | 2.794 s |

Fewer submissions, slower runs, monotonically. What fusing actually trades is
submissions for pipeline barriers: three submissions a layer carry three
barriers between them, and one carries ten. A barrier drains the device, and
against dispatches this small the drain costs more than the submission it
replaced. The division into 0.63 ms a submission was arithmetic that happened
to land in a plausible range, not a measurement of what a submission costs
when there is one fewer of them.

So the next thing worth doing to this backend is not known, and this file
would rather say so than name the wrong one twice. What is ruled out is
above; what is untried is the shader's own efficiency, which the seven point
eight gigabytes a second under `### Batched prefill` says is not bandwidth.

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

`--device N` says which of the host's devices to compute on, counting from
one in the order `inspect` lists them. A machine with one device has nothing
to choose and the default chooses it; a machine with an integrated device
beside a discrete one has a reason to say which, and until now the answer was
whichever the host named first. A number past the devices the host has is
refused rather than fallen back from: a caller who asked for the second
device and silently got the first would be told the wrong thing about what
its figures describe.

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
| copied to the device, all of them | 23.19 tokens/s |
| a seventh copied, the rest uploaded again as wanted | 3.18 tokens/s |
| read where they lie, none copied | 1.69 tokens/s |

So giving matrices back and uploading them again beats reading the host's
memory by nearly two to one, and either costs four to nine times what having
the weights there costs. Reading where they lie is worth asking for only when
the machine cannot hold the model twice -- which for a seven-billion
parameter model at eight bits is fourteen gigabytes against seven. The
statistics say which of the three happened: 155 matrices on the device and
none given back for the first row, 21 on the device and 1994 given back for
the second, 154 read where they lie for the third.

Under the model, one product at a time, `tests benchmark` measures where that
leaves each format. It prints the machine's load at both ends of its run --
1.70 rising to 2.37 for the figures below -- and **refuses to measure at all
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

Both of those columns were taken before the results a product reads back
came out of cached memory, and the ratios below are from after it: the point
they make about load survives the change, the numbers do not.

Which is what the bias predicted: the single-vector cases are the close ones,
where a processor slowed by other work is most of the difference, and the
batched cases are so far in the device's favour that the machine around them
barely shows. Two readings taken today at loads of 1.88 and 1.64 agree with
each other to within a few per cent on every row, which is the same point
from the quiet end: the spread above is what a wide difference in load buys,
and a narrow one buys nothing worth publishing.

All fifteen formats are measured now, one vector a pass and eight, which
they were not while the shader decoded three of them: twelve branches
arrived with nothing timing them, and a format can be perfectly correct and
four times slower than the one beside it with nothing to say so. A 512 by
2048 matrix, resident, against the serial processor path -- the device's time
as a fraction of it, so below one is faster there, taken in one run at a load
of 1.08 rising to 1.28, most of the rise being the run itself:

| Format | One vector | Eight | | Format | One vector | Eight |
| --- | --- | --- | --- | --- | --- | --- |
| Q2_K | 0.13 | 0.10 | | Q3_K | 0.20 | 0.11 |
| IQ4_NL | 0.14 | 0.08 | | F16 | 0.34 | 0.12 |
| Q5_1 | 0.17 | 0.08 | | Q8_0 | **0.23** | **0.08** |
| Q5_0 | 0.17 | 0.08 | | Q4_K | 0.37 | 0.12 |
| Q4_1 | 0.17 | 0.07 | | Q5_K | 0.30 | 0.15 |
| IQ4_XS | 0.25 | 0.12 | | Q6_K | 0.49 | 0.12 |
| | | | | Q4_0 | 0.26 | 0.08 |
| | | | | BF16 | 0.60 | 0.14 |
| | | | | F32 | 0.72 | 0.15 |

and q8_0 at thirty-two vectors a pass, which is 0.039.

**Every cell of the one-vector column fell** between this reading and the
one before it -- Q2_K from 0.28, Q5_K from 0.59, Q8_0 from 0.36 -- and the
eight-vector column did not move at all. That is the narrow row kernel of
`### The batch that was not there`: it is bound to a batch of one and the
eight-vector column is the control that says so.

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
at its best. Q4_0 has moved from that end of the column to the other since
this table was last taken, 0.54 to 0.90, and nothing about the device
explains it: the processor's Q4_0 kernel got nearly twice as fast in the same
period, which the per-element table under Kernels says in its own units. A
ratio moves when either half of it does. The order of that column is nearly the reverse of the
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

### What the device's prompt is waiting for, and two ways that did not help

The device's prompt is the widest gap in this file -- 201 tokens a second
against 1681 -- and the shader has been read for it twice. It already reads
each weight once for the eight vectors an invocation carries, so the weights
are not what it re-reads. The activations are: `accumulate` wants GROUP
values for every weight, and in the order the engine keeps a batch those lie
a whole row apart, so eight cache lines are touched for one weight read.

**Ablate it before designing against it.** Building the shader with that read
replaced by a single address -- the wrong answer computed by the right
instructions -- takes the 110-token device prompt from 0.516 s to 0.394 over
three alternated rounds. So the activation reads are about a quarter of it,
and worth attacking.

Two ways were built and measured, and **both are worse than the thing they
replace**:

- **A window of the activations in shared memory**, staged once for the
  workgroup's thirty-two rows and swept a window at a time: **1.399 s**,
  nearly three times the baseline. Two barriers a window is sixteen a row,
  and this shader's own notes already record a per-block barrier measuring
  4.300 s against 1.937. Barriers on this part are dearer than almost any
  read.
- **Turning the batch as the host stages it**, so the eight values a weight
  wants are consecutive: **0.746 s**, half again worse, and it also cost the
  correctness of a fused sequence until the shader was told which layout it
  had been given. The reason is the one the ablation hid: a lane reads
  thirty-two consecutive columns of one vector per block, and turning the
  batch trades contiguity along thirty-two columns for contiguity along
  eight vectors. The ablation did not measure the scatter, it measured
  removing seven eighths of the loads, and reading it as the scatter is the
  mistake this file keeps making in new clothes.

### The matrix instruction, and the shape that pays for it

`VK_KHR_cooperative_matrix` is what the other runtime's 1673 tokens a second
is, and this device has it: **revision 2, sixteen by sixteen by sixteen at
subgroup scope**, offered for half-precision into binary32 and -- which
matters, because the weights already are bytes -- for signed bytes into a
thirty-two bit sum.

**Two things had to be true before any of it could run.**

The first was a promise this program had kept since it had a device at all:
it asked the loader for Vulkan 1.0, because 1.0 is what every loader has. A
shader using the instruction is SPIR-V 1.6, which a 1.0 instance may refuse.
**The floor moved without the promise changing.**
`vkEnumerateInstanceVersion` is itself a 1.1 function, so a loader that does
not export it is a 1.0 loader by definition; ask for it through
`vkGetInstanceProcAddr` with no instance, request the best it answers up to
1.3, and fall back when `vkCreateInstance` refuses. A host with a 1.0 loader
runs exactly what it ran before.

The second is that the instruction's operand is half precision and does not
convert on the way in. Loading binary32 into a half-precision matrix
*reinterprets* it, and the answers come back as not-a-number -- which is
worth stating plainly because it looks like a conversion and compiles like
one. A fifth shader makes the copy, once per product.

**This was built once before and thrown away.** That attempt was correct and
2.4 times slower, and three ablations said which parts were not to blame:
converting the batch once rather than once per workgroup was worth fourteen
per cent, decoding four quants a word was worth a thousandth, and replacing
the operand load with a single address -- perfectly cached and wrong -- was
worth less than that. What was left was the shape of the work: a sixteen-row
output tile is a hundred and twenty-eight workgroups of one subgroup each,
on a part that runs five hundred waves for the shader it would replace.

**The shape is the whole of what changed.** A workgroup now takes
thirty-two rows and a hundred and twenty-eight vectors of the answer -- two
weight matrices against eight vector ones, sixteen accumulators held in
registers by a single subgroup from a row's first column to its last, and
the weights decoded into two kilobytes of shared memory a block at a time.
Measured on the matrices this model is made of, in a harness that does
nothing else and counts the half-precision copy against itself:

| product | |
|---|---:|
| 2048 × 2048, 128 vectors | 1845 GFLOP/s |
| 5632 × 2048, 128 vectors | 2249 GFLOP/s |
| 2048 × 5632, 128 vectors | 2039 GFLOP/s |
| 32000 × 2048, 128 vectors | 3842 GFLOP/s |

Four things decided that shape and three of them were the other way round
from the guess:

- **More vector matrices than weight ones.** Four vector matrices against
  one weight matrix read 957 gigaflops; one against four, the same four
  accumulators turned round, read 328. A weight matrix comes from shared
  memory and is used by all of them; a vector matrix comes from memory and
  is used once each.
- **One subgroup to a workgroup.** Two read 1709 and four read 1512 against
  one's 2005, at the tile shapes that suited each.
- **A step of thirty-two columns, which is one Q8_0 block deep.** Sixty-four
  reads 1634 against thirty-two's 2012 -- a deeper step is fewer barriers
  and more shared memory, and the shared memory is what a part decides its
  occupancy by.
- **No test for a partial tile.** Bounding the loops by what the batch
  really holds costs a fifth of the speed, 1647 against 2031, because a loop
  whose length is not known when it is compiled is a loop whose accumulators
  cannot stay in registers. The host rounds the batch up to a whole tile
  instead and the copying shader zeroes what the rounding invents.

End to end, on the same 110-token prompt every other figure here uses:

| 110-token prompt on the device | Q8_0 | Q4_K_M | Q5_K_M |
|---|---:|---:|---:|
| the row product | 0.527 s | 0.891 s | 1.368 s |
| with the eight-bit format tiled | **0.280 s** | 0.891 s | 1.368 s |
| and the four-bit k-quant | | 0.402 s | |
| and the six-bit one | | **0.300 s** | 1.368 s |
| and the five-bit one | | | **0.305 s** |

Medians of three alternated rounds, better in every one, and every digest
unchanged -- `cbf29ce484222325` and `448c2ed68ec342ee` and
`4b6e8e99ae285b2a`. Generating is untouched, 2.363 s against 2.383, and has
to be: a generated token is one vector, and sixteen is the narrowest matrix
the instruction has.

**The three k-quants a "_M" file is made of reach it too**, and between them
they are what published models are actually shipped in. Only the decode
differs from the eight-bit one -- four bits from a nibble less a minimum,
the same with a fifth bit held in an array of its own, or six bits in two
places times a signed sub-block scale, all worked out in binary32 and
rounded once into the tile -- so the four share a shader and the branch is
on a push constant, uniform across a workgroup and taken once a step.
Adding each costs the ones already there nothing: 0.286 s against 0.282 for
the eight-bit file, 0.299 against 0.301 for the four-bit one, across the
same rounds that moved the format being added.

**A "_M" file is a mixture, and that is the whole reason all three had to go
in.** The four-bit format alone took the four-bit file from 0.891 s to 0.402
and stopped there: a sixth of its weights are six-bit, the output projection
among them, and a sixth left on the row product cost more than a quarter of
what was left. The five-bit file makes the same point from the other end --
tiling its six-bit sixth was worth 1.515 s to 1.419 and no more, and tiling
the five-bit five-sixths took it to **0.305**.

**So the three published quantizations of this model now read a prompt on
the device in the same tenth of a second**: 0.286 for the eight-bit file,
0.299 for the four-bit one and 0.305 for the five-bit one, where this
morning they were 0.527, 0.891 and 1.368. The smaller file is no longer the
slower one, which it had been since the device could read k-quants at all.

**And the two sixteen-bit formats, which cost nothing to add.** Half
precision is already what the tile holds, and brain floating point has fewer
mantissa bits than half precision has, so both reach the operand exactly and
the decode is a copy or a shift. A `--repack bf16` prompt on the device reads
**0.302 s against 1.164** -- medians of three alternated rounds, better in
every one, digest unchanged -- which puts a sixteen-bit model level with the
eight-bit one's 0.286.

They also settle what the difference between the tile and the processor is
made of. Measured on the same fixtures, half precision differs by 7.9e-3 and
brain floating point by 7.9e-3, against 7.1e-3 for the eight-bit format and
7.4, 9.5 and 8.1 for the k-quants. **Two formats whose weights arrive exact
differ by as much as the ones that are unpacked**, so what is being measured
is the half-precision operand and not any decode.

**Binary32 is deliberately not among them.** The tile's operand is half
precision, so a binary32 weight would lose thirteen bits of mantissa on the
way in, and a caller who has kept a model at binary32 has asked for exactly
those bits. It stays on the row product, which multiplies in binary32, and
the device format test holds it to the tight bound to prove it still does.

**Where it does not run**, which is still most places. Nine of the fifteen
formats, because `matrix_product.comp` decodes half precision, brain
floating point, eight-bit blocks and the four-, five- and six-bit k-quants,
and nothing else. Every row count the thirty-two-row tile
does not divide, because a workgroup writes a whole tile and a partial one
would write into the next vector's answers. Every batch shorter than
thirty-two. Every device without the extension, and every device whose
subgroups are not sixty-four wide, because the shader's arithmetic is
arranged for a subgroup of that width and is asked about rather than
assumed. All of them go to `row_product.comp`, which reads all fifteen
formats and needs nothing of the device beyond Vulkan 1.0 -- and which is
what this program did everywhere until now.

**And where the rest of a device prompt goes, now that the products are a
matrix product.** The scratch harness says this model's products are about
0.124 s in isolation and the prompt reads 0.28, so more than half of it was
something else. Two suspects were written down here: the eighty-eight of a
prompt's hundred and fifty-four products that go one to a submission with a
fence wait each, and the narrow K and V projections at 403 GFLOP/s against
1845 for the wide ones.

**The first instrument was wrong, and that is the part worth keeping.**
Skipping a kernel and taking the difference does not work when the kernels
feed each other: three of six ablations came out *slower* than the run with
everything in it, because what the others then read was not what they read
before. Doubling works instead. These kernels write rather than accumulate,
so dispatching one twice with the same inputs leaves exactly the same
answers and costs exactly its own time again, and the submission count does
not move either.

| the kernel doubled | its own cost | share |
|---|---:|---:|
| matrix product | 0.103 s | 58 % |
| attention | 0.032 s | 18 % |
| half-precision copy | 0.003 s | 2 % |
| blend | 0.002 s | 1 % |
| row product | 0.002 s | 1 % |
| no dispatches at all | 0.020 s | 11 % |

Minimum of five runs at a load below 1.00, against a baseline of 0.177 s
inside submit-and-wait. They account for 0.162 of it; the rest is the
activation going up and the answers coming back inside the same wait.

**The submissions are not the problem, and that suspect is dead.** Two
hundred empty ones cost 0.020 s -- a tenth of a millisecond each, against
the 0.6 to 2.3 ms this file used to bracket a round trip at, which was
arithmetic on a guess rather than a measurement. Recording and submitting a
whole prompt is eleven per cent of it.

**The matrix product is fifty-eight per cent**, which is where a program that
has just been given one ought to be. Its 0.103 s against the harness's 0.124
for the same products taken one at a time is the engine already overlapping
the ones it records into a single command buffer. So what is left to take is
the kernel itself -- 1845 to 2249 GFLOP/s where the other runtime's prompt
figure implies about 3.2 TFLOP/s -- and attention behind it, eighteen per
cent and untouched since it was written. The narrow projections are worth
less than the number that made them look interesting: K and V together are
0.66 ms of the 5.63 ms a layer's products take, so a fourfold gain on them
is five per cent of a prompt.

**Then the kernel itself, four ways, and none of them kept.** The product is
fifty-eight per cent of a prompt, so it is where the next gain has to come
from. Two ablations that keep the arithmetic and halve an operand's loads,
and one that keeps the loads and removes fifteen of sixteen multiply-adds,
say what it is made of: the operands are about half the time and the
arithmetic the other half, which means neither can be ignored and neither is
the answer on its own.

**What it is short of is workgroups.** The same kernel, the same tile,
against row counts that change nothing but how many there are:

| | workgroups | |
|---|---:|---:|
| 512 rows | 16 | 890 GFLOP/s |
| 2048 rows | 64 | 2694 |
| 8192 rows | 256 | 3238 |
| 32000 rows | 1000 | 3723 |

A two-thousand-row matrix -- which is most of this model -- is sixty-four
workgroups on twelve compute units, and reaches seventy-two per cent of what
the same kernel reaches with a thousand. The multiply-adds alone run at about
3850 GFLOP/s, which is what the whole kernel reaches once there are enough
workgroups to hide the loads behind each other.

So the four attempts, all measured against 0.564 ms and all worse: pinning
either operand to a single address (1918 and 1555 gigaflops against 2182); a
squarer sixty-four by sixty-four tile, which halves the loads per
multiply-add and reads **0.850 ms**; four smaller tiles for more workgroups,
0.670 to 1.081 ms; and **staging the batch tile in shared memory, 1.499 ms**.

That last is the most interesting failure, because it is the standard shape
of a matrix kernel -- stream both operands into shared memory and read them
from there -- and it is two and a half times worse. With one wave to a
workgroup there is nobody to share the staged tile with, so the copy is pure
added cost. It agrees with the two pinning results: the path this part
already has from its cache to the instruction is better than anything built
on top of it by hand.

One thing did measure better and is not worth taking: the narrow K and V
projections read 0.241 ms at a sixteen-by-sixty-four tile against 0.358 at
the one in use, which over twenty-two layers is about three per cent of a
prompt for a second pipeline and a second tile shape to keep in step.

**The column split was the one lever left, and it was built and priced.**
Each workgroup takes a slice of the columns rather than all of them, writes
its partial sums to a slice of its own, and a second pass adds them -- in a
fixed order by a pass rather than by atomics, because an atomic add would
make the answer depend on which workgroup finished first, and a digest here
is meant to be a property of the model rather than of the run.

| split | 2048 × 2048 | 5632 × 2048 | 2048 × 5632 | 256 × 2048 |
|---|---:|---:|---:|---:|
| 1 | 0.5648 ms | 1.3044 | 1.4942 | 0.3232 |
| 2 | **0.5507** | **1.2432** | 1.4381 | 0.2204 |
| 4 | 0.5542 | 1.2602 | **1.4206** | 0.2623 |
| 8 | 0.5896 | 1.4014 | 1.5120 | **0.1821** |

Two and a half to five per cent on the three wide shapes and **forty-four per
cent on the narrow one** -- the projection that was eight workgroups and is
now sixty-four. The gain goes exactly where the starvation was.

**And then the summing pass, which the estimate that led here left out.** It
reads the slices and writes one of them, so the output traffic is multiplied
by the split: at split two a pair of five-thousand-row projections is
seventeen megabytes a layer of reading and writing that did not exist
before. On a wide product the pass costs what the split saves. On the narrow
one, where the slices are small, split eight with the pass included reads
**0.200 ms against 0.323** -- 1.6 times.

So applying it only where it pays, which is K and V twice a layer, is 5.4 ms
over twenty-two layers against a prompt of 177: **three per cent, below the
five a whole-prompt measurement resolves here.** It cannot be demonstrated in
place, and it costs a result buffer sized by the split, a fifth pipeline, a
reduction shader, another barrier and a rule for choosing the split. The
prototype is not kept.

What would change that answer is the model rather than the kernel: this one
has two narrow projections a layer out of seven products, and one with a
smaller key-value width, or more of them, has more of its time in the shape
where the split is worth 1.6 times. The prototype is three lines in the
shader -- a column range from `gl_WorkGroupID.z` and a slice added to the
store offset -- and the pass is a dozen more.

**One thing had to be fixed before any of that could be believed.** The
matrix product was committed with a gate that could not enter it: the
conformance sweep's longest sequence is eight tokens and the device format
test used a batch of ten against twelve rows, and the kernel refuses both.
Every check it passed was a check of the shader beside it. The device format
test now runs its fifteen formats twice, the second time at sixty-four rows
and a batch of forty, which the six tiled formats go through and the other
nine take through the row product at a larger shape than they had. The two
paths are held to different bounds because they differ by different amounts,
and both are measured rather than guessed: at most 2.1e-5 between the row
product and the processor, against 7.1e-3 to 9.5e-3 for the six tiled
formats -- three hundred times as much, and within a third of each other for
all of them, which is what says it is the half-precision operand rather than
any one decode.

### Attention's exponentials, worked out once

Attention is eighteen per cent of a device prompt -- 0.032 s of 0.177 by the
doubling measurement above -- and had never been looked at. What it was
doing, per tile of sixty-four cached positions: every lane worked out
`exp(score - raised)` for every score of the tile in order to sum them, and
then worked it out again for every score for every component of the value.
**Eight thousand exponentials a tile where sixty-four are distinct.** Each
lane now works out its own and puts it back in the shared tile, which costs
two barriers.

| | |
|---|---:|
| attention, the exponential per use | 0.0336 s |
| attention, the exponential once | **0.0318 s** |

Priced by dispatching attention twice and taking the difference, minimum of
four runs. Five per cent of attention and one per cent of a prompt: the whole
device prompt reads 0.293 s against 0.287 over three alternated rounds, which
is inside the floor, and the digest did not move.

**The five per cent is not the finding.** A hundred and twenty-eight-fold
redundancy in a transcendental function was worth a twentieth of the kernel,
which says the kernel is waiting for something else. What is left in it,
named and not measured: a lane computes one score by walking sixty-four
components of a key in series, and the sixty-four lanes of a wave then read
sixty-four keys that are a whole cached position apart -- a thousand and
twenty-four bytes for this model. Each lane's own walk is contiguous, so no
traffic is wasted, but a wave's worth of it lands on sixty-four cache lines
at every step. That is the shape `row_product.comp` was rewritten to avoid,
and it is the next thing to try here.

### The memory shape, and a pattern three times over

The section above named attention's shape: a lane computes one score by
walking a key in series, and the sixty-four lanes of a wave take sixty-four
keys a whole cached position apart, so every step lands on sixty-four cache
lines. The fix is the one `row_product.comp` uses -- read the tile the way the
wave wants it, a position at a time with a lane to each component, into
shared memory, and let every lane find its key there, sixty-five floats to a
row so that no two lanes share a bank.

It is correct: the suite passes and the twelve-token digest does not move. It
is also slower, in every alternated pair.

| 110-token device prompt | | | | |
|---|---:|---:|---:|---:|
| keys read where they lie | 0.492 s | 0.589 | 0.579 | 0.584 |
| keys staged in shared memory | 0.678 s | 1.073 | 0.771 | 0.752 |

The machine carried a load of three to four from something else while these
were taken, so the absolute numbers are half again what this prompt reads
quiet. The pairs are alternated and the direction is the same in all four, at
a ratio of 1.3 to 1.8, which is far outside anything the load explains.

**Why, and it is the same reason each time.** The shared memory a workgroup
takes went from two hundred and fifty-six bytes to sixteen and a half
kilobytes, and a workgroup processor has sixty-four: what it can hold at once
fell from dozens of workgroups to three. Attention is not short of bandwidth
-- a lane's own walk along a key is contiguous and every line it fetches is
used sixteen times -- it is *waiting*, and what hides waiting is other
workgroups. The staging bought locality the cache was already providing and
paid for it in the only currency that mattered.

**That is the third time this program has staged something into shared memory
by hand and measured a loss.** The row product's shared window read 1.399 s
against 0.516. The matrix product's staged operand read 1.499 ms against
0.580. Attention's staged keys read as above. Three kernels, three operands,
one answer: on this part the path from the cache to the instruction is better
than anything built on top of it, and shared memory is worth taking only
where something is genuinely shared -- which is why the matrix product's
weight tile, read by four multiply-adds apiece, is the one staging here that
pays.

What is left for attention is to give a lane a component rather than a
position, read the keys coalesced, and reduce across the lanes. That wants
subgroup operations, which this shader deliberately did not require -- it
runs on a Vulkan 1.0 device, and `row_product.comp` records the same refusal
for the same reason. The refusal is now conditional rather than absolute,
and the section below is what that measured.

### The same kernel, a fifth faster, and a run that cannot feel it

`attention.comp` is compiled twice, the second with `SUBGROUPS`, and the
engine binds it where the device reports the basic and arithmetic subgroup
operations in a compute stage -- a different question from the matrix
instruction, with a different answer, since subgroup arithmetic is core
Vulkan 1.1 and asks for no extension.

What changes is small and exact. Per tile of sixty-four scores every lane
walked all sixty-four entries twice, once for the largest and once for the
sum: a hundred and twenty-eight serial reads a lane, against the sixty-four
the dot product itself takes. Both become one instruction and a partial per
subgroup. The weighted sum of values still reads the tile out of shared
memory, because that is a gather and not a reduction.

| attention alone, `tests device-bench` | before | after | |
|---|---:|---:|---:|
| 1 head, 512 positions | 0.000626 s | **0.000528 s** | 1.18x |
| 32 heads, 512 positions | 0.000622 s | **0.000524 s** | 1.19x |
| 32 heads, 2048 positions | 0.002274 s | **0.001934 s** | 1.18x |
| as the engine asks it | 0.000601 s | **0.000505 s** | 1.19x |
| 32 heads, 16 positions | 0.000097 s | 0.000106 s | none |

**And a run barely notices.** A 110-token device prompt reads 0.269 s
against 0.271, a 1419-token one 4.268 against 4.377 which is inside its own
spread, and sixty-four tokens generated after a six-token prompt do not move
at all. The one shape that does move is sixty-four generated after a
1419-token prompt: 2.305 s against 2.401, better in each of three rounds,
and bit-identical -- `7ec6b755e53e16b4` either way.

That is not attention being a small part of the work. Doubling the dispatch
and taking the difference prices it at **12 per cent of a 110-token prompt
and 31 per cent of a 1419-token one**; it is 1.3 per cent of a token
generated after a short prompt.

**The reason is the workgroup count.** A prompt dispatches one workgroup per
head per position -- thirty-two by fourteen hundred and nineteen, some
forty-five thousand across twelve compute units -- and at that occupancy the
serial reductions' latency is hidden behind other workgroups; what is left
is the memory the keys come out of, which subgroup operations do not touch.
A generated token dispatches thirty-two workgroups, one a head, with nothing
to hide behind, so removing a hundred and twenty-eight serial reads a lane
shows up directly.

The general form is worth stating on its own, because it is a trap this
program walked into: **the same kernel change is worth a fifth where the
device is latency-bound and nothing where it is saturated, and which of the
two a call is depends on how many workgroups it makes rather than on how
much arithmetic it does.** `tests device-bench` measures the latency-bound
shape by construction -- thirty-two workgroups -- which is exactly why it
reads nineteen per cent for a change a prompt cannot feel. A kernel
benchmark and a run are not measuring the same machine.

It is kept, and the case is narrow: faster or level everywhere, answers
unchanged, and the one real shape it helps -- generating with a long context
-- is where a chat session spends its time. It is not kept because of the
nineteen per cent.

### A workgroup answers four queries, not one

The keys are read once per query position, and a long prompt has fourteen
hundred of them. That was priced before anything was built: confining the
key and value reads to eight cached positions -- the same instructions, the
same arithmetic, the same count of loads, all of them cache-resident -- read
attention at **1.27 s against 2.06** on a 1419-token prompt. Two fifths of
attention was the traffic, and the traffic was almost all re-reading.

So `attention.comp` gained a `QUERIES` constant and a third compilation with
`QUERY_TILE`, which sets it to four. A workgroup holds four queries, and the
key component a lane reads for its cached position is multiplied into all
four rather than read again by each. Everything else is the same text:
`QUERIES` is one in the other two compilations, so the per-query arrays are
of length one there and the loops over them have a single turn.

A block wants a maximum and a sum **per query** per tile, so the tiled
compilation requires the subgroup one -- which is why this could not have
been built before the section above it.

| attention alone, 1419 tokens | |
|---|---:|
| two queries a workgroup | 1.709 s |
| **four queries a workgroup** | **1.356 s** |
| eight queries a workgroup | 1.657 s |

**Eight loses what it gains.** A query costs four accumulators, a running
maximum, a running sum and four held components, and at eight the register
pressure takes back more occupancy than the extra reuse buys. That is the
fourth time occupancy has decided a device question here, and the first
where it decided a width rather than a yes or a no.

At four:

| | before | after | |
|---|---:|---:|---:|
| attention alone, 1419 tokens | 2.030 s | **1.356 s** | 1.50x |
| 110-token device prompt | 0.267 s | **0.245 s** | 1.09x |
| 1419-token device prompt | 4.211 s | **3.922 s** | 1.07x |
| 64 generated, 6-token context | 1.567 s | 1.600 s | unchanged |
| 64 generated, 1419-token context | 2.285 s | 2.299 s | unchanged |

Generating does not move and is not meant to: one position is fewer than a
block, so the engine binds the subgroup kernel there and never reaches the
tiled one. The answers are bit-identical -- the long prompt prints
`1a26d24d33b8957b` either way -- because a block changes which invocation
computes a dot product and not the order it accumulates it in.

Attention lands at 1.36 s against the 1.27 s the ablation named as this
kernel's floor, so the block recovered nearly all of the traffic there was
to recover. **What is left is the larger half.** That 1.27 s is 182 Gflop of
useful arithmetic, which is about 153 gigaflops a second on a part whose
matrix tile reaches 2031. Attention is now bound by arithmetic rather than
by memory -- and the section below is what happened when that arithmetic was
handed to the matrix instruction.

One mistake is worth recording because the suite did not catch it. Sweeping
the block width with `sed` set `QUERIES` in both arms of its own `#ifdef`,
so the untiled compilations were built with four as well: a kernel that
answers four queries a workgroup, dispatched one workgroup a query. All two
hundred and eighty tests passed, because the suite's batches are shorter
than a block and the extra queries were clamped onto the last real one. A
repository check now reads the number out of the shader and requires the
engine's `Query_Block` to equal it.

### And the matrix instruction, which lost

Thirteen times of headroom on an instruction this program already
dispatches, so it was built: `attention_matrix.comp`, Q times K transposed
as one matrix product, the softmax in shared memory between them, the
weights times the values as another, at the same sixteen-by-sixteen-by-
sixteen half-precision shape the batched product uses. Sixteen queries a
workgroup, and bound only for a head sixty-four wide or narrower whose width
is a whole number of sixteen.

A separate source rather than a fourth compilation of `attention.comp`,
because the two share no text. That is the line this work has settled on: a
define where only part of a kernel differs, a file where the shape does.

| attention alone, 1419 tokens | |
|---|---:|
| **query block of four**, which stands | **1.396 s** |
| matrix, 16 keys a tile | 1.565 s |
| matrix, 32 keys a tile | 1.583 s |
| matrix, 64 keys a tile | 1.858 s |

**Twelve per cent slower at its best, better in no round, and not kept.**

The reason is shared memory, again. The instruction takes half precision and
the cache is binary32, so the keys and the values have to be staged through
shared memory to be converted; the softmax is not a matrix product, so the
scores come out to shared memory and the weights go back in; and a running
softmax multiplies the answer by a factor a row at a time, which the
instruction cannot do to its own registers, so the accumulators come out and
go back once a tile as well.

The three variants order themselves by exactly that and nothing else -- 8768
bytes a workgroup at 1.579 s, 11328 at 1.607, 16448 at 1.858 -- and a wider
key tile does *fewer* softmax round trips per key while being slower for it,
which rules the round trips out and leaves the room they need. The kernel
that stands uses one kilobyte.

**That is the fourth time hand-staging into shared memory has lost here**,
and the first where what it was staging for was the matrix instruction
rather than a hand-written loop. The three before were the row product's
window, the matrix product's staged operand and attention's staged keys. The
matrix product itself remains the one place staging pays, and the reason has
not changed: its weight tile is read by four multiply-adds apiece, where
these operands are read once.

It would also have changed the answers, which the kernel it replaces does
not: the operands round to half precision, and a deep prompt printed
`77423c8d0bfd05a3` against `7ec6b755e53e16b4`.

### The half-precision cache, which the sweep refused

The paragraph above named the way out -- a cache already in half precision,
so the keys and values need no staging -- and guessed it would not be enough.
**That guess was wrong, and measuring it first is what showed so.** A probe
of the same kernel with the staging deleted and the operands read from the
query room instead, so the same count of instructions and the same matrix
products with neither the room nor the conversion loops, read attention at
**0.99 s** against the staged kernel's 1.65 and the kept kernel's 1.39. The
staging was two fifths of that kernel, not a few per cent of it.

So it was built: the device's copy of the cache written in half precision,
and all four attention kernels reading it as `float16_t`. Three alternated
rounds on a 1419-token prompt, by phase:

| | exact cache, query block | half cache, matrix |
|---|---:|---:|
| rotating | 0.200 s | 0.330 s |
| attending | 1.475 s | **1.031 s** |
| feeding | 1.300 s | 1.492 s |
| accounted for | 4.290 s | 4.190 s |

**Attention is 1.43 times faster.** The cooperative matrix does work for
attention; what had stopped it was the staging, exactly as the section above
suspected, and only the size of that cost was misjudged.

The prompt does not move -- 3.926 s against 3.919 over three alternated
whole runs -- because rotating gains 0.130 s converting every cache row on
the host as it writes it, and feeding gains 0.192 s that nothing here
touches and is most likely attention's own work crossing a phase boundary.

**None of that decides it. The conformance sweep does:**

```
conformance: sequences 28344, outside tolerance 8107, refused 0
```

Twenty-nine per cent of the sweep. A half-precision cache is not a rounding
of the operands the way the batched product's weights are; it is a rounding
that **compounds**, because a key written at the first position is read again
at every position after it. That is why the session cache offers `halved` as
something a caller asks for and not as what it does -- and this is the
measurement of how much it costs.

So it is not kept, and it would not be kept even if the prompt had moved:
the speed is the smaller half of the argument and the sweep is the larger.
What would have to be different is no longer a cache; it is a matrix
instruction that takes binary32 operands, which this device does not offer.

Two things are worth keeping. **The probe technique** -- read the wrong
operands from the right places, so the instruction count and the shared
memory are both right and only the answers are wrong -- priced a change
before it was built and corrected an estimate that was badly wrong. And the
number: attention through the matrix instruction is 1.43 times the
hand-written kernel when the operands are already the precision it wants,
which is the figure to hold against any future part whose cache can afford
to be.

### Eight more formats, and what a branch costs when it is never taken

Six formats reached the device's tile and nine did not. Eight of the nine
were written first: `Q4_0`, `Q4_1`, `Q5_0`, `Q5_1` and `IQ4_NL` share one
shape and take one branch between them, `Q2_K` and `IQ4_XS` a branch each,
and `Q3_K` was left. All fifteen formats pass the device format test at
sixty-four rows and a batch of forty, so the decodes are right.

| 110-token device prompt | before | after |
|---|---:|---:|
| Q4_0 | 0.532 s | **0.358 s** |
| Q2_K | 0.844 s | 0.813 s |
| Q8_0, the control | 0.285 s | **0.372 s** |

**The control got thirty per cent worse**, and it is the shader's size rather
than anything it runs. With the eight new formats refused by the host -- so
that not one line of the new code can be reached -- the same shader still
reads 0.346, 0.427 and 0.350 against the old shader's 0.286, 0.285 and 0.293
in the same sitting. **Twenty-one per cent for code that never executes.**

A pipeline pays for every branch compiled into it whether or not the branch
is taken: the register allocation is for the whole shader, and the occupancy
that follows is for every dispatch. That is the fourth time occupancy has
decided a device question here and the first where the cause is the size of
the code rather than the shape of a read; the three before it were shared
memory taken by hand.

### The second pipeline, and Q3_K with it

So the shader is compiled twice instead. `matrix_product.comp` decodes the
six as it stands and the other eight with `MORE_FORMATS` defined, and the
engine makes a sixth module and a sixth pipeline from the second compilation
and binds whichever of the two decodes the weights it was handed. `Q3_K`
went in with the eight, which makes the tile's coverage every format but
binary32.

| 110-token device prompt | before | after | |
|---|---:|---:|---:|
| Q2_K | 0.821 s | **0.295 s** | 2.79x |
| Q4_0 | 0.469 s | **0.311 s** | 1.51x |
| Q8_0, the control | 0.283 s | 0.276 s | |
| Q4_K_M, a control | 0.291 s | 0.284 s | |
| Q5_K_M, a control | 0.300 s | 0.293 s | |

Medians of alternated rounds in one sitting. **The three controls do not
move**, which is the whole point of the split: the formats that were already
fast are compiled into a pipeline the new decodes are not in, so they cannot
pay for them.

`Q2_K` gained 2.8 times where the one-shader attempt had gained three per
cent, and that is `Q3_K`. A "Q2_K" file is a mixture like every other and
much of it is `Q3_K`, so leaving that one format outside had hidden what
tiling the rest of it was worth. The earlier note named that number as the
one to watch, and it was.

**What it costs.** Two SPIR-V modules in the binary rather than one, 48584
bytes beside 42004; and a rule that the decode is the only part of the
shader that may differ between them, which is a rule a reader has to keep
rather than a thing the compiler checks. What it does not cost is a second
copy of the tile: the accumulators, the column loop, the operand loads and
the store are one text, read twice by the preprocessor. Naming the Ada
constants for the compiled file rather than the source is what let one
source become two constants; shaders compiled once are unaffected, their two
names agreeing.

A first attempt put the decode in a shared function so that `main` could be
byte-identical in both files. **That restructuring alone cost twenty-six per
cent** -- 0.358, 0.372 and 0.362 s against 0.287, 0.285 and 0.283 for the
same six formats and the same arithmetic. A function call is not free here
either, and the preprocessor is the cheaper way to share a text.

### The batched product, profiled

Feeding and projecting are 48 per cent of a long device prompt and 64 of a
short one, and four kernel attempts had already landed on a local optimum.
So this began with a profile rather than a change, and the profile moved the
question somewhere else.

The budget says projecting runs at about **790 gigaflops a second** and
feeding at **1662** -- same kernel, same format. A phase cannot say why,
because a phase is four products, so `tests device-bench` grew a sweep that
times one, at the shapes a layer asks for and a batch of 128:

| | | seconds | Gflop/s | workgroups |
|---|---|---:|---:|---:|
| query | 2048 x 2048 | 0.000396 | 2714 | 64 |
| **keys** | **256 x 2048** | 0.000295 | **455** | **8** |
| out proj | 2048 x 2048 | 0.000529 | 2031 | 64 |
| gate, up | 5632 x 2048 | 0.001110 | 2660 | 176 |
| down | 2048 x 5632 | 0.000922 | 3204 | 64 |
| vocabulary | 32000 x 2048 | 0.007440 | 2255 | 1000 |

**The grouped keys and values appear to run at a sixth of everything else**,
and `### What that table was really measuring` below shows that they do not:
88 per cent of that figure is the instrument. What follows was written before
that was known, and is kept because the correction is the point.

**A second row of that table is the instrument too, and it took a control to
see it.** `query` and `out proj` are the same shape -- 2048 by 2048 at a
batch of 128 -- and the table reads them thirty-three per cent apart. Three
sittings read the pair apart by the same amount and in the same direction,
so it is not noise. The table was therefore given a control: the first row's
shape again, measured last. In one run the four readings of that one shape
are

| | Gflop/s |
| --- | ---: |
| query, first in the table | 3035 |
| out proj | 2173 |
| rows 2048 | 2178 |
| **query last**, the control | **2201** |

The three that are not first agree within one and a half per cent and the
first is forty per cent above them. **The first shape a sitting measures
reads high**, whichever shape it is, because the sweep before it works the
device far more lightly and it enters this one at a boost clock it cannot
hold. So 2714 above is not what a 2048 by 2048 product does; about 2180 is,
which is what `out proj` said all along. The control row stays in the
instrument.

That does not disturb the sub-table below, where every column was taken the
same way in its own build, so the comparison across a row is between two
equally warm first readings. It does mean the absolute figures in this
section's first table are worth about a tenth less than they say, except the
one row that was already known to be wrong for a different reason.

Widening the batch and changing nothing else says it is the workgroup count:
455, 706, 835 and 1103 Gflop/s at 8, 16, 32 and 64 workgroups.

So the fix would be a narrower vector tile, which makes more workgroups at
the batch a prompt actually has. Built and measured:

| vectors a tile | keys | query | gate, up | vocabulary |
|---|---:|---:|---:|---:|
| 128 | 455 | **2714** | 2660 | **2255** |
| 64 | 514 | 2461 | **2778** | 1895 |
| 32 | **575** | 2022 | 1984 | 1323 |

**Twenty-six per cent on the narrow shape for twenty-five off the query and
forty-one off the vocabulary.** Not kept -- and not worth a second pipeline
either, because quadrupling the workgroups bought only a quarter, so the
count is not the whole of what binds that shape.

Then the number that reframes the whole item. Every tile product in a
sequence dispatched twice, unchanged data, so the difference is the
arithmetic and nothing around it:

| | once | twice | the products |
|---|---:|---:|---:|
| feeding | 1.294 s | 1.846 s | **0.552 s** |
| projecting | 0.678 s | 0.678 s | not this path |

**The arithmetic is forty-three per cent of the feeding phase.** The other
fifty-seven -- three quarters of a second on a four-second prompt -- is what
surrounds it: submissions, fences, and the activation that returns to the
host after every product and is uploaded again for the next.
`model_runner-platform-device-products.ads` has said so in a comment since
sequences were written -- *"a sequence of several still returns each result
to the host today, and hoisting that is the next change rather than this
one"* -- and that comment is now a measurement.

The batched product is not what is left of the device's prompt gap. What is
left is around it -- and the section below took the first piece of that.

**That last sentence is half right and the half that is wrong is instructive;
`### The floor a device prompt cannot go below` settles it.**

### The answers nobody read

`Run` copies every step's answer into the caller's target, and both callers
that name several steps then read one. `Dispatch_Gated` said so in a comment
of its own -- *"only the last of the four is wanted here. The arms and the
combined value are the device's business and stay there"* -- **and they did
not stay there.** For a batch of 128 that is the gate at 2.88 MB, the up at
2.88 and the combined value at 2.88, copied to the host to be stepped over,
against the 1.05 MB of the down projection that is read. `Attend_And_Project`
copies the attention blend back with the projection, another 1.05 MB.

Nine and a half megabytes a layer a batch: across 22 layers and the eleven
batches of a 1419-token prompt, about **two and a third gigabytes of memcpy
that nothing reads**.

The change is a `Kept` flag on a step, false where nothing on the host reads
that step's answer, and one test in `Run`'s download loop. The room is still
stepped over, so what a caller indexes does not depend on what it keeps.

| | before | after | |
|---|---:|---:|---:|
| 1419-token device prompt | 3.933 s | **3.538 s** | 1.11x |
| 110-token device prompt | 0.260 s | **0.239 s** | 1.09x |
| 64 generated | 1.594 s | 1.600 s | unchanged |

Better in every round, and **bit-identical** -- nothing about what is
computed changed. Generating does not move and cannot: one vector makes those
answers a few kilobytes rather than a few megabytes.

By phase it lands where the profile said it would: feeding loses 0.191 s,
which is its three discarded answers, and attending 0.110, which is the
blend. **About half of the fifty-seven per cent was this.** The rest is still
submissions and fences, and is still unmeasured.

This is the first change here that is pure subtraction -- no kernel, no
shader, no arithmetic, just four copies that were being made for nobody.

Projecting not moving at all under the doubling is unexplained and is
written down as unexplained: either those products do not take that path, or
the phase counter attributes their wait to the phase after them, the phases
being host-side wall around asynchronous submissions.

### What that table was really measuring

`Multiply` uploads the activation, records a command buffer, submits it,
waits on a fence and copies the answer back. That round trip costs the same
whatever the matrix is, and the sweep above times all of it. Holding the
batch and the columns still and sweeping only the rows -- one workgroup to
sixty-four, so sixty-four times the arithmetic -- says how much:

| rows | workgroups | seconds | apparent Gflop/s |
|---|---:|---:|---:|
| 32 | 1 | 0.000252 | 67 |
| 64 | 2 | 0.000292 | 115 |
| 128 | 4 | 0.000330 | 203 |
| 256 | 8 | 0.000351 | 382 |
| 512 | 16 | 0.000374 | 719 |
| 1024 | 32 | 0.000456 | 1177 |
| 2048 | 64 | 0.000595 | 1805 |

**Sixty-four times the work for two and a third times the time.** A least
squares fit through those seven points is **0.29 ms fixed plus 0.154
microseconds a row**, and that marginal slope is **3.4 Tflop/s** -- confirmed
by differencing adjacent pairs from 128 rows upward, which give 3.19, 6.08,
3.25 and 3.87.

So the narrow key and value projection does 0.13 Gflop of arithmetic, which
at 3.4 Tflop/s is 0.038 ms, on top of 0.29 ms of round trip. **Eighty-eight
per cent of its measured time was the instrument, and there is nothing wrong
with the shape.** The apparent sixfold spread across shapes is the fixed cost
dividing into different amounts of work, and the number to hold about the
tile is 3.4 Tflop/s, not 455.

Below four workgroups the device really is starved -- the 32-to-64 and
64-to-128 steps give 0.42 and 0.87 Tflop/s -- but no shape a layer asks for
is that small.

The fixed cost is not only the instrument's, though. `### The floor a device
prompt cannot go below` measures the whole surround at 0.502 s for a
1419-token prompt, and that prompt makes about 1710 product calls: 0.29 ms
apiece is 0.50 s. The two measurements meet. **What a bigger batch would do
about it is nothing**, and that was checked rather than assumed --
`--batch-size` at 64, 128, 256, 512 and 1024 reads 3.138, 2.490, 2.459, 2.426
and 2.547 seconds, so the default is within three per cent of the best. The
floor is host loops over *positions*, which a batch does not divide.

### One core, and seven idle

After the copies were deleted, joining, normalizing and rotating are 0.394,
0.250 and 0.195 seconds of a 3.882 second device prompt -- **twenty-two per
cent, and the second largest item after attending.** None of them is a
dispatch. They are host loops -- `Join_Residual`, `Normalize`, `K.Add`,
`Apply_Rotary` -- run on the calling task, and a device run does not make
them any less host work.

A one-line experiment says so:

| 1419-token device prompt | wall | processor |
|---|---:|---:|
| `--threads 1` | 3.400 s | 2.94 s |
| `--threads 8` | 3.527 s | 2.97 s |

Eight workers change nothing and the processor time is the same to a per
cent. **One core does elementwise work for a fifth of the run while seven
sit idle.**

Two changes inside the kernels were sized and neither is kept.

**The dead zero-fill.** `RMS_Norm` opens with `Target := [others => 0.0]`
and then writes every element of `Target` below, so the fill is a whole pass
thrown away -- sixty-two thousand times in this prompt. Moving it to the
refusal path is bit-exact, and it is not a win: the device's normalizing
goes 0.251 s to 0.241 while a 110-token processor prompt goes **0.748 s to
0.759, worse in all three rounds**. Removing a write pass making a loop
slower is not what anybody would predict; the likeliest reason is that the
fill brings the lines in before the scattered writes ask for them, so what
looks like a wasted pass is a prefetch. That is written down as a likely
reason, not a measurement.

**The serial accumulator.** `RMS_Norm` sums the squares into one binary64
accumulator left to right, a dependency chain nothing can vectorize. Eight
partial accumulators take normalizing from 0.245 s to 0.221 and joining from
0.390 to 0.373 -- **forty milliseconds, one per cent** -- and reassociate a
sum every published digest depends on, on both backends and the reference
path. Not worth it. The estimate that the chain was worth 0.18 s was wrong:
2048 floats is eight kilobytes, and the loop is nearer memory-bound than
latency-bound.

**That blocker was half of it.** The three phases parallelize by position:
every position's arithmetic is independent of every other's, so shares of a
batch are **bit-exact**, and `Dispatch_Shares` already exists and is already
used a few lines above for attention in the same loop. `Item.Post_Room` --
one scratch array of the model's width that `Join_Residual` writes through
for every position -- is what stopped a straight substitution, and a share
taking its own row is what fixes it.

**The other half was that a device run had no pool at all.** Every place
that opened a session decided one on the backend's `Supports_Parallel`,
which says whether *that backend's own products* divide across workers --
and the device's do not: they divide across the device. So `--threads` on a
device run had nothing to change, and the loops had nothing to be shared out
to. A run is not only its products.

Both halves are fixed, and the rotation is deliberately left alone: it writes
the key and value cache, and on a device that is a call through an engine
that is one task's to use.

| | before | after | |
|---|---:|---:|---:|
| 1419-token device prompt | 3.626 s | **2.522 s** | 1.44x |
| 110-token device prompt | 0.241 s | **0.205 s** | 1.18x |
| 64 generated | 1.558 s | 1.597 s | unchanged |
| 110-token processor prompt | 0.744 s | 0.744 s | unchanged |

Better in every round, and the answers are bit-identical. Generating does not
move: a batch of one is below the sixteen this asks for before it goes to the
pool. The processor does not move either, and that is worth saying -- it had
a pool all along, so all it gains is the loops themselves being shared, which
is five per cent of a processor prompt and inside its noise.

By phase, and this part was not predicted:

| | before | after |
|---|---:|---:|
| normalizing | 0.250 s | 0.129 s |
| joining | 0.393 s | 0.204 s |
| rotating | 0.194 s | 0.193 s |
| projecting | 0.654 s | 0.502 s |
| attending | 1.314 s | 1.038 s |
| feeding | 1.068 s | 0.908 s |
| **accounted for** | **3.904 s** | **3.001 s** |

The two shared loops account for 0.310 s of the 0.903. **The other 0.593 is
in phases that dispatch to the device**, and the likeliest reading is that
the host was the thing keeping the device waiting: a submission cannot be
made while the task that would make it is normalizing a batch. That is a
reading and not a measurement.

One thing it cost: `inspect` now reports three worker tasks for a device run
where it reported one, and the suite caught that -- the number was asserted,
and asserted as one because that was true. It is three now because that is
what the run uses.

### What tokenizing cost, which no figure here had said

A device prompt reported 2.98 s of processor time for 3.755 s of wall, and
two thirds of that was not the model. **Tokenizing a 1419-token prompt took
2.05 s** -- 1.45 milliseconds a token, and more of the run than evaluating
the prompt it produces. It appeared in no published figure, because the
speed tool times tokenization apart from evaluation.

**What it was.** The SentencePiece road merges the best-scoring adjacent
pair until no pair names a vocabulary entry, and it found that pair by
walking every surviving pair, building the two symbols into one string and
looking that string up -- a pass per merge, as the comment above it said.
For this prompt that is 6669 symbols falling to 1419, so 5250 merges over an
average of four thousand pairs: **about 21 million concatenations and hash
lookups**.

What a merge actually changes is two pairs: the one the merged symbol now
begins, and the one that ends where it begins. So the worth of every pair is
worked out once and those two are worked out again -- `6669 + 2 x 5250 =
17169` lookups, **twelve hundred times fewer**. The pass that remains
compares floats, so this is the same O(n²) it was; what changed is that the
constant is a float compare rather than a string built on the heap and
hashed.

| | before | after | |
|---|---:|---:|---:|
| tokenizing the 1419-token prompt | 2.053 s | **0.143 s** | 14.4x |
| the whole run's wall clock | 6.076 s | **4.033 s** | 1.51x |
| its processor time | 3.13 s | **1.07 s** | |
| evaluating the prompt | 3.52 s | 3.54 s | untouched |

**Bit for bit the same tokens.** The scan runs over the same symbols in the
same order -- a merge keeps the left symbol's index, so the living symbols
stay in increasing index order -- and takes a pair only on a strictly
greater score, so the leftmost of equals still wins.

Which vocabularies it reaches, on 3000 characters of the same text:

| | before | after |
|---|---:|---:|
| TinyLlama, SentencePiece | 0.53 s | **0.11 s** |
| Phi-3, SentencePiece | 0.50 s | **0.08 s** |
| Gemma 3 | 0.58 s | 0.54 s |
| GPT-2, byte pair | 0.15 s | 0.15 s |
| Qwen 3, byte pair | 0.46 s | 0.47 s |

The byte-pair road is untouched and was never the problem: it merges within
a word, where the counts are small and its own comment says a pass per merge
is right.

**Nothing was looking for this.** It fell out of asking why a device prompt
used 2.98 s of processor time, which was asked because the phase counters
did not add up to the wall clock. The figure that mattered most to a user
was the one no published figure contained.

### The floor a device prompt cannot go below

The section above said the arithmetic is 43 per cent of the feeding phase, so
the other 57 must be submissions and fences. **That reading is wrong**, and
how it is wrong matters more than the reading did.

The measurement that settles it: every `Dispatch` in the engine asks for zero
workgroups. Every command buffer is still recorded, every descriptor set
updated, every submission made and waited on, every activation uploaded and
every kept answer copied back -- and no arithmetic is done on the device at
all. What is left is the floor.

| | whole | floor | arithmetic |
|---|---:|---:|---:|
| 1419-token device prompt | 2.530 s | **0.502 s** | 80 % |
| 110-token device prompt | 0.208 s | **0.045 s** | 78 % |

**The surround is a fifth of a device prompt**, and most of that fifth is the
host loops that remain -- normalizing, joining and rotating are 0.526 s by the
phase counters, which is the floor itself. Submissions, fences and transfers
are what is left over from that, and it is not much.

**Why the phase counters said otherwise is the part to keep.** A phase is host
wall time around an asynchronous submission, so the "non-arithmetic" part of
the feeding phase is the host *waiting for the device to finish the
arithmetic*. It is not overhead; it is the work, seen from the side that is
not doing it. Emptying feeding's dispatch takes the phase from 0.891 s to
0.351; doubling it adds only 0.405 rather than 0.540, because two dispatches
in one command buffer pipeline better than one does. Neither number is the
arithmetic, and the difference between them is not overhead either.

That is the third time on this page a phase counter has led somewhere false --
feeding gaining time a change did not touch, projecting not moving under a
doubling, and now this. **They are useful for saying which part of a layer
grew and useless for saying what a part is made of.** What says that is a
whole-run measurement with one thing removed.

What it means for the gap: llama.cpp reads 110 tokens at 1657.8 a second, so
this prompt would be about 0.86 s there against 2.53 here. Take the entire
surround away -- every submission, every transfer, every host loop, all of it
free -- and this is 2.03 s, still two and a half times behind. **The remaining
gap is the arithmetic.**

### Short of arithmetic, not of memory

The section above ends by saying there is no instrument here that separates
what the tile does per flop from the memory it reads. There is one now: **one
shape, one batch, every format the tile decodes.** The flops are identical
and only the bytes differ, so what changes between rows is the traffic and
nothing else.

16384 by 2048 at 128 vectors, best of three passes, two rounds averaged:

| | bytes a weight | weights | Gflop/s |
|---|---:|---:|---:|
| f16 | 2.00 | 64 MiB | 2737 |
| bf16 | 2.00 | 64 MiB | 2624 |
| q8_0 | 1.06 | 34 MiB | 3066 |
| q6_k | 0.82 | 26 MiB | 3132 |
| q5_k | 0.69 | 22 MiB | 3176 |
| q4_k | 0.56 | 18 MiB | 3236 |
| q4_0 | 0.56 | 18 MiB | 3225 |
| q2_k | 0.33 | 10 MiB | 3358 |

**Six point one times the bytes for one point two five times the time.** If
the tile were bound by memory the two-bit format would run six times the
eight-bit one's speed; it runs nine per cent faster.

Fitting `time = arithmetic + bytes` across the two extremes gives **3.52
teraflops a second of arithmetic** and a **marginal byte rate of 87 GB/s** --
which is what `row_product.comp`'s own note calls "about ninety" for this
part. **The weight reads are already at the bus**, and for the eight-bit
format memory is 15 per cent of the time against arithmetic's 85.

**What that retires** is the point of having asked. A smaller weight format
is not a faster one here -- `q4_k` and `q8_0` are within six per cent. A
half-precision anything on the weight side buys nothing. A better weight
layout buys nothing. Every idea whose mechanism is *fewer bytes* or
*better-shaped bytes* is answered at once.

What is left is flops per clock out of the matrix instruction. Twelve compute
units at about 2.7 GHz doing 256 half-precision flops a clock each would be
8.3 Tflop/s, so 3.52 is around 42 per cent of it -- and that peak is
arithmetic on a number this page has not measured, so read it as an order and
not a figure.

It also raises the prior on attention, which is measured separately and
agrees: confining its reads to a cache-resident window bought 1.18 times once
the query block was in. **Both device kernels are short of arithmetic and
neither is short of memory** -- a coherent thing to know about this part, and
not knowable from any single measurement.

One note on the instrument. Taken a pass apiece these eight read a spread of
sixty per cent between rounds and disagreed about which format was fastest; a
first reading had `f16` 21 per cent slower than `bf16`, which a second round
showed was noise and **which would have been published as a finding about
`unpackHalf2x16`**. It takes the best of three passes now.

### Every value read four times

`### Short of arithmetic, not of memory` retired the plan for attention's key
reads -- its whole memory cost is fifteen per cent and the fix wanted shared
memory, which is nought for four here. Same target, corrected mechanism.
Attention is 35 per cent of a device prompt and does 182 Gflop in about a
second: **175 Gflop/s on a part that does 3520 on a product.**

The weighted sum of values ran the query loop *outside* the position loop:

```
for each query i:
   for each position j:  got += tile[i][j] * kv[value(j, c)]
```

so `kv[value(j, c)]` -- one address, one value -- was loaded once for every
query of the block. **Four loads for four multiply-adds where one will do.**
The dot product above it already had the shape the other way round, which is
why the query block bought 1.5 times there and this went unnoticed.

| | before | after | |
|---|---:|---:|---:|
| 1419-token device prompt | 2.544 s | **2.235 s** | 1.14x |
| 110-token device prompt | 0.203 s | **0.160 s** | 1.27x |
| 64 generated | 1.591 s | 1.592 s | unchanged |

Generating does not move and its digest does not change: a batch of one takes
the subgroup kernel, where `QUERIES` is one and the swap collapses to the same
code.

**The prompt's answers do change, and I predicted they would not.** Each query
still accumulates over the positions in the same order and the expressions are
the same, so the arithmetic is identical as written; what differs is which
multiply-adds the compiler fuses, which GLSL lets it choose unless a variable
is declared `precise`. The conformance sweep -- the same check the tile's
half-precision operands are held to -- passes at 28344 sequences with none
outside tolerance.

The phase counter moved by 0.055 s where the run moved by 0.310. That is the
fourth time on this page, and by now it is not a surprise but a property.

### The processor's attention read the key cache once a head

The processor prompt is 2.5 times behind and had never had the floor
treatment. Its budget on a 1419-token prompt: **attending 6.79 s, feeding
6.91, projecting 1.98**, and everything else under a fifth of a second --
eighty-five per cent in two phases, and 15.66 s in total against the device's
2.24.

Emptying the score dot product and touching nothing else:

| | whole | score loop emptied |
|---|---:|---:|
| attending | 6.789 s | 2.385 s |
| accounted for | 16.110 s | 11.964 s |

**The score dot product alone is 65 per cent of attending and 27 per cent of
the whole prompt** -- the single largest thing in a processor prompt, and
nothing here had named it.

Two things were tried. **Four accumulators**, because it sums into one
binary64 accumulator a component at a time and an old profile in this project
found 54 per cent of the samples in that procedure on 64-bit moves: seven per
cent of attending, four of the prompt, and it reassociates a sum every
published digest depends on. Not kept, for the reason the same change to
`RMS_Norm` was not.

**The position outside the head.** The head loop was outermost, so each head
walked the whole key cache for itself and the next head walked it again --
363 kilobytes of keys a group at 1419 positions, streamed once for each of
the eight heads that share them. This is the same shape as the device change
above, and the same shape the value blend twenty lines below **already had**;
its own comment says *"a component at a time was one pass over the whole
cache per component"* and gives the reason. The score loop was left.

| | before | after | |
|---|---:|---:|---:|
| 1419-token processor prompt | 15.292 s | **14.669 s** | 1.042x |
| 110-token processor prompt | 0.731 s | **0.703 s** | 1.04x |

Better in every round, and **bit for bit what it replaces** -- this time
checked rather than predicted. Each score is the same expression over the
same components in the same order, computed at a different moment, and no two
scores touch.

Four per cent is small for a loop that is 27 per cent of the prompt, and that
is the finding: four accumulators bought seven per cent of the loop and cache
reuse fifteen, so between them a fifth. **The rest is the binary64 conversion
and the arithmetic itself** -- the same answer the device gave, arrived at
from the other side.

### Scalar however it is written

The score loop is 27 per cent of a processor prompt and converts two binary32
operands to binary64 to multiply them, in one serial accumulator. **The device
has always computed the same scores in binary32**, and the conformance sweep
holds both backends against the same reference at the same tolerance -- the
shader's binary32 differs from the processor's binary64 by 2.2e-05 at worst,
under the sweep's floor. The history records no reason for the wider
accumulator beyond accuracy.

So it was changed to binary32 in eight accumulators, eight being what a
register holds. Two alternated rounds on a 1419-token prompt read 14.783 s and
14.640 against 14.520 and 14.886: **level**. The answers did not move either,
which says something on its own about how little of a score's last bits
reaches a token.

The object file says why. In the procedure that holds both loops:

| | instructions | |
|---|---|---|
| the committed score loop | 14 `mulsd`, 13 `addsd` | scalar binary64 |
| the same loop in binary32 | 25 `mulss`, 72 `addss` | scalar binary32 |
| the value blend beside it | 34 `mulpd`, 32 `addpd` | **packed** binary64 |

**The score loop is scalar in both formats and the value blend twenty lines
below it is packed.** The difference is neither the format nor the accumulator
count: the blend is a *map* -- every component of its output independent, which
GNAT vectorises at `-O3` unasked -- and the score is a *reduction*. Written as
eight independent lanes, which is a map by construction, it still came out as
eight scalar chains; hoisting the operands into renamed slices so the addresses
are plainly contiguous did not change one instruction.

So binary32 replaced one scalar chain with eight, and the loop is not
latency-bound -- four accumulators bought seven per cent, which is what a loop
says when the chain is not what holds it -- so eight scalar chains are no
better than one.

**This explains three other null results that looked unrelated.**
Reassociating `RMS_Norm` bought one per cent; four accumulators here bought
seven; binary32 bought nothing. Every arrangement of scalar arithmetic is
scalar arithmetic. The loop issues about sixty-four scalar multiply-adds where
a packed unit would issue eight, and no way of writing Ada found here makes
GNAT emit the eight.

What would: a machine-code insertion with a runtime capability check, which is
the mechanism this project already uses for exactly this reason --
`model_runner-quantization-integers-kernels.adb` is four thousand lines of it
and `Platform.Instructions` is what asks the processor first. The score dot
product is a fused multiply-add over sixty-four contiguous binary32 pairs and
is a smaller insertion than any of those. It is the section below.

### The instruction the compiler would not emit

`Model_Runner.Kernels.Head_Dot` is that insertion: `vfmadd231ps` over eight
binary32 pairs a turn, the eight lanes folded once at the end, with the
portable loop above still there for a host that has not got it. Sixteen
lines of assembler where the paragraph above spent a day proving that no Ada
would do.

On the 1419-token prompt, alternated rounds at a load under 1.20:

| | before | after |
| --- | ---: | ---: |
| round 1 | 13.538 s | **11.736 s** |
| round 2 | 14.255 s | **11.432 s** |
| round 3 | 13.691 s | **11.664 s** |

**Fourteen and a half per cent of a whole prompt**, better in three of
three. Generating is level, 2.02 s against 2.00, and has to be: a generated
token has one query row, so the score loop is one dot product a head rather
than one a position.

Then the value blend beside it, which was already packed and was packed in
*binary64*. That loop is a map, so the format is the lane count and nothing
else -- `mulps` and `addps` do eight where `mulpd` and `addpd` do four -- and
the object file goes from 34 `mulpd` and 32 `addpd` to 18 `mulps` and 17
`addps`, with no packed binary64 left in the unit. Three rounds did not
clear the noise floor, so it was taken seven times:

| | before | after | | before | after |
| --- | ---: | ---: | --- | ---: | ---: |
| round 1 | 11.803 s | 11.249 s | round 5 | 11.553 s | 11.047 s |
| round 2 | 11.472 s | 11.345 s | round 6 | 11.748 s | 11.180 s |
| round 3 | 11.549 s | 10.921 s | round 7 | 11.728 s | 11.567 s |
| round 4 | 11.815 s | 11.269 s | | | |

**Four per cent, better in seven of seven.** Four per cent is at the floor
for one round and is not for seven. The same change was made in
`Blend_Halved` and `Blend_Eighth`, which say in their comments that they are
what `Blend_Exact` is.

Both change the answers, and the conformance sweep is the arbiter for both
exactly as it is for the byte dot product: 28344 sequences and nothing
outside tolerance, run on each of the two changes on its own. The
sixty-four-token digest moves twice, `448c2ed68ec342ee` to
`cf8edab322fa571f` to `1cb5fffbb21399ad`; the 110-token prompt digest does
not move at all.

**Where the insertion had to live is the part worth writing down.** It was
written into `model_runner-llama.adb` first, beside the loop it replaces,
and a repository check refused it: that file interprets what a model file
holds, so it may not `with Model_Runner.Platform`. The rule is in
`### Repository checks` and it exists so that a chat template or a metadata
value cannot make the program read something else off the machine that
opened the file. So the capability is *told* rather than asked, exactly as
`Quantization.Use_Wide_Decoders` is told -- `Kernels.Use_Wide_Lanes`, called
once from `Backend.CPU`'s elaboration, before any container is open. The
check found a real mistake rather than an inconvenience, and the insertion
ended up in the package that holds the arithmetic rather than the one that
holds the evaluator, which is where it belonged anyway.

### The tile that reads the batch five hundred times, and does not mind

The device's prompt is 2.4 times behind llama.cpp's and the tile product is
what it spends its arithmetic in, so this looked at the tile's shape for the
fifth time.

The argument for the change came out of `tests device-bench`, which times a
16384 by 2048 product at a batch of 128 in each of eight formats. **Every
format lands between 3.1 and 4.3 teraflops a second** -- half precision with
no decode at all, and Q2_K with six times fewer bytes and the most elaborate
decode of the eight, within a few per cent of each other. So neither the
weight bytes nor the decode is what binds it, which leaves what the two have
in common: the activations.

A workgroup takes thirty-two rows and the whole batch, so every row tile
reads the whole batch again. Sixteen thousand rows is five hundred and
twelve row tiles, and a batch of 128 vectors at 2048 columns is half a
megabyte: **a quarter of a gigabyte of activation reads against thirty-four
megabytes of weights.** Doubling the row tile halves that.

So: sixty-four rows to a workgroup, in two waves that split the vectors
between them, each wave holding four of the eight vector matrices and both
using all sixty-four decoded rows. The accumulator count per wave is
unchanged, the decode arithmetic per lane is unchanged, and the loop that
reads the batch runs half as often.

**It lost, in every one of the eight formats:**

| | thirty-two rows | sixty-four |
|---|---:|---:|
| f16 | 3094 | 2142 |
| bf16 | 3562 | 2536 |
| q8_0 | **4203** | 2303 |
| q6_k | 4198 | 2185 |
| q5_k | 3639 | 3274 |
| q4_k | 4079 | 3358 |
| q4_0 | 4181 | 3018 |
| q2_k | 4290 | 3357 |

Two sittings of the thirty-two-row shader read within eight per cent of each
other, and the sixty-four-row one is thirty to forty-five per cent below
both.

The likeliest reason, written down as a reason and not as a measurement:
with one wave to a workgroup a `barrier()` is very nearly free, because
there is nobody to wait for. With two it is a real wait, twice for every
thirty-two columns, and neither wave can start its half of the arithmetic
until the other has finished its half of the decode. The tile went from a
wave that never waits to two that wait sixty-four times a row tile. What was
saved was a quarter of a gigabyte of reads that the numbers above say it was
never paying much for.

**That is the fifth attempt at this tile's shape and the fifth to be
reverted** -- the k-chunk at sixty-four and at a hundred and twenty-eight,
the accumulators two against eight, the vector tile at sixty-four and at
thirty-two, and now the row tile at sixty-four. The local optimum is a real
one, and what is left between this device and the other runtime is not the
tile's shape.

### The blend that could not keep its sums in registers

The insertion two sections above left `Blend_Exact` at thirteen per cent of
a processor prompt and `Head_Dot` at twelve, so attention is a quarter of it
and the value blend is now the larger half. The object file says why, and it
is not the reason the score loop was slow. **`model_runner-llama.o` holds no
packed fused multiply-add at all** -- eighteen `mulps` and seventeen `addps`
-- because this is compiled for baseline x86-64 and the instruction is not
in the baseline.

But the fusing is the smaller half of what was available. The blend is

```
for each position:
   for each of the run's components:
      Sums (c) := Sums (c) + Score * Values (c)
```

and `-O3` does vectorize the inner loop: eight lanes of `mulps` and `addps`.
What it cannot do is keep `Sums` in registers across the positions, because
`Sums` is an array the loop writes and the compiler will not prove the
writes and the reads of `Values` do not overlap. So **every position pays a
load and a store of the whole run as well as its arithmetic** -- five
instructions where the arithmetic is two.

A run of sixty-four components is eight registers. Held there,

| | instructions a position |
|---|---:|
| what `-O3` emits | 40 |
| one broadcast and eight fused multiply-adds | **9** |

`Model_Runner.Kernels.Blend_Run` is that: the eight accumulators loaded
once, a position's score broadcast into all eight lanes, eight
`vfmadd231ps` reading the values where they lie, and the accumulators
stored once at the end. Seven alternated rounds on the 1419-token prompt:

| | before | after | | before | after |
| --- | ---: | ---: | --- | ---: | ---: |
| round 1 | 11.459 s | 10.704 s | round 5 | 11.494 s | 10.723 s |
| round 2 | 11.297 s | 10.534 s | round 6 | 11.095 s | 10.797 s |
| round 3 | 11.372 s | 10.922 s | round 7 | 11.446 s | 11.076 s |
| round 4 | 11.131 s | 10.575 s | | | |

**Median 11.372 against 10.723, five and three quarter per cent, better in
seven of seven.**

The answers move, and this time for a reason worth naming: a fused
multiply-add rounds the product once where the portable form rounds it
twice, so the insertion is the *more* accurate of the two and still a
different answer. The sweep is the arbiter as before -- 28344 sequences,
nothing outside tolerance -- and the portable loop is still what a host
without the instructions runs, so the two have to be held together by a
test rather than by a digest. That test asserts they agree to what binary32
holds, and drives both paths from `Use_Wide_Lanes`, which is the flag
`Head_Dot` already had under a narrower name.

### The instructions that were free

The strip kernel is **fifty-five per cent of a processor prompt** and the
widest thing left in the file, so this went looking inside it. It found two
wrong guesses and one measurement worth keeping.

**The first guess was the register width.** The insertion issues 256-bit
`vpdpbusd` on a processor that reports `avx512_vnni`, so twice the lanes
looked like it was there for the asking. It is not, and the reason is the
shape rather than the capability: `Platform.Instructions.Byte_Products`
already requires `avx512f`, `avx512bw`, `avx512vl` and `avx512_vnni`, and
`integers-deep.ads` is already compiled `-march=x86-64-v4`, so nothing was
being withheld. But a register here holds exactly one Q8_0 block --
thirty-two bytes of quants -- and blocks are thirty-four bytes apart, so a
sixty-four byte load straddles the next block's scale. The other way to fill
a `zmm`, two rows at once, breaks the `{1to8}` scale broadcast: the halves
need different scales, and giving them different scales means an eight times
larger scale table. **The width is pinned to the block, not to the
instruction set.**

**The second guess was where the time goes**, and the profile answered it:

| | share of the kernel |
|---|---:|
| `vpxor` (twelve) | **13.96 %** |
| `vpdpbusd` (eight) | 12.81 % |
| `vfmadd231ps` and `vcvtdq2ps` | 15.11 % |
| shuffles: `vunpcklps`, `valignd`, `vmovlhps`, `vshufps`, `vextractf32x4` | **~25 %** |
| `vaddps` and `vmovaps` | 7.22 % |

A quarter of the biggest symbol in the program is shuffling, and the zeroing
`vpxor` before each byte dot product costs more than the dot product it
feeds. The shuffles map -- through `addr2line`, the guess having been wrong
twice already -- not to the reduction that finishes a row but to the loop
that builds the scale table, where a four-turn inner loop writes `Scaling`
and read-modify-writes `Undo`, an array `-O3` cannot keep in registers.

So the row went outside the block and the row's four corrections into a
local. Same arithmetic, same order, bit for bit; the object file's shuffle
count fell from 299 to 236 with three of the four kernels still untouched.

**And it bought nothing.** Five alternated rounds on the 1419-token prompt,
median 10.998 s against 10.839, better in three of five, digest
`1a26d24d33b8957b` either way -- level, inside what this pair resolves.

**That is the finding, and the conclusion drawn from it below was wrong.**
Halving the shuffles in a block holding a quarter of the samples moved the
whole prompt by one per cent, so those *instructions* are not what the block
costs. What was written here next -- that they issue in the shadow of the
byte-product loop and cost nothing a clock notices -- does not follow, and
`### The second loop, of the same length` measures the block at **seventeen
per cent of a prompt**. Halving its shuffles bought nothing because its cost
was never its shuffles.

A profile says where instructions *are*, and this file has recorded several
occasions where that is not where the *time* is. This one is the reverse
mistake: reading a null on one kind of instruction as a null on the block
that holds it.

Nothing kept. The kernel is as it was.

### What a doubling can and cannot say

`### The floor a device prompt cannot go below` above put the arithmetic at
eighty per cent of a device prompt by emptying every dispatch. This went at
the same question from the other side, doubling one kind of dispatch at a
time, and got answers that cannot both be right beside it:

| doubled | added | of the prompt |
|---|---:|---:|
| every tile product | 0.226 s | 10 % |
| attention | 0.040 s | 1.7 % |
| every row product | 0.022 s | 1.0 % |

Twelve per cent against eighty. The doubling is even linear -- four tile
passes add 0.233 s each against the pair's 0.226, within three per cent --
which is what a measurement looks like when it is measuring *something*
consistently.

**What it is consistently measuring is not the share.** A second dispatch of
the same product is recorded into the same command buffer with no barrier
between it and the first, so the device overlaps them; and it reads weights
and activations the first pass has just pulled into cache. Both make the
second pass cheaper than the first, so **a doubling is a lower bound on what
a kernel costs, not its share of the run**. This page already said so --
"doubling it adds only 0.405 rather than 0.540, because two dispatches in
one command buffer pipeline better than one does" -- and the trap was walked
into anyway, which is the reason for writing it down twice.

The floor is the sounder instrument of the two, because emptying a dispatch
removes the work without leaving a warmed cache behind it. The arithmetic is
most of a device prompt, and the surround is a fifth.

**And one thing here is new and stands on its own.** If the arithmetic is
what binds this, it is fair to ask what about it binds: the same prompt on
the same code at three weight sizes --

| | weights | prompt |
|---|---:|---:|
| Q8_0 | 1171 MB | **2.292 s** |
| Q4_K_M | 638 MB | 2.342 s |
| Q2_K | 461 MB | 2.465 s |

**Two and a half times fewer weight bytes is slower, not faster.** The device
prompt is not bound by the weight traffic at any of these sizes, which
agrees with what `tests device-bench` says about the tile in isolation and
now says about the whole run as well. What is left is the arithmetic itself
and the decode in front of it -- the cheaper formats do more work per byte,
and the table above is that cost showing through.

Nothing kept; three scratch builds, all discarded.

### The exponential the compiler could not see past

A softmax over an attention row called the library's exponential once an
element, in binary64, and a processor prompt is heads times positions times
positions of them. A profile of the 1419-token prompt:

| | share |
|---|---:|
| `__ieee754_exp_fma` | 2.89 % |
| `exp` | 2.01 % |
| `Numerics.Exp` | 1.24 % |
| `Kernels.Softmax` | 2.38 % |

Eight and a half per cent, nearly all of it inside one call. **A call cannot
be vectorized and this shape can**: exponentiating a row is a map, every
element independent of every other, which is the one thing `-O3` does
without being asked -- as the value blend two sections above already
demonstrated by being packed before anyone touched it.

`Model_Runner.Kernels.Exponentiate` replaces the call with the standard
decomposition: e^x as two raised to *x* over the logarithm of two, the whole
part built as an exponent field and the fraction by a degree five
polynomial, in binary32.

**Two things stopped it vectorizing, and both are worth writing down because
neither is visible in the source.** `'Truncation` is not an instruction: it
is a call into `System.Fat_Flt.Attr_Float`, and one call in a loop is a loop
that stays scalar. Adding three halves of two to the twenty-third and taking
it away again rounds to the nearest whole number in two additions and no
call. And `Integer (Whole)` carried an overflow check, which is a branch;
the floor at eighty-seven bounds the value, so the check is suppressed with
the reason written beside it. With both gone the object file holds 18
`addps` and 16 `mulps` where it held `mulss`, `addss` and two `call`s -- four
lanes rather than eight, because the baseline target is x86-64 and that is
what an `xmm` holds.

| | before | after |
| --- | ---: | ---: |
| round 1 | 10.854 s | 10.484 s |
| round 2 | 10.770 s | 10.593 s |
| round 3 | 10.611 s | 10.392 s |
| round 4 | 11.129 s | 10.316 s |
| round 5 | 11.029 s | 10.480 s |

**Median 10.854 against 10.480, three and a half per cent, better in five of
five.** The profile said eight and a half and the clock says three and a
half, which is the lesson this page keeps relearning: samples are not
seconds.

The answers move, so the sweep is the arbiter -- 28344 sequences, nothing
outside tolerance -- and a test holds the two exponentials against each
other to a few parts in a million over the range a softmax hands it. That
test names the floor as the case that matters: below eighty-seven the true
value is smaller than binary32 holds, and the exponent this builds would
wrap rather than saturate, so a score far behind the leader would come back
*ahead* of it.

### What the strip kernel is short of, and what it is not

`### The instructions that were free` ended by saying the strip kernel is
not short of instruction slots and that what it *is* short of is a different
measurement. This is that measurement, and then an attempt to act on it that
did not survive.

**First, the counters for a whole prompt.** 710.3 G instructions in 235.7 G
cycles is an **IPC of 3.01**, with frontend stalls at 1.4 per cent of cycles
and cache misses at 0.4 per cent of instructions. The machine is not
stalling. That already explains the null in the section above: at three
instructions a cycle with slack to spare, the shuffles removed there were
filling slots something else had left idle.

**Then, whether the byte dot product is the wall.** One extra `vpdpbusd` was
added to the chain of eight -- the same operand into the same accumulator,
so the answers are wrong and the shape is exactly right. Twelve and a half
per cent more byte products, and:

| | cycles |
|---|---:|
| eight dot products | 224.7 G |
| **nine** dot products | **222.1 G** |
| eight again | 221.8 G |

**An eighth more byte products costs no measurable cycles** -- less than the
spread between two identical runs. The wall clock could not resolve this at
all (better in two of four rounds and worse in two, which is drift); cycles
could.

So the loop has slack, and the reason is latency rather than throughput:
each accumulator's chain is `vpxor` into `vpdpbusd` into `vcvtdq2ps` into
`vfmadd231ps`, four deep, and only eight of them run independently.

**The obvious remedy, and it lost.** Two Q8_0 blocks a turn with sixteen
accumulators instead of eight, so that the odd and even blocks stay
independent all the way to the reduction -- which also halves the loop's own
overhead, the cursors advancing 68 and 64 instead of 34 and 32.

| | one block a turn | two |
| --- | ---: | ---: |
| round 1 | 10.426 s | 10.872 s |
| round 2 | 10.538 s | 10.943 s |
| round 3 | 10.516 s | 10.802 s |
| round 4 | 10.686 s | 10.856 s |
| round 5 | 10.594 s | 10.626 s |

**Three per cent worse, in five of five.** More independent chains and less
loop overhead, and it is slower.

The likeliest reason, written down as a reason and not a measurement: the
loop body went from about thirty-nine instructions to about seventy-eight,
and something that was holding the shorter one -- an op cache, a loop
buffer -- stops holding the longer. This page has met that shape before on
the other side of the machine, where adding eight unreachable formats to a
shader cost the six that were reachable twenty-one per cent.

So the strip kernel has issue slack and cannot be given more independent
work without losing more than the slack is worth. What is left to try is the
other direction -- a *shorter* chain rather than more of them -- and this
does not answer whether that exists.

Nothing kept.

### The fold, paid once for eight scores instead of eight

After the exponential landed, a fresh profile put `Kernels.Head_Dot` at
**twelve per cent** of a 1419-token prompt -- the second largest symbol in
the program, and one written three commits earlier.

| | share |
|---|---:|
| `rows_by_strips` | 60.67 % |
| **`head_dot`** | **12.00 %** |
| `blend_exact` | 5.27 % |
| `blend_run` | 4.23 % |
| `softmax` | 2.69 % |
| `exponentiate` | 1.64 % |

**The premise was checked before anything was written**, which is the habit
this page has been arguing itself into. A dot product is eight fused
multiply-adds and then a fold -- `vextractf128`, `vaddps`, two `vhaddps`,
`vmovss` -- a serial chain of about twenty cycles standing behind arithmetic
worth eight. Removing the fold gives wrong answers and says what it costs:
**10.501 s against 10.076**, four per cent of the whole prompt, faster in
five of five.

`Kernels.Head_Scores` computes eight scores at once. Eight accumulators, one
a key, and the whole sixty-four-wide query head held in eight more registers
across all of them: a key costs eight fused multiply-adds reading it where it
lies and nothing else, and the eight folds become **one twelve-instruction
reduction** -- `vhaddps` in pairs, then pairs of those, then the two halves
added -- with two dependent chains where there were eight. The query is
loaded once a run rather than once a score.

**Where it is called from is the part that took thought**, because neither
obvious order works. Position outside head reads the key cache once, which
is what `### The processor's key cache read once a head` won, but asks for
one score at a time. Head outside position lets eight keys share a fold and
walks the whole cache again for every head. Eight positions at a time has
both: the eight key rows a block needs are eight kilobytes for this
architecture and stay in the nearest cache while all thirty-two heads read
them.

| | before | after |
| --- | ---: | ---: |
| round 1 | 10.286 s | 9.326 s |
| round 2 | 10.098 s | 9.383 s |
| round 3 | 10.528 s | 9.383 s |
| round 4 | 10.255 s | 9.638 s |
| round 5 | 10.528 s | 9.607 s |

**Median 10.286 against 9.383 -- eight and eight tenths per cent, better in
five of five.** The processor's prompt goes 167.4 to **176.3 tokens a
second** and the gap to llama.cpp on a prompt 2.35 to **2.22 times**. Unlike
the three changes before it this one shows on the 110-token prompt too,
because a fold is paid once a score whatever the context length.

Not bit for bit with `Head_Dot` and it cannot be: a lane's products are
summed in the same order and the eight lanes are folded in a different one.
The sweep is the arbiter, and a test compares **every score of a run**
against the one `Head_Dot` gives for the same key -- which catches a
permutation of the fold, where a comparison of totals would not.

### The serial half

`### The instructions that were free` and `### What the strip kernel is
short of` between them established that the largest symbol in the program --
sixty-one per cent of a prompt's samples -- is bound by neither its
instruction count, nor its chain latency, nor the weight bytes, and that the
machine runs it at three instructions a cycle without stalling. Every
attempt to make it faster has measured level or worse.

This asks a question none of those did: **how much of a prompt can seven
workers reach at all.** The same 1419-token prompt at one, two, four and
seven:

| workers | wall | processor | speedup | efficiency |
|---|---:|---:|---:|---:|
| 1 | 34.606 s | 35.58 s | 1.00x | 100 % |
| 2 | 16.860 s | 45.45 s | 2.05x | 103 % |
| 4 | 12.249 s | 50.77 s | 2.83x | 71 % |
| 7 | **9.540 s** | 53.12 s | **3.63x** | 52 % |

Amdahl fitted to the four- and seven-worker points gives a **serial fraction
of fifteen per cent** and predicts 3.63 times at seven, which is exactly
what it reaches. The prompt is *at* its ceiling: the wall clock is fully
explained by the part that does not share.

**And that part is now the larger half of the run.** Fifteen per cent of the
one-worker time is 5.19 s, and the whole prompt at seven workers is 9.54 s:

| | of a seven-worker prompt |
|---|---:|
| what one core does alone | **54 %** |
| what seven cores do together | 46 % |

Halving the strip kernel -- the thing four changes have now failed to do --
would take the prompt from 9.54 s to about 7.4. Removing the serial part
would take it to 4.35.

**A profile cannot see this**, which is why those four changes went to the
wrong place. `perf` reports where instructions are, summed over eight
threads, and by that measure the strip kernel is sixty-one per cent and the
serial loops are a few per cent each. The serial part is one thread's worth
of samples and more than half of the clock. `### One core, and seven idle`
found the same shape on the device and named the blocker as one scratch
array shared between shares; the joining phase has had per-share scratch
since, and this says there is more of it left than that entry accounted for.

The two-worker row is worth a note: 2.05 times on two workers is superlinear
and the model under-predicts it by three seconds, which is what a second
core's share of cache looks like. The fit is to four and seven for that
reason, and the fifteen per cent should be read as the number that explains
those two rather than as a constant of the program.

Nothing was changed here. The next thing to do on the processor is in the
serial half, and this is the measurement that says so.

### The gate's activation, and what a share cannot fix

`### The serial half` put fifteen per cent of a prompt in a part seven
workers cannot reach. Profiling **by thread** says which part: the main
thread is busy for 9.46 seconds of a 9.54 second prompt and each worker for
6.24, and outside the strip kernel the main thread carries 8.7 per cent of
all samples against a worker's 3.2. Named:

| main thread only | share of all samples |
|---|---:|
| `quantize_vectors` | 1.54 % |
| `SiLU` and the exponentials it calls | ~2.0 % |
| `Multiply`, `mat_mul_range_packed` | 0.63 % |
| `Apply_Rotary`, `RMS_Norm`, `Add` | 0.25 % |

Small shares of a profile and large shares of a clock, because they are paid
whole rather than divided among eight.

**The obvious remedy is wrong, and its failure found the right one.** If the
submitting task carries more than a worker, give it a smaller share -- half
of one, the rest spread over the workers. That measured **three per cent
worse, in five of five**. The reason is worth keeping: the serial work
happens *between* dispatches, not inside one, so shrinking the submitter's
share overlaps it with nothing and merely gives the workers more to do. A
share cannot fix what is not in a share. Reverted.

**What was kept.** `SiLU` is `Value / (1 + exp (-Value))` in binary64 with a
library call an element. It now goes through the same polynomial the softmax
got in `### The exponential the compiler could not see past`, hoisted into
one body-local `Raised` so the constants exist once -- inline, and with the
checks suppressed *inside* it. Suppressing them in the callers instead left
an overflow check and a call in the loop and cost both of them their
vectorization; the object file caught that before any measurement did.
Clamped at both ends rather than one, because SiLU's argument is unbounded
where a softmax's is not.

| | before | after | |
|---|---:|---:|---|
| 1419-token prompt | 9.384 s | **9.057 s** | 3.5 %, five of five |
| 110-token prompt | 0.843 s | **0.810 s** | 3.9 %, four of four |

The processor's prompt reads **183.6 tokens a second** and the gap to
llama.cpp on a prompt is **2.09 times**, from 2.5 when the day began.

**And two mistakes about the instrument, both nearly published.** The
110-token prompt read 0.84 s in one alternation and 0.62 in the sitting
before it, and the conclusion drawn was that removing the load-average wait
from the gate had removed an accidental cool-down. It had not: **two copies
of the sitting script were running at once**, and the part sat at 95 degrees
while they fought and fell to 63 within twenty-five seconds of killing them.
Contention, not temperature. That is the third measurement this session
spoiled by running something beside it, and the gate caught two of the three
by refusing outright.

The second: the repository checks can be run alone -- `tests check ..
--repository`, eleven seconds against five minutes -- and that flag was in
the usage line the whole time. A conformance sweep was run after every
restamp for no reason at all.

### The packing, shared

`quantize_vectors` was the largest of the main-thread-only items the section
above named: **1.54 per cent of the program's samples and all of them on one
thread of eight**, which is about nine per cent of the clock.

**Checked before changed**, because two of today's wins came from doing that
and the one loss came from not. The loop is already vectorized -- 16
`cvttps2dq`, 16 `addps`, 8 `mulps` -- and its two calls are cold check
handlers, not per-element. There were no lanes left to win. The lever was
parallelism.

**And it has to be its own dispatch.** Packing runs before the workers are
woken, and it cannot be folded into the product's shares: that job is cut by
*rows of the weight matrix* and every worker needs *all* of the activation,
so none of them can start until the whole of it is packed. But the packing's
own loop is over blocks, and a block is independent of every other -- its own
scale, its own bytes, its own total. So `Quantize_Blocks` takes a range of
them and the packing becomes a dispatch of its own, before the product's.

The bound is 256 blocks. A wake and a barrier are not free, and a run of a
few blocks is packed faster than a pool can be told about it; a generated
token is one vector and is the case that bound is really keeping out.

| | before | after |
| --- | ---: | ---: |
| round 1 | 9.221 s | 8.478 s |
| round 2 | 8.506 s | 8.258 s |
| round 3 | 8.546 s | 8.139 s |
| round 4 | 8.911 s | 8.350 s |
| round 5 | 8.947 s | 8.401 s |

**Median 8.911 against 8.350 -- six and three tenths per cent, better in five
of five.** And **bit for bit**, digest `cbf29ce484222325` either way, because
splitting independent blocks between tasks cannot change what any of them
writes. A test asserts that directly: a run cut into four uneven pieces, one
of them empty, must give the same bytes, scales and totals as the run packed
whole.

**The processor's prompt reads 206.8 tokens a second and the gap to
llama.cpp on a prompt is 1.87 times** -- under two for the first time, from
2.5 when the day began.

### The instruction is twice as fast and the kernel is slower

The strip kernel is **sixty-nine and a half per cent** of a processor prompt
and four changes have failed to move it. `### What the strip kernel is short
of` established what it is not bound by; what it had never been asked is
whether the *instruction* is the ceiling.

**It is not, and by a wide margin.** A scratch program timing nothing but
byte dot products, four independent chains, on this host:

| | giga-multiply-adds a second | time for the same instruction count |
|---|---:|---:|
| 256-bit `vpdpbusd` | 152 | 0.168 s |
| **512-bit `vpdpbusd`** | **324** | 0.158 s |

**A `zmm` byte dot product costs what a `ymm` one costs and does twice the
work** -- 2.12 times, agreeing to six tenths of a per cent across rounds. It
is not double-pumped, which is what the entry on the 512-bit idea guessed
without measuring and got wrong.

And the arithmetic said the kernel had room for it: 3.1e12 multiply-adds in
a 1419-token prompt over eight cores is about 67 giga a core inside this
symbol, against the instruction's 152. It issues **thirty-nine instructions
for two hundred and fifty-six multiply-adds** where the peak is one for
thirty-two.

**So it was built, and it lost.** Two rows' blocks into one register with
`vinserti64x4`, the activation duplicated into both halves with
`vbroadcasti64x4`, and the per-block scale -- which is a broadcast for one
row and cannot be for two -- expanded from the existing table by `vpermps`
rather than by storing a table sixteen times the size.

| | before | after |
| --- | ---: | ---: |
| median of five | 8.275 s | **9.228 s** |
| | | worse in five of five |

**Eleven and a half per cent slower.** And the counters say exactly why, and
rule out the obvious excuse:

| | cycles | instructions | IPC |
|---|---:|---:|---:|
| 256-bit | 190.1 G | 550.0 G | 2.89 |
| 512-bit | 206.7 G | **532.5 G** | 2.58 |

**Fewer instructions in more cycles, and no clock effect at all** --
cycles a second is one and a third per cent *higher* on the wide build, so
Zen 4 is not throttling for AVX-512 here. The instructions that feed the
wide dot product simply cost more than the dot products they save:
`vpermps` is a cross-lane permute, and there are four of those, four
`vbroadcasti64x4` and a `vinserti64x4` for every block.

That is the same shape as `### And the matrix instruction, which lost` on
the device: an instruction worth having that the data's layout cannot feed.
Making it pay would mean changing the layout -- interleaving several rows'
quants so that one wide load is one wide operand, which is what the other
runtime's repacked formats are for -- and that is a change to what a
file becomes at load, not to a loop.

Reverted. The measurement is what is kept: **the wide instruction is worth
2.12 times and this kernel cannot reach it from the layout it reads.**

### The interleaving, priced before it was built

The entry above ended by naming the interleaved layout as the way to reach
the wide byte product: rows' quants rearranged at load so that one wide load
is one wide operand. Done at *four-byte* granularity it removes the last
cross-lane instruction as well -- if a 512-bit lane alternates between two
rows, the scale operand is `[sA, sB, sA, sB, ...]`, which is a
`vbroadcastf32x2` from memory and not a `vpermps`.

That is a change to the loader, the packer, the kernel and a fallback path.
**So it was priced first**, with both loop shapes written against synthetic
data and nothing in the engine touched:

| | giga-multiply-adds a second |
|---|---:|
| two rows in two 256-bit registers, as committed | 127, 130 |
| **interleaved into one 512-bit, no permutes** | **137, 137** |

**Five per cent.** Twenty-five instructions a block against thirty-nine, the
cross-lane permute gone, the row pairing free -- and a twentieth. Five per
cent of an inner loop that is about half the kernel, on a kernel that is
seventy per cent of a prompt, is under two per cent of a prompt for a change
to what a file becomes at load. **Not built.**

**And the priced experiment says something worth more than its own result.**
That same loop reaches 127 here and the real kernel manages about 67 -- the
same instructions at half the speed. So the inner loop is already at
four-fifths of what the byte dot product does in isolation, and **half of
this kernel's time is not in its inner loop.** The annotation agrees: it put
the inner loop at forty-seven per cent of the symbol and the scale-table
build at about a third.

Which leaves a contradiction, and it is now the sharpest open question here.
`### The instructions that were free` halved the scale-table build's shuffles
and measured level, concluding they overlap with the dot products and cost
nothing. If that is right, the missing half is somewhere neither measurement
has looked.

### The second loop, of the same length

Two entries disagreed. `### The instructions that were free` halved the
scale-table build's shuffles and measured level, and concluded the block was
free. `### The interleaving, priced before it was built` found the inner loop
already at four-fifths of the byte product's isolated peak, which leaves half
this kernel somewhere else. Both cannot be right.

One ablation settles it: build the table for the first panel only. Wrong
answers, but valid floats -- an uninitialised table would read as denormals
and time nothing honest -- and the build's cost divided by the panel count.

| | with the build | without it |
|---|---:|---:|
| round 1 | 8.456 s | 6.700 s |
| round 2 | 8.058 s | 6.829 s |
| round 3 | 7.798 s | 6.541 s |
| round 4 | 8.328 s | 6.841 s |
| round 5 | 7.869 s | 6.700 s |

**Seventeen per cent of a prompt -- 1.358 seconds -- better in five of
five.** The scale table is not free and never was.

**And the arithmetic that should have been done first says why both
measurements are true.** For a 2048-row matrix the build runs one thousand
and twenty-four panels of sixty-four blocks of eight, which is 512 thousand
iterations; the insertion beside it runs 512 thousand byte dot products.
**The build is not overhead around the inner loop. It is a second loop of
the same length**, four or five instructions an iteration against the dot
product's four. Halving one kind of instruction inside it was never going to
show, and removing the loop shows immediately.

What it computes is `Scale (row, block) * Vector_Scale (block, vector)` --
eight products a block, stored, then read back one at a time by the
insertion as a broadcast. The products themselves are irreducible: the
insertion needs each of them. What is not irreducible is computing them once
a panel and writing them to memory to be read again a few instructions
later, and that is where the seventeen per cent lives.

Nothing kept here: the ablation gives wrong answers and exists to price the
block. But it is the largest single item this file has measured on the
processor since the byte dot product itself.

### The scale table, as two loops

The ablation above priced the build at seventeen per cent of a prompt. What
it computes -- eight products a block, a weight scale times an activation
scale -- is irreducible: the insertion reads every one of them. **The shape
was not.**

The inner four turns did two things at once: a store into `Scaling` and a
read-modify-write into `Undo`. The second is what stopped the nest
vectorizing, and it is why halving the shuffles inside it did nothing --
there was never anything wrong with the shuffles.

Apart, the first is a map and the second an accumulation, and `-O3` takes
both four at a time. And the correction now multiplies by the block's scale
times its total, worked out **once a call** rather than once a panel, so a
turn multiplies by one number where it multiplied by two.

| | before | after |
| --- | ---: | ---: |
| round 1 | 8.383 s | 8.214 s |
| round 2 | 8.369 s | 7.760 s |
| round 3 | 8.436 s | 7.909 s |
| round 4 | 8.116 s | 8.064 s |
| round 5 | 8.264 s | 8.062 s |

**Three and seven tenths per cent, better in five of five.** That is about
0.31 s of the 1.358 the ablation priced -- a quarter of the block. The other
three quarters are the products and their stores, which the insertion needs.

Not bit for bit: `(Scale * Vector_Scale) * Vector_Total` became `Scale *
(Vector_Scale * Vector_Total)`, the same three numbers in a different order,
and the sweep is the arbiter as usual.

**The same restructuring measured level two days ago and was reverted.** The
difference is the second multiply: splitting the loops alone left every turn
multiplying twice, and the entry that recorded that null did not yet know
the block was worth seventeen per cent, so it read a small null as a closed
question.

### One multiply-add against thirty-two

The scale table's remaining cost was split by two more ablations, each
keeping one half of the block and dropping the other. Four rounds, three
builds alternated inside each round so drift touches all three alike:

| | median | worth |
|---|---:|---:|
| as committed | 8.113 s | |
| the table's multiply and its load gone | 7.646 s | 0.466 s, 5.7 % |
| **the correction's accumulation gone** | **6.186 s** | **1.927 s, 23.7 %** |

**The correction is a quarter of the prompt.** It is one multiply-add per
block, row and vector, standing beside a byte dot product that does
thirty-two -- a thirty-second of the arithmetic taking half the time. That
is not a cost, it is a symptom, and `addr2line` names it: the four turns
write `Undo (At_Undo + Vector)`, an array read and written in place, and
`-O3` builds a shuffle network around it. `vunpcklps`, `valignd` and
`vaddps` come to **eighteen per cent of the symbol** for four additions.

**Two ways around it were tried and neither works.**

*The row outside the block*, so the four corrections live in registers.
That halves the shuffles -- `vunpcklps` 95 to 48, `valignd` 72 to 36 -- and
measures **eight per cent worse, in five of five**, because the scale table
is then written with a stride of eight floats in two passes where it was
written straight through. Getting one of the two things right is worse than
getting neither.

*The block still outermost, both inner loops written out*, eight named
scalars across the whole block loop and the table still written in order.
The object file comes back with **exactly the baseline's shuffle counts** --
94, 72, 64, 50 -- and it measures level. GNAT is vectorizing across the
block loop, not within the four turns, and neither shape reaches that.

So the correction's cost is real, large, and out of reach from Ada as
written. What is left is to compute it where the code is not the compiler's:
the insertion already reads the scale table a block at a time, and could
accumulate the correction with one more fused multiply-add and one more
broadcast per dot product. That is about a wash by instruction count and it
moves eighteen per cent of a symbol out of a shuffle network, which is the
whole of the argument for trying it.

**And the reduction, which completes the accounting.** The last unpriced
block is the eight lanes the insertion leaves, summed into a binary64
accumulator once a row-vector pair. Ablated by summing one lane instead of
eight -- which keeps the structure and the store, so nothing downstream goes
dead -- it is **0.310 s, three and nine tenths per cent**, against the eight
and a half per cent of samples `addr2line` put at that line.

| | of a prompt |
|---|---:|
| the bias correction | **23.7 %** |
| the table's multiply and load | 5.7 % |
| the `Landed` reduction | 3.9 % |
| the byte dot products | the rest |

**Two of the three want the same fix.** The insertion holds its eight
accumulators in registers when the block loop ends: it could fold them there
-- the twelve-instruction reduction `Head_Scores` already uses, two dependent
chains instead of eight separate folds -- and it could accumulate the
correction with one more broadcast and one more fused multiply-add a dot
product. One change, twenty-seven and a half per cent of a prompt in reach,
and both blocks out of the shuffle network that neither Ada restructuring
could escape.

Nothing kept.

### Both blocks, moved into the insertion

The accounting put the bias correction at **23.7 per cent** of a prompt and
the eight-lane reduction at **3.9**, and found both to be shuffle networks
and widening loops that `-O3` built around Ada and that no arrangement of
Ada could talk it out of. Both are the insertion's now, which is the one
place in this kernel where the code is not the compiler's.

**The correction, in three instructions a block.** It wants, for each of the
eight row-vector pairs, the sum over blocks of that pair's scale times the
block's total. The insertion *already reads those eight scales* -- one per
dot product, as a `{1to8}` broadcast. Read instead as a single thirty-two
byte `vmovups` they are eight lanes in the order `[row0 v0..v3, row1
v0..v3]`, and the block totals, written twice over at eight to a block, line
up with them lane for lane. So one `vmovups`, one `vfmadd231ps` into an
accumulator, and **all eight corrections advance together**.

**The fold, in twelve at the end**: `vhaddps` in pairs, then pairs of those,
then the two halves added -- the reduction `### The fold, paid once for
eight scores instead of eight` already proved, two dependent chains where
Ada had eight widening loops. The accumulators moved from `ymm16`--`23` down
to `ymm8`--`15`, because `vhaddps` has no EVEX encoding and cannot reach the
high sixteen; the assembler said so plainly and it is the sort of thing only
the assembler knows.

| | before | after |
| --- | ---: | ---: |
| round 1 | 8.339 s | 7.378 s |
| round 2 | 7.825 s | 6.953 s |
| round 3 | 8.144 s | 7.005 s |

**Fourteen per cent, better in three of three** -- the largest single change
this file has measured on the processor. Against the 27.6 the two blocks
were priced at, recovering fourteen is what three instructions a block and
twelve a panel predict.

**The processor's prompt read 254.6 tokens a second in that sitting and the
gap to llama.cpp on a prompt was 1.51 times**, from 2.5 when this began. The
three sittings after it read 226.3 and 1.54, then 238.1 and 1.37, then 238.1
and 1.40, on code that got faster each time while the machine wandered under
it -- llama.cpp included, which is what `### A slower day, measured on both
sides` is for.

The answers move -- the correction associates differently and the fold is a
tree where it was an ascending binary64 sum -- and the sweep is the arbiter
as always.

### Five hundred and twelve bits, measured and refused

With the strip kernel down to sixty-three per cent of a prompt, the next
thing to price was its innermost four instructions: a zeroed accumulator,
the byte dot product, a convert, and a scaled multiply-add. One of the four
is arithmetic. Two blocks in one five-hundred-and-twelve bit register halves
the other three per unit of work, and an earlier probe measured this part's
wide byte dot product at **2.12 times** the narrow one.

It was built. Two rows of the panel share one wide register, the weights
arriving as an insert of the second row's thirty-two bytes above the first;
the activation is broadcast to both halves; the row scale is a sixteen-lane
read whose halves are the panel's two rows, so the combined per-panel scale
table that cost the Ada beside the insertion its whole remaining share goes
away entirely.

| | instructions | cycles |
| --- | ---: | ---: |
| before | 469.3 G | 156.5 G |
| after | 435.6 G | **188.0 G** |

**Seven per cent fewer instructions for twenty per cent more cycles.** The
2.12 is not a bonus, it is the double pump: this part executes a
five-hundred-and-twelve bit operation as two two-hundred-and-fifty-six bit
ones, so a wide dot product costs what the two narrow ones it replaces cost
and the three instructions around it cost what *their* two copies cost.
Nothing was saved on the arithmetic, and the scale plumbing the wide shape
needs -- a broadcast of the activation, a multiply to fold the row scale in,
four correction multiply-adds where there was one -- is new work with nothing
to pay for it.

The change is reverted and this is what is left of it. **The width was never
the lever**; the instruction count would have been, on a loop that was
front-end bound, and this one is not. It is worth the paragraph because the
2.12 reads like a promise and is not one, and because the only way that was
going to be found out was to build it and count cycles.

### What the compiler could not be talked into

Three loops the profile named, none of them in the strip kernel, all three
the same failure: a shape `-O3` will not vectorize, in a translation unit
compiled for baseline x86-64.

**The driver's scale table, 3.3 per cent.** The loop that reads a tile's
weight scales out of the file asked `Block_Bytes` for the block size *inside
the loop*, and it did not inline: a call, an overflow check and a bounds
compare, per block, around a two-byte load. The size is already a constant
of the enclosing procedure. Using it, and suppressing the checks the
enclosing procedure suppresses everywhere else, is the whole change.

**Softmax's division, and its total.** Four passes over the scores, and two
of them were paying for the wide format: the last divided every score by a
binary64 sum -- a convert up, a divide, a convert back, four values a turn --
and the one before it accumulated that sum one lane at a time down a chain
where every add waited on the one before. The division is one reciprocal now,
taken wide and rounded once, then a narrow multiply a score. The total is
four independent chains put back together in a fixed order, so the answer is
a function of the input and not of the length.

**Softmax's maximum, 8 lanes for 1.** The first pass wanted two things of
every score: the largest, and whether it is finite. The second is an integer
test of the exponent field, and a compiler that sees a float turned into bits
one element at a time will not make eight lanes of it -- so neither happened.
Written out as an insertion both are lane work: a maximum, and an ordered
compare of the magnitude against infinity whose mask is accumulated and read
once at the end. A value that is not finite fails that compare whether it is
an infinity or a NaN, which is exactly the test the caller wanted.

| | before | after |
| --- | ---: | ---: |
| round 1 | 7.739 s | 7.478 s |
| round 2 | 7.845 s | 7.878 s |
| round 3 | 7.812 s | 7.299 s |
| round 4 | 7.867 s | 7.632 s |

**Three and a half per cent of a 1419-token prompt, better in three of
four**, and 469.3 G instructions against 456.7. The digest does not move.

**It does not show on the 110-token prompt at all** -- 0.50 s either way,
alternated -- and that is the shape of the work rather than noise. Attention
grows with the square of the context, so two thirds of what this change
touches is a hundred and sixty times smaller there. A change measured on one
prompt length and published against another is a change measured on nothing,
which is why both are here.

### The scalar loops nobody had looked at

The strip kernel had had five changes and attention had been priced; the two
symbols nobody had ever opened were the quantizer's own and the tile
write-back. Between them they were **5.8 per cent of a prompt**, and both
turned out to be the same failure the softmax passes were.

**The tile write-back, 2.8 per cent.** A tile's answers are binary64 and the
target is binary32, so the loop narrows as it copies. What the profile put on
top were not the converts: they were the index compares -- `cmpq` after
`cmpq` -- guarding a loop whose bounds this procedure proves at entry and
then does not tell the compiler about. Suppressing them and lifting the
vector's base out of the inner loop is the whole change. **2.8 to 1.3 per
cent.**

**The quantizer's magnitude pass, 3.0 per cent.** Every block of activations
is scanned for its largest magnitude and for whether all thirty-two of its
numbers are finite, and it was scanned one number at a time: an `andps` for
the magnitude, a `maxss`, and then `movd` / `notl` / `andl` for the exponent
field. This is exactly `### What the compiler could not be talked into` in a
different unit, and it has the same answer. Four reads of eight lanes: a
bitwise and, an ordered compare of the magnitude against infinity whose mask
is accumulated, and a maximum. A value that is not finite fails that compare
whether it is an infinity or a NaN. **3.0 to 1.8 per cent.**

| | before | after |
| --- | ---: | ---: |
| round 1 | 7.739 s | 6.845 s |
| round 2 | 7.667 s | 6.878 s |
| round 3 | 7.418 s | 7.016 s |
| round 4 | 7.709 s | 6.885 s |

**Ten and a half per cent, better in four of four**, and 410.2 G instructions
against 390.2. Five per cent of the instructions bought ten of the time,
which is what removing scalar code from a program that is otherwise wide
looks like: the instructions that went were the ones retiring slowest.

### Three things measured and not kept

The same sitting tried three more and kept none of them. They are here
because a reader deciding what to try next is better served by four
measurements than by one.

**Prefetching the value cache: no effect.** `Blend_Run` reads two and a half
per cent of the program's instructions and takes seven of its samples, which
says it is waiting. A position's values are contiguous and the next
position's are a whole cache row away, so the obvious suspect is that the
hardware does not follow the stride. Four `prefetcht0` for the next
position's four lines, and the answer is **6.927 s against 6.846 -- better in
two of four**, which is nothing. Whatever it is waiting for, it is not that.

**Two positions a turn: worse in four of four.** The other way at the same
suspicion -- sixteen loads in flight instead of eight, and three instructions
of loop spent on twenty-four rather than twelve. Fewer instructions,
**6.729 s against 6.925, worse every round.** The indexed second operand and
the `leaq` that advances two rows at once cost more than the loop they
replaced.

Between them those two say the value blend is not where a *layout* change
would pay, which is what the pair was run to find out. It stood unexplained
for one commit; `### Three questions asked of the hardware` below explains
it, and the explanation is why both of these failed.

**A strip of twelve: priced at one and a half per cent, not built.** After
`### A strip of eight` the arithmetic looked like it went on. It does not,
and the counting says why: the corrections grow with the strip. Twelve
vectors is 4 weight instructions, 96 dot products, 8 corrections and 5 of
loop -- 113 for 24 dots, against 77 for 16, which is 4.71 per dot against
4.81. **Two per cent of the kernel for a shape needing fifteen of the
sixteen general-purpose registers** and a scale table padded to a hundred and
twenty-eight bytes a block. Eight vectors against two rows is a local
optimum and the counting is what says so, not a measurement that was never
taken.

### Three questions asked of the hardware

The commit before this one left a symbol whose cost had no explanation and
two guesses about it that had both failed. Guessing again was the wrong move;
counting was the right one. `perf record` takes a hardware event as easily as
it takes cycles, and attributing *misses* to symbols rather than *time* is
what settled all three questions below.

**Where the value blend's time goes, answered.** Over the whole prompt the
run takes 2.53 G last-level misses, 19.0 G first-level misses on 172.9 G
loads, and 12.2 M page-table walks. By symbol:

| | LLC misses | L1 misses | TLB walks |
| --- | ---: | ---: | ---: |
| `blend_run` | **68.1 %** | 19.0 % | 8.2 % |
| `head_scores` | 19.9 % | 6.3 % | 11.8 % |
| `rows_by_strips` | 3.3 % | **70.8 %** | 14.1 % |

**Two thirds of everything this program fetches from memory is fetched by
the value blend**, on two and a half per cent of its instructions. That is
the answer, and it says plainly why the two earlier attempts failed: a
prefetch hides latency and an unroll hides latency, and **this is not
latency, it is bytes**. The value cache of a 1419-token prompt is 1.4 MB a
layer and 32 MB across the model, against sixteen of last-level cache, and
every blend reads it from memory.

The strip kernel is the mirror image and it is the reassuring half of the
table: seventy per cent of the first-level misses and three per cent of the
last-level ones, which is a kernel streaming through cache exactly as
intended.

What this points at is **fewer bytes rather than better access**: the value
cache stored at half precision would halve the traffic and change the
answers by a rounding. That is the next thing to try, and it is a different
change from any in this section -- it is not a loop, it is a format.

**The thirty-four byte stride, ablated: nothing.** A Q8_0 block interleaves
its two-byte scale with its thirty-two quants, so the kernel steps weights by
thirty-four and every load straddles a cache line about half the time.
Setting the step to thirty-two gives wrong answers and right timing, and the
timing is **6.629 s against 6.976 -- no gain**. Misaligned loads cost nothing
measurable on this part, so the alignment argument for repacking the weights
is dead.

**And the scale extraction is already done once per share.** The remaining
argument for a repack was `rows`' seven per cent, which reads those
interleaved scales back out. It was hoisted from the kernel to the caller and
measured: **390.2 G instructions to 413.5**, worse, because the tiles already
partition the share's rows -- the work was never repeated -- and the
conditional slice handed down copied itself once a tile. The only version
that would save anything is a cache living across batches, which is about a
hundred and twenty-eight megabytes for this model to save perhaps six per
cent, and the weights would stop being the file's own pages. Written down
rather than built.

**The exponential, ablated.** Everything around it in softmax fell and it did
not, so it was run twice: **6.629 s against 6.985**, five and a half per cent
of the wall for two and three quarter per cent more instructions. One copy is
three to five per cent and retires slowly, like the blend. It is the largest
thing left in these kernels that has never been touched.

### A slower day, measured on both sides

The figures in this section were re-taken twice, because the first sitting
read the processor's prompt at 0.51 s where the sitting before it had read
0.43. The second was started from a genuinely idle machine -- load 0.15, the
part left to cool until its temperature stopped falling -- and read 0.49.
**The part's idle floor had moved from 51 to 54 degrees**; the room was
warmer, and a 15 W part has nowhere to put that.

What says it is the machine and not the code is that **llama.cpp moved with
it**, measured in the same sitting on the same file: 385.0 tokens a second on
a prompt before, 347.8 now, a tenth down. And the two binaries were run
against each other directly, alternated, on that machine in that state: level
on the 110-token prompt and three and a half per cent apart on the long one,
exactly as the section above says.

So every absolute in that sitting was about a tenth below its predecessor,
and the ratios -- which is what a comparison table is for -- were within a
rounding of where they had been.

**And it kept going, and then it came partway back.** Over four sittings
llama.cpp read 385.0, 347.8, 326.0 and 334.4 tokens a second on a prompt, on
a binary that has not been rebuilt -- a thirteen per cent spread with nothing
in it but the machine. This program's own figure went 254.6, 226.3, 238.1,
238.1 over the same four, because the code changed under it. **The gap is the
only thing in this table that means anything across sittings**: 1.51, 1.54,
1.37, 1.40. **An absolute published without the machine it was taken on is a
number about nothing**,
which the host block in
[docs/measured-figures.txt](docs/measured-figures.txt) has said for a while
and this is the first sitting to need it.

### A strip of eight, and four for what it cannot reach

The strip kernel was still sixty-five per cent of a prompt, and after
`### Five hundred and twelve bits, measured and refused` the width was known
not to be the lever. The instruction count was. Per block the kernel loads
two rows of weights and biases them -- four instructions -- and then spends
four per dot product. **Those four loads served four vectors. Serving eight
halves their share**, and the eight extra accumulators the wider strip needs
were sitting unused: this instruction set has thirty-two registers and the
shape was using ten.

| | per block | per dot product |
| --- | ---: | ---: |
| four vectors | 42 instructions for 8 dots | 5.25 |
| eight vectors | 77 for 16 | **4.81** |

The obstacle was not the vector registers, it was the sixteen
general-purpose ones. Eight activation pointers, two weight rows, the scale
table, the block totals, the answers, a block count and three index registers
do not fit. Two things make them fit. **Four pointers reach eight vectors**:
the strip's vectors are a fixed stride apart, so a second index register
starting at four strides and stepping beside the first addresses the upper
four through the lower four's pointers. And the two operands that are read
once each -- the block count and that stride -- are given memory constraints
rather than registers, which costs two instructions at entry and buys two
registers for the loop.

The bias corrections stopped needing a fold at all. A row's eight of them are
the eight lanes of one accumulator, one to a vector, so where the four-wide
shape spent twelve instructions folding them the eight-wide shape spends one
store. The sums still fold, twice -- and the second row's eight accumulators
live above the sixteenth register, which `vhaddps` cannot encode, so they
come down first. Ten instructions once a panel, against a hundred and
seventy-six blocks of work.

| | before | after |
| --- | ---: | ---: |
| round 1 | 7.588 s | 6.947 s |
| round 2 | 7.199 s | 6.971 s |
| round 3 | 7.660 s | 7.021 s |
| round 4 | 7.604 s | 6.777 s |

**Eight and a half per cent, better in four of four**, and 449.2 G
instructions against 410.2. Every digest is unchanged: the association inside
each accumulator is what it was, and doubling the number of accumulators does
not touch it.

**A strip of eight cannot reach four to seven vectors, and the first attempt
sent them through the single-vector kernel.** That cost a sixth of the
six-token prompt and *moved its answer*, because the single-vector kernel
sums a row in one register across blocks where a strip folds eight lanes.
Neither is wrong and they do not agree in the last bits. So the four-wide
kernel stayed, as `Rows_By_Strips_Four`, for the one strip of four a batch
may end with; three or fewer after that still go singly, as they always did.
A batch is a hundred and twenty-eight and divides by eight, so this is the
last batch of a prompt and nothing else -- and it is the difference between a
digest that moves and one that does not.

### Two kernels priced, and what the price says

Attention's two kernels are eleven per cent of a prompt between them and
neither had ever been priced. Both are already hand-written wide, so a
profile share says nothing about whether there is anything to win. Running
each one twice does.

| | instructions added | wall added |
| --- | ---: | ---: |
| `Head_Scores` | 26.4 G, **6.5 %** | 2.8 % |
| `Blend_Run` | 9.6 G, **2.4 %** | ~6 % |

**They are opposite kinds of expensive, and both answers are useful.**

`Head_Scores` issues six and a half per cent of the program's instructions
and a second copy of it costs under three per cent of the wall -- so it is
already overlapping with everything around it, and making its instructions
fewer would buy a fraction of that. There is nothing here.

`Blend_Run` is the reverse: **two and a half per cent of the instructions and
six and a half per cent of the samples**. It is not computing, it is waiting.
It walks the value cache with a stride of the cache's row width, one position
at a time, which is a gather in everything but name. What that says is that
the thing to change is the layout it reads, not the code that reads it -- and
that is a different kind of change from every one in this section so far.

Neither was built. The point of pricing a block is to find out whether to,
and this pair says: not this one, and not that way.

### Against llama.cpp

Nothing here delegates to another runtime, and the comparison with one has
until now been about agreement rather than speed: `docs/reference-runtime.md`
records that llama.cpp and this engine read the same file into the same
tokens and continue it the same way. What each of them costs to do that is
this table, taken in one sitting on the host every other figure in this
section was taken on, against the same TinyLlama-1.1B-Chat Q8_0 file on both
sides, with llama.cpp at `95b8e33e1`:

| | prompt, 110 tokens | generating, 64 tokens |
| --- | ---: | ---: |
| model_runner, processor | **238.1 t/s** | 31.3 t/s |
| llama.cpp, processor | 334.4 t/s | 40.0 t/s |
| model_runner, device | 679.0 t/s | **40.1 t/s** |
| llama.cpp, device | 1666.2 t/s | 56.1 t/s |

On the processor: **1.3 times slower generating and 1.4 times slower reading
a prompt** -- the generating figure has read 1.3 and 1.4 across sittings of
code that did not change between them, which is what a ratio does when both
of its sides sit within a per cent of a rounding boundary -- where the first
reading of this table said 3.3 and 16. On the device, **1.4** and **2.5**,
where the sittings before this one said 1.4 and 2.2, then 1.4 and 2.5, then 1.4 and 2.3, then 1.4 and 2.5, then 1.4 and 2.4, then
1.4 and 2.6, then 1.4 and 2.5, then 1.4 and 3.0, then 1.4 and 3.6, then 1.4 and 3.8, then 1.4
and 3.9, then 1.4 and 4.0, then 2.0 and 4.0, and the first said 3.8 and
10.1. Both device rows have moved for a named reason:
`### The matrix instruction` for the prompt, `### The batch that was not
there` for the generating one, which went 28.1 to 40.8 tokens a second.

**This table was wrong for one commit and the way it went wrong is worth
recording.** The four rows above were restamped in the same sitting as
everything else under `### Against llama.cpp` -- and the edit that wrote
them failed partway and was never applied, while the sentences either side
of it were. So the repository carried a table saying 141.2 and 352.0 under
prose quoting 166.7 and 389.0, for one commit. Nothing here caught it: the
fingerprint check asks whether a group was re-measured, not whether every
number in it moved, and it cannot ask the second question without knowing
which numbers belong to which figure. Reading the table against its own
prose is what caught it, which is a thing only a person does.

**The device row and llama.cpp's processor row generate at about the same
rate** -- 40.1 against 40.0 in this sitting, where the six before read 40.7
against 40.0, 38.9 against 40.0, 40.9 against 40.4, 41.0 against 40.4, 40.7
against 40.7, and 41.6 against 40.0. Five of those seven put this program's
device ahead and two put it behind, by under three per cent either way, which is a pair of figures
sitting on top of each other rather than a lead in either direction. What is left
between it and llama.cpp's own device figure is 1.4 times.

The processor's generating row is the other kind of gap. It reads every
weight once a token and does one multiply with each, so the bus answers
rather than the arithmetic: llama.cpp's 40.0 t/s is about 46 GB/s of this
model and 31.3 is about 37. What is left there is a gap in the kernels --
ordinary Ada compiled for baseline x86-64, which `## Not implemented` says
and this measures -- rather than a gap in what the program is doing.

The prompt is the other kind, and the device row has just stopped being an
example of it. A batch here shares one reading of the weights between the
tokens in it, which is what `### Batched prefill` is about; what it did not
share was the arithmetic, which stayed a row product per token. The other
runtime turns the same batch into a matrix-matrix product against
hand-written kernels -- AVX-512 with integer dot products on this processor,
cooperative matrices on this device -- so its prompt figure was never
eighteen times a better loop, it was a different shape of work.

**On the device that shape is now this program's shape too**, and the gap
went from eight times to four. On the processor it is not: a prompt there is
still a row product per token, against the other runtime's matrix kernels,
and closing that needs the same change made in a different place.

The runs are

```
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt.txt \
  --max-tokens 0
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt-short.txt \
  --max-tokens 64
llama-bench -m MODEL -p 110 -n 64 -t 8 -r 3 --device none
llama-bench -m MODEL -p 110 -n 64 -ngl 99 -r 3
```

with `--backend device` added to the first two for the device rows. `tests
speed` reports seconds and this table reports rates: 110 tokens in 0.462 s
and 64 in 2.043 s on the processor, 0.162 s and 1.595 s on the device,
medians of three as everywhere else here.

**The blend two sections above does not show in this table and cannot**,
which is worth saying rather than leaving as a puzzle. Attention grows with
the square of the context, so a 110-token prompt holds about a hundred and
sixty times less of it than the 1419-token prompt that change was measured
on. Five and three quarter per cent there is a fraction of a per cent here,
and the processor's prompt row reads level -- 0.660 s against 0.652 -- as it
should. The processor rows are at the
default arithmetic and the device rows are not affected by it.

`--device none` is doing work in that command. With `-ngl 0` and a Vulkan
device present llama.cpp still evaluates the prompt on it -- 760.7 t/s rather
than 334.4 -- so a reader who takes this again the obvious way will measure
the device and read it as the processor, and will get a *smaller* gap than
the true one for the processor row.

The device generating row was the noisiest here for a long time: 40.1 t/s
now, against 40.7, 38.9, 40.9, 41.0, 40.7, 41.6, 41.3, 40.6, 41.0, 41.5, 41.2, 40.8, 28.1, 30.9, 27.1, 31.0, 30.9, 27.3, 26.9, 31.0, 31.2, 28.1,
31.8, 32.0, 31.1, 30.7, 30.5, 22.0, 21.1, 23.3, 24.2, 18.2, 15.9, 17.7,
14.9, 14.1, 14.1, 13.7, 16.9, 16.2 and 13.3 in twelve earlier sittings at
comparable loads. Every reading between 26.9 and 32.0 is the same code; the
step to 40.8 is the narrow row kernel and nothing else, and it is the first
time this row has moved for a reason rather than for a sitting. The
processor rows and both prompt rows repeat to a few per cent. Every figure in the table is one
model, one file, one host and two prompt lengths, and a model that is not a
small dense llama may sit anywhere with respect to it.

The processor rows have moved six times since the first reading -- 21.5 to
24.1 to 48.2 to 53.5 to about 62 to 79.9 to 87.4 to 92.2 to 99.0 to 137.5 to
140.3 to 140.7 to 136.5 to 149.1 to 153.0 to 144.2 to 146.9 on the prompt, and 11.0 to 12.2 to about 23 to 28.6 to 29.0 to 27.9 to 27.6 to
29.8 to 29.6 to 30.5 generating, where the four before the last are one path read in four
sittings rather than four changes, and the last is the first thing to move
that row since the arithmetic did -- and the moves are different kinds of thing. One of
them is the machine rather than the program, and is quoted loosely for that
reason: the prompt read 1.687, 1.732 and 1.767 s across three sittings with
nothing between them touching the processor path at all, before attention
took it to 1.377. The first was the same arithmetic in a
different order: attention's blend reads a position's values where they lie
now rather than once per component, and the rotation's angles are computed
once per position rather than once per head, and the run's digest did not
change. The second is a different arithmetic, bounded and measured rather
than free, and the digest did change. Quoting them together without saying
which is which would be the kind of figure this file exists to avoid. The
third is neither: four rows of the matrix are multiplied against one reading
of the activation instead of one, which changes no value at all -- the
generated text's digest is what it was before it -- and moves only the
prompt, because only a prompt has rows enough at once for it to matter. The
fourth is a default: the batch a prompt is read in went to the engine's cap,
which the device cared about far more than the processor did.

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

All three medians of three:

| | Twelve tokens | |
| --- | --- | --- |
| TinyLlama-1.1B at eight bits | 0.441 s | 37 ms a token |
| the same model at two bits | 1.816 s | 151 ms a token |
| the first, drafted by the second | 3.797 s | 24 proposed, 7 accepted |

The two-bit file is a third of the size on disk and costs nearly three times
as much per token to run, because what it saves in bytes it spends unpacking
them -- and because the eight-bit file now multiplies its activations as
bytes while the two-bit one has no integer kernel and cannot. A smaller file
is not a faster model, and that alone decides this pair: a draft costing more
per token than the model it drafts for cannot win at any acceptance rate. The
gap between the two was twice, then fifteen per cent, then nearly three
times, then three and a quarter, then three and two thirds, then three and a
half, and is now four; widening it does not change the sign either.

The arithmetic, from the same three figures. Six rounds of four proposals
cost 3.433 s, of which the draft's own twenty-four passes are 24 × 127 ms =
3.05 s, leaving 0.38 s for six checks -- **64 ms to check five positions**,
against 36 ms for one token generated normally. A batch is one pass over the
weights and the extra work is the output projection per position, which is
why five positions cost about two tokens rather than five.

So a round of K proposals costs `K × d + 64 ms` and yields `1 + a` tokens,
against `(1 + a) × 36 ms` without a draft. At the acceptance measured here,
about 1.2 of four, a round yields 2.2 tokens worth 79 ms and the check alone
costs 64: no draft pays at this acceptance, the check alone costing more
than the tokens a round yields. **That threshold has read 17, 10, 6, 9, 6,
4, 7 ms a token, nothing at all, 11, 18, and nothing twice more across
twelve sittings of the same code**, because it is a difference of
two twelve-token runs and a twelve-token run is a third loading and warm-up.
The conclusion is stable and the number is not: this draft costs an order of
magnitude more than any of them. The check got a great
deal cheaper with the arithmetic -- it was 320 ms -- and so did the model it
is checking for, which is why the answer is the same as it was.

The drafted run now prints the same digest as the undrafted one --
`33f48397f89839f6` both ways -- which is the guarantee this section opens
with, showing up in a published figure rather than only in the test that
holds it.

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

Twelve tokens from the short prompt, generation only, medians of three. The
four-bit file answers this prompt in ten and stops, so its row is ten tokens
and carries the per-token figure beside it; the rows are comparable to each
other along that column and within themselves along the others:

| weights | generated | as stored | `f32` | `bf16` | as stored, a token |
|---|---|---|---|---|---|
| Q8_0 | 12 | **1.014 s** | 1.499 s | 1.022 s | 84.5 ms |
| Q4_K_M | 10 | **0.807 s** | 1.107 s | 0.835 s | 80.7 ms |
| Q2_K | 12 | 1.304 s | 1.363 s | **0.955 s** | 108.7 ms |

So repacking now pays for Q2_K and for neither of the others: `bf16` takes
twenty-seven per cent off the two-bit file, nothing off the eight-bit one and
three per cent *onto* the four-bit one, and `f32` costs time in all three —
half as much again on Q8_0. That reverses the reading this table had when the
same three modes were last measured, where `f32` paid for Q2_K and `bf16` paid
everywhere.

The kernels explain the reversal. A binary32 row product is still the fastest
per element — 0.26 ns against 0.32 for BF16, 0.39 for Q8_0 and 0.73 for Q2_K
— but those are measured on a 64 MB matrix, and a repacked model is 4.4 GB in
binary32 against 2.2 in BF16 and 1.2 as stored. At that size the product waits
for memory, and every step that makes the decoding faster moves more of the
run into that wait: what repacking buys is decoding, and what it costs is
bytes to fetch. Q8_0 decodes fast enough now that there is nothing left to
buy; Q2_K is the slowest format here to decode and is the one where buying it
still wins.

The Q4_K row was missing from the reading before this one, this machine having
had no four-bit file of this model at the time; it was fetched to take it,
which is why the file named in
[docs/fixture-provenance.md](docs/fixture-provenance.md) is now the one
TheBloke published rather than one requantized here. The row read 1.44 s
stored, 1.55 s to `f32` and 1.40 s to `bf16` when it was last taken, on a
file made the other way and a machine two sittings ago.

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

| `--batch-size` | prompt evaluation, `cpu` | rate | `device` |
|---|---|---|---|
| 1 (one token at a time) | 3.863 s | 28.5 tokens/s | |
| 2 | 2.338 s | 47.0 tokens/s | |
| 4 | 1.631 s | 67.4 tokens/s | |
| 8 | 1.372 s | 80.2 tokens/s | 0.711 s |
| 16 | 1.297 s | 84.8 tokens/s | |
| 32 | 1.337 s | 82.3 tokens/s | 0.519 s |
| 64 | 1.296 s | 84.9 tokens/s | |
| 128 (cap, default) | 1.195 s | 92.1 tokens/s | 0.554 s |

This table used to be measured through the chat template while the figure at
the top of the section was measured raw, and neither said which. That is
where its old caption's "131-token prompt" came from -- the file is 110
tokens and the template wraps it to 131 -- so a reader who took the command
printed above and pointed it at this prompt got numbers about a quarter
lower than the table and nothing to explain the gap. Both are raw now. The
templated numbers were 13.16 s down to 6.45 s across the same sweep; they
were not wrong, they were answering a question the caption did not ask.

The default is the cap, and the device column is why. Batching amortizes the
cost of reading the weights across the tokens that share them, which is what
the processor column measures and where it flattens after eight. The device
column measures something else: the number of times the host tells the device
to do something. The three device readings are the same weights read the same
number of times -- a batch of eight and a batch of a hundred and twenty-eight
both pass over the model sixteen times for these 110 tokens -- and they
differ by a factor of 2.6, which is all telling.

That was worth finding. This program had assumed the cost of a device call
was small enough to leave the default where the processor wanted it; it is
0.6 to 2.3 ms a call, and a 110-token prompt at a batch of thirty-two makes
about five hundred of them. What the default now costs instead is how often a
run can be cancelled or report progress while reading a prompt -- every
hundred and twenty-eight tokens rather than every thirty-two, which on this
model is about a second. A caller who wants a finer grain asks for a smaller
batch and pays for it in prefill.

The device column's first two readings are from the sitting that chose the
default; the one at the cap has since halved again, to 0.608 s, because
neither the activation a product writes nor the results it reads back are
mapped and unmapped once a call any more. That is the batching working exactly as described, on a smaller
share of a much smaller total.

### Quantized activations

`--arith int8` rounds the vector a matrix product multiplies to one byte an
element, with a scale for every thirty-two of them, and multiplies two
integers where `--arith f32` multiplies two floats. **It is the default**,
and every figure above is at it; `f32` is the other one and is what the
figures published before this option existed were taken at.

```
model_runner run MODEL --arith f32
```

On the same TinyLlama-1.1B Q8_0, medians of three, the two arithmetics
against each other in one sitting:

| | `f32` | `int8` |
| --- | ---: | ---: |
| twelve tokens | 1.341 s | **0.471 s** |
| -- processor time | 8.71 s | **2.66 s** |

Those two are one pair, taken back to back. The longer runs were measured as
a pair in an earlier sitting, before the four rows below were tiled, and read
4.940 s against 2.210 s on the 110-token prompt and 5.642 s against 2.922 s
for sixty-four generated tokens, with 38.68 s of processor time against
17.13 s. Twice as fast on either, and half the energy.

The rows are multiplied several at a time against one reading of the
activation. A row at a time read the same bytes out of the same cache line
once for every row of the matrix -- two thousand times for a matrix of two
thousand rows -- and being in the nearest cache is not the same as being in a
register. A tile also gives the processor that many independent chains where
one row gave it one. It changes no value -- the generated text's digest is
what it was -- and it moves only the prompt, because only a prompt has rows
enough at once to reuse anything.

**How many rows is not a constant, and finding that out is the more useful
half of this.** Four was measured and published here: 2.120 s at two rows a
tile, 1.948 s at four and 2.122 s at eight on the 110-token prompt, read as
four being where the register file runs out. Taken again it says something
else -- 1.379 s at four, 1.351 at six and **1.281 s at eight** -- and nothing
about the kernel changed between the two sittings. What changed is the batch:
that first sweep was run when a prompt was read thirty-two vectors at a time
and the default is a hundred and twenty-eight now. A tile reads the
activation once and the activation is re-read once per tile, so what a larger
tile saves grows with the batch, and the answer to "how many rows" moved
without the question being asked again.

A generated token is one vector, and there the activation is two kilobytes
and in the nearest cache whatever the tile: eight measures slightly worse
than four, 2.593 s against 2.545. So the tile is chosen from the vector count
rather than fixed -- eight for a prompt, four for a token -- which is the
only reading here that took both.

That the two disagree is the useful part. A prompt is bound by re-reading
activations and a generated token is bound by streaming weights, and a
constant tuned against one of them is a constant tuned against the wrong
thing half the time. Two other attempts at the same suspicion were measured
and dropped, both recorded in `docs/measured-figures.txt`: keeping the eight
lane sums a block product leaves, so the horizontal reduction happens once a
row rather than once a block, costs 2.6 times the prompt, because the lane
form is no longer a reduction and the compiler stops emitting the
sixteen-bit multiply-add this kernel is written around; and storing the
quantized activations sixteen bits wide, which removes a widening that is a
quarter of the kernel's element operations, is level generating and slower on
the prompt, because doubling the activation array costs more in traffic than
the widening costs in arithmetic. What it costs is stated below,
and what it does not cost is worth saying first: within a block this path is
the *more* accurate of the two. Thirty-two byte products summed into a
thirty-two bit integer cannot exceed 516128 and so round nothing at all,
where the floating-point path rounds every one of the thirty-two products
and then rounds the sum. What is rounded is the input, once, before the
product -- and every layer's output is the next layer's input, which is where
the error that is left comes from.

The conformance sweep holds it to 5.0E-2 relative and 5.0E-1 absolute, a pair
measured the way the three lossy pairs above it were, and it runs the mode
rather than only stating a bound for it: every gate run compares the
quantized path against the independent implementation on the formats that
have an integer kernel, and the count of what it compared is published with
the sweep's other figures so that a pass which quietly fell back to the
floating-point path reads as the zero it would be. Forcing the whole sweep
into the mode -- `tests conformance --arith int8`, every format, every
architecture, every shape -- gives 0.426 worst absolute and 1.92 worst
relative over 1.1 million logits, none outside the bound.

On a published model the same change leaves greedy output character for
character where it was over the first two dozen tokens, which is an anecdote,
and the bound is set from the sweep instead.

### The four-bit k-quant, which had none of this

Every kernel above was written for Q8_0 and served Q8_0 alone. `Q4_K` is what
most published models are actually stored in, and until now it took the
floating-point path for every product it ever did -- so the same model, in
the smaller file, read a prompt **seven and a half times slower** than the
larger one.

It did not need a new idea. It needed the one already here, pointed at it:

- **A nibble is already what the instruction wants.** `VPDPBUSD` multiplies
  unsigned bytes against signed ones, and the eight-bit format has to be
  biased by a hundred and twenty-eight and the bias taken back out of the
  answer. A four-bit quant is zero to fifteen and goes in as it lies.
- **One read serves two sub-blocks.** The low nibbles of thirty-two packed
  bytes are one sub-block and the high nibbles the next, which is the pairing
  the decoder beside it already reads them in. A mask gives the first and a
  shift with the same mask the second: four instructions where the eight-bit
  format needs two, for twice as many multiplies.
- **The correction is the `Totals` table, at last used for what it is for.**
  A Q4_K value is a scale times the quant less a minimum, so the sum wants
  the sub-block's activation total -- which this kernel has been handed since
  the byte product was written, and which the note beside it says was "put
  there for the formats that carry a minimum and unread for this one".

| 110-token prompt, TinyLlama Q4_K | | |
|---|---:|---:|
| the floating-point path | 4.598 s | 31.67 s of processor time |
| the byte dot product | **1.317 s** | **8.19 s** |

Medians of three alternated rounds, better in every one, and **the digest is
the same in all six**: `4b6e8e99ae285b2a`. Nothing about the arithmetic
changed except which instruction performs it -- the integer sums are exact
either way and the rounding falls in the same places, which is not true of
the eight-bit format and is worth saying because it is the happier case.

**And a generated token has one too, which is the half that was not
obvious.** The eight-bit format's generated token is bound by the memory
path: it stops getting faster at four workers, and a better kernel cannot
help a token that is waiting. This one was not waiting. Varying the worker
count said so before anything was written -- 1.510 s at two shares, 1.130 at
four, **0.993 at seven**, still improving where the eight-bit format is flat
past four -- because the floating-point path it was taking spends its time
unpacking and multiplying rather than fetching. A token that is working can
be helped, and the same three differences apply unchanged.

| thirty-two generated, TinyLlama Q4_K | | |
|---|---:|---:|
| the floating-point path | 0.938 s | 6.33 s of processor time |
| the byte dot product | **0.505 s** | **2.81 s** |

Medians of three alternated rounds, the same digest again, and the prompt
beside it unmoved. Fifty milliseconds a token against eighty-four, where the
eight-bit format takes thirty-three -- so what was three times behind is now
half again.

A strip of four vectors, or one vector, and nothing between: two and three
vectors have no kernel, nor has a host without the byte dot product, and all
of them go back where they went before. The one thing that had to be added is
a question the caller asks first -- whether a product of this format and this
many vectors will *use* the quantized activations -- because quantizing them
for a product that then declines is the whole cost of the packing and none of
its benefit. Measured before that question existed: forty per cent of a
generated token.

### And the six-bit one beside it, because a file is a mixture

Giving Q4_K a kernel took its prompt from 4.598 s to 1.317 and then stopped
short, and a profile said why in one line: `accumulate_dot`, the
floating-point row product, was **44.7 per cent** of what was left, sitting
beside the new kernel's 43.6. Reading the file's own tensor table says what
that was.

| TinyLlama Q4_K_M | tensors | share of the weights | share of the prompt |
|---|---:|---:|---:|
| Q4_K | 135 | 83.1 % | 43.6 % |
| **Q6_K** | 21 | **16.9 %** | **44.7 %** |

**A "_M" file is a mixture by construction** -- the output projection and a
handful of other tensors are kept at six bits -- so the most commonly shipped
quantization is one sixth Q6_K by weight and was half Q6_K by time. One
format left on the old path cost as much as the eighty-three per cent on the
new one.

Three things differ from the four-bit kernel, and the middle one is the
pleasant surprise.

- **A quant is six bits in two places**: four in a nibble of the low array
  and two in a field of a shared byte, at a shift the group decides.
  Assembling thirty-two is a mask, a shift, a second mask, a shift and an or
  -- five instructions where the four-bit format needs two, and still
  nothing beside the twenty the four vectors then spend multiplying them.
- **A scale covers sixteen elements where an activation block covers
  thirty-two**, so a block wants two of them -- and the instruction makes
  that free. The byte dot product sums four bytes into each of eight lanes,
  so the first sixteen bytes land in lanes nought to three and the second
  sixteen in lanes four to seven: **the two halves are already apart when
  the sums arrive.** Two masked multiply-adds, one per half of the register,
  and nothing has to be split or done twice.
- **The quants go in unsigned**, without the thirty-two the format subtracts,
  because unsigned is what the instruction's first operand wants. Taking it
  back out needs the activation's sum over each *sixteen* -- not over each
  thirty-two, which is what `Totals` holds -- so that one is summed here
  rather than read.

| 110-token prompt, TinyLlama Q4_K_M | | |
|---|---:|---:|
| Q4_K on the byte product, Q6_K on the old path | 1.355 s | 8.29 s of processor time |
| both on the byte product | **0.990 s** | **5.47 s** |

and `### The scales were decoded once for every strip` takes the same file to
0.875 s further down, by removing work rather than by adding an instruction.

Medians of three alternated rounds and the same digest again. **Four and a
half times, end to end**: this file read a 110-token prompt in 4.598 s that
morning.

**And its generated token, which was the last floating-point path left.** A
six-bit product of one vector had nowhere to go until it had a kernel of its
own, and a profile put the unpacking and the floating-point dot product
together at **forty-one per cent** of a Q4_K_M token. With one:

| thirty-two generated, TinyLlama Q4_K_M | |
|---|---:|
| the six-bit tensors on the floating-point path | 0.505 s |
| the six-bit tensors on the byte product | **0.356 s** |

Thirty-five milliseconds a token, where the eight-bit file takes thirty-three
-- so a file two thirds the size now generates at the same rate, and the
prompt beside it is unmoved.

**One of these two kernels did not work at first, and why is worth keeping.**
Every insertion in this file advanced the pointers it was handed -- an `addq`
on an operand the compiler was told is an *input* -- which says nothing to
the compiler and works only while it has no other use for that register. With
eleven operands it stopped working: the procedure raised inside a worker, and
*adding an exception handler and nothing else made it run*. That is the
signature of code generation rather than arithmetic, and a handler is not a
fix.

**So none of them do it any more.** All six insertions keep their cursors in
registers of their own, named in the clobber list, and advance nothing they
were given; where a counter was decremented in place it is copied first. Four
of the six were working at the time and had passed gates -- including the one
every generated eight-bit token runs, which advanced four operands, more than
the kernel that failed. They were correct by luck rather than by
construction, and the luck was observed running out once already.

Three alternated rounds on both models say the change costs nothing: 2.086 s
against 2.085 generating the eight-bit file, 0.765 against 0.767 on its
prompt, 0.362 against 0.357 generating the four-bit one, every digest
unchanged. `Rows_Singly` is one instruction a block shorter than it was,
because three pointer advances became two.

Not every product takes it. A weight format with no integer kernel, and a
width that is not a whole number of thirty-two, are computed the other way
whatever is asked for -- Q8_0, Q4_K, Q5_K and Q6_K are what have one today,
and the eleven others are still decoded into binary32 first. The refusal is per product and it is
all or nothing over a worker's share, so no row is computed twice and none is
left at zero. `--backend reference` never quantizes anything: it exists to be
a second opinion with none of the fast path's shortcuts, and this is one of
them.

The width that made it work is sixteen bits rather than eight, which is worth
writing down because the obvious reading is the other one. Baseline x86-64
has no byte dot product; it does have a pair of sixteen-bit lanes multiplied
and added into a thirty-two bit lane. Unpacking a block's weights to
sixteen-bit integers once and multiplying those was 2.4 times the
floating-point path with one vector a pass and 2.75 with thirty-two -- from
ordinary Ada, with no intrinsic and no instruction set beyond the baseline.

Those two figures are history now, and re-reading them says something this
file had not noticed. `tests benchmark` measures whichever compilation the
host admits, which on this one is the byte dot product, and it reads **4.86
times the floating-point path with one vector a pass and 0.96 with
thirty-two** -- medians of three runs, and the same pair on the compilation
before the change that first found it, so it is a standing property rather than
anything done to the kernel here. The batched case has crossed below one:
with thirty-two vectors a pass the floating-point path decodes a block once
and multiplies it thirty-two times, so its decode is amortized away, while
the quantized path has thirty-two activation vectors of its own to round
first. That reading is the measurement; the explanation for it is a guess
until something ablates it, and it is written here as one.

The first version of this was *slower*: level with one vector a pass and 41
per cent behind at thirty-two. It unpacked the weight bytes inside the loop
over the batch rather than outside it, so each vector re-read the whole block
and a batch stopped being a batch. That is the same lesson the note above
`Accumulate_Dot` records from the other direction, and it took a measurement
to see either time.

### And the five-bit one, which is the same kernel and one more bit

`Q5_K` is `Q4_K` with a bit taken out of every quant and kept apart: the same
two scales, the same twelve bytes of packed six-bit scale and minimum pairs,
then thirty-two bytes carrying the fifth bit of all two hundred and fifty-six
elements, then the nibbles. Both of the four-bit format's kernels therefore
applied as they stood, and the only question was what putting that bit back
costs.

**Three instructions a sub-block and one constant register.** The bit a
sub-block wants is bit *s* of its byte, so a word shift brings it to bit four
-- left by four for the first sub-block of a block, right by three for the
eighth -- a mask of one in sixteen per byte drops whatever the shift dragged
in from the neighbouring byte, and an or puts it on the nibble. The quant is
then zero to thirty-one, which is still what the byte dot product's unsigned
operand wants, so everything around the instruction is the four-bit kernel's
unchanged: no bias, and the minimum's term taken out once a row against the
sub-block's activation total. Counted in the strip kernel's block:
**forty-eight instructions against the two hundred and fifty-six the
multiply-adds spend**, beside the thirty-two nibble masks and shifts the
four-bit kernel already paid.

| TinyLlama Q5_K_M | | |
|---|---:|---:|
| 110-token prompt, floating-point path | 4.193 s | 29.09 s of processor time |
| 110-token prompt, byte dot product | **1.061 s** | **5.73 s** |
| thirty-two generated, floating-point path | 3.330 s | 19.45 s |
| thirty-two generated, byte dot product | **1.241 s** | **4.32 s** |

Medians of three alternated rounds, better in every round, and the digest is
the same in all twelve runs -- `cbf29ce484222325` for the prompt and
`0a1a63f0305d35d6` for the generated tokens. As with the four-bit format the
integer sums are exact either way and the rounding falls in the same places,
which is not true of the eight-bit one.

A `Q5_K_M` file is the same mixture a `Q4_K_M` file is, so its six-bit
tensors were already covered and its five-bit ones were the whole of what
was left. Four of the fifteen formats have a kernel now, and between them
they are what a `Q4_K_M` or a `Q5_K_M` file is made of.

### The scales were decoded once for every strip

A batch is swept four vectors at a time, so a 110-token prompt is
twenty-eight strips -- and every one of them decoded the same weight scales
again. For the eight-bit format that is one half-precision number per row and
block. For the k-quants it is that plus twelve bytes of six-bit fields
unpacked into eight scales and eight minimums, or sixteen signed sub-block
scales. All of it is the same for every strip, and all of it was done
twenty-eight times.

A profile said where to look and the counter said what it was worth:
`rows_by_strips` is 73.5 per cent of a prompt, and inside it the machine-code
insertion is 43 per cent against 57 for the arithmetic around it.

The scales are worked out once per call now, into a table the strips read.

| 110-token prompt on the processor | before | after |
|---|---:|---:|
| Q4_K_M | 1.046 s | **0.875 s** |
| Q5_K_M | 1.077 s | **0.882 s** |
| Q8_0 | 0.815 s | 0.792 s |

Medians of three alternated rounds, better in every round for the two
k-quants, every digest unchanged, and a generated token untouched -- 2.240 s
against 2.233 for sixty-four of them, because a generated token is one vector
and goes through a kernel with no strips in it.

**The eight-bit format has the least to gain and gains the least**, and its
counter is the honest measure of the whole change: 54.9 thousand million
instructions became 43.5, and 14.72 thousand million cycles became 14.45. A
fifth of the work removed bought two per cent of the time, which says that
kernel was never issue-bound. What the k-quants had was not a few more
instructions but several times as many, and there the same removal is worth a
fifth of the prompt.

That is also why this was not found by reading. The redundancy is visible in
the source -- a decode inside a loop whose caller loops over strips -- and it
had been visible since the strip kernel was written. What made it worth
finding was the profile, and what made it worth keeping is that the two
figures disagree: the instruction count says a fifth and the clock says two
per cent, and both are true of different formats.

### A tenth of the instruction's peak, and why that is arithmetic

A 110-token prompt is **103.6 thousand million multiply-adds** through the
strip kernel -- counted by a counter in the panel loop rather than estimated
-- in 13.4 thousand million cycles at one worker. That is 7.75 a cycle, where
a byte dot product delivers thirty-two of them and this part issues two a
cycle. Twelve per cent of the peak, and nothing here explained it.

**It is the instruction mix, and there is no stall in it.** The insertion's
loop body is forty instructions and eight of them are the byte dot product.
The other thirty-two are the eight zeroed accumulators, the eight converts
from integer to binary32, the eight multiply-adds that apply the scales, the
two weight loads and four of loop control. One instruction in five -- and not
one of the thirty-two is waste, because a format with a scale every
thirty-two elements cannot convert or scale less often than that.

| a 110-token prompt, one worker | instructions | |
|---|---:|---:|
| the whole run | 43.55 G | |
| the strip kernel's symbol | 31.2 G | 71.6 % |
| the insertion inside it | 16.2 G | 37 % |
| the Ada around the insertion | 15.0 G | 34 % |
| everything else | 12.4 G | 28 % |

So one instruction in ten across the whole prompt is a byte dot product, each
delivers thirty-two multiply-adds, and 3.26 instructions a cycle gives about
ten multiply-adds a cycle before the rest of the program is counted. The 7.75
measured is that. **The peak of sixty-four is a loop of nothing but the
multiply, which no per-block-scaled format can have.**

**An ablation that did not work, kept because it looked as though it had.**
The insertion was replaced by a single `nop` and the run counted 42.6
thousand million instructions against 43.55 -- which would have made the byte
dot product two per cent of the program, and was wrong. With the insertion
stubbed the model no longer answers the prompt with its end token, so that
run generated twelve tokens the reference run did not, and the two counts are
of different work. The counter in the panel loop replaced it. A counter is
exact where a difference of two runs is not, and that is the second time
today an ablation has quietly measured something other than what it was
pointed at.

**The next step this suggested was the wider registers, and its premise is
false on this part.** One five-hundred-and-twelve-bit dot product covers two
blocks in a single instruction, so the loop would fall from eighty
instructions per two blocks to about fifty-two. The premise is that a wide
instruction does the work of two narrow ones in the time of one. Measured, in
a loop of eight independent dot products with nothing else in it:

| | |
|---|---:|
| 256-bit byte dot product | 279 G multiply-adds a second |
| 512-bit byte dot product | 292 G |
| one wide instruction is worth | 1.04 to 1.13 narrow ones |

and the multiply-add, which this kernel issues as often as the dot product,
answers the same: 1.03 to 1.16. **The wide instruction takes twice as long
and does twice as much** -- the datapath behind it is two hundred and
fifty-six bits and the wide form is issued over two passes. That is a fact
about this processor, a Zen 4, and not about the instruction set; a part with
full-width datapaths would answer two, which is why it is written down.

So the rewrite would leave the floating-point work exactly as it is, cut a
third of the instructions, and the hoist above already proved this kernel is
not issue-bound -- a fifth of its instructions removed bought two per cent of
its time. It is not done. Two blocks are not contiguous either: a Q8_0 block
is thirty-four bytes, so a wide load would need two narrow ones and an
insert.

**What the accounting does point at.** The floating-point floor here is three
operations per thirty-two multiply-adds per row and vector -- 9.7 thousand
million operations, 4.9 thousand million cycles at two a cycle, against 13.4
measured. The difference is instructions that are not the arithmetic, and the
largest block of those is the **fifteen thousand million in the Ada around
the insertion**, which is more than the insertion's own sixteen. That Ada
works four floats at a time, because a strip is four vectors, on pipes two
hundred and fifty-six bits wide: it uses a quarter of what it is issued on.

**So a strip of eight was built, and it is thirteen per cent slower.** Built
the cheap way, so that only the thing being tested changed: the strip carries
eight vectors and the table beside it is built eight at a time, while the
insertion still takes four and is run twice. Three alternated rounds, better
in none -- 0.776 s against 0.881, and 3.82 s of processor time against 4.45.

The stack frame it doubled is not the reason. Shrinking the tables' room from
a thousand and twenty-four blocks to two hundred and fifty-six, a quarter of
the frame, changed nothing. What is left is the shape of the read -- the
insertion now walks the table twice, each pass taking half of every
sixty-four byte entry, where before each pass had a contiguous table of its
own -- and that is a guess, written as one.

It did one other thing worth recording. A batch of four to seven vectors no
longer reaches a strip, so it goes through the single-vector kernel, and the
two agree to the sweep's bound rather than bit for bit: the twelve-token
run's digest moved on a six-token prompt. Nothing was wrong; the batching was
different. A performance change that moves a published digest has to be
noticed rather than discovered later.

**Three attempts in a row now, measured and not kept**, and together they say
one thing. The hoist removed a fifth of this kernel's instructions and bought
two per cent of its time. The wider registers do not make one instruction
worth two. Widening the arithmetic around the insertion is slower. **This
kernel's time is not set by the number of instructions it issues**, every
lever reachable from the instruction mix has now been tried, and whatever the
two-and-a-half times to the other runtime is, it is not that.

### Attention had never been told the bounds were proved

`Blend_Exact` is the attention over the cache -- the scores, the softmax and
the blend of the values -- and it was ten per cent of a prompt and rising as
a share while everything around it fell. A profile said what the ten per cent
was, and it was not arithmetic:

| | share of `Blend_Exact` |
|---|---:|
| 64-bit moves | 53.7 % |
| `jo`, the overflow branch | 19.7 % |
| everything else, including every multiply | 26.6 % |

**Not one of its ten hottest instructions was a multiply.** These three
blends were the only loops in the engine's own arithmetic that had never been
given the suppressions the row kernels carry -- six index checks an element,
on indices that differ from the last by a constant, plus an overflow branch
after each one.

Both are gone now, and in two steps that are not the same step:

- **Overflow checking off, everywhere in the three blends.** What is dropped
  is the check that an index computation does not wrap; every value in one is
  an element count of a model this program validated when it read it. Nothing
  about memory safety changes, because the index that arithmetic produces is
  still bounds-checked.
- **Bounds checking off in `Blend_Exact`, after proving the ranges once.**
  Every index it forms is a fixed function of the loop bounds, so the largest
  of each is computed at entry and compared against the array it will index;
  a call that would step outside is refused through `Ok`, which is a path the
  caller already handles because the softmax can refuse too. That is what
  `Model_Runner.Quantization.Integers.Kernels` has always done, said in the
  same words.

Attending falls from **0.074 s of a prompt to 0.039** -- 8.9 per cent to 5.3
-- and the instruction count from 62.0 thousand million to 54.7. **No answer
changes**: both digests are what they were, and the conformance sweep is at
zero outside tolerance, because a check that never fired costs time and
nothing else.

The note at the top of `Model_Runner.Llama` used to say that bounds and range
checking were untouched there. It now says where they are not, and why.

### A tile written the way the target is laid out

`Mat_Mul_Range_Packed` hands a tile of rows to the integer kernel and then
copies what came back into the target. It copied it in the order the *tile*
is laid out -- a row at a time, the vectors inside -- and the target is laid
out the other way round, a whole vector's answers together. So every step of
the inner loop moved a row count along: eight kilobytes between consecutive
writes on a two-thousand-row tensor, a cache line touched and abandoned for
each of eight hundred and eighty writes a tile.

Turning the two loops about makes the writes contiguous and leaves the reads
to stride, inside a seven-kilobyte tile that is in the nearest cache walked
either way. It is two lines, and it takes that procedure from **5.1 per cent
of a prompt to 2.1** and the prompt itself from 0.777 s to 0.744, three
rounds alternated. The same values reach the same places; no digest moves.

**The alternated rounds are the measurement and the sitting is not.** Every
figure in this section moved by less between the sitting before this change
and the sitting after it than the change is worth -- 0.784 s against 0.782 --
because the spread between sittings on this machine is larger than four per
cent. A change this size can only be seen by running both versions in one
sitting, and the profile agrees with the rounds rather than with the table.

**Unrolling the strip kernel's block loop was measured beside it and is not
here.** Four instructions of overhead a block -- two cursor advances, a
counter and a branch -- serve eight row-vector pairs, and a profile put them
at twenty-one per cent of the samples in that kernel. Two blocks a turn
removes half of them and the instruction count says so: 54.79 thousand
million against 54.03. The alternated rounds say it is *slower*, 0.756 s
against 0.738, better in none of three. The twenty-one per cent was skid --
samples charged to the branch that belong to the loads it waits for -- and
what the doubled body cost instead is not visible in any counter this file
reads. The instruction count and the clock have now disagreed twice, in
opposite directions, and the clock has been right both times.

### What a generated token is waiting for

The paragraph above says a generated token is bound by the bus rather than by
the arithmetic, and until now that was an inference from a ratio -- 27.6
tokens a second is about 31 GB/s of this model against llama.cpp's 45, so it
must be the memory. This file has been wrong that way before, and the way to
settle it is to ask the machine.

Vary the worker count and see whether the wall follows it. Sixty-four tokens,
three rounds, medians:

| shares | generating | processor time | 110-token prompt | processor time |
|---|---:|---:|---:|---:|
| three | 2.303 s | 6.30 s | 1.377 s | 3.61 s |
| four | **2.123 s** | 7.28 s | 1.051 s | 3.40 s |
| five | 2.144 s | 8.66 s | 0.981 s | 3.91 s |
| eight | 2.187 s | 12.68 s | **0.815 s** | 4.18 s |

**A generated token is done adding workers at four shares.** From four to
eight the wall goes *up* by three per cent while the processor time nearly
doubles: the memory path is saturated by two or three cores and the rest are
paying for a queue. That is the bus, measured rather than inferred, and it is
the clearest statement this file has of why the generating row will not move
for any rearrangement of the arithmetic.

**A prompt is the opposite and wants every share**: 0.815 s at eight against
1.051 at four, because a batch shares one reading of the weights between its
tokens and is bound by the arithmetic instead. The two cases disagree about
the worker count exactly as they already disagree about the row tile.

**So the share count follows the batch now**, as the row tile beside it
already does: a product of one vector asks for four shares and a batch asks
for every one. Cutting the team alone was not enough and the first attempt
measured it -- the processor time fell by a quarter and the wall rose three
per cent, because `Coordinator.Post` bumped a generation counter that opened
*every* worker's barrier whatever the job had asked for, so the four with
nothing to do still cost the wake. The barrier now tests the team as well,
and `Post` counts only the workers it will open for.

Sixty-four generated tokens: **2.196 s to 2.102**, and **12.64 seconds of
processor time to 7.17** -- three rounds alternated, better in every one.
Twelve tokens cost 1.62 s of processor time where they cost 2.63. The prompt
is untouched, and so is every digest: which worker computes a row does not
change how the row is computed.

**The arithmetic decides this, not the vector count**, and that took a second
measurement to find. Asked before the activations are quantized, the smaller
team goes to the floating-point path too -- and that path does four times the
arithmetic on the same bytes, so it is not memory-bound at all: twelve tokens
at `--arith f32` measured 1.806 s against 1.365, a third slower. The team is
therefore chosen after `Prepare_Packed` has said which arithmetic the job
carries.

### Attention, in shares of the heads

Attention over the cache was the one part of a forward pass that ran entirely
on the calling task while every worker sat idle. Reading a prompt it runs in
shares now: a head reads its own slice of the query, writes its own row of
scores and its own slice of the blend, so heads are independent and the pool
cuts them the way it cuts the rows of a matrix.

The one thing that had to change first is that the scores are a row a head
rather than one row shared. A head writes its scores, softmaxes them and reads
them back inside its own iteration, so two heads sharing a row is two heads
answering with each other's arithmetic.

```
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt-long.txt \
  --max-tokens 0
```

| | before | after |
|---|---:|---:|
| 1419-token prompt | 83.757 s | **29.286 s** |
| -- as a rate | 16.9 t/s | **48.5 t/s** |
| 110-token prompt | 1.767 s | 1.319 s |
| 64 tokens generated | 2.830 s | 2.447 s |

**Two point seven times on a long prompt**, and the shape of that is the whole
point: attention is quadratic in the context and everything else in a forward
pass is linear, so the longer the prompt the more of it attention is. At a
hundred and ten tokens it is a fifth of the gain; at fourteen hundred it is
nearly all of it. The 110-token figure is what this file publishes elsewhere
and the long one is why the fixture exists.

Generating is shared out too, and it was nearly not, which is worth a
paragraph. With the sharing in place the gate reported four logits of the
conformance sweep's 1.1 million outside tolerance -- all gemma3, generating a
token at a time, one apart by half -- while the same sweep run on its own was
clean. That is the worst way for a gate to be wrong: differently from the
thing it is meant to reproduce.

The sharing was innocent. The gate runs the unit suite before the sweep, one
of its cases runs the program in this same process, and the program's default
arithmetic is the quantized one -- so the flag was still set when the sweep
started and the whole cross product ran in an arithmetic nobody had asked
for, against the tight bound rather than its own. The gemma3 logit was 0.5131
against a bound of 0.5. The sweep sets its own arithmetic now, from the
command line and from nothing else, and reads 28344 sequences and nothing
outside tolerance either way.

Every digest is unchanged. A head's arithmetic does not depend on which other
heads are being computed beside it, so this is the same values in a different
order of execution -- which is a stronger statement than the tolerance the
sweep would have allowed.

The batched evaluator shares the heads and loops the positions inside each
share, rather than the other way round. Both are the same work; one is a
hand-off per layer and the other is a hand-off per position, which for a
hundred and twenty-eight positions over twenty-two layers would be nearly
three thousand of them for one prompt.

### One product, three compilations

The integer product is built three times from one source: once for the
instruction set every x86-64 has, once for `x86-64-v3`, and once for
`x86-64-v4`, with the host asked at run time which of them it may enter. That is the shape
`Model_Runner.Quantization.Decoders` already had, and it is here for the same
reason -- a format with two implementations has one nobody tests, so there is
one source and three compilations of it.

What the wider set buys was measured before any of it was written:

| | 110-token prompt | 64 generated |
|---|---:|---:|
| the baseline | 1.476 s | 2.672 s |
| `-march=x86-64-v3` | **1.297 s** | **2.402 s** |
| `-march=x86-64-v4`, 256-bit | 1.308 s | 2.366 s |

Twelve per cent and ten, from ordinary Ada that nobody rewrote: the sixteen-bit
multiply-add the kernel is written around has wider lanes and more of them in
the wider set. **v4 is level with v3** and excludes far more hardware, so v3 is
what is built -- and the host question it needs is the one this program
already asks for the decoders, so no new answer had to be found for it.

Both are built with floating-point contraction off, so a fused multiply-add
cannot round once where the other rounds twice, and a test asserts they
answer bit for bit -- the same discipline, and the same reason, as the
decoders' twin.

### And a third, which does not answer the same bits

There is a third compilation now, for `x86-64-v4`, and what it is for is one
instruction the compiler will not reach on its own at any `-march`:
`VPDPBUSD`, which multiplies four eight-bit pairs into a lane where the other
two multiply two sixteen-bit ones. It goes in as a machine code insertion,
and with it the weights are never widened at all -- they are the bytes the
file holds, which is both the unpack loop gone and half the operand traffic.

| | 110-token prompt | 64 generated |
|---|---:|---:|
| the sixteen-bit product | 1.271 s | 2.496 s |
| the byte dot product | **1.222 s** | **2.354 s** |

Medians of three alternated rounds, better in every one.

**Four rows go into one insertion now, and what that buys is the operands it
stops re-reading.** The instruction is one instruction, but the loop around
it was not: reading the code the compiler produced for a single row, eighteen
instructions went by for the one that multiplied, and the other seventeen
were the activation block loaded again, the bias correction loaded again,
four pointers advanced and a branch -- all of them the same for every row of
a tile. Written as four rows in one insertion they are loaded once and held,
and the group is fifty instructions rather than seventy-two: twelve and a
half a row.

| | 110-token prompt | 64 generated |
|---|---:|---:|
| a row to an insertion | 1.163 s | 2.195 s |
| four rows to an insertion | **1.092 s** | 2.192 s |

Medians of three alternated rounds. **The instruction count is what settles
it**, because unlike a time it does not vary between runs: 89.9 thousand
million for this prompt against 71.96, a fifth fewer, with the cycle count
following it down by five per cent. Generating does not move and was not
expected to -- a generated token is one vector, and one vector spends its
time fetching weights rather than issuing instructions.

**And then the batch was given the kernel a generated token already had.**
Reading the two paths beside each other is what found it. A generated token
multiplies one vector, so its accumulators are one for every row of the tile;
that let the block loop live *inside* the insertion, with the sum in a
register from a row's first block to its last, the weights read where the
file holds them and biased by a `vpxor` in flight, and the whole bias
correction taken out once at the end. A batch could have none of that while
it kept an accumulator for every row and every vector at once -- a hundred
and twenty-eight vectors against eight rows is a thousand of them, and the
note above that kernel says so and names the way out.

A **strip** is the way out. Two rows against four vectors is eight
accumulators, and this instruction set has thirty-two registers to hold
them, so the batch is swept four vectors at a time and every one of those
things becomes possible again. Per row, vector and block:

```
  four        the two indices, the counter and the branch
  four        the two rows' weights, loaded and biased -- shared by the
              four vectors, which is what a strip is for
  thirty-two  a zeroed accumulator, the byte dot product against the
              activation where the quantizer left it, a convert, and one
              fused multiply-add whose scale the instruction broadcasts
              out of memory itself
  ----
  forty instructions for eight pairs: five each, against twelve and a half
```

No panel is packed and none is needed: two rows of this model are under five
kilobytes, so a panel stays in the nearest cache across every strip of the
batch, and **the order of the loops is the packing**. The vectors a strip of
four does not reach go one at a time through the single-vector kernel, which
computes the same thing by the same instructions and needed only to be told
where its answers belong.

| | 110-token prompt | 64 generated |
|---|---:|---:|
| four rows to an insertion | 1.093 s | 2.190 s |
| a strip of four vectors | **0.847 s** | 2.185 s |

Medians of three alternated rounds, better in every one. Instructions 72.0
thousand million to **64.8**, cycles 25.1 to **16.1** -- a fifth fewer
instructions and a third fewer cycles, because what went was not only work
but the memory traffic of a running sum written and re-read on every block.
Against llama.cpp the processor's prompt goes from 99.0 to **137.5 tokens a
second** and the gap from 3.8 times to **2.8**.

**The strip keeps eight lanes, and that is what moved the digest.** The
kernel it replaces folded the byte instruction's eight integer lanes into
four with a `vextracti128` and a `vpaddd` before scaling them, which is two
instructions on every row, vector and block and is what made the byte path
agree with the sixteen-bit one on the tokens this model emits. A strip keeps
all eight, as the single-vector kernel already did, and the sixty-four
generated tokens hash to `448c2ed68ec342ee` where the fold said
`1cb5fffbb21399ad`.

That agreement was a coincidence rather than a guarantee -- the paragraph
below says the byte path is held to the sweep's bound and not to the bits --
and two things suggest the new arrangement is the more accurate of the two,
neither of them proof. Each float accumulator now receives half the magnitude
it did, so there is half as much to round away. And the digests it lands on
are not new ones: the twelve-token run now says what `--arith f32` says on
the same prompt, and the sixty-four-token run says what the device says.
Three paths that round differently agreeing is weak evidence, and it is
recorded as weak evidence.

**The block's scale is widened by the instruction that widens it.** Ada has
no half-precision type, so `Model_Runner.Numerics.To_Real` reads the two
bytes as bits and computes both the normal and the subnormal answer before
selecting -- about sixteen instructions, and unrecognisable to the compiler
as the conversion it is. Both wider compilations are built for instruction
sets that have F16C, whose `VCVTPH2PS` does the whole of it in one
instruction and exactly, subnormals and not-a-number included, which is what
lets the test comparing the compilations still ask for the same bits. A
two-instruction insertion where the kernel reads a scale took the prompt from
64.8 thousand million instructions to 62.0, and the quantized path from 4.44
times the floating-point one to 4.71 with a vector a pass. The baseline
compilation keeps the portable form, because it is the one that runs where
the host said it had none of this.

An earlier measurement said eight lanes were *worse*, and it was wrong for a
reason worth recording: the lane array carried `Alignment => 32` on sixteen
bytes of data, so GNAT padded every entry out to thirty-two and the
insertion, which walks those entries by hand with a stride of sixteen, read
the wrong halves. It gave wrong answers rather than slow ones, twice, and
what caught it both times was the test that compares the three compilations
-- not the conformance sweep, which the wrong answers passed.

**The instruction is unsigned against signed**, which is the whole difficulty
and where the interesting part is. Biasing the weight byte by 128 makes the
operand it wants and turns the answer into `sum(w*a) + 128*sum(a)`; taking
that back out needs the activation block's own sum, which this kernel is
already handed -- the `Totals` table, put there years-of-commits ago for the
formats that carry a minimum and unread for this one.

Where that correction goes decided whether the change was worth anything. The
first version accumulated it as a scalar read-modify-write in the innermost
loop and measured **fifteen per cent worse** than the path it replaced: the
correction cost more than the instruction saved. Built once a block as a
vector with the whole of it in the first lane, and added inside the insertion
as one integer add, the same arithmetic is the table above. A single reading
taken after that fix still said it had failed; three rounds said otherwise.

**This is the one place where what a model says depends on the machine that
ran it.** The two sixteen-bit compilations agree bit for bit and always will
-- that is what their test asserts. The byte one cannot: it multiplies a
different grouping of each block's products into each lane, so the integer
sums are the same and the rounding falls elsewhere when they are scaled. It
is held to the five per cent the conformance sweep states for the quantized
path, which is the same bound the sweep applies everywhere else, and the test
that used to assert equality now asserts that with the reason written into
it. A caller who needs a run reproducible across hosts of different
instruction sets should use `--arith f32`, which is one arithmetic
everywhere.

### Where a token's time goes

`tests benchmark` multiplies the shapes TinyLlama-1.1B has, at the arithmetic
a run uses, and says what each stage costs a token and what share of it that
is. Generating, one vector a pass, pinned to one processor a core at a load
of 1.10:

| | ms a token | share |
|---|---:|---:|
| feed forward, gate up down | 9.746 | 61.3 % |
| attention projections, q k v o | 3.449 | 21.7 % |
| the vocabulary projection | 1.600 | 10.1 % |
| activation and gate | 0.674 | 4.2 % |
| softmax over the vocabulary | 0.178 | 1.1 % |
| normalization, twice a layer | 0.159 | 1.0 % |
| rotation | 0.102 | 0.6 % |
| normalization, once at the end | 0.004 | 0.0 % |
| **what a token costs of these** | **15.911** | |

The same token at `--arith f32` costs 77.813 ms of these, so the products are
**4.9 times** what they were and everything else is where it was. Reading a
prompt, thirty-two a pass, the whole is 5.453 ms a token in the same shape --
8.391 two kernels ago.

This table is read against the load it was taken at and not otherwise. The
same build, unpinned in a sitting whose load rose through the run, reads 20.6
ms against 17.6 for the quantized token and 89.0 against 74.7 for the
floating-point one -- so the second column moves by a fifth with the
conditions while the ratio between them moves by a twentieth. The ratio is
the finding; the milliseconds are a reading.

Two things to take from it, and the second is the useful one.

**The products are 93.1 per cent of what this table measures**, so nothing
else in it is worth optimizing: the rotation is a tenth of a millisecond
since its angles were tabulated, the normalizations are a sixth, and the two
transcendental kernels together are under three per cent. Replacing the
exponential with arithmetic on a wider instruction set -- which the Kernels
section below describes trying and losing -- would now be worth about two per
cent of a token if it won outright.

**And a generated token really costs about 33 ms, against the 15.2 ms this
table accounts for.** The missing half is attention over the cache, which is not
measured here because the three blend kernels are inside
`Model_Runner.Llama` with no entry point this tool can reach. At the first
reading of this table that gap was about a ninth; the products have got 4.8
times faster since and attention has not, so it is now the largest single
thing left on the processor -- and it is the one part of a forward pass that
still runs entirely on the calling task, with the worker pool idle beside it.

### Where a prompt's time goes

The table above is a model of a token: it multiplies the shapes TinyLlama
has and adds the pieces up, and it says in its own last paragraph that
attention is not among them. A prompt is the other case -- attention is
quadratic in the context and everything else is linear -- so a model of it
would be a guess about the term that matters most.

So a session can be asked to keep account of itself instead, and report the
run rather than a reconstruction of it:

```
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt.txt \
  --max-tokens 0 --budget
```

110 tokens, seven workers, `--arith int8`, at a load of 1.19:

| | seconds | share |
|---|---:|---:|
| feeding | 0.483 | 67.3 % |
| projecting | 0.141 | 19.7 % |
| attending | 0.039 | 5.4 % |
| joining | 0.022 | 3.1 % |
| normalizing | 0.017 | 2.4 % |
| rotating | 0.012 | 1.7 % |
| reading out | 0.003 | 0.4 % |
| **accounted for** | **0.717** | |

**The run this came from accounts for 0.717 s of itself**, which is the
first thing worth saying: there is no missing third here, and the reason is
that these figures are read off the run rather than assembled from parts
measured separately. The clock is read once at each boundary -- about a
hundred and fifty reads for this batch -- and only when a caller asks, which
is what `--budget` is for.

**The products are 87.0 per cent of a prompt, and the feed-forward is 3.4
times the attention projections.** That ratio is not an inefficiency: a
layer's feed-forward holds 34.6 million weights against attention's 9.4
million, which is 3.7 times, so the two are within a tenth of each other per
weight and the split is the shape of the model rather than anything this
program does.

Attention is 5.4 per cent of a prompt where it is about a third of a
generated token. It read 6.2 three kernels ago and 8.9 two ago -- rising
while the products around it fell -- and has now halved, which is the one
change in this file that moved it rather than moved past it, which is the difference the two tables exist to show: a
token attends to the whole context and computes one position, a prompt
attends to a triangle and computes a hundred and ten.

This instrument was built to find something that turned out not to be there.
An ablation -- building the kernel with its multiply-add loop cut down and
differencing the times -- put the multiply-adds at 39 per cent of a prompt
and the weight unpack at 7, and the 54 per cent left over was written up here
as unaccounted for. It is not: the ablation had measured the inner loop of
the product against the whole run, and the rest of the product's own work --
the unpack, the activation copy, the scaling, the loop around them -- is most
of what it left out. A difference between two builds is not a share of a
run, and reading it as one is how a third of a prompt went missing on paper.

### And where a generated token's goes

The same instrument, on the path a token takes rather than a batch. The
phases mean the same thing in both, which is the point: a token and a prompt
divide their time very differently and the only way to see that is to measure
them the same way.

```
tests speed --model MODEL --max-tokens 64 --backend device --budget
```

Sixty-four tokens on the device, at a load of 0.45:

| | seconds | share |
|---|---:|---:|
| feeding | 1.495 | 64.9 % |
| projecting | 0.369 | 16.0 % |
| attending | 0.285 | 12.4 % |
| reading out | 0.110 | 4.8 % |
| normalizing, rotating, joining | 0.047 | 1.9 % |
| **accounted for** | **2.304** | |

**The products are eighty-one per cent and they are not reaching the memory
this part has.** A layer's feed-forward is 1062 microseconds a token for 34.6
million weights and its projections 262 for 5.2 million -- about 33 and 36
gigabytes a second each, against something near ninety that the part can do.
The two are within a tenth of each other per weight, and their four-to-one
ratio is their weight ratio, so neither is inefficient beside the other and
there is no outlier here to attack.

Attending looks disproportionate at 12.4 per cent, where a prompt spends 5.4,
and it is not: `Attend_And_Project` sends attention and the matrix that reads
its blend as one submission, so most of that quarter-second is a four-megabyte
product rather than the attention. What is left over is about a hundred
microseconds a submission, three submissions a layer -- call it a fifth of a
token -- and collapsing those is exactly the change measured under
`### The device backend` as **slower**.

So a generated token on the device is in the same position as a prompt on the
processor: the arithmetic is arranged about as well as this program knows how
to arrange it, and what is left is that the products do not run at the speed
the memory could feed them.

**That last sentence was wrong, and the section below is what replaced it.**
The products were not short of memory. They were spending seven eighths of
their arithmetic and seven eighths of their shared memory on a batch that
was not there.

### The batch that was not there

The item this answers said the device generated 2.0 times behind llama.cpp
and had never been diagnosed. The first measurement was five real models
generating sixty-four tokens each, against their own size:

| model | size | a token | reached |
|---|---:|---:|---:|
| Q2_K | 461 MB | 58.5 ms | 7.9 GB/s |
| Q4_0 | 609 MB | 29.8 ms | 20.4 GB/s |
| Q4_K_M | 638 MB | 68.1 ms | 9.4 GB/s |
| Q5_K_M | 747 MB | 117.7 ms | 6.3 GB/s |
| Q8_0 | 1171 MB | 34.4 ms | 34.0 GB/s |

**Time per token is not a function of size.** The smallest file takes twice
as long per token as the largest, and the rate reached varies five and a half
times between formats. A kernel bound by the bus cannot do that.

`tests device-bench` grew a per-format sweep to say what it is bound by
instead -- a resident 2048 by 4096 matrix, one vector, in absolute seconds
rather than the ratio against the processor `tests benchmark` prints, because
a ratio cannot say which side moved. Multiplying its cost per element by a
model's element count reproduces the token time for every format: `Q8_0` 34.2
ms predicted against 34.4 measured, `Q5_K` 121 against 118, `Q2_K` 55 against
58.5. **A generated token on the device is the row product and nothing else**
-- attention, the blends, the sampling and the submissions are all inside the
error bar.

Half precision and binary32 then named the cause between them. Binary32 reads
four bytes an element and reaches the bus. Half precision reads two, and took
*the same time per element* at half the traffic. Something fixed was being
paid per element by every format alike.

It was the batch group. The shader carries `GROUP` accumulators, reads
`GROUP` vector offsets per weight, and reserves `256 * GROUP` floats of
shared memory for its reduction; `GROUP` is eight because a prompt reads
eight vectors to a pass. A generated token is one vector, so seven eighths of
the arithmetic, seven eighths of the activation reads and seven eighths of
eight kilobytes a workgroup went on padding that the write at the end throws
away -- and on this device the shared memory is the part that decides how
many workgroups a compute unit will hold.

So `row_product.comp` is compiled twice, the second with `SINGLE`, which sets
the group to one, and the engine binds the narrow pipeline when the batch is
one. The same arrangement the matrix product already uses, built the same
morning, and the third time occupancy has decided a question here.

| 64 generated, on the device | before | after | |
|---|---:|---:|---:|
| Q5_K_M | 7.499 s | **2.301 s** | 3.26x |
| Q2_K | 4.211 s | **1.433 s** | 2.94x |
| Q4_K_M | 4.594 s | **3.061 s** | 1.50x |
| Q4_0 | 1.970 s | **1.324 s** | 1.49x |
| Q8_0 | 2.072 s | **1.630 s** | 1.27x |

Medians of three alternated rounds, better in every one. The answers are
bit-identical -- `448c2ed68ec342ee` either way -- because the narrow kernel
accumulates the same products in the same order and drops only arithmetic
whose results were never written. A prompt does not move, 0.336 s against
0.340, because a prompt is never a batch of one. **Binary32 barely moves
either, at 1.05 times, and that is the control**: it was the one format
already at the bus, so the one with nothing to win.

The gap to llama.cpp on a generated token goes from 2.07 times to 1.49.

Two formats gained almost nothing and are named rather than averaged away:
`Q6_K` at 1.07 and `Q5_1` at 1.06. Whatever binds those two is not the group
width, and nothing here has yet asked what it is.

### What the counters say, and what this file got wrong

An earlier version of the paragraph above said the processor's prompt was
losing to stalls, and put this program at 0.7 instructions a cycle against
another runtime's 2.5. Both numbers were arithmetic on a guessed instruction
count. `perf_event_paranoid` was 4 on the machine every figure here comes
from, so nothing in this file had ever seen a cycle counter; with it lowered,
the 110-token prompt reads:

| | |
|---|---:|
| instructions | 54.7 G |
| cycles | 13.8 G |
| **instructions a cycle** | **3.98** |
| cache miss rate | 1.5 % |
| stalled cycles, front end | 2.8 % |

**It is not stalling.** Four instructions a cycle is at what this part can
retire, on a 1.5 per cent miss rate, and far above the figure that was
attributed to the other runtime. What the prompt costs is instructions:
about fifty-five thousand million of them for something near a hundred and
twenty thousand million multiply-accumulates, which is now under one
instruction for every two that multiply and was twenty-odd when this section
was first written.

**Count both, because they do not move together.** The four readings this
file has taken are 93.2 thousand million instructions at 3.40 a cycle, then
72.0 at 2.87, then 64.8 at 4.02, then 54.7 at 3.98. The second issued a fifth
fewer instructions at a *lower* rate and still cost eight per cent fewer
cycles; the third cut a tenth more instructions and a third of the cycles,
because what it removed was a running sum written to memory and read back on
every block. A rising instructions-a-cycle figure is not the goal and can be
bought by doing more work. The goal is cycles, and the counter is the only
thing that tells the difference.

Eleven attempts to cut the instruction count are recorded in
`docs/measured-figures.txt`; five made no difference or were worse, including
one that executed *more* instructions than the loop it replaced while looking
like less code, and three in a row that each moved work out of the inner loop
and each came back slower than the version they tidied. Six worked. Four of
them are the same idea four times -- stop re-reading operands the loop does
not change: the activations read where the quantizer left them took 96.3
thousand million to 93.2, the activation scale held in a register took it to
89.9, four rows in one insertion took it to 72.0, and a strip of four vectors
took it to 64.8.

The other two are a different idea, and it is the one this section is really
about: **stop computing what an instruction already does, and stop checking
what has already been proved.** A profile said the strip kernel spent a
quarter of itself on shifts and masks, and most of that was widening a
half-precision scale in software on a compilation built for an instruction
set that has `VCVTPH2PS`; two instructions instead of sixteen took the count
to 62.0. It said `Blend_Exact` spent fifty-four per cent of itself on 64-bit
moves and twenty on `jo`, the overflow branch after every index -- attention
was the only arithmetic in the engine never given the suppressions the row
kernels carry -- and proving its ranges once instead took the count to 54.7.
Neither of those is a better algorithm. Both are work the source asked for
without saying so.

The lesson this file would keep is narrower than the measurement. Every
statement above about where time goes that was not read off a counter has
turned out wrong -- the missing third of a prompt, the stalls, the
instruction counts of three separate rewrites. A profiler was one sysctl away
for the whole of that.

**And a profile finds things a counter does not.** The strip kernel's first
working version spent **sixteen per cent of the prompt in `memset`**: three
arrays it declares were given `[others => 0.0]`, which is sixty-four
kilobytes zeroed for every strip of four vectors, and every entry of them is
written by the loop that follows. Nothing about the source says so -- an
initializer is one of the shortest things one can write in Ada -- and the
instruction count barely noticed, because a `rep stos` moves sixty-four bytes
per instruction. It cost a fifth of the prompt and `perf report` named it on
the first run.

### Kernels

Row dot product, nanoseconds per element, release build, every format the
engine supports:

| Format | ns/element | Format | ns/element |
|---|---|---|---|
| F32 | 0.26 | Q4_1 | 0.50 |
| Q4_0 | 0.32 | Q3_K | 0.50 |
| BF16 | 0.33 | IQ4_XS | 0.52 |
| Q8_0 | 0.38 | Q5_0 | 0.54 |
| Q4_K | 0.39 | F16 | 0.57 |
| Q6_K | 0.40 | Q5_1 | 0.59 |
| Q5_K | 0.42 | IQ4_NL | 0.65 |
| | | Q2_K | 0.72 |

Taken on a part that has stopped cooling, which this table needs and did not
used to say: every row here is a serial rate, and `## Speed`'s scaling
section measures a serial rate losing a tenth on a part that is merely hot.

The two five-bit legacy formats used to be the outliers of this table, at
1.06 and 1.10, and the reason is where they keep the fifth bit: bit *j* of a
thirty-two bit word rather than a fixed place in a byte already being read.
The shift amount therefore varies with the element, and an instruction set
without a per-lane shift cannot vectorize that loop. Baseline x86-64 has
none. Building the whole program for a host that does measured slower
everywhere else -- that note stood here for months without a number beside
it, and the numbers are now in
[docs/measured-figures.txt](docs/measured-figures.txt): those two formats
gain half again, and eleven others lose between seven and forty-two per
cent.

So the decoders are compiled twice from one source and chosen per format.
`Model_Runner.Quantization.Decoders` is a generic; `.Plain` and `.Wide` are
two instantiations of it, and the project file gives the second
`-march=x86-64-v3 -ffp-contract=off` and gives nothing else in the program
those switches. Four formats are sent to it -- these two and the two
non-linear ones below -- and only where the host says it has the
instructions, which is read from the host rather than assumed from whatever
machine did the building. Contraction is off so a decoded block is the same
bits either way: what is wanted there is the shift and the gather, not a
fused multiply-add.

Only the decode is compiled wide. A row product decodes a span into a buffer
and then multiplies it by each vector, and that second half is shared by
every format and is slower built wide -- it was dragging the four down with
it. Split, they do better than the whole-program build managed: 1.36 ns to
0.61 for IQ4_NL, 1.02 to 0.53 for Q5_0, 1.06 to 0.57 for Q5_1, 0.90 to 0.48
for IQ4_XS. Eleven of the remaining formats sit within three per cent of
where they were and the twelfth, Q4_1, is eleven per cent slower with nothing
here to explain it; the figures file says so at more length, and says which
guess was tried and disproved.

The two non-linear formats are the other outliers, and for a different
reason: a nibble there is an index into a table of sixteen levels rather than
a number, so every element costs a load from that table at an address the
element decides. That is a gather, and it does not vectorize either. IQ4_XS
comes out faster than IQ4_NL despite doing more per element -- a sub-block
scale to form as well as the lookup -- because its block is 256 elements
against 32, so the per-block work is spread eight times thinner. Both are in
the four that take the wider compilation, and both were above 0.9 before it. The table is
what these formats buy their accuracy with, and this is what it costs.

Four rows moved a long way since this table was last published, and they are
the same four that moved a long way the time before, in the other direction.
Q4_0 went 0.33, then 0.59, and reads 0.32 now; IQ4_NL went 1.44, then 0.59,
and reads 1.38; IQ4_XS went 0.95, then 0.48, and reads 0.92; Q2_K went 0.79,
then 1.01, and reads 0.73. Three of the four are back within a hundredth of
where they were two readings ago.

What moved them the first time is written down in
[docs/measured-figures.txt](docs/measured-figures.txt) and applies again: no
decoder changed, `kernels.adb` gained an unrelated procedure, and adding a
subprogram to the unit every decoder lives in moves what the compiler does
with the rest of it. These four rows are the ones sensitive to that -- the
gather-bound and shift-bound loops, where the vectorizer's decisions are
finely balanced -- and they are sensitive to it in both directions. Three
runs here, on two build profiles, at loads from 1.20 to 1.88, agree to a
hundredth of a nanosecond, so the reading is not in question; what the four
rows measure is the code and its layout together, and only one of those is
the decoder. Read them as a band rather than a value, and read a change in
one of them as a question rather than an answer.

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

These agree with the end-to-end measurement, and the agreement is worth
following through because it says which row of which table applies. Evaluating
the 110-token prompt above at a batch of 128 takes 31.79 s of processor time,
and the prompt puts 110 tokens through 1.10e9 parameters, which is 1.21e11
element products, or 0.26 ns each. The row-dot table says 0.39 for the format
that model uses, which the end-to-end figure beats -- and it beats it because
a batch is not a row dot: the same benchmark's matrix product at thirty-two
vectors a pass reads 4.6e3 Me/s in one share, which is 0.22 ns an element, and
0.26 sits just above it with a real model's other work included. Read against
the wrong row the check looks like an impossibility; read against the right
one it is what closing the loop looks like. That is the reason to publish
both.

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
elements a second. Unfused it decodes at 0.32 ns an element, which makes it
the fastest quantized format in the table above rather than the slowest --
and the table above disagreed with this sentence for two sittings, reading
0.59 while this paragraph read 0.31, which is the swing that entry explains
and this retake closed.

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
