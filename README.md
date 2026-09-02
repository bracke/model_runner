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
| Backends | Three, selected with `--backend`. `cpu`: an Ada worker pool with a protected coordinator, reusable worker tasks, deterministic row partitioning, a single-job bounded queue, worker-failure propagation and clean shutdown; `--threads` selects the count and the result is bit-identical whatever it is -- share boundaries fall where the row tile does, for the reason `### The same answer at every worker count, which it was not` gives. `reference`: one row at a time on the calling task, no pool and no batching, the same logits and about twelve times as long -- see below for the measurement -- for asking a suspicious result again by different code. `device`: the products run on a compute device, reached through the host's Vulkan loader opened by name at the moment it is asked for, from a shader compiled into the binary. The shader decodes every one of the fifteen formats this program reads, from the bytes the file holds, and takes a batch of eight vectors per invocation, so no model needs repacking to reach a device and a prompt is one reading of the weights rather than one a token. A second shader computes a batch as a matrix product instead, through `VK_KHR_cooperative_matrix` where the device offers it -- 413.5 tokens a second on a prompt against 207.9, and a `Q5_K_M` file 1.368 s against 0.305 -- and every device without it runs what it ran before. It is compiled twice, once for the six formats a published model is usually made of and once for the eight others, because a pipeline pays for every branch compiled into it whether or not the branch is taken; between the two it decodes every format but binary32, which it refuses on purpose because its operand is half precision. The engine binds whichever of the two decodes the weights it was handed. Each matrix is uploaded once and stays on the device. Measured faster than the pool on this machine, at the same generated text. A machine with no device is told so rather than quietly given another backend |
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
                                           # vulkan1.1 -DSUBGROUPS -DWIDE`
                                           # and with `--target-env
                                           # vulkan1.1 -DSUBGROUPS
                                           # -DQUERY_TILE`.
                                           # `attention_matrix.comp` needs
                                           # `--target-env vulkan1.3` as
                                           # the matrix product does. A
                                           # constant is named for the
                                           # compiled file, so they arrive
                                           # as Matrix_Product and
                                           # Matrix_Extra, Row_Product and
                                           # Row_Single, Attention,
                                           # Attention_Subgroups,
                                           # Attention_Tiled and
                                           # Attention_Matrix.
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
             worst absolute 2.23648335708759E-05,
             worst relative 5.51705186852182E-02,
             rounded logits compared 156888,
             rounded worst absolute 1.34238864580048E-01,
             rounded worst relative 1.99694654308486E+00,
             cached logits compared 66720,
             cached worst absolute 9.22822739555551E-03,
             cached worst relative 1.47282761332370E+00,
             quantized logits compared 1248,
             quantized worst absolute 9.12532826218675E-02,
             quantized worst relative 1.92313144939159E+00,
             byte logits compared 66720,
             byte worst absolute 3.02784067592779E-01,
             byte worst relative 1.99904656218687E+00,
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
take **0.389 s** -- 0.054 s evaluating the prompt and 0.337 s generating --
and **2.05 s** of processor time, the median of three runs. Loading the model
costs a further **0.074 s** of wall that this figure does not include, and it
used to cost 0.6 s: the weights are the file's own pages now rather than a
copy of them, so what loading does is open a mapping and what reading them
costs is paid as they are touched.

The arithmetic is half of that. `--arith int8` is the default and rounds the
vector a product multiplies to a byte an element; the same run at `--arith
f32`, taken back to back in the same sitting, is **1.263 s** for 9.97 s of
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
in the same sitting, the same run at fifteen threads takes **0.491 s** of
wall against **0.389 s** at seven, and 3.09 s of processor time against
2.05 s.

That is twenty-six per cent worse on the wall for fifty-one per cent more
processor time -- and the processor time on both sides is larger than it was,
because a worker now looks for its next job before it blocks for it, which is
what `### The wake, not the work` below is about. The sitting before
read sixteen per cent worse for forty-three per cent more, the one before thirty-three per cent worse for fifty-eight per cent more, the one before thirty-eight per cent worse for sixty-four per cent more, the one before seventeen per cent worse for forty-nine per cent more, the one before level for twenty per cent more, the one before two and a half per cent worse for twenty per cent more, the one before eight per cent worse for thirty-one per cent more, the one before that thirteen per cent worse for eighteen per cent more, the one before that eight per cent for fifteen, the one before twelve per cent worse for sixteen per cent more, the one before fourteen per cent worse for
seventeen per cent more, the one before eight per cent worse for
fifteen per cent more, the one before ten per cent worse for seventeen per
cent more, the one before that two per cent worse for fifteen per cent
more, the one before four per cent *off* the wall for ten per cent more and
the one before that one per cent off for sixteen. All three
are inside what this pair resolves, and the honest summary after thirteen
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
which is not the same thing. Eight shares take 0.389 s for 2.05 s of processor
time and fifteen take 0.427 s for 2.68 s: the second worker on a core shares
the first one's execution units, and what is left over for it to use is
small enough that the pair keeps changing sign. Ten per cent *slower*
for thirty-one per cent more processor time, where the reading before this one
was six per cent for thirty-three, the one before thirteen per cent for thirty-three, the one before nine per cent for thirty-two, the one before seven per cent for twenty-nine, the one before thirteen per cent for eighteen, the one before eight per cent for fifteen, the one before twelve per cent slower for
sixteen, the one before fourteen per cent
slower for seventeen, the one before eight per cent
slower for fifteen, the one before ten per cent slower for
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
eight shares reads 13265 Me/s against seven at 12498 -- so with one vector a
pass eight is above seven by six per cent, where the sitting
before read it ten above, the one before eleven above, the one before thirteen above, the one before ten above, the one before level, the one before nine and a half above, the one before one per cent below, the
one before three and a half below, the
one before that nine above, and it used to fall by a quarter and then by six.
Batched it is level: thirty-two vectors a pass reads 22110 at eight against
22489 at seven, two per cent below. What the change was for was the
quarter, and the quarter is gone: what is left flaps around zero by a few
per cent and changes sign between sittings, which is the honest reading of
five of them. The 9326 is history: it needs the commit before the change, and it is
quoted here as the reason rather than as something a reader can reproduce.

Unpinned, eight is above seven both ways -- 13241 against 12192 with one
vector, nine per cent, and 22269 against 21748 batched, two. The sequence
with one vector: four per cent below, seven above, two below, six above, five
below, three above, eight below, nine above, nine above, twenty-two below,
ten below, four above and nine above. **Thirteen readings and both signs**,
which is what this pair has always done. Unpinned, the spare task can take a processor
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
rate, and reaches it whether one vector is passed or thirty-two -- 2414 to
13265 Me/s in the first case, 5.5x, and 4552 to 22110 in the second, 4.9x,
medians of three runs, pinned. The first peaks at eight shares when
pinned and the second at seven, where which of the two peaked where used to change between
sittings; which of the two peaks where has
changed between sittings, and that is the reading that moves rather than the
shape of the curve.
If memory were the wall those two would part company, because the second reads
each weight byte once for thirty-two multiplies and the first reads it once
for one. At eight shares the product moves about 15 GB/s, which this machine is
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
13349 Me/s against 13265 at eight shares with one vector, 22114 against 22110
with thirty-two, and 2391 against 2414 serially. Which of the two leads
changes with the case and with the run: half a per cent ahead with one
vector, level batched, a per cent behind serially -- where the fifteen sittings
before read it two per cent behind with one vector, a per cent ahead with one vector and seven behind batched, a per cent behind with one vector and seven behind batched, level on all three, ahead on all three, level on all three, level, level, level,
level, ahead by ten with one vector, ahead by two, behind by two, level, and
behind.
Read seventeen times, the pair is level and the sitting is the spread.
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
`cpu` spends 0.059 s evaluating the prompt and
0.113 s generating; `reference` spends 5.946 s and 3.994 s. That is
**fifty-eight times** the work in total, a hundred and one times on the
prompt and thirty-five times on the generation, and the two print the same
digest.

The ratio doubled when the default arithmetic changed, and it is worth being
clear that only one side moved: `reference` computes what it always did.
Comparing the two at `--arith f32` gives thirteen times, and the ratio at
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
serial against serial, no pool on either side -- and reports 2.34x for q8_0,
2.32x for q4_k and 3.00x for f32. The rest of the thirteen is the worker pool
and the batching, which is the honest way to read the figure: `reference` is
between two and three times slower than the same loop written for speed, and
the remaining factor is the parallelism it has none of. The generation ratio
moved most across these readings, from under five to twelve to thirty,
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
| 6-token prompt, 12 generated | 0.399 s | **0.260 s** |
| -- evaluating the prompt | 0.054 s | 0.033 s |
| -- generating | 0.345 s | **0.227 s** |
| -- processor time | 2.09 s | **0.06 s** |
| 110-token prompt, nothing generated | 0.372 s | **0.104 s** |
| -- processor time | 2.87 s | **0.02 s** |

All six cells were taken in one sitting on 2026-09-01, back to back, at the
same load -- so the two columns are comparable, which they were not in the
version of this table before last. The generating row is where the last
change landed: it read 0.378 s until `### The batch that was not there`
below, and 0.242 s until `### A generated token carried too` further down
gave a generated token the carry a batched one already had.

Read the device's generating cell knowing its spread. Over three sittings
in three days it has read 0.217, 0.227, 0.227, 0.227, 0.228, 0.228, 0.231,
0.233, 0.233, 0.234, 0.236, 0.237 and 0.240 s, and at sixty-four tokens rather than twelve 1.266, 1.266,
1.269, 1.283, 1.319, 1.340, 1.363, 1.364 and 1.373 -- a run-to-run range as wide as most of the
changes that have moved it. What settles a change of that size is not
this cell but the alternated pairs under `### A generated token carried
too`, which is why they are there.

**The device wins both runs now, and spends a twentieth of the processor's
time doing it** on the short run and a hundredth on the long one. Its
110-token prompt has gone from 1.951 s to 0.104 s. Six changes took the
first two thirds of that, to 0.280 s -- the default batch, the results a
product reads back, the activation it writes, the kind of memory those
results are read out of, the width of a workgroup, and -- last and largest -- the batch computed as a
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
default. That reading is half again as large now -- the cache is kept
twice, binary32 and half precision, for the reason `### Attention through
the matrix instruction` below gives. With the processor fallback compiled out entirely, so that it could
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
costs 1.263 s that way against 0.389 s, which is the quantized activations
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
processor's short run is 0.428 s now and the device's 0.259, both below the
whole of those ranges, which is the program rather than the machine. The two
columns have swapped which of them the table is about since that paragraph
was written: the device wins both runs and the long one by four times.

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
`--batch-size` at 64, 128, 256, 512 and 1024 reads 1.729, 1.065, 1.047, 1.073
and 1.061 seconds, so the default is within two per cent of the best and half
the batch is much worse. The
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

**Asked again after the device's fusings**, because the processor's
feed-forward is 64.5 per cent of its 1419-token prompt and that is the
largest single number left anywhere in this file. The answer is the same one
and now has a ceiling attached to it.

The block loop still disassembles to what it did: **seventy-seven
instructions, of which fifty want one of the two vector pipes** -- eighteen
`vfmadd231ps`, sixteen `vpdpbusd`, sixteen `vcvtdq2ps` -- so its floor is
twenty-five cycles. What it achieves, taken from `perf stat` over a whole
prompt rather than from a microbenchmark: 132.7 G cycles for the run, about
fifty-eight per cent of them in this symbol, against 3.05 G iterations of
the loop, is **25.2 cycles an iteration**. It is on its floor.

**And sixteen of those fifty pipe slots do the multiplying.** The other
thirty-four are the format: Q8_0 keeps one scale for every thirty-two
elements, and a `vpdpbusd` covers exactly one block, so every block's
integer result must be converted and scaled before it can join the row's
running sum. One convert and one multiply-add for each dot product, forever,
whatever the tile is.

So this kernel runs at about a third of what the part's byte dot product
could do, and the two thirds are not waste that a better loop recovers --
they are what reading a per-thirty-two-element scale costs. Getting past it
means a format with a coarser scale, which is the file's choice and not this
program's. The strip is closed for the same reason the device's matrix
shader is: the thing that is left is not in the loop's shape.

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
six sittings after it read 226.3 and 1.54, then 238.1 and 1.37, then 238.1
and 1.40, then 253.5 and 1.34, then 237.6 and 1.40, then 252.9 and 1.32, on
code that got faster each time while the machine wandered under it --
llama.cpp included, which is what `### A slower day, measured on both sides`
is for.

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

### The narrow context nobody could afford

Three storages for a session's committed keys and values have been here for a
while -- binary32, half precision and one byte with a scale a row -- and
`--kv-cache f16` halves what a long context costs to hold. Nothing wide read
the narrow two. A prompt taking 6.9 seconds at full precision took **26.9 at
half**, and eighty-one per cent of it sat in one scalar loop: a saving in
memory that nobody could afford to take.

Two kernels fix it, both the exact ones with a convert in front.
`Blend_Run_Halved` reads a position's values as eight sixteen-byte loads and
converts each to eight lanes, then the same eight fused multiply-adds; the
instruction count a position goes from twelve to twenty and the bytes go from
two hundred and fifty-six to a hundred and twenty-eight. `Head_Dot_Halved`
does the same for the key side, where the convert is free -- the query load
and the key load were two loads either way.

| `--kv-cache` | prompt | against f32 |
| --- | ---: | ---: |
| f32 | 6.698 s | -- |
| f16, before | 26.9 s | 4.0x |
| f16, after | **7.682 s** | **1.15x** |
| q8, before | 18.263 s | 2.7x |
| q8, after | **7.971 s** | **1.19x** |

**Three and a half times faster, and the mode is usable now.** The byte cache
wanted the same pair and got them the following commit: `Head_Dot_Eighth` and
`Blend_Run_Eighth` widen eight bytes with `vpmovzxbd`, take the hundred and
twenty-eight out, convert and multiply -- four instructions for eight
components where the exact path spends one, and **a quarter of the bytes**.
`q8` went 18.263 s to 7.971, from two and three quarter times f32 to one and
a fifth, at a quarter of the memory a context costs.

What this does *not* do is make the default faster. Halving the bytes did not
halve the time, which is the third piece of evidence -- after the prefetch and
the unroll -- that the value blend is not simply short of bandwidth. Two
thirds of the program's memory traffic is still there and still unexplained by
anything that has been tried against it. `### The blend is not waiting for
its loads` below is the fourth piece, and the one that says what the answer
is not.

### The lanes are the change, the arithmetic is not

`Exponentiate` was the last thing in these kernels never to have been
touched, at three per cent of a prompt and, doubled, five and a half of the
wall. It is `Raised` over a run: a clamp, a multiply, the magic constant added
and taken away for a round to nearest, a degree-five polynomial and a power of
two built in the exponent field. Every step of that is lane arithmetic and
none of it branches -- but this unit is compiled for baseline x86-64, so what
the compiler made of it was four lanes with separate multiplies and adds.

Written out it is eight lanes, and **381.9 G instructions against 390.2**.

**The polynomial is deliberately not fused, and finding out why was the
useful part of this.** Fused it is one instruction a term instead of two, and
rounds once instead of twice -- more accurate, and a different answer. The
conformance sweep passed it at 28344 sequences. The suite passed it at 286
tests. What caught it was a digest in the sitting: **the drafted run stopped
matching the undrafted one.**

That identity is a published claim two sections above -- a proposal either is
the model's own choice or it is not, so a drafted run produces exactly the
text the model produces alone -- and it holds because two evaluations of the
same positions agree to the last bit: one a batch, one a token at a time.
Rounding the exponential differently moved a near-tie across the boundary
between them. Nothing about that is a tolerance question, which is why no
tolerance caught it, and it is a good argument for a sitting printing digests
next to its seconds.

So the polynomial rounds twice, as it did, and every digest in the sitting is
the one that was there before.

### The traffic was never needed, and reordering it made it worse

The counter said the value blend takes two thirds of everything this program
fetches from memory on two and a half per cent of its instructions.
Prefetching it did nothing, unrolling it did nothing, halving its bytes did
nothing. **The reason all three failed is in the loop above the kernel, not
in the kernel.**

Attention in a batch is `for Which in 0 .. Count - 1` -- one query position at
a time, each sweeping the whole committed cache. **A batch of a hundred and
twenty-eight positions therefore reads the entire key and value cache a
hundred and twenty-eight times.** That is what two thirds of the memory
traffic is: not a kernel that reads badly, a loop that reads the same thing
over and over.

So the loops were swapped -- a head at a time down the positions instead --
because one head's slice of the cache is three hundred and forty-seven
kilobytes and the second-level cache holds that.

| | cache misses | prompt |
| --- | ---: | ---: |
| as it is | 7.57 G | **6.403 s** |
| heads outside | 16.18 G | 7.148 s |
| heads outside, sixteen positions a tile | 16.29 G | 6.973 s |

**More than twice the misses**, and tiling the positions did not bring them
back. The reuse it gains is smaller than the locality it loses, and the
layout is why: a position's keys and values are one contiguous kilobyte
across all its heads, so a position at a time reads whole rows and a head at
a time reads a quarter of every row it touches. The redundant reads are
cheap because they are sequential; the reused ones would be expensive because
they are not.

**Which puts the two halves of this together.** The traffic is redundant, and
removing the redundancy needs a head-major order to read it in. That was the
conclusion, and `### The traffic was free` below is what happened when it was
built: the redundancy went, and the time did not.

### The traffic was free

The section above ends by saying the redundant reads need the cache laid out
head-major, and that this is the next thing. It was built, and it is not.

The stored order stays as it is -- the writers want it, the device wants it,
a saved session is it. What was added is a head-major *copy* of one layer,
built once before that layer's attention: a pass over what is committed,
against the hundred and twenty-eight passes the order otherwise costs. Then
attention holds a head still and walks the positions through it, which is the
reorder that made things worse before and is right here, because now a head's
run of positions is contiguous.

| | cache misses | prompt |
| --- | ---: | ---: |
| as it is | 7.57 G | 6.802 s |
| head-major copy | **1.47 G** | 6.788 s |

**Five times fewer misses and the same time.** Better in two rounds of four,
which is nothing.

The arithmetic of it is worth writing down, because it is unusually clean.
The copy adds about 1.4 gigabytes of traffic over the prompt and removes
about 130. **The hundred and thirty were free**, and the reason is what the
loop is: eight fused multiply-adds a position against eight independent
accumulators, which is enough work in flight to cover a second-level miss
that the third level answers -- and the third level does answer them, because
one layer's committed keys and values are under three megabytes against
sixteen of it.

So five things have now been tried against the value blend's seven per cent:
prefetching it one position ahead, prefetching it eight, sixteen and
twenty-four, unrolling it two positions a turn, halving its bytes, and
removing five sixths of its reads outright. **None of them moved it.** The
memory is not what it costs, and the counter that said two thirds of the
program's fetches happen there was answering a question nobody should have
asked: where the fetches are, not what they cost.

That leaves the seven per cent standing on twelve instructions a position.
`### What the two loops are actually waiting for` below asks the processor
what they are waiting for, and gets an answer.

### What the two loops are actually waiting for

Five changes have been made to the strip kernel and five things tried against
the value blend, and not once did anybody ask the processor what either loop
was limited by. It answers in one run. Zen 4 dispatches six slots a cycle, so
a slot is either an operation or a stall, and the stall has a side:

| | instructions | cycles | IPC | front-end stalls | back-end stalls |
| --- | ---: | ---: | ---: | ---: | ---: |
| whole prompt | 382.0 G | 133.5 G | 2.86 | 3.2 % | 43.3 % |
| `rows_by_strips` | 283.3 G | 87.1 G | **3.25** | **0.6 %** | 39.3 % |
| `head_scores` | 25.3 G | 9.6 G | 2.63 | 5.2 % | 40.9 % |
| `blend_run` | 9.8 G | 10.4 G | **0.94** | 1.1 % | **78.6 %** |

**The strip kernel is at its arithmetic floor, and that is the end of it.**
Three and a quarter instructions a cycle, six tenths of one per cent lost to
the front end. Per block it issues **fifty** multiply-add-class operations
-- sixteen byte dot products, sixteen integer-to-float conversions and
eighteen scaled accumulations -- onto the two pipes that can take them, which
is twenty-five cycles of floor against the twenty-four and a fifth it takes.
Every one of the fifty is arithmetic the answer needs.

*(This paragraph said thirty-six and eighteen for four sittings, because it
counted the conversions as free. They are not: see `### The floor was
mis-counted, and the kernel is on it` below, which disassembled the loop
rather than describing it.)*

That also kills the one idea left for it. Sixteen of the seventy-seven
instructions a block are `vpxor` zeroing an accumulator, which looked like
twenty per cent worth removing -- but a zeroing idiom is eliminated at
rename, so it never reaches a pipe, and the front end is not the constraint
by a factor of sixty. **Five changes in, the kernel is done**: nothing but a
different algorithm moves it.

**The value blend is waiting on the first-level cache, which is why nothing
worked.** Nought point nine four instructions a cycle and seventy-nine per
cent of its slots stalled behind the dispatch. It is not bandwidth -- five
experiments say so -- and it is not the front end. It is that a position's
values are two hundred and fifty-six bytes and thirty-two kilobytes does not
hold a prompt's worth of them, so every position is four first-level misses
whatever the order they lie in. The head-major copy did not change that
either: a megabyte and a half is not thirty-two kilobytes.

The only reuse there is to have is **across query positions**, and that is
now a calculation rather than a guess. Two queries against thirty-two
components is eight accumulators and two broadcasts, which fits the register
file with room; it reads each cache line for two queries instead of one and
costs about seventeen per cent more instructions to do it. On a loop running
at nought point nine four, seventeen per cent more instructions is close to
free. That is the next thing to try, and it is the first attempt at this
seven per cent that starts from a measurement of what it is doing rather than
a guess about what it might be.

### The other half of the same argument

The score loop has read eight positions at a time since long before any of
this, and the paragraph above it says why: eight key rows are eight kilobytes
and stay in the nearest cache while all thirty-two heads read them. **The
blend never had that argument made about it**, and it is the same argument.

Eight heads share one key head's values -- that is what a grouped query is --
so the shape this replaces read the same values eight times over, once for
the head that wanted them and again for the seven beside it, over a position
range far larger than the nearest cache. Turned about, with a tile of sixteen
positions outside and the heads inside, a tile is sixteen kilobytes of values
against thirty-two of cache and **every head after the first reads them where
the first left them**.

| | cache misses | prompt |
| --- | ---: | ---: |
| before | 2.56 G | 6.739 s |
| after | **1.48 G** | **6.569 s** |

**Three and seven tenths per cent, better in four of four**, on one and seven
tenths per cent more instructions -- the accumulators live in memory between
tiles now rather than only at the ends. `blend_run` went from seven and eight
tenths of the prompt's cycles to five and six tenths.

**This is what `### The traffic was free` was missing, and the pair is worth
reading together.** That change also cut the misses -- to 1.47 G, within noise
of this one -- and bought nothing, because it moved the values from memory
into a megabyte-and-a-half buffer, and a megabyte and a half is the
second-level cache. This one moves them into sixteen kilobytes. The
measurement that told them apart was `### What the two loops are actually
waiting for`: seventy-nine per cent of the blend's slots stalled behind
dispatch with the front end idle, which is a first-level number, and it was
only after reading it that the right size of tile was obvious.

**Generating pays one per cent for it**, worse in three readings of three, and
that is worth stating rather than burying. A tile costs a load and a store of
every accumulator at each of its ends and buys nothing where the whole range
already sits in cache -- and a sixty-four token run looks back over seventy
positions. The first version lost a fifth of the generating run before a
guard was put on it; what is left is the shape of the loop rather than the
tiles, and the trade is three and seven tenths per cent of a prompt for one
of a token.

### Where a device prompt's time goes

The processor's gap to llama.cpp on a prompt is 1.32 times and the device's
is 2.48. That has been the widest number in this file for a while and nobody
had opened it, because `perf` cannot see inside a device and the reflex is to
reach for `perf`. The engine has kept per-phase times all along, and
`--budget` prints them.

A device run of the 1419-token prompt generates twelve tokens after it, so
the phases are the two together. Subtracting a six-token prompt with the same
twelve generated leaves the prompt:

| | prompt | share |
| --- | ---: | ---: |
| attending | **0.907 s** | **40 %** |
| feeding | 0.520 s | 23 % |
| projecting | 0.375 s | 16 % |
| rotating | 0.206 s | 9 % |
| joining | 0.176 s | 8 % |
| normalizing | 0.084 s | 4 % |

**Attention is the largest phase of a device prompt and it is not close.**
That is not where the reading of the last several sections would have put it:
on the processor the matrix products are two thirds of a prompt and attention
is a seventh. The device turns the products into one matrix multiply per
layer against its matrix instruction and they fall to a third between them,
which leaves attention -- quadratic in the context, and the one part of a
layer that a longer prompt makes worse rather than merely bigger.

**And a device prompt still spends nine per cent of itself on the
processor.** A profile of the run agrees: what the processor does during it
is `rms_norm`, `memmove`, `add` and `apply_rotary` -- normalization, the
residual adds, the cache writes and the rotation. Attention itself does not
appear, so it is on the device where it should be; the rotation and the cache
write are not, and that is nine per cent sitting in the wrong place.

Two things to try, in that order, and neither is small: attention as one
shader over a tile of queries rather than what it is now, and the rotation
moved to where the values it rotates already are.

### The words did not match the source

The section that used to sit here said a shader change was measured, right,
and blocked: recompiling anything regenerated the words committed beside it,
and this machine's glslang gave a set that ran seven per cent slower and
answered differently. The conclusion was that the toolchain was wrong. **The
toolchain was right and the source was wrong**, which took one more
measurement to see and is a better thing to have found.

Recompile all nine and compare them one at a time, rather than diffing the
generated file as a whole: **seven of the nine reproduce byte for byte.**
Only `matrix_product.spv` and `matrix_extra.spv` differ, and only in
thirty-six words. Disassembled, the difference is one constant:

```
<     %uint_64 = OpConstant %uint 64        committed words
>    %uint_128 = OpConstant %uint 128       compiled from the committed source
```

`TILE_V` in `matrix_product.comp` says 128 and the committed words were built
from 64. Somebody changed it and never regenerated. **Every device figure
this file has ever published describes `TILE_V = 64`**, and the edit that
said 128 has never once run -- which is as well, because compiling it makes a
device prompt seven per cent slower.

Setting the source back to 64 makes all nine reproduce exactly, and the
device answers `b3d99fb4151edc6d` at the same speed it always did. The check
beside this could not have caught it: it compares the source against a digest
recorded when the words were made, so a stale `.spv` handed to `tests shader`
updates the digest and leaves the words. **What it proves is that the source
has not changed since somebody ran the tool, not that the words came from the
source.**

### Eight queries a block

With the shaders reproducible the attention change lands. `QUERIES` and
`room` multiply into the per-lane store `held[QUERIES][room / 64]`, so they
trade against each other: eight queries against the existing window of two
hundred and fifty-six is thirty-two floats a lane and measured twenty-six per
cent worse, which is spilling. Eight against a window of a hundred and
twenty-eight is sixteen again -- the same registers, twice the reuse, half
the window.

| | attending | device prompt |
| --- | ---: | ---: |
| four queries, 256 window | 0.931 s | 2.427 s |
| eight queries, 128 window | **0.782 s** | **2.337 s** |

**Sixteen per cent off attention and three and seven tenths off the whole
device prompt, better in three of three, and the digest does not move.**

`Query_Block` beside it in the engine says how many workgroups to ask for and
had to move with it. **A repository check caught that and the conformance
sweep did not**, which is worth recording: the dispatch asked for a block of
four and the shader answered eight, so half the workgroups did work already
done and the answers came out right anyway. Right answers, twice the
workgroups, and only a check that reads both numbers would ever have said so.

**The device's prompt gap is 2.1 times**, from 2.5.

### The nine per cent is arithmetic, not transfer

A device prompt spends nine per cent of itself on the processor, and the
obvious suspect was the transfer: the cache is written a position at a time,
so a batch of a hundred and twenty-eight costs two hundred and fifty-six
calls a layer where the attention dispatch beside it costs one and the file
already says a call is eighty-three microseconds. The rows of a batch lie
next to each other at both ends, so one call each way does it.

**It measured nothing.** The phase went 0.208 s to 0.201 and the prompt did
not move. `Put_Cache` writes into a buffer that stays mapped -- which is why
`memmove` shows in the profile and not a submission -- so a call there is a
copy and not a fence. Reverted.

**So the phase is its own arithmetic**, and it is worth saying what that is.
Replacing the cosine and the sine with the angle itself -- wrong answers,
right timing -- takes the phase from **0.203 s to 0.137**: a third of it is
two transcendentals a pair a position a layer, computed in binary64.

And half of that third is redundant. `Apply_Rotary` is called twice for every
position of a batch, once for the queries and once for the keys, and **each
call computes the same table of angles**: same position, same base, same
scaling, same factors. Sharing it between the two is bit-for-bit the same
answer and about one and a half per cent of a device prompt -- which is what
it costs, measured, rather than what it looked like it might.

That is the next thing here, and it wants care: the rotation is where every
other figure in this file starts, so a refactor of it is a refactor of
everything's first step.

### One table, two rotations

The section above priced the rotation's transcendentals at a third of the
phase and said half of that third was redundant, because a position rotates
its queries and its keys by the same angles and each call computed the table
again. It is one call now.

| | rotating | device prompt |
| --- | ---: | ---: |
| two calls, two tables | 0.201 s | 2.339 s |
| one call, one table | **0.154 s** | **2.188 s** |

**Twenty-three per cent off the phase and six and a half off a device
prompt, better in three of three**, and the processor's prompt takes one and
a half with it. Every digest is unchanged, which is the whole claim: the same
angles by the same expressions, and a pair touches two elements of one head
that no other pair or head touches.

**The way it is written is the measurement, not a preference.** The obvious
shape is a nested procedure the two vectors share, and that shape cost the
processor six per cent of a prompt -- the rotation loop stopped being one the
compiler could see the bounds of, and `pragma Inline_Always` did not give
them back. So the loop is written out twice and the table computed once,
which is duplication put there on purpose and measured against the
alternative. The comment beside it says so, because the next reader's first
instinct will be to factor it.

**And a warning about how nearly this was read backwards.** Measured with
single runs the processor looked six per cent *worse* and stayed that way
through two attempts to fix it; the spread within one variant was ten per
cent. Five alternated rounds of three said one and a half per cent better in
four of five. A change worth one per cent of a prompt cannot be seen at all
by the method that reads five per cent as signal.

### Where a device prompt's time goes now

Two changes have gone into attention since it was last broken down -- eight
queries a workgroup, and one table of angles for a position's two rotations
-- so it is worth asking again. Same method: the long prompt with a
generation-only run subtracted.

| | before | now |
| --- | ---: | ---: |
| attending | 0.907 s, 40 % | **0.690 s, 35 %** |
| feeding | 0.520 s, 23 % | 0.505 s, 26 % |
| projecting | 0.375 s, 16 % | 0.367 s, 19 % |
| rotating | 0.206 s, 9 % | 0.158 s, 8 % |
| joining | 0.176 s, 8 % | 0.165 s, 8 % |
| normalizing | 0.084 s, 4 % | 0.079 s, 4 % |

**Attention is a quarter cheaper in absolute terms and still the largest
phase.** What has changed is that it is no longer the obvious answer: the two
matrix phases together are forty-five per cent now, against attention's
thirty-five.

And the arithmetic of the gap is worth doing. llama.cpp reads this prompt in
0.79 s on the same device and this program in 1.98. **If attention were free
this program would be at 1.29 s and still 1.6 times behind**, so whatever is
next on the device is not only attention.

### The score loop was already right

`head_scores` is six per cent of a processor prompt and reads eight positions
at a time, and the value blend had just been taken from no tiling to sixteen
for three and seven tenths of a prompt. The same argument at eight seemed
worth pushing to sixteen.

| tile | prompt |
| --- | ---: |
| eight positions | **6.423 s** |
| sixteen | 6.461 s |
| thirty-two | 6.510 s |

**Eight is the best of the three and the other two are inside the noise of
it.** The reuse is already complete at eight: eight key rows are eight
kilobytes and every one of thirty-two heads reads them from the nearest cache
before the next eight arrive, so a wider tile has nothing left to gain and a
longer live range to pay for. The paragraph above that loop says it was
chosen by measurement, and this is that measurement taken again with a
different number in mind and landing in the same place.

### A compiled file older than its source

The stale words two sections above were possible because nothing looked. The
check compares a shader's source against a digest recorded when the words
were made, which proves the source has not changed since somebody ran the
tool -- not that the words came from the source. Handing `tests shader` a
`.spv` built before the last edit updates the digest and leaves the words,
and neither the tool nor the check can tell.

Compiling the source at check time would settle it and would put a shader
compiler in the way of running the tests, which is a large thing to require
for a small thing to catch. **A modification time is the weak thing that
knows.** `tests shader` now refuses a compiled file older than the source it
claims to come from, and says which:

```
shader: .../matrix_product.spv is older than ../src/shaders/matrix_product.comp;
        compile it again before naming it here
```

That is exactly the case that happened -- the source edited, the compiler not
run, the tool run -- and it is caught at the only moment anybody could act on
it. It does not catch a `.spv` compiled from a *different* source of the same
age, and nothing short of compiling would.

### Every device prompt over sixty-four tokens was wrong

The tile constants disagreed -- `matrix_product.comp` said a tile of sixty-four
vectors, the engine said a hundred and twenty-eight, and the Ada comment
beside it said the two have to agree. The section that used to sit here said
so and stopped, because the shipped words were the sixty-four and the sweep
passed. **The sweep passing was the thing to disbelieve.**

A workgroup answers `TILE_V` vectors. The dispatch asks for
`Room / Tile_Vectors` workgroups. With sixty-four against a hundred and
twenty-eight, **a workgroup answered the first sixty-four vectors of every
tile and nothing answered the rest**. Ask the two backends the same question
at greedy sampling and watch where they part:

| prompt | device says |
| --- | --- |
| ~18 tokens | what the processor says |
| ~36 tokens | what the processor says |
| ~72 tokens | `usedovoovoovoovoovoovoo` |
| ~180 tokens | `ielélélélélovoélélélél` |

**Every prompt of more than sixty-four tokens came back as noise on the
device**, and the figures published for that backend were timing it.

`TILE_V` is a hundred and twenty-eight now, which is what the shader's own
comment two lines from the constant has said all along -- "all eight vector
matrices". The device answers what the processor answers: the 110-token run
returns `cbf29ce484222325` where it used to return `7614f34a26a84b3c`, and
the 1419-token run returns `1a26d24d33b8957b`, both of them the processor's
own digests to the bit. **It also stops generating when the processor stops**;
the old run read the noise, never found its ending, and ran on to twelve
tokens, which is visible in every sitting recorded in the figures file and
which nobody read as a symptom.

**The figures get worse and they are worth more.** A 110-token device prompt
reads 575.9 tokens a second where the broken path read 709.7, and the gap to
llama.cpp goes 2.3 times to 2.9. What was being measured was a computation
that skipped half of every tile.

### How it survived, which is the part worth keeping

Three things had to line up and all three did.

**The sweep's longest sequence is eight tokens.** Every comparison it makes
is against a batch of eight or of three, so no comparison it has ever made
crosses a tile of anything. Twenty-eight thousand sequences and not one of
them could see this.

**A speed run reports a digest that nothing compares.** The device digest sat
in the figures file, sitting after sitting, differing from the processor's --
which is what a device is expected to do, within tolerance. It was not
within tolerance. It was noise.

**And the check that would have caught it exists, for the other shader.**
`attention.comp`'s `QUERIES` is checked against the engine's `Query_Block`,
and the comment above that check says the pair drifted within an hour of
being written. The same check for the matrix tile was never written, and the
same drift lasted until somebody went looking for a tile to tune. It is
written now, and it fails on the old numbers:

```
fail: src/shaders/matrix_product.comp answers a tile of 32 rows by 64 vectors
      and the engine dispatches for 32 by 128; whatever a workgroup does not
      reach is left uncomputed, which is noise and not an error
```

**The sweep's blind spot is still there** and is worth naming rather than
quietly fixing: its longest sequence is eight tokens against a tile of a
hundred and twenty-eight, so nothing it does exercises a full tile, let alone
a partial one. Lengthening it would catch this class rather than this
instance, and it would cost the gate real time. That is a decision about what
a test suite is for, and it is not one to make quietly at the end of a
commit.

### The device breakdown, taken on a device that was working

`### Where a device prompt's time goes now` two sections above was measured
on the path that skipped half of every matrix tile. Its numbers are not
wrong about what the program was doing; they are wrong about what the
program is for. Taken again, four runs, prompt only:

| | on the broken path | corrected |
| --- | ---: | ---: |
| feeding | 0.505 s, 26 % | **0.650 s, 33 %** |
| attending | 0.690 s, 35 % | 0.590 s, 30 % |
| projecting | 0.367 s, 19 % | 0.370 s, 19 % |
| joining | 0.165 s, 8 % | 0.156 s, 8 % |
| rotating | 0.158 s, 8 % | 0.145 s, 7 % |
| normalizing | 0.079 s, 4 % | 0.082 s, 4 % |

**Feeding is the largest phase and it was never attention.** The feed-forward
grew twenty-nine per cent when it started computing the tiles it had been
skipping, which is the shape of the bug: the products are what the matrix
shader does and the feed-forward is where the biggest of them are.

**Attention fell fifteen per cent, and that is the stranger half.** Attention
does not use the matrix shader, so nothing about the fix should touch it --
except what it was being fed. The old path handed it the output of half a
product and the rest of a buffer, and whatever that arithmetic was, it was
slower than arithmetic on real numbers. A phase timed on noise is not
timing anything.

So the ordering that section drew, and the sentence built on it, are both
withdrawn. What replaces them: **the two matrix phases are fifty-two per cent
of a device prompt against attention's thirty**, and llama.cpp reads the same
prompt in 0.79 s where this program reads it in 1.99. **With attention free
this program would be at 1.40 s and still 1.8 times behind** -- which was
1.6 when the products were doing half their work.

### The tile sweep, and why there was almost nothing to sweep

The matrix phases are half a device prompt, the constants are three numbers
at the top of one file, and the attention sweep next door had just paid
sixteen per cent for changing two. Six shapes, all with the engine's
`Tile_Rows` and `Tile_Vectors` moved to match so the new check is satisfied:

| rows x vectors, chunk | device prompt |
| --- | ---: |
| **32 x 128, 32** | **2.34 s** |
| 32 x 64, 32 | 2.45 s |
| 16 x 128, 32 | 2.56 s |
| 64 x 64, 32 | *does not run* |
| 64 x 128, 32 | *does not run* |
| 32 x 128, 64 | *does not run* |

**Three of the six do not run at all** -- "a run did not complete; nothing
published", before any answer comes back. Every one of those three moves
`TILE_R` or `KCH`; every one that runs leaves both alone. So the shape is not
three free parameters. It is one free parameter, `TILE_V`, and two numbers
that other arithmetic in the shader depends on: the staging loop maps lanes
onto `wt[TILE_R * KCH]` by hand, and moving either end of that leaves a
kernel that compiles and does not work.

**And the one free parameter is already at its best.** A hundred and
twenty-eight beats sixty-four by five per cent, which is what the batch size
predicts: a batch is a hundred and twenty-eight vectors and a tile of a
hundred and twenty-eight is exactly one of them, where sixty-four is two
dispatches for the same work.

So the sweep bought nothing, which is worth as much as if it had. **The
matrix shader is not a kernel with a tunable tile; it is a kernel written for
one tile**, and making it take another means rewriting the staging, not
changing a constant. That is a different piece of work from the one this set
out to be, and knowing which it is was the point of looking. It was done,
in `### The tile made a number, swept, and put back` below, and the answer
was that this tile is the right one.

### Attention through the matrix instruction, built and not kept

The section below priced attention at the weight product's rate as seventeen
per cent of a device prompt, on the ground that both are matrix products and
only one of them uses the instruction. It was built. **It is correct and it is
thirteen per cent slower**, and why is worth more than the number.

`attention_matrix.comp`: a workgroup answers sixteen query positions of one
head and walks the cache in tiles, doing the scores as the queries against
the transpose of the keys and the blend as the weights against the values,
both through `coopMatMulAdd` at sixteen by sixteen by sixteen. The online
softmax is kept -- a running maximum and sum a query, the blend so far
rescaled when a tile raises the maximum -- because storing a context length
of scores is still what a device cannot afford.

**It is correct, and more than correct: the published digests do not move.**
1419 tokens with twelve generated answers `1a26d24d33b8957b`, and the
110-token prompt `cbf29ce484222325`, which is what the lane-at-a-time kernel
answers. Half-precision operands did not move a single token.

The sweep, device long prompt, medians of three, against 1.911 s as it is:

| | |
|---|---:|
| room 128, tile of 16 positions | 2.735 s |
| room 128, tile of 32 | 3.215 s |
| room 128, tile of 64 | 4.718 s |
| room 64, tile of 16 | 2.307 s |
| room 64, tile of 32 | 2.649 s |
| room 64, tile of 64 | 2.917 s |
| room 64, tile of 16, softmax across the workgroup | **2.157 s** |
| room 64, tile of 32, softmax across the workgroup | 2.473 s |
| room 64, tile of 64, softmax across the workgroup | 2.703 s |

**Every shape runs the wrong way**: more for the instruction to chew on is
worse, not better. That is the answer, and it is the opposite of what the
matrix product's own sweep found.

The instruction takes its operands from shared memory, and shared memory is
what bounds how many workgroups a compute unit will hold. `attention.comp`
uses **two kilobytes** a workgroup and reads a key and a value straight from
the cache into the multiply-add; this one must stage them, and at its best
shape uses **nine and a half**. Widening the room from this model's head of
sixty-four to the hundred and twenty-eight the caller allows costs half a
second on its own -- the first three rows against the second three -- which
is occupancy and nothing else.

The arithmetic did exactly what it was meant to. A tile of sixteen positions
is **eight cooperative-matrix multiplies where the old kernel issues five
hundred and twelve multiply-adds a lane** for the same thirty-two thousand
products: sixty-four times fewer instructions. The arithmetic stopped being
the cost, and the staging became it.

What would be needed to win, in the order worth trying: stage the keys and
the values together and lose a barrier a tile; keep the blend in accumulators
rather than in shared memory, which needs a way to rescale an accumulator by
a per-row factor -- a diagonal multiply, or a store and reload on the rare
tile where a maximum moves; and answer thirty-two queries a workgroup rather
than sixteen, to halve the staging a query. **Every one of those trades
against the shared memory that is already what binds it**, which is why none
of them is obviously the answer and why this is written down rather than
tried on.

**It was tried on later, and the answer was none of the three.** Two of them
were built -- the tile of thirty-two queries, and the blend kept in
accumulators by walking the keys twice so that no maximum ever moves -- and
both were slower still. What wins is to stop staging at all, which means
keeping the cache in half precision so that the instruction can read it
where it lies. `### Attention through the matrix instruction` below is that,
and it is thirteen per cent faster where this was thirteen per cent slower.

### Device attention, priced, and the rate it runs at

`--budget` puts attending at **24.6 per cent of a device prompt**, second
only to the two matrix phases, and it had never been taken apart. Three
ablations, each replacing one thing with a constant, the same instrument that
priced the matrix shader above:

| | |
|---|---:|
| as it is | 1.911 s |
| the score half, the query against the keys, removed | 1.689 s (**−11.6 %**) |
| the blend half, the weights against the values, removed | 1.759 s (−7.9 %) |
| the subgroup reductions removed | does not run |

The reductions cannot be ablated at all: without the running maximum a score
of minus infinity reaches the exponential and the run refuses, which is the
guard doing exactly what it is for.

So **the two arithmetic halves are 19.5 per cent of a device prompt** of the
24.6 that attending takes, and the softmax, the barriers and the stores are
the remaining five. Nothing is hidden in attention. It is its two products.

**And the rate they run at is the finding.** Attention is
`pairs × heads × (head_size + value_size) × layers` = 1,007,490 × 32 × 128 ×
22 = 90.8 thousand million multiply-adds, or 181.6 Gflop, done in 19.5 per
cent of 1.911 s: **0.49 Tflops**. The weight product in the same run is 2.94
Tflop in the 59.8 per cent the two matrix phases take: **2.57 Tflops**.
Attention runs at **a fifth of the rate the same part reaches on the same
prompt in the same second**.

The reason is not subtle once it is written down. The weight product goes
through `VK_KHR_cooperative_matrix`; attention does not. Both halves of
attention *are* matrix products -- the query against the transpose of the
keys, then the weights against the values -- and both are computed a lane at
a time in binary32, which is what a fifth of the rate looks like.

Which priced the next thing. **Attention at the matrix product's rate would
be about five per cent of a device prompt rather than twenty-five: seventeen
per cent of the prompt, and the largest single number left anywhere in this
file.** It is also the change the other runtime has already made, which is
part of why its device prompt is two and a half times this one.

So it was built, and `### Attention through the matrix instruction, built and
not kept` below is what happened: it is correct, it does not move a single
token, and it is thirteen per cent slower. The seventeen per cent is not
available this way.

### What a device prompt is not waiting for

The matrix shader unpacks Q8_0 into half precision in shared memory on every
dispatch -- twelve times over for a 1419-token prompt, since a batch is a
hundred and twenty-eight vectors and the tile is a hundred and twenty-eight.
The obvious answer is to upload the model already decoded and let the shader
read half precision, which it already does for `F16` files. It costs two
bytes a weight against 1.06, so it is worth knowing what it would buy before
it is built.

Three ablations say. Each replaces one thing with a constant; the answers are
wrong on purpose and what is measured is the time. Device long prompt,
medians of three:

| | |
|---|---:|
| as it is | 1.939 s |
| the weights never read or unpacked | 1.815 s (**−6.4 %**) |
| the activations never loaded | 1.752 s (−9.6 %) |
| the weights gone from the tile as well | 1.673 s (−13.7 %) |
| all three | 1.720 s (−11.3 %) |

The last two bracket each other, so with every operand removed the prompt
still takes about 1.70 s of 1.94. **The whole handling of both operands is
fourteen per cent of a device prompt and the decode alone is six and a half.**

So the upload is priced out without being written. Deleting the decode cannot
buy more than six and a half per cent, and would buy less -- an f16 copy
still has to be read and is nearly twice the bytes -- in exchange for
doubling what a model costs on the device, which is the resource that decides
whether a model runs there at all.

Where the time is instead, from `--budget` on the same prompt: **feeding 40.2
per cent, attending 24.6, projecting 19.6**, joining 5.7, rotating 5.6,
normalizing 2.6, reading out 1.6. The two matrix phases are sixty per cent
and their operands are fourteen, so **three quarters of the matrix phase is
the instruction itself and the loop around it.**

Which is the third thing this section and the sweep below agree on, and
together they are a shape. The weights are not the wall: reading them half as
often costs sixty per cent, and not reading them at all buys six. Occupancy
is not the wall: more subgroups sharing one tile is worse at every count. The
operands are not the wall: fourteen per cent between them. What is left is
the rate this part retires cooperative-matrix multiplies at, and nothing
tried here has moved it.

### A layer's second half in one submission

The section below names the three submissions a layer makes as structural --
the host normalizes, rotates and joins between the products, so no two of the
device's sequences are adjacent. One of the three was removed.

What that took: `norm.comp`, the root-mean-square normalization, whose three
shapes are most of what this section is about; a third unit on
`combine.comp`, where two is not a unit but an addition -- the residual join,
in three lines rather than a kernel; `Add_Norm` and `Add_Join` on the
sequence, with back-references so a step may read one it names rather than the one before
it, which a fused layer needs because both arms of its feed-forward read the
normalization four steps back and its second join reads the first; and
`Attend_And_Feed`, nine steps in one submission where the engine made two.

**The first shape was right and forty per cent slower.** With the sum walked
in order on one invocation and accumulated in binary64, which is what the
processor does, twelve generated tokens on the device answer
`5abff916f9d83ca6` and sixty-four answer `448c2ed68ec342ee` -- the published
digests, so a normalization computed on the device agreed with the
processor's to the last bit. It cost 0.367 s against 0.256 for sixty-four
generated. Two candidates were measured and neither was it. The binary64 sum
is worth eight per cent of the difference -- the same kernel in binary32
reads 0.365 and answers the same tokens. And the barriers are worth nothing:
fencing every reader serialized the two arms of the feed-forward, which used
to run together, and publishing instead -- one barrier makes every step
before it visible, so a second reader of the same result needs none -- gave
back four thousandths of a second.

So a third of a generated token goes somewhere the submission count does not
explain, and that is written down rather than guessed at.

**It was the normalization, and it was the two hundred and fifty-five lanes
doing nothing.** A bisect settles it: the same sequence with the
normalization replaced by a join of the same shape -- one dispatch, one
barrier, the same nine steps -- reads 1.370 s for sixty-four generated
against 1.820 with it, and against 1.48 unfused. So the fusing is worth what
the submission count says it is worth, and the kernel in the middle of it was
giving all of that back.

The kernel walked a position's sum on one invocation. Its second shape had
the workgroup fetch each block of the row together and one lane add that
block up out of shared memory, which took three hundred and twenty
microseconds a layer down to a hundred -- and the hundred is the adds, with
the other two hundred and fifty-five lanes at a barrier for the whole of
them. Only folding the sum puts them to work: each lane adds a stride of the
row and the workgroup halves eight times.

**That means giving up the bit-exact agreement, and the sweep is what says
whether it may be given up.** A tree associates differently from a walk, so
this is one of the few places on the device where the answer is the
conformance sweep's to judge rather than a digest's. The sweep runs 28344
sequences across thirteen architectures and fifteen formats, and none is
outside tolerance. The published digests did not move either -- twelve
generated tokens still answer 5abff916f9d83ca6 and sixty-four still answer
448c2ed68ec342ee -- which is a fact about this model rather than a
guarantee, and the sweep is the guarantee.

**Kept: sixty-four generated tokens read 1.447 s against 1.476, better in
each of nine alternated rounds, and a token is forty-five submissions where
it was sixty-seven.** Three to four per cent, which is what a fifth of the
submissions is worth once the kernel that replaced them is not the cost.
The prompt is level -- a batch amortizes a submission over its positions
already, and its normalization is real work rather than a fixed cost -- so
the fused path is where it earns and the batched path is where it does not.

**And a bug it uncovered that predates it.** A sequence acquires every matrix
it names before it dispatches any of them, and acquiring one can evict
another to stay inside `--device-memory`. The victim is the matrix wanted
longest ago, which within a sequence is the one acquired first -- a matrix a
later step of that same sequence is about to read. The descriptor then points
at a buffer that no longer exists. Three matrices never reached it; five did,
and the answer came back as a logit that was not finite. So a sequence pins
what it has taken: the eviction skips anything wanted since the sequence
began, and a budget too small to hold all of it takes the memory outside the
budget and gives it back at the end of the call, which is what the loader
already did for a single matrix larger than the whole budget.

**Three bugs on the way, none of which a type could have caught.** A pipeline
created before its request had an entry point and a layout: the driver takes
the module and faults later, with a stack in `libvulkan` and nothing in this
program to look at. A barrier emitted only for a step chained to the one
before it, where a step that names an earlier one needs it just as much --
without it the sequence answers, and answers wrongly. And a normalization
handed to the weight loader as its Rows by its Columns, which for a step
whose Rows and Columns say what it reads and writes is a square: the loader
was asked to upload four million values out of an array of two thousand.

### What a generated token on the processor is waiting for

The processor's generating row is 1.20 times behind llama.cpp and had not
been looked at this year. It is memory, and the shape of that is worth
writing down because it settles three questions at once.

**It saturates at four threads and the engine already knows.** One share
takes 4.558 s for sixty-four tokens, two take 1.943, three take 1.905, and
nothing after that moves: eight threads read 1.963 and twelve 1.970. That is
not the sweep discovering anything -- `Vector_Team` in the pool caps the
single-vector byte path at four shares on purpose, with a comment saying
four saturate the memory -- so the sweep was measuring the cap. Sweeping the
cap itself says the same thing: three 2.025 s, four 1.965, five 1.953, six
1.940, eight 2.013, and four against six alternated four times is 1.955
against 1.949, which is three tenths of a per cent and noise. **The cap is
still right.**

Sixty-four tokens read 69.8 gigabytes of weights in 1.907 s, which is 36.6
gigabytes a second. llama.cpp generates the same model at 39.7 tokens a
second, which is 43. So the gap is neither parallelism nor arithmetic: it is
eighteen per cent of streaming, against a wall both are near.

**And inside the kernel, the half of it nobody looks at costs as much as the
half everybody does.** Annotating the profile splits `Rows_Singly` almost
evenly in two:

| | share of the kernel |
|---|---:|
| the vector loop -- `vpdpbusd`, `vcvtdq2ps`, `vfmadd231ps` | 33.5 % |
| the scalar pass that builds the row's scale table | 31.3 % |

The second is a loop over the row's sixty-four blocks that reads each
block's own scale as a half, multiplies it by the activation's, and
accumulates a correction in binary64 -- one serial dependency chain a row,
sixty-four deep, feeding a vector loop of about the same length. It is not
free and it is not the arithmetic anybody would have named.

Fixing it means breaking that chain into partials, which associates the sum
differently and moves what the model says. That is a decision the
conformance sweep judges rather than a rewrite, and it is where this row's
next per cent is. Not taken here.

**And there may be nothing there either**, which one more measurement
suggests. The scalar pass walks the whole row before the vector loop reads
any of it, so it is the pass that waits for memory and the vector loop is
the one that hits cache -- their near-equal shares are then a wait and an
arithmetic, not two arithmetics. If that is right, making the scalar pass
issue fewer instructions buys nothing, and helping it wait less is the only
thing that would. Prefetching the next row from inside the vector loop --
one `prefetcht0` a block, a row ahead -- is **level**: 1.944 s against 1.948
over three alternated rounds. The hardware prefetcher already has this
stream, which is what a row of two thousand contiguous bytes should look
like to it.

### The output projection is not the thing, and a table that was wrong

The output projection is thirty-two thousand rows against one vector, once a
token, and it looked like the next thing to take: 6.8 per cent of a
generated token, one submission of its own. It is not. It reads sixty-nine
megabytes and takes 1.4 milliseconds, which is fifty gigabytes a second --
exactly the rate the rest of the token runs at. There is nothing special
about it to take, and that is the whole of what this section originally
said that survived.

**The rest of it was wrong, and how it was wrong is the part worth keeping.**
It published a table of four quantizations with a generating rate for each,
concluded that this program reads Q8_0 at half the rate it reads Q4_K, and
called that the largest number left on the device. Every rate in it was
computed by dividing by sixty-four tokens. Three of the four runs did not
generate sixty-four tokens: at these quantizations the model reaches its
end-of-sequence token sooner, and `tests speed` reports how many it actually
produced in the same line as the time. Q4_K generated ten.

Taken again with the counts read rather than assumed:

| | file | generated | a token |
|---|---:|---:|---:|
| Q8_0 | 1116 MB | 64 | **22.3 ms** |
| Q5_K_M | 746 MB | 64 | 32.4 ms |
| Q4_0 | 608 MB | 28 | 16.0 ms |
| Q4_K_M | 637 MB | 10 | 43.5 ms |

The two that ran to sixty-four are the only pair that compares cleanly, and
they say the opposite of what was published: Q8_0 is faster than Q5_K_M per
token while reading half again as many bytes. The two short runs cannot be
turned into a rate at all without knowing what a run costs before it
generates anything, and ten tokens is not enough to divide that out.

**And the comparison cannot be completed with this tool**, which is worth
saying rather than leaving as a gap: a fair cross-format generating figure
needs every run to produce the same number of tokens, and nothing here
ignores an end-of-sequence token. `--stop` and `--stop-token` add reasons to
stop; there is no flag that removes one.

What stands after all that is what the table under `### Against llama.cpp`
already says: Q8_0 generates at 44.8 tokens a second here against llama.cpp's
56.4, which is fifty gigabytes a second against sixty-one. That gap is real
and it is 1.26; there is no factor of four anywhere, and this file said there
was for one commit.

### The angles kept the way the activation is kept

The section below built a layer as one submission and found it four per cent
slower for a generated token, where the submission count said it should be
eight per cent faster. The reason named there was per-call overhead, and one
piece of it is nameable: the rotation's table.

A matrix reaches the device through the loader that keeps it -- it is
uploaded once, kept by its address, and found again on every call after. A
table of angles cannot be kept, because it depends on the position, so it
went through the same loader with no key: an allocation, a mapping, a copy
and a release, twice a layer. A batch of a hundred and twenty-eight
amortizes that over its positions. A generated token pays it whole, and a
token is twenty-two layers.

The activation has exactly this shape -- it changes every call -- and is not
loaded that way at all: the engine holds one buffer, grows it when it has to
and copies into a standing mapping. The angles are held the same way now.

| device | before | after |
| --- | ---: | ---: |
| 64 generated tokens | 1.319 s | **1.277 s** |
| 1419-token prompt | 1.689 s | 1.670 s |

**Three and a half per cent of a generated token, better in each of three
alternated rounds**, and the whole layer is what a token does again: two
submissions became one, and 46.2 tokens a second against 44.4. The prompt is
level, as it should be -- it was the case that amortized the cost.

Still short of the eight per cent the submissions are worth, so there is
per-step overhead left: seventeen descriptor sets written and seventeen
dispatches recorded, where the two halves wrote thirteen between them.

### The key gather, and why staging it costs more than it saves

Attention's dot product has each lane walk its own cached position, so the
sixty-four lanes of one instruction want addresses a whole position apart --
a kilobyte on this model, sixty-four transactions serving one instruction.
An ablation prices it: with the key reads removed attention was 0.626 s
against 0.772, a fifth of it, which is about six per cent of a device
prompt.

The fix a book would give is to stage the tile the other way round: a
position at a time with the lanes over its components, so each read is one
line and the tile crosses the bus once. Sixty-four positions of a
sixty-four-wide head is sixteen kilobytes of shared memory, padded by a word
a row so that a lane reading its own position lands on a bank of its own
rather than on the one every other lane is on.

| 1419-token device prompt | |
|---|---:|
| as it is | 1.692 s |
| the keys staged | **2.499 s** |

**Forty-eight per cent slower**, three rounds of three, and the digest does
not move -- so the staging is right and it is not the arithmetic. It is the
occupancy: shared memory is what bounds how many subgroups a part will run
at once, and seventeen kilobytes of it takes this kernel from fourteen
subgroups a SIMD to four. A kernel that is waiting on memory and has a
quarter of the waves to hide it behind loses far more than coalescing wins.

**And the half measure is worse than nothing.** Staging thirty-two
components instead of sixty-four brings the occupancy back to eight, but a
head of sixty-four then exceeds the room and the staging never runs -- and
the shader is still four per cent slower than the one without the branch in
it. That is the third time this file has measured a pipeline paying for code
it never executes.

What would fix the gather without paying for it is a cache laid out
component-major, so that consecutive lanes read consecutive addresses with
no staging at all. That is the host's cache, its writes, the placing kernel,
attention and the processor's own blend, for a ceiling of six per cent.
Priced and not taken.

### A layer, in one submission

Everything above is the two halves of a layer and the host between them. The
turning became a step; the cache write is the other thing the host did there,
and it is fifteen lines: a workgroup a position, its lanes over the row,
writing where attention will read. With both of them steps there is nothing
in the middle, and `Whole_Layer` names all seventeen -- the normalization,
the queries, the keys and the values, the turning of the first two, the two
cache writes, attention, its projection, the residual join, the second
normalization, both arms of the feed-forward, their combination, the
projection down and the join after it.

| device, 1419-token prompt | before | after |
| --- | ---: | ---: |
| wall | 1.757 s | **1.692 s** |
| processor | 0.60 s | **0.53 s** |

**Three and a half per cent, better in each of three alternated rounds**, at
the same digests. The device's prompt is 1030.5 tokens a second and its gap
to llama.cpp there is 1.70, from 1.81.

**And it does not pay for a generated token, which is what it was built
for.** A token was forty-five submissions and this makes it twenty-three,
which the file prices at fifteen per cent; measured, the whole layer is
**four per cent slower** for a single position, three rounds of three. The
seventeen steps each want a descriptor set written and a dispatch recorded,
and the rotation's table is uploaded fresh every call because it depends on
the position -- a batch of a hundred and twenty-eight amortizes all of that
over a hundred and twenty-eight positions and a token cannot. So the whole
layer is for batches, the two halves stay for a token, and the fifteen per
cent is still there for something that can take it without the overhead that
came with this.

**A bookkeeping failure worth recording, because this file has recorded it
before.** The section under `### Against llama.cpp` describes a commit whose
table was restamped by an edit that failed partway and was never applied. It
happened again in the commit before this one: the script that rewrites the
figures raises on the first anchor it cannot find and writes nothing, so a
sitting's tables were measured, discarded, and the previous sitting's left
in place -- under prose that had been updated by a second, smaller script
that did land. Two sittings of figures in one file. What fixes it is not
care: it is that the script now applies what matches, reports what does not,
and always writes, so a missed anchor is a line of output rather than a
silent revert.

### The rotation, turned on the device without knowing whose it is

The section below said the rotation was the last thing the host did during a
device prompt and that it was left there on purpose: every architecture turns
by a different angle -- the stretch a file states, its ramp across a band of
dimensions, a per-dimension divisor table, an attenuation -- and putting all
of that in a shader is a second implementation of the most variable part of
this program.

**It does not have to go.** What varies is the angle, and an angle is a
cosine and a sine. The host tabulates thirty-two of each for this model and
then does two thousand three hundred multiply-adds with them; the table is a
seventieth of the work and all of the architecture. So the table stays on the
host, `Kernels.Rotary_Table` is what computes it -- the same code the
processor's own rotation now calls, so the two cannot drift -- and the shader
is twenty lines that know nothing about any model:

```glsl
y[even] = float (first * c - second * s);
y[odd]  = float (first * s + second * c);
```

In binary64, because that is what the processor does: it widens each
component, multiplies by a wide cosine and a wide sine, and rounds once. A
part that runs binary64 at a thirty-second of its binary32 rate still
finishes a layer's rotation in microseconds, because there is a thousandth
as much of it as there is of a matrix product. **The digests do not move**,
which is the whole point of passing the table rather than the angle.

| device, 1419-token prompt | before | after |
| --- | ---: | ---: |
| rotating | 0.128 s | **0.040 s** |
| projecting | 0.344 s | 0.422 s |
| the whole prompt | 1.800 s | **1.764 s** |

**Two per cent, better in each of three alternated rounds**, which is less
than the seven the rotation cost because the table is most of what is left
and the turning was cheaper than the transcendentals that feed it. What
remains under `rotating` is the cache write, which is a copy into a standing
mapping.

**What it is really for is the submission after it.** A layer is two of them
-- the normalization with the projections, then attention with the whole
feed-forward -- and it is two because the host has to rotate and write the
cache in between. The rotation is now a step; the cache write is not, and
when it is, the two become one. A generated token is forty-five submissions
at eighty-three microseconds, **fifteen per cent of it**, and halving that is
the largest single thing left on the device. Not built here: it wants the
whole layer as one entry point of seventeen steps, and a step that writes
into a buffer the sequence does not own.

**And the generated shader words crossed the megabyte** this repository
allows a committed file, on the tenth shader. They were written as
hexadecimal literals, five to a line; written plainly they are 455 kilobytes
against 1025, because a compiled shader is not a number anybody recognizes
and the four characters a literal's wrapper costs were a fifth of the file.
The bound that keeps models out of here did not move.

### The other half of a layer, and what is left on the host

`### The same fusing, for a batch` fused a layer's second half for a prompt
and left its first half alone: the host normalized the layer's input, and
the queries, the keys and the values went as three submissions of their own.
Four round trips a layer, for a normalization and three matrices that all
read it.

A normalization first in a sequence reads what the caller handed in, which
is what a product first in a sequence already did, so the three matrices
chain to it and nothing else was needed. One submission where there were
four, and the normalized value never leaves the device.

| device prompt | before | after |
| --- | ---: | ---: |
| 1419 tokens, wall | 1.883 s | **1.787 s** |
| 1419 tokens, processor | 2.27 s | **0.65 s** |
| 110 tokens, wall | 0.459 s | 0.458 s |
| 110 tokens, processor | 0.29 s | **0.14 s** |

**Five per cent of the long prompt, better in each of three alternated
rounds, and seventy per cent of what processor time was left.** Two commits
ago a 1419-token device prompt spent 3.30 s of processor; it spends 0.65,
and a 110-token one spends 0.04 s where the table above published 0.32 in
the morning. What the host does during a device prompt is now the rotation,
the sampler and the reading out.

**The queries, keys and values were the third thing this was going to look
at, and this answers it.** They run at about half the feed-forward's rate on
the device -- 1.27 teraflops against 2.48 -- and `### Three more
rearrangements, and the shader is closed` establishes that the reason is
neither too few workgroups nor the operands. What could be done for them was
to stop paying four round trips for them, and that is what this is; the rate
itself is the matrix instruction's.

**The rotation is what is left, and it is left on purpose.** It is 0.128 s
of a 1.78 s prompt -- seven per cent, the largest single thing still done on
the host -- and it is not the upload it looks like: `Put_Cache` is a copy
into a standing mapping with no call to the driver, and the cache write is
inside that figure. What costs is the arithmetic, and that arithmetic is
where the architectures differ most: Yarn's ramp across a band of
dimensions, a per-dimension divisor table, an attenuation, two pairings, and
a scaling that is read off the file. Restating all of it in a shader is a
second implementation of the part of this program that varies most between
models, for seven per cent, and the conformance sweep is the only thing that
would catch a mistake in it. Priced and not taken.

### The same fusing, for a batch

`### A layer's second half in one submission` fused the nine steps for a
single generated position and said nothing about a prompt, because a prompt
does not go through that path: it has its own loop, and that loop made the
same three submissions a layer with the host joining and normalizing between
them. For a hundred and twenty-eight positions those two are a quarter of a
million elements a layer crossing the bus to be added up and scaled, and the
worker pool did it.

Nothing new was needed. Every kernel in the sequence takes a position count
already -- the normalization dispatches a workgroup a position, the join runs
elementwise over whatever the arms hold -- and `Attend_And_Feed` takes
`Positions`, a window and a causal flag because the batched path is the one
that needs them. The batched loop calls it under the same nine conditions the
single-position path uses, and skips its whole tail when it succeeds.

| device prompt, medians of three | before | after |
| --- | ---: | ---: |
| 110 tokens, wall | 0.164 s | **0.154 s** |
| 110 tokens, processor | 0.30 s | **0.18 s** |
| 1419 tokens, wall | 1.602 s | 1.577 s |
| 1419 tokens, processor | 3.30 s | **2.31 s** |

**Six per cent of the short prompt and one and a half of the long one, and a
third of the processor time either way.** The wall figure is the smaller
half of this. What the host was doing between the submissions was the join
and the normalization, and moving them to the device does not make them free
-- it makes them the device's, and the device was going to be waiting for
them anyway. What it does make free is the two round trips a layer, and what
it takes off the machine is a third of the processor a device prompt was
using while the device did the work.

That distinction is why the table above quotes both. A backend whose point is
that the processor is free to do something else should be measured on
whether the processor is free.

**The published rates moved further than that**, and the note in
`docs/measured-figures.txt` says so: the long prompt reads 891.9 tokens a
second against 827.4, which is eight per cent where the alternated
measurement of the change is one and a half. The rest is the day -- the same
code read 1.715 s in one sitting and 1.602 in the next -- and llama.cpp's own
rows, taken in both sittings, repeat to within their spread and are what says
which is which.

### One load an operation, and the eight that replaced it

Attention is thirty-one per cent of the device's 1419-token prompt and it
was the one phase running at about processor speed: 0.754 s there against
0.894 s on eight cores, where the feed-forward beside it is 4.6 times faster
on the device than on the processor and the projection 2.2. Measured against
what the part is good for it read 236 Gflop/s of a 4.15 Tflop/s ceiling --
five and a half per cent -- while the feed-forward beside it, which goes
through the matrix instruction, reads 2.5 Tflop/s.

**Four things were tried before the one that worked, and each is a fact
about the part rather than about attention.**

The block's queries staged in shared memory, so the dot product reads them
there rather than out of the buffer once per tile per lane: **two per cent
slower**, three rounds of three. The query address is the same for every
lane of the workgroup, so the compiler was already issuing a scalar load
into the constant cache, and shared memory is a vector read -- the staging
took a free operand and made it cost something.

A wider block, sixteen queries where there are eight, so that fewer blocks
re-read the same cache: **level**. A narrower one, four: **ten per cent
worse.** So the reuse the block exists for is saturated at eight and the
cache re-reads are not what this is waiting on.

Both reductions taken for the whole block at once rather than a query at a
time -- one barrier a tile where a device that makes its subgroups narrower
than the workgroup would need sixty-four: **level**, because this device
gives a sixty-four-lane workgroup one subgroup and the barriers were never
there.

**What priced it was reading the wrong operands from the right places.**
Three probes, each removing one thing and keeping the instruction count and
the shapes: without the key reads attention is 0.626 s, without the value
reads 0.581, and without the shared-memory reads of the score tile 0.698 --
against 0.772. So the two global reads are two fifths of it, shared memory
is a tenth, and half of it is neither.

That half is the loop, and the loop is **one memory operation per
multiply-add**. Per component the dot product reads one key, reads eight
query components -- one for each query of the block -- and does eight
multiply-adds. The key is reused eight times and the queries are not reused
at all, and a scalar load whose result feeds one operation is a scalar load
the arithmetic waits for.

**Eight components a turn is the whole change.** A query's components lie
next to each other, so eight consecutive ones are one fetch rather than
eight; the same argument applies to the tile of weights the value phase
reads, where a query's eight weights for eight cached positions also lie
together. Both loops unrolled by eight:

| 1419-token device prompt | before | after |
| --- | ---: | ---: |
| attending | 0.783 s | **0.513 s** |
| the whole prompt | 2.113 s | **1.963 s** |

**Thirty-four per cent of attention and seven of the prompt**, better in
each of three alternated rounds, and the digest does not move: each dot
product still accumulates over the components in increasing order and each
blend over the positions in increasing order, so the unrolling is a
different instruction schedule and the same arithmetic.

Sixteen a turn is no better than eight -- 0.663 s against 0.660 -- and with
the loops unrolled a block of sixteen queries is worse than one of eight,
0.573 s against 0.498, where before the unrolling the two were level. The
balance the block width was chosen at moved when the inner loop did, which
is the sort of thing that has to be re-measured rather than reasoned about.

A generated token does not feel this: it is one query, so the block is one
and attention is a small part of a token anyway. The 110-token prompt does
not feel it either, because attention grows with the square of the context
and a hundred and ten tokens is a hundred and sixty times less of it than
1419. **The long prompt is the figure this moved**, and it took the device's
gap to llama.cpp there from 2.36 to 2.21.

### The engine asks the fence before it waits for one

The section below counts sixty-seven submissions a generated token, three a
layer, each a submit and a wait on a fence -- and prices them at
twenty-three per cent of the token. The three a layer are structural: the
host normalizes, rotates and joins between the products and holds the
activations itself, so no two of the device's sequences are adjacent and
merging them is a redesign rather than a change.

**What is not structural is the waiting.** `vkWaitForFences` blocks in the
driver, and what a short dispatch pays there is not the device's work but the
wake-up at the end of it -- which is the same thing the worker pool's own
wake cost, and answers the same way. The engine now asks
`vkGetFenceStatus` up to a thousand times before it waits, and waits exactly
as it did if the asking finds nothing.

| medians of three, six alternated rounds | before | after | |
|---|---:|---:|---:|
| 64 generated on the device | 1.667 s | **1.583 s** | better in 6 of 6 |
| 1419-token prompt on the device | 1.975 s | **1.886 s** | better in 6 of 6 |

Five per cent generating and four and a half on a prompt, and the digests do
not move: `448c2ed68ec342ee` and `1a26d24d33b8957b` either way. **The device's
gap goes 2.52 times to 2.32 on a prompt and 1.41 to 1.34 generating.**

The budget matters and was swept. Asking is not free -- `vkGetFenceStatus`
goes into the driver, it is not a `pause` -- so a spin long enough to cover a
*prompt's* dispatches costs more than it saves: at forty thousand turns the
long prompt reads 2.39 s against 1.97, twenty per cent worse, while
generating still gains. A thousand turns covers a generated token's
dispatches and gives up long before a prompt's. What it costs is host time
the device was not using: a sixty-four token run goes from 0.22 s of
processor time to 0.48.

**And it changed what one test could see, which is the part worth writing
down.** A standing stop request is noticed between slices of the wait, and a
spin that covers a whole short dispatch is a spin that reaches the wait with
the fence already signalled -- so the request was never seen and the test
said so. The spin now asks the same question every sixty-four turns. Its
companion assertion, that the wait "went round more than once", was written
against slices; the engine now waits in two stages and `Waited` counts both,
because a product the asking answered has waited and saying otherwise would
have been false.

### A generated token on the device is sixty-seven submissions

The device generates at 1.41 times the other runtime and had had no work at
all this sitting. Where its token goes, from `--budget`: **feeding 63.1 per
cent, projecting 16.9, attending 12.6**, reading out 4.8, normalizing 1.2,
rotating 0.9, joining 0.5.

**The products are pure streaming**, which two ablations of
`row_product.comp` settle. Sixty-four generated tokens, medians of three:

| | |
|---|---:|
| as it is | 1.549 s |
| the activation never read | 1.528 s (−1.4 %) |
| the weights never read | 0.011 s |

So the weights are ninety-nine per cent of the row product and the activation
is nothing. A token reads 1.09 GiB and the products take about eighty-five
per cent of 24.4 ms, which is **55.5 GB/s** -- against the other runtime's
whole token of 17.7 ms, which cannot be under 61.6 GB/s even with no overhead
at all. Eleven per cent apart on the stream itself, and that is the half of
the gap nothing here can reach.

**The other half is attending, and it is not arithmetic.** Its cost against
context:

| context | a token |
|---|---:|
| about 40 | 3.6 ms |
| about 1450 | 13.9 ms |

Thirty-six times the work for three and nine tenths times the time. Fitting a
line gives 0.0073 ms a position and **3.3 ms a token that does not depend on
the context at all** -- thirteen and a half per cent of a generated token
spent before a single position is read.

What that fixed cost is: a counter on `vkQueueSubmit` says a run of six
prompt tokens and sixty-four generated makes **4421 submissions**, and eight
generated makes 669 -- so a generated token is **sixty-seven submissions,
three a layer**. Every one is a submit and a wait on a fence, which this file
measured at eighty-three microseconds before it computes anything. Sixty-seven
of those is 5.6 ms of a 24.6 ms token: **twenty-three per cent**.

Which is the largest single cost identified anywhere on the device, and no
shader touches it. Everything a token does between the sampler at one end and
the sampler at the other is device work -- the norms, the rotation, the
attention, the blends and the joins are all dispatches -- so **a layer needs
no round trip in principle and a token needs one**. Three a layer is what
this engine does, not what the device asks for.

Not built, and priced: one a layer would be about fifteen per cent of a
generated token, one a token about twenty-two.

### Three more rearrangements, and the shader is closed

After the tile sweep, the operand ablations and the attention kernel, three
things were left that could be rearranged without changing what the matrix
shader computes. None of them moves it.

**The subgroup width.** This part's matrix instruction is documented at
wave32 and the shader asks for a workgroup of sixty-four, so it was compiled
with a workgroup of thirty-two as well, the staging dealt round however many
lanes there are: **1.926 s against 1.917**. Level.

**The barriers.** A workgroup of one subgroup executes in lockstep, so the
two barriers a step were replaced with `memoryBarrierShared` alone: 1.907 s
against 1.936, one and a half per cent and inside the noise -- and not
correct in general, because a device whose subgroups are thirty-two wide
makes that workgroup two of them and this shader is compiled once for every
device. Not pursued for a per cent of noise.

**Software pipelining**, which is the one with a real argument behind it. The
loop decodes a step, waits, multiplies it and waits again, so the unpack and
the instruction are end to end and neither can start until the other has
finished. Two buffers instead of one, a turn multiplying the step already
decoded while it decodes the next, one barrier a turn rather than two:

| | |
|---|---:|
| as it is | 1.971 s |
| pipelined | 1.960 s |

Six alternated rounds of three, three each way, better in four of six. **Six
tenths of a per cent**, which is nothing; the digest does not move either
way, so the restructure is right and simply does not buy anything. Two
kilobytes more of shared memory for six tenths of a per cent is not a trade
worth making.

**Two more, after the layer was fused.** The accumulator in half precision
rather than binary32, on the chance that the instruction retires faster when
it writes less: **level**, 1.672 s against 1.668, and the tokens change, so
the trade would have had to be worth something and is not. And the
arrangement the sweep above did not cover -- not one tile split across more
subgroups but two subgroups each keeping a whole tile, sharing the batch
through shared memory instead of reading it twice: **2.5 times slower**,
3.349 s against 1.339. Staging a hundred and twenty-eight vectors by hand,
one half-precision element an invocation at a time, costs far more than the
`coopMatLoad` it was meant to halve. The operands are twelve per cent of
this kernel and no mechanism for sharing them is cheaper than that.

**And the instruction itself, priced before anything was built for it.**
This device offers ten cooperative-matrix shapes, not one: sixteen cubed in
half precision to half or to binary32, and six integer forms including
signed eight-bit in to thirty-two-bit out. Q8_0 weights are already signed
bytes, so an integer kernel would skip the decode entirely, and RDNA3's
integer matrix instruction is documented at twice the half-precision rate.
That is the largest thing this file has had reason to hope for.

It is worth eleven per cent. Timed with the staging equalized -- both arms
copying their operands into shared memory, so the only difference is which
instruction retires -- eight-bit integer reads 3.733 s against half
precision's 4.199. Not two times; eleven per cent.

Which decides it, because eleven per cent is less than what using it would
cost. Q8_0 keeps a scale for every thirty-two elements, so an integer
accumulator has to be converted and scaled once a block against a rank-one
tile of weight and activation scales, and the activations have to be
quantized to bytes and carried over as well. The ablations above put every
operand this kernel touches at twelve per cent of it. A mechanism that costs
some of twelve to win eleven of eighty-eight is not obviously worth
building, and it is certainly not the 1.7 times.

**And where the 1.7 times is not.** llama.cpp reports what it uses on this
part -- `matrix cores: KHR_coopmat` -- so it is the same extension, the same
shapes and the same device. It can also be told not to use it, which prices
the instruction from the other side: `GGML_VK_DISABLE_COOPMAT=1` reads 1353.7
tokens a second against 1949.3 with it. So the matrix instruction is worth
1.44 times to them.

**Their kernel without the matrix instruction is twenty-eight per cent faster
than this one with it** -- 1353.7 against 1059. That is the finding, and it
moves the question off the instruction entirely: this program's coopmat
kernel does 2.33 teraflops where their scalar one does 2.98 and their coopmat
one 3.98.

Three attempts at closing it, all worse, all bit-exact so it is the shape and
not the arithmetic:

| 1419-token device prompt | |
|---|---:|
| as it is, one subgroup, the batch read by `coopMatLoad` | **1.66 s** |
| two subgroups sharing a staged batch, staged an element at a time | 3.35 s |
| the same, staged sixteen bytes at a time | 2.62 s |
| four subgroups sharing it | 3.15 s |

Vectorizing the staging recovers most of what staging costs and still loses,
and sharing it across more subgroups loses further. The reading being staged
away is not a cost: `coopMatLoad` from the buffer issues wide loads straight
into the matrix registers, and any trip through shared memory is a trip it
did not need. So the operands are not it, the instruction is not it, the tile
is not it, and the batch is not it -- and their scalar kernel still beats this
one. What is left is unnamed, and this file would rather say that than name
something it has not measured.

**So the kernel that number belongs to was built.** A register-tiled product
with no matrix instruction in it: a hundred and twenty-eight rows by a
hundred and twenty-eight vectors to a workgroup, two hundred and fifty-six
invocations dividing that sixteen ways by sixteen, each holding an eight by
eight square of the answer in sixty-four registers and reading eight weights
and eight activations a column to do sixty-four multiply-adds with -- four
multiplies for every read, where the kernel it would replace does one. Both
tiles staged column-major so that a column's sixteen readers are neighbours,
the stride padded by one so they land on banks of their own, Q8_0 decoded
into the staging, everything else left to the kernels that read everything
else.

It is right and it is slower. **2.98 s against 1.66** for the long prompt, at
the same digest, and the second arrangement of the lane ownership -- every
sixteenth row rather than eight in a row, so that a step's readers are
neighbours -- moved it from 3.04 to 2.98.

It is not registers and it is not occupancy, which is what makes it worth
recording: a hundred and four registers against the matrix kernel's hundred
and sixty-eight, nothing spilled, and **eight subgroups a SIMD against six**.
The inner loop is sixteen shared-memory reads, sixteen conversions out of
half precision and sixty-four multiply-adds, which is two thirds efficiency
at best and measures a quarter.

**Then the source was read instead of guessed at**, which should have come
first and is the only reason the number moved. The other runtime is on this
machine; its kernel is a file. What it does that this did not is one
instruction:

```glsl
spirv_instruction(extensions = ["SPV_VALVE_mixed_float_dot_product"],
                  capabilities = [6912], id = 6916)
float v_dot2_f32_f16 (f16vec2 a, f16vec2 b, float acc);
```

Two half-precision multiplies and an addition into a binary32 running sum, in
one instruction, where a scalar loop spends two. The part reports it as a
capability of its own -- `fp16: dot2` in the line that runtime prints at
startup, which had been read past several times. Their kernel's fallback for
a part without it is four `fma` calls in a row, which is exactly what had
been written here.

With the tiles staged as pairs and the inner loop calling it, **2.98 s becomes
2.02**. That is the 1.47 times the instruction is worth, arriving where the
arithmetic said it would. Four halves to a read rather than two is slightly
worse, 2.12, so the pair is the width.

**And 2.02 is still behind the matrix kernel's 1.66**, which is the answer to
the question this started from. The instruction was the largest single thing
in their kernel and it is not the whole of the difference: the rest is the
warp-level tile between the workgroup and the thread, a per-thread square of
four by two rather than eight by eight, and a tile of sixty-four by sixty-four
rather than a hundred and twenty-eight -- a shape chosen against the part.
This is two iterations of that; the campaign is what the remaining twenty-two
per cent is.

**And their shape too, read off the same source.** A sixty-four by sixty-four
tile rather than a hundred and twenty-eight, two hundred and fifty-six
invocations holding four by four of the answer rather than eight by eight,
which is sixteen accumulators a thread rather than sixty-four. It is the
worse ratio -- sixteen multiply-adds for eight reads against sixty-four for
sixteen -- and the better occupancy, and on this part the occupancy wins:
**1.95 s against 2.02**.

| 1419-token device prompt | |
|---|---:|
| the matrix kernel this program uses | **1.64 s** |
| scalar multiply-adds, 128 tile, eight by eight | 2.98 s |
| the packed dot product | 2.02 s |
| their tile and their thread shape as well | 1.95 s |

**Forty-eight registers and twenty subgroups a SIMD**, against the matrix
kernel's hundred and sixty-eight and six. So the kernel is not short of waves
and not short of registers and is still eighteen per cent behind, which is
the arithmetic nobody had written down: a cooperative-matrix multiply-add is
four thousand and ninety-six multiply-adds in one instruction where a packed
dot is two a lane, and even at sixteen cycles against one the instruction is
twice the rate. **A dot-product kernel cannot beat a matrix kernel that is
fed at all**, and this file's is.

**So the two kernels were disassembled and compared.** The other runtime
runs on the same driver, and that driver will print the machine code it
generates: `RADV_DEBUG=asm` on both, and `RADV_DEBUG=shaderstats` for what
each one costs to run. That is a thing that could have been done at any point
in the last several sections and was not.

Their hot loop is five hundred and twelve `v_dot2acc_f32_f16` against ninety
`ds_load_b64` -- sixty-four-bit shared reads, four halves apiece, eleven and
a half multiply-adds for every read where the kernel above managed eight. And
their occupancy line says seventy-two registers and fourteen subgroups a
SIMD, where the kernel above had forty-eight and twenty: **fewer waves and
more registers, and faster.** So the arrangement to copy was a hundred and
twenty-eight invocations holding thirty-two accumulators each, not two
hundred and fifty-six holding sixteen.

Copied, it reads 1.89 s, and the disassembly says why the copying is finished:

| | this program | the other runtime |
|---|---:|---:|
| `v_dot2acc_f32_f16` | 508 | 512 |
| `ds_load_b64` | 96 | 90 |
| `s_waitcnt` | 42 | 111 |
| instructions | 921 | 1718 |
| registers | 72 | 72 |
| shared memory | 9216 | 9216 |
| subgroups a SIMD | 14 | 14 |

**Same registers, same shared memory, same occupancy, the same arithmetic in
the same instruction, fewer instructions around it and fewer waits -- and one
and eight tenths times slower.** There is nothing left in the kernel to
copy.

**So the device was asked what it had been doing.** A query pool of
timestamps, one written before the first dispatch of every sequence and one
after each of them, read back after the fence; `timestampPeriod` on this part
is 10.019 nanoseconds, which `vulkaninfo` reports and the arithmetic below
needs.

The stamps between the dispatches turned out to say nothing -- a timestamp
waits for what came before it to reach the stage, so consecutive ones tile
the span rather than dividing it, and the sum of the intervals is the span by
construction. What the first and last say together is the whole point:

| device, 1419-token prompt | |
|---|---:|
| the device running command buffers | **1.05 s** |
| the phase | 1.65 s |
| the device's share of it | **64 per cent** |

**A third of a device prompt is not the device.** The processor time for that
run is half a second, which is the other side of the same number: a sequence
is recorded on the host, submitted, waited for, and read back, and the
recording and the reading do not overlap the running because each sequence
waits for its own fence before the next is built. Seventeen descriptor writes
and seventeen dispatches a layer are host work, and they are host work that
the device sits idle through.

Which is what a difference that survives replacing the kernel looks like from
the other side. Both of this program's kernels run inside a sixty-four per
cent duty cycle; the other runtime records a whole graph and submits it, so
its recording overlaps its running. **That is where the 1.7 times is**, or
enough of it to explain why nothing inside the kernel ever moved it.

**And then the third was measured rather than assumed, which changed what to
build.** A clock around each of a sequence's three parts, summed over the two
hundred and forty sequences of a prompt:

| a prompt sequence | |
|---|---:|
| recording -- descriptors, commands, and the activation going over | 0.276 s |
| submitting and waiting -- the device running | 1.119 s |
| reading the answers back | 0.023 s |

The reading back is nothing, which kills the theory that the host was copying
its time away. The waiting is 1.119 s against the device's own 1.05 s, so a
submission and a fence cost about seventy milliseconds over two hundred and
forty of them -- a fifth of a millisecond each, and not the thing either.

**The recording is 0.276 s, and it is sixteen per cent of the prompt.** What
it is not is descriptors and commands: the two hundred and forty *generated*
sequences after it add two thousandths of a second between them, ten
microseconds each against the prompt's eleven hundred. A cost that appears
only when the batch is deep is the activation going over -- a hundred and
twenty-eight positions of two thousand and forty-eight components, a megabyte
a layer, written into the mapping before every sequence.

Which is not what two command buffers would fix. Recording a generated
token's layer costs ten microseconds; there is nothing there to hide. What
the megabyte a layer says is that **the activation should not be going over
at all**: it is the previous layer's output, which the previous sequence left
in the device's own result buffer and then copied to the host so that the
host could copy it back. A sequence that read its input where the last one
wrote it would delete the upload, the copy out, and sixteen per cent of the
prompt with them.

**It was built, it is right, and it changes nothing.** A slot reserved at the
head of the answer buffer, the last step's result copied into it inside the
device's own memory, and the next sequence reading its input from there
instead of being handed a megabyte: 1.665 s against 1.660, three rounds each
way, at the same digest. The upload was not the cost.

Which the clock then said outright, once it was asked in four parts rather
than three:

| a prompt sequence, 240 of them | |
|---|---:|
| sizing the steps and finding their weights | **0.255 s** |
| growing the buffers, and the activation where it still goes over | 0.003 s |
| writing descriptors and recording commands | 0.012 s |
| submitting and waiting | 1.110 s |
| reading the answers back | 0.022 s |

**Fifteen per cent of a device prompt is spent working out where things go.**
Not sending them, not recording them, not waiting for them: the loop that
walks a sequence's seventeen steps, checks their shapes, and asks the loader
for each one's matrix. Over two hundred and forty sequences that loop asks
two thousand one hundred and seventy times and is answered from the resident
list one thousand nine hundred and seventy-one times -- the other hundred and
ninety-nine are the first sight of each matrix, so nothing is being uploaded
twice. A hit is a walk of a list of a hundred and ninety-nine entries
comparing five fields, and it is costing a hundred and seventeen microseconds.

That is the next thing to look at and this file does not yet know why it is
slow. What it does know is that it is not the kernel, not the instruction,
not the tile, not the operands, not the batch, not the submissions, not the
upload and not the readback -- every one of those measured, most of them
twice.

Which is the useful end of a long thread, because it says where to look next
and it is not here. This program's matrix kernel is 1.7 times off their
matrix kernel, and this program's dot kernel is 1.8 times off their dot
kernel: **two unrelated kernels of ours, each about the same distance from
its counterpart.** A difference that survives replacing the kernel is not in
the kernel. What both of ours share is everything around them -- seventeen
steps to a layer, a barrier between most of them, and dispatches as narrow as
eight workgroups where a key projection is two hundred and fifty-six rows
wide. The next measurement is timestamps around the dispatches rather than
around the phase, and that is the one this file does not have.

Not kept: a kernel that is right and slower costs a measurement every time
somebody reads the file. What is kept is the instruction, which is written
down here because nothing else in this program has used it and the next
kernel that wants a multiply-add loop should.

Which closes this shader. **Every rearrangement of it has now been
measured** -- nine tile shapes, three subgroup counts, the batch against the
vector tile, the decode ablated, both operands ablated, the wave width, the
barriers and the pipelining -- and the only one that ever mattered was the
tile it already had. The two and a half times is not in the shader's
structure.

**Asked again after attention was unrolled, and it closes the same way** --
with one figure above corrected. The mix had moved: the matrix phases are
sixty-two per cent of the device's long prompt where they were sixty, so
the question was worth putting again with three ablations and a sweep.

| 1419-token device prompt | feeding | projecting | whole prompt |
| --- | ---: | ---: | ---: |
| as it is | 0.900 s | 0.497 s | 1.953 s |
| the weights neither read nor unpacked | **0.763 s** | 0.456 s | **1.752 s** |
| the activation operand always from the first step | 0.807 s | 0.467 s | 1.807 s |
| the row tile halved, sixteen rows | 1.116 s | 0.550 s | 2.246 s |

**The decode is ten per cent of the prompt and not six and a half.** The
earlier reading was taken with a probe that filled a hundred and twenty-eight
of the tile's thousand and twenty-four entries and left the decode running
underneath, which is a probe measuring nothing; this one guards the decode
with a test on a push constant that is false at run time and not at compile
time, so the code and its registers stay and only the work goes, and fills
the tile with a constant so the answers are finite enough for the run to
finish. That the correction is upward does not change what it decides:
half precision is 1.9 times the bytes of Q8_0 and the read is part of what
was ablated, so uploading the model decoded still buys less than it costs and
still doubles what a model needs on the device.

**The row tile is not starving the narrow matrices.** A layer's key and value
projections are 256 rows against 2048 for the query -- eight workgroups of
the tile it has -- and the projection phase runs at half the feed-forward's
rate, so too few workgroups is the obvious explanation and it is wrong.
Halving the tile doubles the workgroups and costs sixteen per cent of the
prompt: what a workgroup loses in weight reuse is worth more than what the
part gains in occupancy, on a phase that already reaches six subgroups a
SIMD. And a deeper batch, which multiplies the workgroups the other way, is
level at 256 and 384 against 128.

So the wall is where it was, and it is the rate this part retires
cooperative-matrix multiplies at.

### The tile made a number, swept, and put back

`### The tile sweep, and why there was almost nothing to sweep` ended by
saying the matrix shader is not a kernel with a tunable tile but a kernel
written for one tile, and that changing it means rewriting the staging. So
the staging was rewritten, the shapes it could not reach were swept, and the
rewrite was taken out again.

The staging was sixty-four invocations decoding thirty-two rows of a
thirty-two column step, half a row each, with the invocation number cut in
two to say which row and which half. The rewrite deals **sixteen-value units**
round the workgroup instead -- a unit is half a thirty-two element block,
which is the largest piece all fourteen formats decode the same way -- so
the tile stops being an assumption. A workgroup of more than one subgroup
became possible at the same time, each subgroup carrying its own slice of the
vectors and all of them sharing one decode.

Every shape then ran, where three of six used to produce a kernel that
compiled and answered nothing. The long device prompt, medians of three:

| | |
|---|---:|
| 32 x 128, step 32, one subgroup | **1.935 s** |
| 64 x 128, step 32 | 2.058 s |
| 32 x 128, step 64 | 2.062 s |
| 32 x 128, step 128 | 2.122 s |
| 32 x 128, step 32, two subgroups | 2.130 s |
| 64 x 64, step 32 | 2.148 s |
| 16 x 128, step 32 | 2.198 s |
| 64 x 128, step 64 | 2.213 s |
| 32 x 128, step 32, four subgroups | 2.461 s |
| 32 x 256, step 32, two subgroups, batch 256 | 2.803 s |
| 32 x 256, step 32, batch 256 | 3.207 s |

All eleven answered `1a26d24d33b8957b`. **The shape that was already there is
the best of them and it is not close** -- the nearest alternative is six per
cent behind.

Two of those rows say what this shader is *not* waiting for, which is worth
more than the ranking. Raising the vector tile to 256 with the batch raised
to match halves how often the weights are read, and costs sixty per cent:
**the weights are not the wall.** More subgroups sharing one tile's decode is
worse at two and worse again at four: **occupancy is not the wall either.**
What is left is the register pressure of the accumulators against the cost of
the decode, and thirty-two by a hundred and twenty-eight is where those two
cross.

**The rewrite itself costs one and a half per cent** -- 1.99 s against 1.965,
better in three of eleven alternated rounds -- and it was written three ways
to try to give that back: a strided loop, a counted loop, and a counted loop
whose step arithmetic is guarded by constants so the kept shape folds back to
a straight line. All three cost the same, so it is the loop and not the
arithmetic in it.

Generality that costs one and a half per cent and unlocks nothing is not
kept. What is kept is **a repository check that `TILE_R` and `KCH` are
thirty-two**, which is what the staging is written for, so that the next
person to turn one of them gets a failure rather than a kernel that runs and
answers nothing. The trap is what was worth removing; the tile was already
right.

### What lengthening the sweep costs

The blind spot has been named twice without a number on it: the sweep's
longest sequence is eight tokens, the matrix kernel is not entered below
thirty-two, and its tile is a hundred and twenty-eight. Here is the number.

A fifth sequence of seventy-two tokens was added, used by one comparison --
the batched device one, which is the only place it could have mattered --
and the sweep was timed. **It went from about five minutes to over forty**,
and was stopped rather than finished.

The cost is not the comparison. It is that the sweep's expectations come from
an independent implementation written for clarity, in binary64 and without a
pool, and it computes every sequence for every fixture whether a comparison
asks for it or not. Seventy-two positions of that, thirteen architectures and
fifteen formats over, is the forty minutes.

**So the sweep is the wrong instrument for this**, and knowing why is worth
the hour. What the missing test wants to ask is whether two backends agree,
not whether one of them agrees with an independent implementation -- and two
backends can be asked that for the price of running them. A test doing
exactly that was written and does not yet run: the processor side comes back
`BACKEND_CLOSED` where the same calls in the harness beside it do not, which
is a fixture question and not an engine one. It is not committed, because a
test that does not run is worse than a gap that is written down.

**What is committed is the check that catches the case that happened** --
the shader's tile against the engine's dispatch, which fails on the old
numbers -- and this paragraph, which says what the remaining hole is and what
it would cost to close it the obvious way.

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

**And it kept going, and then it came partway back.** Over seven sittings
llama.cpp read 385.0, 347.8, 326.0, 334.4, 338.5, 333.7 and 335.0 tokens a
second on a prompt, on a binary that has not been rebuilt -- a thirteen per
cent spread with nothing in it but the machine, and the last four of them
within two per cent of each other. This program's own figure went 254.6,
226.3, 238.1, 238.1, 253.5, 237.6, 252.9 over the same seven, with the code
moving one way the whole time. **The gap is the only thing in this table that
means anything across sittings**: 1.51, 1.54, 1.37, 1.40, 1.34, 1.40, 1.32. **An absolute published without the machine it was taken on is a
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
| model_runner, processor | **296.5 t/s** | 34.8 t/s |
| llama.cpp, processor | 339.5 t/s | 39.2 t/s |
| model_runner, device | 1078.4 t/s | **50.6 t/s** |
| llama.cpp, device | 1647.2 t/s | 55.5 t/s |

**And the same four rows against a prompt of 1419 tokens**, which is the one
every change in this section is actually judged on:

| | prompt, 1419 tokens | generating, 64 tokens |
| --- | ---: | ---: |
| model_runner, processor | **291.4 t/s** | 34.8 t/s |
| llama.cpp, processor | 269.1 t/s | 39.2 t/s |
| model_runner, device | **1687.3 t/s** | 50.6 t/s |
| llama.cpp, device | 1802.4 t/s | 55.5 t/s |

**The processor's long-prompt row is ahead of llama.cpp: 291.4 tokens a
second against 269.1.** What moved it is `### A share a worker, decided
before any of them started`, below -- eleven per cent of a prompt lost to
waiting for the slowest of eight fixed ranges. Three commits before that it
was 1.16 behind.

**And the generating row is 1.12 behind, from 1.18**, after `### The share
count a generated token was tuned to` found that constant had been chosen
against the pool the same change replaced.

Both tables are one sitting this time, taken with `llama-bench` on the same
pass, and the machine was gated to a load under 0.7 and a settled part before
the first of them rather than only cooled. The rule the entry before this one
added still holds and is what the reading is checked against: the long-prompt
figure here, 5.273 s, sits inside the 5.350 to 5.391 the alternated A/B read
in a different window, so it is a sitting and not a window.

**The 1419-token processor row published before this one was wrong, and the
way it went wrong is the same trap this file keeps setting for itself.** It
said 260.4 tokens a second and a gap of 1.04, from a retake that read 5.450 s
-- a median of three, taken at a load of half, and ten per cent faster than
every other reading of that same binary taken that day, which cluster between
5.9 and 6.1 s. Nine alternated readings in the A/B beside it, three more in
the sitting, and this sitting's own quiet retake at 6.071 s all say the same
thing and the published one did not. A median of three inside one window is
not a defence against a window that is itself unusual; only readings spread
across windows are. The row now says 233.7 and 1.16.

**The longer prompt is the harder one and the quieter one, and it took this
long to publish because nobody asked it to.** Two things it says that the
short one does not.

The processor's long prompt is **ahead by 1.08** where its short one is 1.15
behind, and the device is **1.07** behind at 1419 tokens against 1.53 at
110. Attention grows with the square of the context and it
is the part of a layer this program is furthest behind on, so a table taken
at a hundred and ten tokens reads a little kinder than the work deserves.

And it is far less noisy. `llama-bench` reports its own spread, and over
three runs it is **±1.3 on 269.1 at 1419 tokens against ±25 on 339.5 at
110**, and the same 1419 figure read 224.9 ±20 half an hour earlier on a
machine that was not quiet -- a hundred and ten tokens is where a call's fixed cost still shows,
on both sides. This section has twice had to explain a figure that moved
more between sittings than the change being measured moved it: the device row
went 808.8 to 709.7 while the code got six and a half per cent faster. The
row above is why that happened; the row here is what should have been read.

Both are kept. The short prompt is what nine sittings of history in this
section were taken on and dropping it would throw that away, and a reader
comparing against somebody else's `pp110` needs it. But **the long one is the
figure to argue about**.

On the processor at 110 tokens: **1.1 times slower generating and 1.2 times
slower reading a prompt** -- the generating figure has read 1.1 twice, 1.2 eight times, 1.3 and 1.4 across sittings, the first four of them
after `### The wake, not the work`, which is what a ratio does when both
of its sides sit within a per cent of a rounding boundary -- where the first
reading of this table said 3.3 and 16. On the device, **1.1** and **1.5**,
where the sittings before this one said 1.1 and 1.4, then 1.1 and 1.5, then 1.1 and 1.6, then 1.1 and 1.5, then 1.1 and 1.5, then 1.1 and 1.5, then 1.1 and 1.6, then 1.1 and 1.5, then 1.2 and 1.4, then 1.2 and 1.7, then 1.2 and 1.6, then 1.2 and 1.6, then 1.2 and 1.7, then 1.3 and 1.7, then 1.2 and 2.1, then 1.3 and 2.1, then 1.3 and 2.3, then 1.2 and 2.4, then 1.3 and 2.5, then 1.3 and 2.7, then 1.4 and 2.7, then 1.4 and 2.6, then 1.4 and 2.7, then 1.4 and 2.9, then 1.4 and 2.3, then 1.4 and 2.1, then 1.4 and 2.5, then 1.4 and 2.5, then 1.4 and 2.2, then 1.4 and 2.5, then 1.4 and 2.3, then 1.4 and 2.5, then 1.4 and 2.4, then
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

**The device row is now clear of llama.cpp's processor row** -- 50.3 against
39.2 in this sitting, more than a quarter ahead, where for twenty-one
sittings the two sat on top of each other: 50.6 against 39.2, 50.3 against 38.8, 50.3 against 38.8, 50.3 against 39.2, 50.4 against 39.2, 50.0 against 39.5, 49.9 against 39.4, 50.6 against
39.2, 50.6 against
39.4, 46.6 against
39.4, 47.8 against
39.5, 47.0 against 39.6, 48.5 against 39.7, 48.0 against 39.6, 46.2 against 39.7, 44.4 against 39.6, 48.5 against 40.1, 44.5 against 39.5, 44.4 against 39.3, 45.8 against 39.4, 43.8 against 39.6, 42.3 against 40.4, 40.1
against 40.4, 40.3 against 40.4, 39.8 against 40.3, 40.6 against 39.8, 40.5
against 39.9, 40.4 against 39.9, 40.2 against 39.9, 40.1 against 40.0, 40.7
against 40.0, 38.9 against 40.0, 40.9 against 40.4, 41.0 against 40.4, 40.7
against 40.7, and 41.6 against 40.0. Most of those put this program's device
ahead and a few put it behind, by under three per cent either way, which was
a pair of figures sitting on top of each other rather than a lead in either
direction; the last three readings are the first that are not. What is left
between it and llama.cpp's own device figure is 1.2 times.

The processor's generating row is the other kind of gap. It reads every
weight once a token and does one multiply with each, so above three workers
the bus answers rather than the arithmetic: llama.cpp's 39.2 t/s is about 45
GB/s of this model and 34.8 is about 40. The entry before this one said the
counters disproved that, on an instruction-per-cycle figure of 2.29 -- and
that figure is an average over cycles that include seven workers spinning in
a four-instruction loop waiting for the next job, which issues at nearly four
a cycle and has nothing to do with the kernel. `### The generating kernel has
no slack` below has the correction and the measurement that settles it: one
worker reads this run at 16 GB/s and issues 3.46 instructions a cycle, three
workers reach 39 GB/s, and four to seven add nothing at all. What is left there is a gap in the kernels --
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

and the 1419-token table is the same four with the long prompt file and
`-p 1419` in place of `-p 110`:

```
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt-long.txt \
  --max-tokens 0
llama-bench -m MODEL -p 1419 -n 64 -t 8 -r 3 --device none
llama-bench -m MODEL -p 1419 -n 64 -ngl 99 -r 3
```

`llama-bench` counts tokens rather than reading a file, so its 1419 are
synthetic where this program's are a real text. What is being timed is the
number of them.

with `--backend device` added to the first two for the device rows. `tests
speed` reports seconds and this table reports rates: 110 tokens in 0.453 s
and 64 in 1.911 s on the processor, 0.102 s and 1.281 s on the device,
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
device present llama.cpp still evaluates the prompt on it -- 676.1 t/s rather
than 339.5 -- so a reader who takes this again the obvious way will measure
the device and read it as the processor, and will get a *smaller* gap than
the true one for the processor row.

The device generating row was the noisiest here for a long time: 50.6 t/s
now, against 54.2, 50.3, 50.3, 50.3, 50.4, 50.0, 49.9, 50.6, 50.6, 46.6, 47.8, 47.0, 48.5, 48.0, 47.7, 48.3, 48.2, 48.4, 47.3, 48.0, 46.2, 44.4, 48.5, 44.5, 44.4, 45.8, 43.8, 42.3, 40.1, 40.3, 39.8, 39.4, 40.6, 40.6, 40.5, 40.4, 40.2, 40.1, 40.7, 38.9, 40.9, 41.0, 40.7, 41.6, 41.3, 40.6, 41.0, 41.5, 41.2, 40.8, 28.1, 30.9, 27.1, 31.0, 30.9, 27.3, 26.9, 31.0, 31.2, 28.1,
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
| TinyLlama-1.1B at eight bits | 0.393 s | 33 ms a token |
| the same model at two bits | 1.659 s | 138 ms a token |
| the first, drafted by the second | 3.378 s | 24 proposed, 7 accepted |

The two-bit file is a third of the size on disk and costs nearly three times
as much per token to run, because what it saves in bytes it spends unpacking
them -- and because the eight-bit file now multiplies its activations as
bytes while the two-bit one has no integer kernel and cannot. A smaller file
is not a faster model, and that alone decides this pair: a draft costing more
per token than the model it drafts for cannot win at any acceptance rate. The
gap between the two was twice, then fifteen per cent, then nearly three
times, then three and a quarter, then three and two thirds, then three and a
half, then four, then four and a third, then four and a half twice, then
four, and is now four and a fifth; widening it does not change the sign
either.

The arithmetic, from the same three figures, in generating time alone so that
the prompt each run also pays is not counted twice. Six rounds of four
proposals cost 3.036 s, of which the draft's own twenty-four passes are
24 × 112 ms = 2.68 s, leaving 0.36 s for six checks -- **60 ms to check five
positions**, against 28 ms for one token generated normally. A batch is one pass over the
weights and the extra work is the output projection per position, which is
why five positions cost about two tokens rather than five.

So a round of K proposals costs `K × d + 60 ms` and yields `1 + a` tokens,
against `(1 + a) × 28 ms` without a draft. At the acceptance measured here,
about 1.2 of four, a round yields 2.2 tokens worth 62 ms and the check alone
costs 60 -- a threshold of half a millisecond a token, against a draft
costing 112: no draft pays at this acceptance, the check alone costing more than
the tokens a round yields. **That threshold has read 17, 10, 6, 9, 6,
4, 7 ms a token, nothing at all, 11, 18, nothing seven times more, 3.5, nothing again twice, and half a millisecond
across twenty-one sittings of the same code**, because it is a difference of
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
| three | 1.845 s | 5.73 s | 0.706 s | 2.02 s |
| four | **1.776 s** | 7.22 s | 0.514 s | 1.88 s |
| five | 1.837 s | 7.54 s | 0.508 s | 2.27 s |
| eight | 1.873 s | 8.01 s | **0.350 s** | 2.36 s |

**A generated token is done adding workers at four shares.** From four to
eight the wall goes *up* by four per cent for ten per cent more processor
time: the memory path is saturated by two or three cores and the rest are
paying for a queue. That is the bus, measured rather than inferred -- but
only half of it is the bus, and **`### The wake, not the work` below is the
other half**, which was worth seven per cent and was hiding behind this
table for as long as it stood.

This table was re-taken after `### The wake, not the work`, and the shape of
it survived while every number in it fell. What did change is the price of
the wrong answer: eight shares used to cost 12.68 seconds of processor time
against four shares' 7.28, and now costs 8.01 against 7.22. A share that
finds nothing to do is cheap when it is not woken to find out.

**A prompt is the opposite and wants every share**: 0.350 s at eight against
0.514 at four, because a batch shares one reading of the weights between its
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

### The same answer at every worker count, which it was not

`--threads` is documented three times in this file as changing how long a run
takes and not what it says. That was false for a batched prompt, for as long
as there has been an integer tile kernel, and this is what it looked like:

```
tests speed --model MODEL --prompt-file tests/fixtures/speed-prompt-short.txt \
  --max-tokens 64 --threads 3     ->  3248ac1bb7011de0
                  --threads 4     ->  3740ed87be385f2d
                  --threads 7     ->  3248ac1bb7011de0
```

Same file, same seed, same temperature of zero, different text. It appears at
the forty-third generated token and not before, and `--batch-size 1` makes it
go away, which between them say what it is: a difference of a few units in
the last place, made while reading the six-token prompt, carried in the key
cache until it lands on a token where the top two logits are close enough for
it to decide.

**A batch is computed a tile of rows at a time, and a tile of an odd size
takes a different kernel from a full one** -- eight lanes folded one way
against four folded another, which is the same products summed in a different
order. The rows were cut into shares without regard to the tile, so every
share ended in a short tile, and where those short tiles fell depended on how
many shares there were.

So a share boundary now falls on a multiple of the row tile. Every share but
the last holds a whole number of tiles, the tile grid is anchored at row zero
wherever the boundaries land, and the only short tile in a product is the one
the matrix's own row count leaves -- the same one the serial path has. **At
the worker count this program chooses for itself the partition is unchanged**,
because 2048, 5632, 256 and 32000 rows all divide by eight into eight shares,
which is why no published figure or digest in this file moves: `--threads 2`
through `--threads 15` now all answer `3248ac1bb7011de0`, and that is the
answer the default was already giving.

**Every test here passed while this was true**, and the reason is worth more
than the fix. `Parallel_Matches_Serial` compares a parallel product against a
serial one at every worker count -- against a *binary32* weight and *one*
vector, which is the one shape the integer tile kernel is never asked for.
The tile only exists for quantized weights and only tiles for a batch. So the
test named after the property tested the shape the property could not break
in.

The new one uses a hundred rows -- which divides by neither the tile nor most
of the share counts -- of `Q8_0` against a batch of eight, and compares every
element of the result against the serial one bit for bit at every share count
from one to eight. It fails on the old partition at two workers, on element
99, which is the last row of the matrix.

It also asserts nothing while a pool is in scope. A failed assertion raises,
which skips `Close`, and the frame that declares a pool waits for its
workers: the first version of this test hung where it meant to fail, for ten
minutes, until it was killed. `Parallel_Matches_Serial` beside it had the
same shape and now does not.

### The registers were never the wall

Three sittings running ended on the same sentence: sixteen registers is
exactly what these kernels have and exactly what blocks the next step, and
the thirty-two the processor offers under `AVX-512` are out of reach because
`Model_Runner.Kernels` is compiled for baseline x86-64 so the program runs
where the wide instructions do not. The unlock was named as a second
compilation of the unit, gated by the host check the integer product already
uses three times.

It is two lines, not a second compilation:

```ada
procedure Probe_Wide (Sums : in out Real_Array);
pragma Machine_Attribute (Probe_Wide, "target", "avx512f");
```

and what comes out of the baseline-compiled unit is

```
00000000000c5050 <probe_wide_x>:
   c5050: 62 e1 7c 28 10 07    vmovups (%rdi),%ymm16
   c5056: 62 e1 7c 28 11 07    vmovups %ymm16,(%rdi)
```

An `EVEX` prefix and the seventeenth register, in a unit every other
subprogram of which is baseline. The attribute is per subprogram, so a kernel
that names it can be reached through the same run-time flag its insertion
already hides behind, and a machine without the instructions never enters it.
**The register file is available for the asking.**

And having asked, neither thing it was wanted for is worth doing. The score
kernel's sixteen-position block saves four instructions in ninety-eight,
because the fold and the zeroing scale with the accumulators rather than with
the call -- that is the correction in the section below. The paired blend, at
sixty-four components rather than the thirty-two the sixteen registers forced,
loses the two and a third per cent the narrowing cost, but the pairing itself
measured level in situ: halving the loads bought nothing because that loop is
not load-bound either.

So the wall these three sittings kept arriving at was never the register
file. It is that both attention kernels are bound by the two multiply-add
pipes, with a fold that is fifteen per cent of the loop and structural, and
more registers do not move either of those. **The finding worth keeping is
the two lines**: the next thing that wants the upper sixteen registers can
have them, and does not have to restructure a compilation unit to get them.

### The score half of attention, and the sixteen registers again

`head_scores` is seven per cent of a prompt and the one attention kernel
nothing had ever been aimed at -- the blend has had six changes. Its
horizontal fold was the suspect. It is not the fold.

Disassembled, one turn of its loop is **a hundred and twenty-nine
instructions** and computes eight positions' scores for one head:

| | |
|---|---:|
| `vfmadd231ps`, the query against a key, reading it where it lies | 64 |
| `vxorps`, zeroing an accumulator | 8 |
| the fold: 6 `vhaddps`, 2 `vextractf128`, 2 `vaddps`, 2 `vmulps`, 2 stores | 14 |
| pointer advances, the scale broadcast and the branch | 43 |

**Half the body is not the dot product.** The fold that was suspected is
fourteen instructions of a hundred and twenty-nine, and the profile agrees:
its six `vhaddps` sample at 1.2 to 1.4 per cent each, about nine per cent of
the symbol between them.

Against the counters, `head_scores` retires **25.2 G operations in 9.53 G
cycles, 2.65 a cycle**; sixty-two per cent of its body contends for the two
pipes, so its own issue ceiling is about 3.2 and it is at **eighty-three per
cent** of it. For comparison, `rows_by_strips` -- proved to be on its floor
two sections above -- retires 3.17 a cycle against a ceiling of 3.08, and
retires nothing at all for 41.7 per cent of its cycles where `head_scores`
does for 46.7. **The two are in the same state**, and forty-seven per cent
of cycles retiring nothing is what a balanced loop looks like from the retire
side, not a symptom.

What is left is the half of the body that is not arithmetic. Eight positions
need eight accumulators; the query is sixty-four components and lives in
eight more; sixteen registers is exactly what that is, with nothing left
over.

**And a block of sixteen positions would not help, which this section said
first and had wrong.** The sixty-five instructions that are not the dot
product do not divide into a fixed cost and a per-position one: eight of them
zero an accumulator and fourteen fold the accumulators down, and *both scale
with the accumulators*. Sixteen positions need sixteen accumulators, sixteen
zeroing exclusive-ors and a fold of twelve `vhaddps` rather than six. Only
four instructions a call are actually fixed -- the scale broadcast, the
counter and the branch -- so doubling the block saves four instructions per
sixteen positions out of ninety-eight per eight. **Two per cent of the
kernel, which is a tenth of a per cent of a prompt.**

The fold is the tax and it is fifteen per cent of the loop by count. Cutting
it needs positions in the lanes rather than components -- broadcast a query
component and multiply it against eight positions' keys -- which needs the
keys component-major, which is the head-major order this file measured and
recorded as buying nothing three sittings ago.

`### The registers were never the wall` below is what came of asking whether
the sixteen could be thirty-two.

### The floor was mis-counted, and the kernel is on it

`### What the counters say` above has said for four sittings that the strip
kernel issues thirty-six multiply-add-class operations a block onto two
pipes -- eighteen cycles of floor against twenty-four taken -- and that the
third left over was somewhere. Part of it was the staging the section below
removes. The rest was a counting error, and disassembling the loop rather
than describing it is what found it.

The block loop is **seventy-seven instructions**:

| | |
|---|---:|
| `vpxor`, zeroing an accumulator or flipping the bias | 18 |
| `vpdpbusd`, the byte dot product | 16 |
| `vcvtdq2ps`, the integer sum made a float | **16** |
| `vfmadd231ps`, scaled and accumulated | 18 |
| loads, pointer arithmetic and the branch | 9 |

The sixteen conversions were never counted. A dot product here is not two
operations but **three** -- multiply the bytes, convert the sum, scale and
add -- because every block carries its own scale and an integer sum cannot be
scaled until it is a float. So the pipe-bound count is 16 + 16 + 18 = **fifty
a block, and the floor is twenty-five cycles, not eighteen**. The eighteen
`vpxor` are a zeroing idiom eliminated at rename and never reach a pipe,
which the earlier paragraph got right.

And the kernel is on that floor. Counting retired operations rather than
instructions, `rows_by_strips` retires **243.9 G ops in 76.8 G cycles, 3.17 a
cycle**, on a run whose whole is 351.2 G instructions in 131.2 G. Seventy-seven
ops a block over 243.9 G is 3.17 thousand million block iterations, and 76.8 G
cycles over those is **24.2 cycles a block against a floor of 25** -- under it,
because the renamed `vpxor` retire without ever occupying a pipe.

**So there is no third missing.** Forty-two per cent of the kernel's cycles
retire nothing because an operation is not complete, and a quarter of those
are loads, which is what a loop running at its issue limit looks like from
the retire side rather than a symptom of anything.

What the count does say is where the cost comes from. **Sixteen of the fifty
-- thirty-two per cent of the kernel's arithmetic -- are format conversion**,
not multiply-add, and they are there because `Q8_0` puts a scale on every
thirty-two elements. A format with a wider block would pay fewer of them per
weight; this one cannot be made to. That is the price of the file's own
shape, and it is not a thing the kernel can be written out of.

### A tile of thirty-two rows, and the table it stops rebuilding

The strip kernel is sixty-two per cent of a prompt and this file has called
it finished twice: thirty-six multiply-add-class operations a block onto the
two pipes that take them, eighteen cycles of floor against twenty-four taken,
five changes in, done. (Thirty-six was a miscount; see `### The floor was
mis-counted, and the kernel is on it`.) A third of the hottest symbol in the program was
outside that argument, and this is where it was.

At the top of every call the kernel stages the batch's own numbers -- each of
the strip's eight vectors, where its scales begin, the scale itself and the
block total the bias correction wants. **Those are the batch's numbers and
not the row's**, so they are the same for every tile of rows a share is cut
into, and the kernel built them again for each of them. A share of two
thousand and forty-eight rows in tiles of eight is two hundred and fifty-six
tiles; a profile put that staging at **twelve per cent of the symbol**, a
scalar loop of eight instructions on a kernel whose whole reason for
existing is that it is not scalar.

The tile is the cheap half of the answer, and it is one constant. Long
prompt, medians of three:

| `Row_Tile` | prompt |
|---|---:|
| 8 | 6.244 s |
| 16 | 6.206 s |
| **32** | **5.874 s** |
| 64 | 6.059 s |
| 128 | 6.411 s |

**Five and nine tenths per cent**, better in three of three alternated
rounds, and the digest does not move -- the same rows are multiplied by the
same numbers in the same order, four times as many of them per staging. The
curve turns over at sixty-four because the tile's accumulators stop fitting
the first-level cache: thirty-two rows by a hundred and twenty-eight vectors
is sixteen kilobytes of them, sixty-four is thirty-two, and a hundred and
twenty-eight is back where it started.

The share partition follows, because a share boundary falls on a multiple of
the row tile -- see `### The same answer at every worker count, which it was
not`. Two thousand and forty-eight, five thousand six hundred and thirty-two,
two hundred and fifty-six and thirty-two thousand rows all still divide by
thirty-two into eight shares, so no partition moves and no digest with it.

**The other half was built and is not kept.** With the tile at thirty-two the
staging is still done eight times a share where once would do, and hoisting
it -- staged for the whole share by the caller, handed down a strip at a
time -- measures **5.926 s against 5.938, level in six alternated rounds**.
Two shapes of it were tried and the difference between them is worth more
than the result: reading the shared table through one name at a chosen
address costs **7.256 s against 6.014**, a fifth, because an object at an
address the compiler cannot reason about is one it cannot prove does not
alias the table being written, and the innermost loop stops vectorizing.
Written out twice, once against the parameter and once against the local,
both arms vectorize and the whole thing comes out level.

Level, because the table it saves building is two kilobytes freshly written
into the first-level cache, and the table it reads instead is thirty-two
kilobytes walked eight strips apart. Building it there is as cheap as
fetching it from further away -- which is the third time this file has found
that shape, after the row scales a tile re-reads and the values a head
re-reads.

### The blend is not waiting for its loads

The value blend has been about five per cent of a prompt and unexplained
since the counters were first read here: prefetching its next position did
nothing, unrolling two positions a turn made it worse, halving its bytes made
it worse, and a head-major copy of the layer changed nothing. Four
measurements more, and this time the answer is what the loop is *not* waiting
for.

**The tile is flat.** Swept again now that everything around it has moved:
8 positions is 6.161 s, 16 is 6.230, 32 is 6.222, 64 is 6.304. A per cent
across a factor of eight is the noise floor.

**It is not missing disproportionately.** Counting `dc_access_in_l2` by
symbol on the long prompt puts `rows_by_strips` at 83.4 per cent of the
first-level misses, `head_scores` at 6.2 and `blend_run` at 5.2 -- against
5.0 per cent of the cycles. The tile of sixteen positions is what fixed that,
and it stays fixed.

**So the loads themselves were tried.** Eight heads share one key head's
values, so two of them can be blended from one reading: load a position's
values into registers once and multiply them into both accumulator sets.
Half the loads for a fifth more instructions. On a bench reading from the
second-level cache that kernel is **39867 Me/s against two single blends'
29788, one and a third times faster**.

In the engine it is worth nothing at all -- 4.92 per cent of the prompt where
the single blend took 4.95, and a wall of 6.388 s against 6.309. The bench
measured the wrong regime. With the heads walked *inside* a tile of positions
every head after the first reads values the first left in the first-level
cache, and there the load ports are not what the loop waits for.

**And the pair is not free to try.** Two heads of sixty-four components is
sixteen accumulators, which is every register the base encoding can name --
with none left for the values, which is the whole point of pairing. So the
component run has to halve and a head becomes two passes; that alone, with
the pairing switched off, measures **6.454 s against 6.309, two and a third
per cent worse in three of three**, paid in twice the calls and twice the
tile bookkeeping.

Which prices the family rather than one member of it. Any two-way pairing of
this blend -- across heads, as here, or across query positions, which is what
`docs/measured-figures.txt` proposed and has not been built -- needs sixteen
accumulators, so it needs the narrow run, so it **starts two and a third per
cent behind**. Query pairing would halve the first-level misses where head
pairing only halves the loads, and halving those misses is what the tile did
for three and seven tenths per cent; but it has to find that twice over
before it is level.

The constraint is the register file, not the cache and not the loads. Nothing
here is kept.

### The wake, not the work

The section above says a generated token is done adding workers at four
shares and calls that the bus. It is half right, and the half it got wrong
was worth about seven per cent.

What said so was counting cores rather than seconds. Sixty-four tokens, both
runtimes on the same file, `perf stat`:

| | this program | llama.cpp |
|---|---:|---:|
| wall | 2.12 s | 1.63 s |
| cycles | 31.0 G | 56.5 G |
| instructions | 87.1 G | 39.2 G |
| cores busy | **3.4** | **8.0** |

llama.cpp spends thirteen core-seconds to this program's seven and finishes
in thirty per cent less time. Half this machine was idle, and a run that is
idle is not a run that is out of memory bandwidth. Two copies of this program
generating at once settle that: alone it moves about 37 GB/s of the model,
and two together move 44 -- **so the bus had a fifth left in it and the pool
was not asking**.

It was not asking because its workers were asleep. A worker blocked on a
protected entry is blocked in the kernel, and waking it is a system call at
each end. Generating a token is a hundred and fifty-five products, so the
wake is paid a hundred and fifty-five times a token, and a share of a small
product -- the key and value projections are 256 rows, thirty-two rows a
worker -- can be shorter than the wake that delivered it. That is the real
reason the share count was capped at four: past four the wakes cost more than
the core brought.

So a worker looks for its next job before it blocks for it. A ticket counts
jobs posted and a second counter counts the shares of the current one still
to report; a worker spins on the first for about ten microseconds before
entering the entry, and a submitting task spins on the second before entering
`Await`. **Neither decides anything.** The coordinator still opens the
barrier, still hands over the job, still says when the job is done and still
says when the pool is closing; the two counters only decide whether a task is
awake when it asks. A run in which no spin ever finds anything runs exactly
what it ran before, which is what makes this safe to say.

| medians of three, alternated | before | after | |
|---|---:|---:|---:|
| 64 generated | 2.058 s | **1.906 s** | better in 4 of 4 |
| 1419-token prompt | 6.549 s | **6.450 s** | better in 4 of 4 |

Bit-identical either way -- `3248ac1bb7011de0` generating and
`1a26d24d33b8957b` on the prompt -- because nothing about what is computed or
who computes it changed.

**It is paid for in processor time**, and the twelve-token figure at the top
of this section went from 1.57 s to 1.85 s for it. A task that spins is a task
that is running; the spin is bounded so that a pool with nothing coming stops
burning a core almost at once, and a worker that spins its whole budget and
finds nothing has cost one core about ten microseconds and then sleeps as it
used to. The budget was swept: four thousand turns and sixty thousand measure
the same as twenty thousand generating, and four thousand is worse on a
prompt, which is the shape a spin that ends too early makes.

**What it did not do is move the share count.** Six shares now measures level
with four rather than worse, and eight is still behind, so a generated token
still asks for four. What changed is the price of the wrong answer: eight
shares cost 12.68 seconds of processor time against four shares' 7.28 before,
and 7.97 against 7.23 after.

Two other explanations were measured first and are not it. The single-vector
row tile was swept at one, two, four and eight rows -- 2.17 s, 2.08, 2.04,
2.04 -- so more rows in flight per worker is not the lever, and **one row at
a time, which reads the weights perfectly contiguously, is the worst of the
four**: the access pattern inside a share was never the problem either.

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

### Where the device's prompt goes, one piece at a time

Four sections above measured the parts of a layer against each other. This
measures them by taking each one out and seeing what the prompt costs
without it, which answers a different question: not what a piece takes but
what removing it would be worth. All four are the 1419-token prompt on the
device, median of three, against a baseline of 1.282 s.

| what was taken out | prompt | what it was worth |
| --- | ---: | ---: |
| nothing | 1.282 s | -- |
| the weight staging, decoding a constant instead | 1.082 s | **0.200 s** |
| that and the activation loads as well | 0.983 s | 0.099 s |
| thirty-one of every thirty-two matrix instructions | 0.916 s | **0.366 s** |

The last row is the one to read twice. Every load and every decode still
happens; only the arithmetic is gone. **The matrix instruction is
twenty-nine per cent of a device prompt**, so a kernel that did the
multiplies for nothing would read 0.92 s where llama.cpp reads 0.74. The
gap is not in the multiply, and three attempts at it in one sitting say the
same thing from three directions -- all measured, none kept:

The packed half-precision dot product, which is what llama.cpp uses and
what this file spent a day looking for, is **thirty-nine per cent slower**
than the matrix instruction here: 1.806 s against 1.295, three alternated
rounds each. The kernel is real -- the disassembly holds 2048
`v_dot2acc_f32_f16` in one unbroken run, at 144 registers against the
matrix kernel's 256 and six subgroups a SIMD against four -- and it is
better on every static measure and slower on the only one that counts. It
is also not where llama.cpp's speed comes from: with `GGML_VK_DISABLE_COOPMAT=1`
it reads 1418 tokens a second and without it 1408, so both of its paths
arrive at the same place and neither of them is the difference.

A taller tile -- a hundred and twenty-eight rows over four subgroups, with
the activations staged in shared memory so the four share one copy -- reads
**2.665 s**. The arithmetic that suggested it was wrong: a workgroup of
thirty-two rows re-reads its half-megabyte tile of activations sixty-four
times for a two-thousand-column matrix, which is thirty-three megabytes
against four and a half of weights, but those re-reads are second-level
cache hits and not memory at all. Staging them traded cache bandwidth,
which was free, for shared-memory bandwidth, which was not, and turned
every barrier into a real four-wave sync.

A wider tile -- five hundred and twelve vectors over four subgroups sharing
one decoded copy of the weights, with the step deepened from thirty-two
columns to a hundred and twenty-eight so that every invocation has a share
of the decode -- reads **1.624 s**, with the same registers, the same
occupancy, a quarter of the barriers and a quarter of the passes over the
weights. Five hundred and twelve vectors is a two-megabyte tile of
activations, which is this part's whole second-level cache, so what the
weights stopped paying the activations began paying. The batch width on its
own is neutral -- 1.319, 1.261 and 1.336 s at 128, 512 and 256 -- because
a workgroup re-reads the weights whatever the batch is.

So thirty-two rows by a hundred and twenty-eight vectors is where this
part's cache hierarchy puts the optimum, and the matrix product is not
where the remaining gap is. What is left is the row above it: attention,
nineteen per cent of a prompt and fifteen of a generated token.

### The width of an attending workgroup

`attention.comp`'s second compilation now runs two hundred and fifty-six
invocations to a workgroup where it ran sixty-four. **Sixty-four generated
tokens after a 1419-token prompt read 1.603 s against 1.715**, better in
each of three alternated rounds, with every wide run faster than every
narrow one.

Sixty-four is one subgroup, which is what made every barrier in that kernel
free. What it cost is that a workgroup is then one wave. Generating, a
workgroup is one head of one position, so a thirty-two-head model is
thirty-two waves and this part has twenty-four SIMDs to fill: a layer's
attention reads eighty-seven gigaflops where the same layer's matrix
products read four thousand. That is not bandwidth and not arithmetic; it
is a kernel with nothing behind it to hide a load. Four subgroups is four
times the waves, and the barriers stop being free.

Which of those wins depends on how many workgroups there already are, and
the two attending compilations are on opposite sides of it. Reading a
prompt, a workgroup is a head of a block of eight positions and there are
five hundred and twelve of them, which fills the part on its own -- and
there the same change **costs six per cent**, 1.740 s against 1.635. So the
tiled compilation stays narrow and only the single-position one is widened.
The first compilation, the one for a device with no subgroup operations,
stays narrow too: it reduces by walking the score tile, and four times the
lanes would be four times the serial reads that kernel exists to avoid.

The value a lane carries is now summed in four parts and added up once at
the end rather than accumulated in one running sum, so the order of a
floating-point addition changed. **Both digests are unchanged** --
`1a26d24d33b8957b` and `7ec6b755e53e16b4` -- and the sweep reads 28344
sequences with none outside tolerance.

It is worth least where the cache is shortest, which is exactly where the
table under `### The device backend` measures it: twelve tokens after a
six-token prompt moved 0.249 s to 0.240, and sixty-four tokens after that
same six-token prompt read 1.340 s against 1.348, which is level. Attention
grows with the context, and so does what widening it is worth.

### Attention through the matrix instruction

A prompt's attention is now two matrix products with a softmax between
them, on the same `VK_KHR_cooperative_matrix` instruction the matrix
product uses. `### Attention through the matrix instruction, built and not
kept` above is the same kernel, built earlier and rejected for being
thirteen per cent slower; what it was missing is the last paragraph of
this one. **The 1419-token prompt reads 1.236 s against 1.323**, better
in each of three alternated rounds with every matrix run faster than every
scalar one, and the gap to llama.cpp on that prompt falls from 1.63 times
to **1.52**.

The section above measured attention's loop apart and found nothing in it
worth attacking: its key loads cost four thousandths of a second, its value
loads four, its reductions five, its exponentials eleven. What it did not
say is what llama.cpp's own profiler says when asked. `GGML_VK_PERF_LOGGER`
prints per-operation timings, and against ours, in microseconds per
position per layer:

| | ours, before | llama.cpp |
| --- | ---: | ---: |
| attention | 6.12 | 2.85 |
| the five matrix products | 22.5 | 21.6 |
| everything else | 3.3 | 3.1 |

**Our matrix product was already level with theirs** -- 2048 by 512 by 2048
runs at 4154 gigaflops for them and 4050 for us -- which is why three
attempts at its tile shape all failed. Attention was fifty-two per cent of
what remained, and their own build says why: with `GGML_VK_DISABLE_COOPMAT=1`
their attention reads 1610 gigaflops and with it 2945, and a 1419-token
prompt goes 1240 tokens a second to 1744. It is the instruction, and
nothing else in the kernel.

**The cache is kept twice now, and that is the whole difficulty.** The
instruction reads half precision; this cache was binary32. Two kernels were
written that converted it into shared memory a tile at a time, and both
were slower than the scalar kernel they replaced -- 1.535 s for the
straightforward one, and 1.785 for a variant that walks the keys twice so
that nothing is ever rescaled and the answer can stay in the accumulators
from the first tile to the last. **The difference between those two is one
more staging and one more product, a quarter of a second**, which is what
said the staging was the cost. llama.cpp never pays it because their cache
is half precision in memory.

So `place.comp` writes each position twice, binary32 where it always went
and half precision after it in the same buffer, and attention loads its
keys and values straight into the instruction with the cache's own stride.
Nothing is staged but the queries, which arrive in binary32 and are read by
every tile. The cache costs half again as much room, and the sweep is what
says the rounding is small enough: 28344 sequences, none outside tolerance.
Every published digest held.

Two things about the kernel are worth writing down.

**The running softmax cannot rescale a cooperative matrix.** An
accumulator's elements belong to lanes in an order the hardware chooses, so
no lane knows which row it holds, and when a tile raises a row's largest
score everything accumulated so far has to be multiplied by the difference.
llama.cpp's answer is to keep the weighted values in ordinary registers and
move each tile's product through shared memory to get them there, and that
is what this does: the two products are the instruction's, and the carrying
is not.

**The reduction is clustered, not a walk.** Sixty-four invocations hold
thirty-two rows of scores, thirty-two columns each, so the thirty-two that
share a row agree on its largest score and the sum of its weights through
one reduction over their half of the subgroup. Written the obvious way --
one invocation to a row, walking its thirty-two columns -- the same kernel
read 1.606 s.

It is a fourth attending kernel rather than a fourth compilation of
`attention.comp`, because only the softmax between the products reads the
same. A device without the instruction, a head wider than sixty-four or one
that is not a multiple of sixteen, and every generated token -- a workgroup
answers thirty-two query positions and a token is one -- go to the scalar
kernels exactly as before.


### Sixteen rows, and two shapes that are not the answer

The attending tile is sixteen query rows a workgroup rather than
thirty-two. **The 1419-token prompt reads 1.212 s against 1.237**, better
in each of three alternated rounds, and the device now reads it at 1194
tokens a second.

Sixteen is the floor -- it is the instruction's own tile -- and the reason
it wins is the register file. Thirty-two rows hold twice the answer, and
that is **two hundred and fifty-six registers against ninety-six, four
subgroups a SIMD against ten**. The arithmetic per workgroup is the same
either way; what changes is how many of them the part will hold at once.

The other two things this was measured against are worth writing down,
because both were argued from a diagnosis that is right and both lost.

**The workgroup count follows the rows, and the narrow products suffer for
it.** A workgroup of the matrix product answers thirty-two rows by a
hundred and twenty-eight vectors, so over a batch of that width the
feed-forward arms make a hundred and seventy-six workgroups, the
projections sixty-four, and the keys and values **eight** -- eight waves on
a part with twenty-four SIMDs. The rates follow exactly: 4390, 4050 and
3814, and 1040 gigaflops. That is a quarter of what this program is still
behind by, and the cause is not in doubt.

Two ways at it were tried. Sending the narrow products to the row product
instead, which dispatches thirty-two workgroups for a
two-hundred-and-fifty-six-row projection, reads **1.246 s against 1.223**:
the matrix kernel wins even eight workgroups deep. Splitting a workgroup's
rows between two subgroups -- twice the waves for the same workgroups, half
the accumulators each -- reads **1.360 s**, and that is the third time a
workgroup of more than one subgroup has lost in this kernel, after the
taller tile and the wider one. Its barriers are free at one subgroup and
are not free at two, and nothing measured so far buys back what they cost.

What is left is to raise the workgroup count without sharing a barrier:
split the columns across workgroups, each accumulating a partial answer,
and add them up in a pass of their own. That is the one shape not yet
tried, and it is the only one that does not put two subgroups behind the
same barrier.


### The seventh of a prompt that was not in a dispatch

Per-step GPU timestamps, summed: the seventeen steps of a layer account for
1025 ms of a 1190 ms prompt. **Eighty-six per cent of a device prompt was
inside a dispatch, where llama.cpp's own logger accounts for
ninety-six** -- 784 ms of an 813 ms prompt. A seventh of ours was somewhere
no kernel could reach, and three sections above spent themselves on the
other six sevenths.

Timing `Run` from the caller's side splits it. Of a prompt with the
one-time weight upload netted out: **1093 ms waiting on the device, 40 ms
inside `Run` and not waiting** -- recording, the activation over, the
answers back -- **and 190 ms outside `Run` altogether**, which is host work
between one layer and the next, three quarters of a millisecond a layer.

Most of it was the rotation table. `Rotary_Table` is called once a position
a layer, and for each it works out a cosine and a sine a pair in binary64 --
a hundred and twenty-eight positions by thirty-two pairs, twenty-two times a
batch. **It does not depend on the layer.** Everything it reads is fixed for
the whole of one call except the rotation base, and an architecture states
one base unless it states a local one for windowed layers, which this
family does not. So it is tabulated once a base now rather than once a
layer, and a batch does the work once instead of twenty-two times.

**The 1419-token prompt reads 1.131 s against 1.209**, better in each of
three alternated rounds and clear of them: the slowest cached run is faster
than the fastest uncached one. That is six and a half per cent, and the
device now reads the prompt at **1244 tokens a second** against llama.cpp's
1760 -- a gap of 1.42 where it was 1.52.

It is worth about a hundred milliseconds on the processor too, which is one
and a half per cent there rather than six: the same work saved against a
prompt five times longer. Both backends compute the table in the same place
and neither needed it.

What is left outside a dispatch is a little over a hundred milliseconds a
prompt. The rest of that is the keys and values copied back into the host's
own cache, the sequence built a layer at a time, and the residual
bookkeeping -- none of it yet measured apart.


### The activation kept where the device wrote it

A layer's answer is the next layer's activation, and between them it went
to the host and came back: a megabyte a layer out of the mapped result
buffer and the same megabyte over again. It stays now. **The 1419-token
prompt reads 1.105 s against 1.134**, better in each of three alternated
rounds with the slowest carried run faster than the fastest uncarried one,
and the device reads it at **1296 tokens a second** against llama.cpp's
1761 -- a gap of 1.36 where it was 1.40.

The section above priced it. The answers coming back were 21 ms of a prompt
and the activation going over 9, and the measurement said 2 to 3 per cent;
this is 2.6.

**Nothing is copied to make it happen.** The result buffer keeps room at
its front that nothing else is placed in, and where a layer carries out,
its last step is placed *there* rather than after the others -- so the
device writes the answer straight into the room the next layer reads it
from. The first attempt did copy, with a transfer command and a barrier on
each side of it, and that was worth half as much: 1.2 per cent against 2.6.
The two barriers drain the pipeline once a layer, and the copy is a
megabyte the device has no reason to move.

Reading it back is safe for the same reason the copy was: the only step
that reads that room is the first residual join, and a barrier publishes it
long before the last step runs.

**A layer may only carry out if the next one will be taken whole as well.**
A layer that falls back reads the host's copy of the activation, and the
host's copy is exactly what carrying does not write -- so the condition
that decides whether the device takes a layer is now a function, asked of
the next layer before this one hands anything on. The first layer of a
batch reads what the host sent and the last writes what the host reads.

What this does not remove is the fence a layer still waits on. The host
wants nothing from a carried layer except its keys and values, which it
copies into its own mirror of the cache; if that mirror went, the
submissions could chain and the 68 milliseconds a prompt spends between
submit and wake would go with it. That is a change to what a session
guarantees, not a change to a kernel, and it is not made here.


### Two of everything, so a layer does not wait

The engine holds two command buffers, two fences, two sets of descriptors
and a semaphore, and a layer hands its work over without waiting for it.
**The 1419-token prompt reads 1.041 s against 1.113**, better in each of
three alternated rounds with the slowest chained run faster than the
fastest waiting one. The device reads it at **1354 tokens a second**
against llama.cpp's 1761 -- a gap of 1.30 where it was 1.36, and 2.32 when
this began.

`### The seventh of a prompt that was not in a dispatch` measured what this
recovers: of the time a layer spent inside its wait, ninety-four per cent
was the device computing and six was the gap around it -- the device
finishing, the host waking, recording, submitting, and the device starting
again. Sixty-eight milliseconds a prompt in which nothing computes. Chained,
the next sequence is already queued when the last one ends.

**It only became possible two changes ago.** A layer that must hand its
answer to the host has to be waited for; one that leaves its answer on the
device and its keys and values in the device's own cache has nothing the
host wants, and `Run` waits only where a step is kept, a matrix was
borrowed, or the answer is the last one. In a twenty-two layer batch that
is the last layer.

Four things had to be doubled and one added, and each is a rule rather than
a preference:

A command buffer may not be re-recorded while it executes, and descriptors
may not be written while a submission reads them -- so two of each, swapped
every sequence, and the one being taken up is waited for first. That wait
is for the sequence *before the previous one*, which finished long ago.

Two submissions to one queue are not ordered against each other unless they
are made to be, and the second reads what the first left at the front of
the result buffer -- so a semaphore, waited on and signalled by every
submission. **One semaphore, not two.** A binary semaphore may not be
signalled while already signalled, and a signal nothing waits for -- the
last sequence of a batch -- leaves it that way; waiting and signalling the
same one in the same submission keeps it balanced whatever came before. Two
semaphores deadlocked the device tests until that was understood, and a
flag left set across a close deadlocked them again: a new engine's fresh
semaphore has signalled nothing, so anything remembering that the old one
had was waiting for something that would never come.

And a matrix the sequence still in flight is reading may not be given back,
so the floor under the eviction clock is one lower where there is one; a
sequence that borrowed anything waits before it hands it back; and anything
that writes what a submission may be reading -- the activation sent over, a
buffer grown, an engine closing -- settles everything in flight first.


### Sixty-four cached positions to an attending tile, and where that kernel stops

The attending tile takes sixty-four cached positions at a time rather than
thirty-two, which halves everything a tile pays once -- its barriers, its
reductions, the round trip its weighted values make through shared memory.
**It is worth one per cent**: 1.025, 1.032, 1.033 and 1.046 seconds against
1.041, 1.043 and 1.046, never behind in four rounds and ahead in three.
That is small enough to say plainly. It is kept because it never loses, and
because sixty-four is the tile the scalar kernel beside it already walks.

A hundred and twenty-eight is worse -- 1.058 s -- because a tile's scores
are held in shared memory and doubling them costs more occupancy than the
halved tile count buys.

**What that leaves is a kernel with no large overhead in it.** Attention is
3.95 microseconds a position a layer against llama.cpp's 2.85, and the
pieces that might account for the difference have each been priced now:

| | |
|---|---:|
| the round trip the weighted values make, removed entirely | 0.5 % |
| sixty-four cached positions to a tile rather than thirty-two | 1.0 % |
| a hundred and twenty-eight | −1.5 % |

That round trip is the one thing a two-pass form would remove: walk the
tiles once for each row's largest score and once to weigh against it, and
nothing is ever rescaled, so the answer stays in the cooperative matrices
from the first tile to the last. It was built that way earlier in this work
and measured slower, and the half per cent above says why it always would
be -- what it removes is that, and what it adds is a whole second pass over
the scores.


### A generated token carried too

`### Two of everything, so a layer does not wait` gave a batch three things:
a layer's answer stays in device memory instead of coming home between
layers, a layer's keys and values stay in the device's own cache instead of
being mirrored one layer at a time, and the two together let a layer be
handed over without the host waiting on its fence. The evaluator that
generates -- one position rather than a batch -- got none of them, and
generating is where the host's share of a token's time is.

**What said to look there.** A generated token dispatches 18.29 ms of work
on this device against llama.cpp's 17.9 for the same token: level overall,
six times faster on attention (180 microseconds against 1166) and twice as
fast on the keys and values (250 against 577). The token takes 20.8 ms of
wall. The kernels were not what was left; the two and a half milliseconds
between the dispatches and the wall were, and twenty-two layers each waiting
on their own fence is where they go.

So the single-position path carries too. The first layer of a token reads
the activation the host has, the last writes back what it read, and the ones
between take it where the device left it; each of them leaves its one
position of keys and values in the device's cache; and after the last layer
one pass reads those positions back for the host's own copy, which the
snapshot, the eviction and the other two precisions all need. One position
apiece rather than twenty-two waits.

**Worth about five per cent**, and measured the way a five per cent claim
has to be. Sixty-four generated tokens on the device, the two arms
alternated round by round, medians of three:

| | chained | waiting |
| --- | ---: | ---: |
| round 1 | **1.269 s** | 1.351 s |
| round 2 | **1.273 s** | 1.336 s |
| round 3 | **1.286 s** | 1.369 s |

and an earlier sitting on the same pair read 1.249 and 1.272 against 1.316
and 1.331. Eight pairs, eight wins, and none of the eight inside four per
cent.

**The end-to-end cell moved less than that, and the reason is worth
recording rather than hiding.** The same sixty-four tokens read 1.319 s in
the sitting the tables above were taken in and 1.364 s an hour later on the
same binary -- a spread as wide as the change. That is why the alternated
pairs are the evidence and the cell is only the figure: a table cell is one
reading of a machine that moves, and a difference measured round against
round has the machine's drift in both arms.

One condition is not obvious and cost a debugging session in the batched
version of this: the test for whether a layer may be carried is asked of the
**next** layer as well as this one. A layer the device cannot take whole
falls back to the host, the host reads its own copy of the activation, and
the host's own copy is exactly what carrying does not write.


### The tile llama.cpp uses, and what this part does with it

The matrix product is what is left of the device's prompt. A profile of both
sides at 1419 tokens, `--budget` here and `GGML_VK_PERF_LOGGER` there, says
where the difference is and says it plainly:

| | here | llama.cpp | behind |
| --- | ---: | ---: | ---: |
| matrix products | 0.828 s (79 %) | 0.581 s (77 %) | **1.42x** |
| attention | 0.160 s (15 %) | 0.078 s (10 %) | 2.06x |
| norm, rotate, join, gate | 0.024 s | 0.093 s | ahead |

**Eighty-four per cent of the whole gap is in the one row.** Our kernel runs
that work at 3.4 teraflops and theirs at 4.9.

Read the attention row with the correction under `### What attention
actually costs` below, which was measured later and by removal rather than
by this instrument: attention is a ninth of a prompt and 1.4 times behind,
not a sixth and 2.1. The row above overstates it, and the reason is the
instrument rather than the arithmetic.

So the other runtime's tile was read out of its source rather than guessed
at. For an AMD device with `VK_KHR_cooperative_matrix` on the open driver,
`ggml-vulkan.cpp` picks `{256, 128, 128, 32}`: a hundred and twenty-eight
rows by a hundred and twenty-eight vectors, thirty-two columns at a step,
two hundred and fifty-six invocations as four subgroups, with **both**
operands staged in shared memory and every subgroup loading its quarter from
there. Ours is thirty-two rows by a hundred and twenty-eight over one
subgroup, with the weights staged and the batch read where it lies.

That was built, and it is **thirty-one per cent slower**. The two halves of
it were then separated, because a change that loses says nothing about which
of its parts lost. Alternated round by round, medians of three, the
1419-token device prompt:

| | prompt |
| --- | ---: |
| thirty-two rows, one subgroup, the batch read in place | **1.026 s** |
| the same, the batch staged in shared memory | 1.195 s |
| a hundred and twenty-eight rows, four subgroups, in place | 1.170 s |
| a hundred and twenty-eight rows, four subgroups, staged | 1.355 s |

**Both halves lose on their own and the two costs compose.** Staging the
batch costs sixteen per cent with one subgroup, where the barrier is free
and cannot be blamed; the taller tile costs thirteen with the batch left
where it is. Neither is an artefact of a cheap implementation: the staged
arms were measured again reading four values at a time, as the other runtime
does, and read 1.195 and 1.419 -- the same and slightly worse.

What the tall tile buys is real and is not enough. A thirty-two-row tile
re-reads the batch four times as often as a hundred-and-twenty-eight-row one
-- thirty-two megabytes against eight for a 2048-row layer -- but those
re-reads are second-level cache hits, and this part would rather serve them
than pay a shared-memory round trip and a four-wave barrier for each one.
The same conclusion was reached from a different direction under `### The
tile that reads the batch five hundred times, and does not mind`, and this
is the third measurement to reach it.

**One per cent of it was worth keeping**, and it is the smallest part. The
shared tile of decoded weights is read sixteen rows at a time, and its
stride was thirty-two half-precision values -- a power of two, so all
sixteen rows land in the same shared-memory banks. llama.cpp pads its own
tile on these devices for exactly this reason. Padded by four, the prompt
reads 1.036 s against 1.048, better in each of seven alternated pairs across
two sittings.

The pad is worth reporting in full because only part of it is understood.
Four, eight and sixteen measure the same -- 1.039, 1.040 and 1.041 s -- so
what this buys is a stride that is not a power of two rather than any
particular bank pattern. And two is **worse than none**, 1.097 s, which no
bank arithmetic predicts. A stride of sixty-eight bytes is the only one of
these that a sixteen-byte load cannot be assembled from, so alignment rather
than banking is the likely reason, and it is written down as likely rather
than shown.

So the remaining 1.42 times on the matrix product is not the tile's shape,
and the three shapes either side of ours have now been priced. It is
somewhere inside a kernel whose shape is right.


### A prompt in three passes over the weights, not twelve

Taking the decode apart is what found this, and it found something else.
Replacing the decode with a constant takes the 1419-token device prompt from
1.04 s to 0.81 -- **twenty-three per cent** -- so the obvious reading is that
turning `Q8_0` bytes into half-precision values is what a prompt spends its
time on. The disassembly agreed: the inner loop holds thirty-two matrix
instructions and about a hundred and fifty other arithmetic ones, and it
wrote the shared tile one sixteen-bit value at a time where four would fit
in a store.

Both of those were fixed and **both measure nothing**. Holding the tile four
values to an element turns sixteen `ds_store_b16` into two wide stores;
applying the block's scale to a whole vector instead of value by value turns
sixteen half-precision multiplies into eight packed ones, which the
disassembly confirms. Alternated three rounds each: 1.031, 1.039 and 1.032
seconds for one value, four out, and four with the packed scale. Level.

So the twenty-three per cent was split, because removing the decode had
removed the loads that feed it as well. Keeping the loads and the scale and
throwing away only the conversion:

| | prompt |
| --- | ---: |
| the whole decode | 1.047 s |
| its arithmetic gone, its loads kept | 1.011 s |
| both gone | 0.810 s |

**The arithmetic is three and a half per cent and the weight reads are
nineteen.** A hundred and twenty instructions of decoding are worth almost
nothing, which is why two careful attempts at them were worth nothing, and
what a prompt is really doing is reading the weights.

**And it was reading them twelve times.** A batch is one pass over the whole
model, and `Max_Batch` was a hundred and twenty-eight, so a 1419-token
prompt made twelve passes where llama.cpp -- whose `n_ubatch` is five
hundred and twelve -- makes three. Raising it to five hundred and twelve:

| batch | device prompt |
| --- | ---: |
| 128 | 1.027 s |
| 256 | 0.991 s |
| **512** | **0.987 s** |
| 1024 | 1.026 s |
| 1419 | 1.028 s |
| 2048 | 1.028 s |

Alternated, three rounds on the device and two on the processor, five
hundred and twelve is ahead in every one: 0.961, 0.995 and 0.987 seconds
against 1.027, 1.026 and 1.036, and 6.126 and 6.248 against 6.440 and 6.336.
**Four per cent on the device and three on the processor**, and the same
tokens.

Above five hundred and twelve it goes back, which is the part worth keeping:
a batch holds the activations of every position in it, and at a thousand and
twenty-four those stop fitting in whatever they were fitting in. So this is
not "bigger is better" -- it is a shape with an optimum, and the optimum is
where the other runtime already had it.

**A measuring tool that carried its own default nearly hid this.** The
figures above were first taken with `--batch-size` defaulting to a hundred
and twenty-eight inside `tests speed`, a copy of a default the command had
just moved, and the sitting measured a batch nobody would ever run. That is
the second time this tool has differed from the command it publishes figures
for -- the first is three paragraphs under `### The device backend` -- and it
now reads the default out of the request record rather than repeating it.

The `Max_Batch` constant that all of this turns on lives in a specification
file that no fingerprint group listed. Two defaults elsewhere happened to
move with it and those were listed, so the check fired anyway; it fired by
luck. `model_runner-llama.ads` is in the five groups now.


### The tile is in a corner, and here is what holds each wall

A batch is five hundred and twelve now, so the tile could finally be as wide
as the section above made the batch. A workgroup reads `TILE_R` rows of
weights by the whole depth to produce `TILE_R` by `TILE_V` answers, so the
weight reads per answer fall as the tile widens -- and those reads are a
fifth of a prompt. The sweep that once called tile width neutral was run
when a batch was a hundred and twenty-eight and a wide tile could never be
full.

It is worse, and the part number says why. Two rounds each, medians of
three, with the same digests throughout:

| tile width | 1419-token prompt | 110-token prompt |
| --- | ---: | ---: |
| **128** | **0.954, 0.964 s** | **0.114, 0.113 s** |
| 256 | 1.223, 1.176 s | 0.208, 0.209 s |
| 512 | 14.678, 14.420 s | 4.713, 4.756 s |

**A tile's accumulators are its registers**, and there are `TILE_R/16` by
`TILE_V/16` of them, four registers apiece. Sixteen accumulators fit; at
twice the width the shader reports **256 registers with 67 spilled** and
twelve kilobytes of shared memory taken to spill them into, and its
occupancy falls from six subgroups a SIMD to four. At four times the width
the accumulators alone want the whole register file, and the fifteen-fold
figure is what a kernel does when every one of them is a memory access.

So the four walls of this tile are all now measured, and two of them are
different walls:

| direction | what it costs | what holds it |
| --- | ---: | --- |
| wider -- 256, 512 vectors | +23 %, +1400 % | the register file |
| taller -- 128 rows, four subgroups | +13 % | the barrier |
| operands staged in shared memory | +16 % | the round trip |
| deeper -- 64, 128 columns a step | slower | measured earlier |
| the shared tile's stride, padded | **-1 %** | kept |

Thirty-two rows by a hundred and twenty-eight vectors on one subgroup is a
corner, not a choice: the register file stops it widening and the cost of a
second subgroup stops it growing any other way, because more output per
workgroup needs either more registers each or more subgroups sharing them
and this part refuses both.

**And the loads are already as wide as they go.** The natural next thought
-- that four one-word reads of a weight block should be one four-word read
-- is already true: the executed Q8_0 loop holds thirty-four
`buffer_load_b128` and three `buffer_load_b32`, and the three are the block
scales.

Where the prompt stands after all of it, on the current kernel, two rounds
each:

| | 1419-token device prompt |
| --- | ---: |
| as it is | 0.960 s |
| the decode and the weight reads that feed it, gone | 0.734 s |
| thirty-one of every thirty-two matrix instructions, gone | 0.803 s |

Twenty-four per cent is the weights arriving and being turned into
half-precision values, sixteen is the multiply itself, and the shape around
both of them is at a local optimum in every direction anyone has thought to
push it.


### The batch was already the right way round

One lever was left on those reads. The instruction's second operand is
sixteen depths by sixteen vectors, and the half-precision batch is
vector-major, so reading one is sixteen runs of thirty-two bytes a whole
vector apart -- four kilobytes on this model. Kept depth-major instead, the
sixteen vectors a tile wants at one depth would be one contiguous run of two
hundred and fifty-six bytes. `half_batch.comp` writes that copy and
`matrix_product.comp` is its only reader, so the change is two shaders and a
push constant.

It is **thirty-two per cent slower**, and taking it in two pieces says why
-- the copy alone first, with the reader left as it was, which computes the
wrong answers on purpose and times the transpose by itself:

| | 1419-token device prompt |
| --- | ---: |
| both as they were | **0.966 s** |
| the copy turned on its side | 1.059 s |
| and the reader turned with it | 1.271 s |

The copy costs ten per cent, which is the smaller surprise: it runs once per
product, but that is seven times a layer and twenty-two layers and three
batches, and turning it round makes its own reads the strided ones.

**The reader costs twenty-two, and that is the thing worth knowing.** The
turned version reads contiguous memory where the original strides four
kilobytes, and it is much slower anyway, because the operand's layout is not
a preference -- `gl_CooperativeMatrixLayoutColumnMajor` is what this
instruction's second operand natively is on this part, and asking for
`RowMajor` buys a rearrangement in registers that costs more than every byte
of locality it wins.

So the batch's vector-major layout was never an accident to be fixed. It is
the layout the instruction reads for free, and the four-kilobyte stride that
looks wrong on paper is invisible beside a transpose that is not.


### Attention split four ways, as llama.cpp splits it

Attention is what is left: seventeen per cent of a device prompt and 2.1
times behind -- 0.16 s against 0.078. An earlier sitting priced every
overhead inside the kernel and found none, so whatever is left is
structural, and the other runtime's structure was read out of its source
rather than guessed at.

`get_fa_tuning_params_coopmat1` gives this device sixteen query rows by
sixty-four cached positions -- **the same tile this kernel already uses** --
and then `row_split = 4`: four subgroups to a workgroup, two hundred and
fifty-six invocations, where this uses one subgroup of sixty-four. Their
split falls in three different places, and reading `flash_attn_cm1.comp` is
what shows the third one is the clever part:

| phase | what a subgroup takes |
| --- | --- |
| scoring | sixteen of the tile's sixty-four cached positions |
| the softmax | four of the block's sixteen query rows |
| weighing | sixteen of the head's sixty-four components |

Splitting the weighing by *component* rather than by row or by key is what
makes the whole thing cheap: a subgroup weighs every cached position of a
tile against its own slice of the head, so the slice it accumulates is its
own from the first tile to the last and **nothing has to be reduced across
the four**. Only the softmax's rescale crosses, through sixteen floats of
shared memory.

That was built. It computes the same tokens, and it is **fourteen per cent
slower** -- 1.108, 1.099 and 1.092 seconds against 0.968, 0.951 and 0.964,
behind in each of three alternated rounds.

**And it is slower having won every number that was supposed to make it
faster.** The shader report, before against after:

| | one subgroup | four |
| --- | ---: | ---: |
| registers | 128 | **64** |
| subgroups a SIMD | 8 | **16** |
| code | 17588 bytes | **6032** |

Half the registers, twice the occupancy, a third of the code, four times
fewer sequential matrix instructions in a subgroup -- and fourteen per cent
worse. What it buys instead is four real barriers a tile where a workgroup
of one subgroup needs none, and on this part that trade is a loss.

**Occupancy was not the constraint**, which is worth saying plainly because
it is the thing every one of these attempts assumed. This is the third
independent measurement to reach it: a hundred-and-twenty-eight-row product
tile over four subgroups cost thirteen per cent, staging both its operands
cost sixteen, and now attention over four subgroups costs fourteen. Three
kernels, three shapes, one answer -- a workgroup here wants to be one
subgroup, and what it saves by being one is more than what more waves in
flight can win back.

One caution about the instrument, since this run exposed it. `--budget` puts
attention at 0.241 s before the change and 0.236 s after, which is no change
at all, while the run it is part of is a seventh slower. Its spans are
host-side and the device's work runs on past them, so the phase shares say
where work is issued and not where the machine spends its time. The
end-to-end figure is the one to read.


### What attention actually costs

That caution turned out to be worth following up, because every figure this
section had for attention came from the instrument it warns about. So the
kernel was priced the way the matrix product was priced -- by taking pieces
out and reading the whole run:

| what was taken out | 1419-token device prompt |
| --- | ---: |
| nothing | 0.965 s |
| the scores' matrix instructions | 0.956 s |
| the weighing's | 0.967 s |
| the keys, loaded as a constant instead | 0.956 s |
| the values | 0.947 s |
| both | 0.954 s |
| the queries' staging and everything after it | 0.844 s |
| **the whole kernel** | **0.855 s** |

**Attention is 0.111 s, a ninth of a prompt** -- where the instrument said a
sixth. Against llama.cpp's 0.078 s of flash-attention nodes that is **1.4
times behind, not 2.1**, and everything else in the prompt is 0.854 against
their 0.726, which is 1.18. The gap is flatter than this section has been
saying, and the part of it that is attention is a fifth of what is left
rather than a third.

**And nothing inside the kernel is individually attributable.** Removing the
matrix instructions of either product changes nothing. Removing the keys,
the values, or both changes nothing. Staging the queries is free. Only
removing the whole tile loop shows, which is what a loop looks like when its
loads, its arithmetic and its shared-memory traffic all overlap and none of
them is the wall on its own.

That is the same conclusion the four-subgroup split reached from the other
direction, and together they say this kernel is on a plateau: it is not
short of occupancy, not short of arithmetic, and not waiting on any one of
its own operands.

The lesson about the instrument is the transferable part. `--budget` puts
attention at seventeen per cent of a prompt and removal puts it at eleven,
because the instrument times host-side spans and the device runs on past
them. Both numbers in this file are real measurements of different things,
and every ratio quoted against another runtime's per-node timings wants the
second one.


### Where a device prompt goes, every kernel taken out in turn

Having priced attention that way it was worth pricing everything that way,
so each of the eight kernels a prompt runs was voided in turn -- an early
`return` at the top of `main`, which computes nothing and leaves the
dispatch, the descriptors and the barriers where they were. Two rounds each,
medians of three, against a 0.964 s baseline:

| kernel | prompt without it | what it costs |
| --- | ---: | ---: |
| `matrix_product` | 0.322 s | **0.642 s, 67 %** |
| `attention_matrix` | 0.848 s | 0.116 s, 12 % |
| `combine` | 0.886 s | 0.078 s, 8 % |
| `half_batch` | 0.888 s | **0.076 s, 8 %** |
| `norm` | 0.927 s | 0.037 s, 4 % |
| `rotate` | 0.955 s | 0.009 s |
| `place` | 0.958 s | 0.006 s |
| `row_product` | 0.962 s | 0.002 s |

The eight add to 0.966 s against a prompt of 0.964, which is the check that
matters: **nothing is unaccounted for**, so this is the whole of where a
device prompt goes rather than a sample of it.

`half_batch` is the surprise. It is the smallest kernel in the program -- a
binary32 activation copied into half precision, two values a word, no
arithmetic at all -- and it costs as much as attention's keys, values and
both its matrix products put together. It is eight per cent of a prompt for
a format change.

### A layer converts four activations, not seven

It costs that because it ran once for every product. A layer asks for seven
-- the query, the key, the value, the projection back, the two feed-forward
arms and the projection down -- and hands them **four** activations between
them: the query, key and value all read one normalization, and both
feed-forward arms read another. Three of the seven copies were of something
the copy before them had just made.

The engine already knows this. It computes, for the barrier that decides
whether a step must wait, which earlier step's answer this one reads. A
tiled product now remembers what the copy holds and skips the conversion
when the product before it converted the same answer at the same width; a
step of any other kind clears that, because anything else may have written
what the copy holds.

**Worth 3.7 per cent**, ahead in each of three alternated rounds: 0.933,
0.921 and 0.937 seconds against 0.944, 0.969 and 0.969, at the same tokens.
The device reads the long prompt at 1500 tokens a second and the gap to
llama.cpp is 1.17.

A note on how nearly this was measured wrong. The first attempt toggled the
two arms with a `sed` whose pattern matched the one arm and not the other,
so after the first switch every round built the same program; it read 0.960
against 0.949 and looked like a small loss. What caught it was that the
twelve-token run came back identical to the thousandth of a second in both
arms, which two different binaries do not do.

What is left here is the other four sevenths, and the obvious way to take
them is the next section -- which does not work.


### The conversion moved and did not get cheaper

With the copy made once an activation rather than once a product,
`half_batch` still costs 0.047 s. The way to be rid of the rest of it is to
stop it being a kernel: the step that produces an activation writes the
half-precision copy beside the binary32 one, which is what `place.comp`
already does for the cache. Then there is no second pass over the activation
and no dispatch to wait for -- two bytes written instead of four read and
two written.

`norm.comp` produces two of the four activations a layer converts, so it
went first. It writes the half copy beside its own answer, zeroes the
positions the rounding invented, and tells the engine it has done so; the
engine skips the conversion for any product reading that normalization.

**It works and it is level**: 0.926, 0.939 and 0.916 seconds against 0.928,
0.931 and 0.943, at the same tokens. And the diagnostic says why, which is
the part worth keeping:

| | voiding `half_batch` is worth |
| --- | ---: |
| before the normalization wrote the copy | 0.047 s |
| after | 0.011 s |

**The fusing removed thirty-six milliseconds of the conversion's work and
the run did not get thirty-six milliseconds faster**, so that work reappeared
in the normalization. Which is the whole lesson: what a conversion costs is
the writing, and the writing costs the same wherever it is done. What fusing
saves on top -- one read of the activation, one dispatch, one barrier -- is
small enough to be swallowed by making a kernel that was already
store-bound write two arrays instead of one.

That was the wrong shape for it, and the next section is the right one.

### The binary32 nobody reads

The section above has the normalization write the half-precision copy
**beside** its own answer, so the fusing added a write and the work moved
rather than went. Ask a different question -- **who reads the binary32?** --
and for three of the four activations a layer converts the answer is nobody.

A normalization is read by the query, the key and the value; the second one
by both feed-forward arms; the gated middle of the feed-forward by the
projection down. Every one of those is a tile, and a tile's operand is half
precision -- it reads the copy and never the original. So the original is
written and never read.

The engine works that out for itself rather than being told. For each step
it walks the steps after it, and where every step that reads it is a tiled
product and the host keeps none of it, the step writes **only** the copy:
two bytes a value instead of four, into the place the conversion would have
put it, and the conversion does not run at all. Where any reader is not a
tile -- a rotation, a placing, a join, or a product the tile shape does not
take -- nothing changes.

**Worth four per cent of a device prompt**, ahead in each of three
alternated rounds: 0.897, 0.905 and 0.905 seconds against 0.938, 0.940 and
0.944, at the same tokens. The 110-token prompt goes 0.112 to 0.107. The
device reads the long prompt at **1577 tokens a second** and the gap to
llama.cpp is **1.12**.

The difference from the attempt above is worth stating plainly, because the
two look alike and only one of them works. Writing the copy **as well** adds
a store and removes a pass; on a part where everything is at the bus those
cancel. Writing the copy **instead** removes a store and a pass and adds
nothing. The question that separates them is not "can this kernel write half
precision" but "does anything want the binary32", and the engine already had
what it needed to answer it -- the same back-references it uses to decide
where a barrier goes.

### And the fourth, which is why the kernel is dead

The attention blend is the fourth, read by the projection after it and by
nothing else. The same rule applies, and the engine now applies it -- but
only where the tile kernel is the one that will attend, because the scalar
one writes its blend the way it always has and the engine already picks
between them by that test.

**It is level**: 0.886, 0.900 and 0.905 seconds against 0.901, 0.904 and
0.901, ahead in two rounds of three. Predicted at rather less than one per
cent and measured at rather less than that, which is what a kernel already
found to have no attributable piece inside it does with one more store
removed.

It is kept anyway, and for a reason that is not the time. **With all four
gone, the conversion kernel does not run at all.** Voiding `half_batch`
entirely -- replacing its body with an immediate return -- leaves the
1419-token prompt at 0.885 seconds and the 110-token one at 0.105, and both
still answer `1a26d24d33b8957b` and `cbf29ce484222325`. A kernel whose
absence changes neither the answers nor the time is a kernel that is not
being dispatched.

It stays in the program, because the single-product path still uses it and
so does any sequence whose producer feeds something that is not a tile. But
on the path this file measures, a whole pass over every activation of every
layer has gone.

**And one thing nearly went wrong that is worth writing down.** The first
reading of this change was taken from a binary that did not contain it. The
build helper this work uses swallowed its own compiler output, so an Ada
error -- an arithmetic expression on `Interfaces.C.unsigned` that needed a
conversion -- failed the build silently and the measurement ran the previous
executable. It read 0.893 seconds and the digests held, which is exactly
what a correct change looks like. What caught it was a second script that
reported the failure instead of hiding it. The helper prints its errors now;
a measurement harness that cannot fail loudly is a harness that will publish
somebody's last build.


### Where a device prompt goes now

With the conversion gone the budget was taken again, each kernel voided in
turn, two rounds each against an 0.897-second prompt:

| kernel | costs | share |
| --- | ---: | ---: |
| `matrix_product` | 0.635 s | **71 %** |
| `attention_matrix` | 0.106 s | 12 % |
| `combine` | 0.071 s | 8 % |
| `norm` | 0.051 s | 6 % |
| `rotate` | 0.017 s | 2 % |
| `half_batch` | **-0.003 s** | -- |
| `place` | -0.004 s | -- |

The five that cost anything add to 0.880 s of 0.897, and the conversion
kernel measures **below nothing**, which is what a kernel reads when it is
compiled, bound, and never dispatched.

### The normalization's second read, which is free

That leaves the normalization at six per cent, and it walks its row twice --
once to sum the squares, once to scale by the root of their mean. A
workgroup is two hundred and fifty-six lanes and a row is two thousand and
forty-eight values, so **sixteen values a lane**: the whole row fits in
registers, and the second walk need not happen. Kept in an array indexed by
a literal in an unrolled loop, so that it is registers and not scratch --
the shader report confirms scratch stays at zero -- with the tail of a row
too wide to hold read twice as before.

It is bit-exact and it is **level, if anything behind**: 0.899, 0.906 and
0.885 seconds against 0.883, 0.895 and 0.902, ahead in one round of three.

The report says why, and it is the second half of the same sentence:

| | registers | subgroups a SIMD |
| --- | ---: | ---: |
| the row read twice | 24 | **32** |
| the row kept | 48 | 20 |

**A third of the occupancy for a read that was never going to memory.** A
row is eight kilobytes and the kernel that wrote it ran a moment before, so
the second read is a cache hit; what it costs is an instruction, and what
holding it costs is twenty-four registers and twelve waves. Not kept.

That is the fourth measurement in this file to find that occupancy is what
this part is short of, after a taller product tile, staged operands and a
four-way attention -- and the first where the change removed work rather
than adding it.


### The workers are not spinning for nothing

A profile of the processor generating puts 73.5 per cent in the eight-bit
row kernel and **12.1 per cent in the worker loop** -- and annotating that
loop shows ninety-five per cent of its samples in four instructions: a load
of a shared counter, a compare, a `pause`, a decrement. Seven cores waiting,
a hundred and fifty-four times a token. It reads like pure overhead. It is
not, and three measurements say so.

**The spin earns its keep.** Its budget was swept, medians of three, sixty-
four generated tokens on the processor:

| spin budget | generating |
| --- | ---: |
| **20 000** | **1.90 s** |
| 4 000 | 1.93 s |
| 400 | 2.04 s |
| 0 | 2.07 s |

Taking it out costs nine per cent. What the workers are avoiding is the
kernel putting them to sleep and waking them again, and at a hundred and
fifty-four jobs a token that wake is worth more than the core it burns.

**The false sharing is not real either.** `Ticket` and `Left` are adjacent
fields of one record, so every worker's decrement of `Left` as it finishes
takes the line away from the six still reading `Ticket` for the next job --
which is exactly the shape the annotation suggests. Given each its own cache
line, generating reads 1.911 seconds against 1.907 and the long prompt 6.085
against 5.972. Level, and slightly worse. Not kept.

**What the workers are waiting for is the bus**, and a later sitting put a
number on it. One worker generates in 4.575 s and moves 16 GB/s of this
model; three do it in 1.894 s and 40 GB/s; seven do it in 1.893 s and add
nothing. One worker also issues 3.46 instructions a cycle, which is a core
spending its time on arithmetic rather than waiting -- so the kernel is
issue-bound alone and bus-bound in company, and the corner is at three. The
worker count swept over the same run:

| workers | generating |
| --- | ---: |
| **3** | **1.875 s** |
| 4 | 1.911 s |
| 5 | 1.916 s |
| 6 | 1.913 s |
| 7 | 1.927 s |
| 8 | 1.918 s |

Flat from three to eight, and three is the fastest of them. Generating reads
every weight once and does one multiply with each, and **three cores of this
part saturate whatever carries them**; the other four have nothing to do,
and the spin is what makes having them cheap rather than what makes them
expensive.

The prompt is a different program on the same cores, and it scales: 25.142
seconds at one worker, 9.207 at two, 7.677 at three, 6.841, 6.350 and 5.944
at seven. A batch shares one reading of the weights between five hundred and
twelve tokens, so it is arithmetic where generating is traffic.

**So the processor's two gaps are two different problems.** Generating is
1.16 times behind at 39.7 gigabytes a second against llama.cpp's 46, on a
wall both of them are near. The prompt is 1.11 times behind with real
scaling still in it, and that is where the row kernel is worth attacking.

### Five hundred and twelve bits, on a part that has none

A profile of the processor reading the 1419-token prompt puts 62.3 per cent
in the eight-bit strip kernel and **14.1 per cent in attention** --
`head_scores` at 6.5, `blend_run` at 5.6, `blend_exact` at 1.9. That is the
largest thing on that side which is not the hand-written strip kernel, and
it is larger than the gap it sits in: the whole processor prompt is 1.11
times behind.

**Nothing in this library uses a five-hundred-and-twelve-bit lane.** Every
hand-written vector kernel here is `ymm` -- two hundred and fifty-six bits
-- on a processor that has `zmm`, and the three files the project file gives
`-march=x86-64-v3` and `-v4` to are quantization units, not these.

So the blending run was widened. It weighs a whole head of values against
one score -- eight `vfmadd231ps` a position, which carry sixty-five per cent
of that kernel's samples -- and four of them in `zmm` do the same work. It
is **bit-exact**, and that is not luck: every component of the sum
accumulates the same terms in the same order, and only how many of them a
register holds has changed. A dot product would not be, because its lanes
are added to one another at the end and their number decides the
association.

It is **slower**: 6.176, 6.266 and 6.166 seconds against 6.049, 6.086 and
6.199, behind in two rounds of three, with `1a26d24d33b8957b` throughout.

**Zen 4 executes a five-hundred-and-twelve-bit instruction on
two-hundred-and-fifty-six-bit hardware**, two passes to the instruction, so
halving the instruction count leaves the cycle count where it was and adds
the transitions. Which is why the byte dot product in the quantization units
*is* worth compiling for `x86-64-v4` and this is not: that is a new
instruction doing four multiplies in a lane, and this is only a wider lane.

And `head_scores` would not have gone the same way even if the lanes had
paid. Its annotation is not led by its multiply-adds but by six `vhaddps` --
the horizontal reduction that ends every dot product. Widening the lanes
makes that reduction longer, and it would move every digest this file
publishes for the processor.

### What is left in the two elementwise kernels

The device's combining step is eight per cent of a prompt, and it is
**entirely traffic**. Replacing its gated unit -- the sigmoid-weighted or
Gaussian function on one arm -- with a plain addition costs nothing: 0.890
and 0.896 seconds against 0.892 and 0.895, where taking the whole kernel out
reads 0.823. Two arms in and one out is what it costs, and the only lever
left is fewer bytes: the two feed-forward arms exchanging half precision
rather than binary32, about twenty-three megabytes a layer. That was built,
and the section below is what it cost.

### The arms in half precision -- and a control that was wrong

The two arms of a gated feed-forward are read by the step that combines them
and by nothing else, and that step can read half precision. So the products
that make them can write half precision -- the same rule as `### The binary32
nobody reads`, one step further: a product whose only reader is a combining
step that reads halves need not write binary32 either.

**It is worth four and a half per cent**, and the way there is worth more
than the number.

The first build had the buffer hold two regions, one for each arm.
Alternated, it read 0.845 and 0.847 seconds against 0.904 and 0.896 -- and
**the answers changed every run**: `d2c51a052ab789a2`, `e7fae034fbfe106e`,
and three others besides. That is not a wrong answer, it is a race, and it
was caught only because the measuring tool prints a digest for every run
rather than a pass or a fail.

The race is the layout. Two arms need two places, but **three answers are
live at once**: the normalization both arms read is still sitting in the
first region when the first arm writes over it, and whether the second arm
reads it before or after is timing. Three regions, and the race is gone --
the same digest in five runs.

**And then a control said the three regions cost twenty-two per cent, and
the control was wrong.** Two readings, taken at `--repeats 1` with no test
of what else the machine was doing, put a three-region allocation at 1.102
and 1.106 seconds against 0.901. On that evidence the whole change was
thrown away and written up as refused.

It does not reproduce. The allocation swept over five sizes, medians of
three, two rounds, with the arms left in binary32 throughout:

| half-precision buffer | 1419-token device prompt |
| --- | ---: |
| one region | 0.893, 0.894 s |
| two | 0.882, 0.894 s |
| three | 0.891, 0.881 s |
| four | 0.894, 0.910 s |
| six | 0.890, 0.894 s |

Flat. The size of that allocation costs nothing, and the twenty-two per cent
was the machine and not the code.

So all four cells were measured together, alternated, each waiting for the
machine to fall below 1.05:

| | 1419-token device prompt | tokens |
| --- | ---: | --- |
| binary32 arms, one region | 0.881, 0.891 s | as published |
| binary32 arms, three regions | 0.893, 0.885 s | as published |
| **halved arms, two regions** | 0.845, 0.847 s | **differs every run** |
| **halved arms, three regions** | **0.851, 0.842 s** | **as published** |

The three-region form is as fast as the racing one and gives the same
tokens. It is kept. The device reads the long prompt at **1699 tokens a
second** and the gap to llama.cpp is **1.07**.

**The same tokens, and not by accident.** The digest is of the generated
text, and the arms crossing in half precision moves the logits in the last
bits without moving any argmax -- which is what the sweep is for, and it
reads 28344 sequences across nine architectures and fifteen formats with
none outside tolerance. That is also why the racing version's digests were
evidence of a race and not of rounding: rounding does not change the text,
and garbage does.

**Three readings taken at `--repeats 1` have now pointed the wrong way in
this section**, and this one nearly cost a change that was correct and worth
four and a half per cent. The rule this file has had for months -- alternate
the arms, take medians of three, wait for the machine -- is not a
formality, and a control deserves it as much as a candidate does.

### The two loops attention was paying for

A profile of the 1419-token prompt on the processor put `head_scores` at
**6.7 per cent** of it -- the largest thing on that side after the strip
kernel and the value blend. The list this section works from said the cost
was the horizontal fold at the end of it, eight separate reductions where one
transposed fold would do. That was wrong: the transposed fold has been there
since `### The score half of attention`, and the six `vhaddps` it costs are
about seven per cent of the kernel.

What the samples actually said is that **forty-six per cent of them were not
in the run at all**. They were in the prologue: ten arguments, several of
them arriving on the stack, six reach comparisons, an index check on each of
the three arrays every time an address was taken, and a frame. Against
sixty-four multiply-adds.

The ratio is that bad because of how the caller had been arranged, and the
arrangement is right. `### Attention, in shares of the heads` walks a block of
eight key positions and every head across that block before the next one, so
the eight key rows stay in the nearest cache while the heads read them. But
that makes the call **one block of eight keys against one head**, which is
exactly one turn of the loop inside the kernel. There was nothing for the
prologue to amortize against.

So both loops moved into the kernel. `Head_Scores_Across` takes the head
range and the whole key run, proves the reach once for the widest head and
the last key -- the footing the row kernels and the blend already stand on --
and then issues the run in place, block outside and head inside, which is the
order the caller had. Nothing else changed: the run is the same string of
instructions, issued from a constant both procedures share, so it is the same
arithmetic in the same order and the scores are bit for bit what they were.
`Head_Scores` is still there and still does one head, which is what the
tail of a run shorter than eight keys and every host without the lanes takes.

Measured by counting rather than by timing, because the effect is smaller
than a wall clock resolves on this host:

| | instructions | cycles |
| --- | ---: | ---: |
| a head at a time | 1032.5 and 1032.4 e9 | 380.1 and 378.7 e9 |
| the range at once | 991.4 and 991.3 e9 | 376.0 and 370.7 e9 |

**Four per cent of every instruction the prompt executes**, and the counts
reproduce to five figures across two alternated rounds. The cycles fall by
1.6 per cent, which is the honest number: what was removed was cheap work --
compares and spills that were issuing beside the multiply-adds rather than
instead of them. Nine wall-clock runs alternated over three rounds read
6.057 s against 5.952, which is 1.7 per cent and inside the spread on its own.
Three measurements, one direction.

The instruction count is what settles it and the wall clock is not, which is
the reverse of the usual advice on this page and worth saying plainly: a
change that removes four per cent of the instructions and 1.6 per cent of the
cycles is real whether or not a 6-second run resolves it, and a change that
moves a 6-second run by 1.7 per cent and moves neither counter is not.

Inside the kernel the split went from 39 per cent multiply-adds to 51, and
the 46 per cent of prologue to 30. What is left of the 30 is the address
arithmetic a head still needs and the fold, and the fold is not going
anywhere: the run is at both walls at once. Sixty-four multiply-adds and
sixty-four loads to a block, and this part does two of each a cycle, so the
loads and the arithmetic finish together and neither can be traded for the
other. Holding two query positions against one block of keys would halve the
loads, which is exactly the resource that is not scarce.


### The generating kernel has no slack, and four ways of finding that out

The list this came from said the generating row product copies and biases
every weight before it multiplies it, and put the cost at four instructions
against one. It was reading the wrong kernel. **A generated token does not go
through the four-row insertion at all**, and the way to be sure is to delete
its staging loop and count: 81216 million instructions against 81181, four
hundredths of a per cent. A path that costs nothing to remove is a path
nothing runs.

What a token runs is `Rows_Singly`, and it is already what the plan wanted:
the weights are read where the file holds them, the accumulator lives in a
register from a row's first block to its last, and the loop is eleven
instructions for every thirty-two multiply-adds.

**This section said next that the generating side is not waiting for the bus,
and that was wrong.** The figure it rested on -- 81.2 billion instructions in
35.5 billion cycles, 2.29 a cycle -- is an average over cycles that include
seven workers spinning in a four-instruction loop waiting for the next job.
That loop issues at nearly four a cycle and says nothing about the kernel.

Asked properly, by worker count, the answer is the one this page had before:

| workers | generating | of this model |
| --- | ---: | ---: |
| 1 | 4.575 s | 16 GB/s |
| 3 | 1.894 s | 40 GB/s |
| 7 | 1.893 s | 40 GB/s |

**One worker issues 3.46 instructions a cycle and moves 16 GB/s; three reach
40 and seven add nothing.** So the kernel is issue-bound on one core and
bus-bound on three, and the published configuration is well past the corner.
That is what the four measurements below are really measuring, and it is why
they read the way they do.

Four changes were then measured against that kernel. **None is kept**, and
the four together say the same thing.

**The block scale, decoded by the hardware.** `Scale_At` builds a sixteen-bit
number out of two byte loads, a shift and an or before `vcvtph2ps` can start
-- six instructions, in a function every block of every row calls.
`vpinsrw` takes the two bytes at the address directly, which is three.

| | instructions, 64 tokens |
| --- | ---: |
| two byte loads, a shift and an or | 81220, 81274, 81204 e6 |
| the pair loaded by the insertion | 74404, 74411, 74396 e6 |

**Eight and four tenths per cent of every instruction a generated token
executes**, reproducing to five figures, and bit for bit the same tokens --
it is the same convert of the same two bytes. It is also not faster: Q8_0
cycles read 35.50 against 34.77 in one sitting and 35.61 against 35.85 in the
next, and **Q4_K generation is plainly worse** -- 9.86 billion cycles against
14.90, and 0.40 s generating against 0.69. The two byte loads issue beside
everything around them; `vpinsrw` is a load and an insert into one register
and the convert waits behind both. Fewer instructions on a longer chain.

**The four kilobytes of `rep stosq`.** `Row_Scale` has room for a thousand
blocks and is zeroed on entry to set the hundred and seventy-six a row
overwrites, and the instruction is among the ten hottest in a profile of a
generated token. Alternated, three rounds: 1.893 s generating against 1.870,
Q4_K level. One and two tenths per cent, under the floor.

**The bias correction as an integer rather than a sum.** The insertion's
unsigned operand is the weight byte with its sign bit flipped, and what that
adds comes back out as a running binary64 sum over every block of every row
-- seven instructions a block, and removing it outright takes twelve per cent
off the whole run. It need not be a sum: the correction is an integer smaller
than a million, it depends on the activation block and not on the row, and
the lane the multiply-add accumulates into can start at it rather than at
zero. That is a load where the insertion had a `vpxor`.

| | instructions | cycles |
| --- | ---: | ---: |
| base | 81220, 81274, 81204 e6 | 35499, 36155, 35264 e6 |
| the pair loaded and the correction folded in | 66191, 66226, 66165 e6 | 35432, 35420, 34861 e6 |

**Eighteen and a half per cent of the instructions and nothing on the
clock** -- worse, by one and nine tenths per cent, than the pair-loaded arm
on its own. The `vpxor` it replaces is a zeroing idiom, which occupies no
execution unit at all, and the load that replaces it joins the chain the
multiply-add is already waiting on. It moves the answers too --
`3740ed87be385f2d` against `3248ac1bb7011de0`, with the suite at 294 of 294
-- because the correction becomes exact where it was a rounded sum. Being
more nearly right for nothing is not a reason to change published digests.

So nothing is kept here and no figure moves. What is worth keeping is the
shape of the result: **three of the four cut instructions by four to eighteen
per cent and not one of them cut cycles at seven workers**, because at seven
workers the bus is the wall and instructions are free. The next section takes
the first of them and puts it where the wall is not.


### The same three instructions, in the one kernel that can spend them

The refusal above is not the whole of it. Decoding a block's scale with
`vpinsrw` rather than two byte loads, a shift and an or takes six
instructions to three and eight and four tenths per cent off everything a
generated token executes -- and put in `Scale_At`, where every format takes
it, it costs Q4_K generation twenty-one per cent and a Q4_K prompt fourteen.
Three instructions on a longer chain: `vpinsrw` is a load and an insert into
one register and the convert waits behind both, where two byte loads issue
beside whatever else is in flight.

**But the eight-bit generating kernel has something to hide that behind and
the k-quant one does not**, and the two do not share a code path.
`Rows_Singly` is Q8_0 and nothing else -- it is the kernel a generated token
runs, and the block width is written into its insertion as a literal 34. So
the pair-loading decode goes there and nowhere else, as `Scale_Pair_At`,
with the measurement that says why written above it.

Alternated, three rounds, medians, and every reading of one arm below every
reading of the other:

| | one worker | seven workers |
| --- | ---: | ---: |
| two byte loads, a shift and an or | 4.594 s | 1.891 s |
| the pair in one instruction | **4.410 s** | **1.864 s** |

**Four per cent at one worker and 1.4 at seven**, and the difference between
those two numbers is the whole lesson of the section above: at one worker the
core is issuing as fast as it can and instructions are what it costs; at
seven the bus is the wall and most of what is saved is given back. Q4_K is
untouched -- it never enters this kernel -- and reads 0.400 s against 0.405,
which is the noise. The tokens are identical: it is the same convert of the
same two bytes, and `3248ac1bb7011de0` on both sides.

Generating goes from 33.85 to 34.34 tokens a second and the gap to llama.cpp
on that row from 1.16 to 1.14.

`Blend_Run` was measured in the same sitting and is not kept. Its inner loop
is eight fused multiply-adds behind a broadcast, two pointer advances, a
decrement and a branch -- four instructions of scaffolding for eight of
arithmetic, at 5.7 per cent of a processor prompt. Two positions a turn
shares one set of four and turns the second pointer advance into a `lea` of
twice the stride, which is twenty-two instructions where two turns were
twenty-six. It is bit for bit the same answer, and it is worth **0.38 per
cent of the instructions a prompt executes and nothing at all on the clock**
-- 125.32 billion cycles against 125.32. The arithmetic said so before the
measurement did: fifteen per cent of a kernel that is 5.7 per cent of the run
is under a per cent of the run, and this machine gives back more than half of
any instruction cut. Twenty-five lines of insertion and a branch for a third
of a per cent is not a trade worth making.


### Three items priced, and one premise that was wrong

**The device prompt has no fixed cost.** The 110-token and 1419-token device
prompts do not lie on a line through the origin -- 0.104 s and 0.850 -- and
the obvious reading is that a prompt pays something once, about thirty-five
milliseconds of it, whatever its length. Voided every compute shader at once,
the 110-token prompt reads **0.008 s**. Ninety-two per cent of it is in the
shaders and eight milliseconds is everything else: the host, the queue, the
submissions and the readback together. There is nothing there to remove.

Where the short prompt's gap actually is: `matrix_product` costs 0.088 s of
the 0.104 at 110 tokens and 0.604 of the 0.850 at 1419 -- **0.80 milliseconds
a token against 0.425**. The tile product is one and nine tenths times as
expensive per token at the shorter length, and that is the whole of 1.51
against 1.11. A 110-column batch gives each dispatch about sixty-four
workgroups on twelve compute units, where a 1419-token one gives twelve
times that.

It is not the batch, which was the first thing asked. The long prompt in one
batch of 1536 reads 0.845 s against 0.831 in three of 512; at 256 it is
0.852, at 128 0.919, at 64 1.549. The short prompt is one batch at every size
down to 128 and reads 0.102 to 0.103 throughout.

**And the measurement method has a limit, which this found.** Voiding one
kernel at a time in the 110-token prompt:

| voided | reads | voided | reads |
| --- | ---: | --- | ---: |
| nothing | 0.104 s | rotate + place | 0.075 s |
| `matrix_product` | 0.016 s | + `norm` | 0.072 s |
| `attention_matrix` | 0.072 s | the five small together | 0.069 s |
| `combine` | 0.073 s | all six | **0.008 s** |
| `norm` | 0.071 s | | |
| `rotate` | 0.074 s | | |
| `place` | 0.076 s | | |

Each of the five small kernels appears to cost about thirty-two milliseconds
on its own, and all five together cost thirty-five. **That cannot be true of
any of them** -- `place` costs nothing at all at 1419 tokens and appears here
to cost twenty-eight milliseconds. At a prompt this short, removing one
kernel stops measuring that kernel, and only the two ends of the table mean
anything. Every earlier budget on this page was taken on the long prompt,
where the same kernels do add up, and that is the length to take it at.

**The strip kernel's scale table: three and a half per cent, and no way to
it.** The table holds the weight scale times the activation scale, one number
for every row, block and vector of a panel, and the insertion reads it as the
broadcast operand of its fused multiply-add. Removing the multiply and the
load that feeds it -- a build that answers wrongly, so a ceiling and not a
change -- reads 5.526, 5.686 and 5.650 seconds against 5.842, 5.925 and
5.853, and 320.5 billion instructions against 330.0. Both routes to that
ceiling fail:

- Reading the eight activation scales once for a block rather than once for
  each of the panel's four rows is bit for bit the same and **slower**: 6.083
  s against 5.929, and a Q4_K prompt 0.621 against 0.578. GNAT was already
  hoisting it; materializing the eight as an aggregate is what the change
  actually added.
- Moving the multiply into the insertion removes the table entirely -- scale
  the converted dot by the weight scale, and let the multiply-add broadcast
  the activation scale straight out of the per-call table. But the insertion
  holds two rows and eight vectors, so that is **sixteen extra `vmulps` a
  block against the three or four the table costs**, and it would move every
  processor digest besides: `(W × V) · dot` rounds the scales together where
  `V · (W · dot)` rounds the scaled dot. Four times the work to be less
  exact.

**The two small prompt kernels are not overheads.** `quantize_blocks` reads
2.1 per cent of a prompt in a profile; removing it takes the prompt from
5.888 s to **6.734**, because without a quantized activation the integer path
refuses and the floating-point one runs instead. It is a purchase, not a
cost. `mat_mul_range_packed` reads 3.4 per cent; removing it takes the prompt
to **1.541 s**, because it is the procedure that dispatches the whole product
rather than a kernel beside it. Neither was ever three per cent of anything.


### The feed-forward's activation ran on one core

A profile sorted by thread rather than by symbol says something a profile
sorted by symbol cannot. `silu` and `multiply` -- the feed-forward's gate
unit and the multiply by the up projection -- appear on the main task and on
**no worker at all**. Every other hot symbol appears on all eight; these two
appear on one.

They are 1.18 and 0.59 per cent of the samples collected, and at 35.66
seconds of processor time in 5.93 seconds of wall that is about **0.63
seconds of a 5.93-second prompt** spent on a machine with eight cores, using
one. A batch is five hundred and twelve positions and each is five thousand
six hundred and thirty-two numbers wide; twenty-two layers of that is the
largest loop in the program that was never shared out.

Three loops over a batch already went to the pool -- the normalization on the
way in, and the two residual joins -- and the comment above them names the
rotation as the fourth and says why it stays. It does not name the fifth,
which is this one, and which is bigger than the three together.

It is elementwise like the others: a position's slice of the gate buffer is
read and written by that position and by nothing else, so a share of the
batch is the same arithmetic in the same order and the answer is bit for bit
what one task produced. `Feed_Share` is the same shape as `Norm_Share` beside
it, with one field for whether there is an up projection to multiply in or
only the unit and the bias before it.

Alternated, three rounds, medians, every reading of one arm below every
reading of the other:

| | 1419-token prompt | 110-token prompt |
| --- | ---: | ---: |
| on one core | 5.930 s | 0.468 s |
| shared out | **5.355 s** | **0.448 s** |

**Nine and seven tenths per cent of the long prompt**, `1a26d24d33b8957b`
both ways, and the device row untouched -- 0.854, 0.875, 0.896 against 0.854,
0.864, 0.889 -- because a device takes the whole gated block at once and
never runs this loop.

**The processor's long prompt is now level with llama.cpp**: 269.1 tokens a
second against 269.8, a gap of **1.00**, where it was 1.16 before this and
2.7 when this section began. The 110-token row went 1.39 to 1.08 with it.

What is worth taking from the method is the sort order. Every profile in this
file before this one was sorted by symbol, and by symbol these two kernels
read 1.8 per cent of a prompt and look like rounding. Sorted by thread they
are ten per cent of the wall and the only two entries in the list with no
workers under them. **A symbol's share of the samples is not its share of the
time when the samples are not evenly spread across the threads** -- and the
whole point of a worker pool is that they are not.


### Two accumulators, seventeen per cent, and the guarantee that stopped it

The generating side reads 1.17 gigabytes a token and gets 40 GB/s where
llama.cpp gets 46, so the first suspect was the page tables: 1.17 gigabytes
through four-kilobyte pages is two hundred and eighty-five thousand of them,
and a walk apiece would explain a good deal. Counted, it does not. **11.1
million second-level TLB misses over sixty-four tokens** -- a hundred and
seventy-three thousand a token, which at twenty-five cycles each is **eight
tenths of one per cent** of the run.

What is the wall, below three workers, is the accumulator. `Rows_Singly`
keeps one binary32 accumulator for a row and adds each block into it with a
fused multiply-add, so consecutive blocks form a dependent chain four cycles
long apiece. Two accumulators -- even blocks into one, odd into the other,
folded once at the end -- read:

| workers | one accumulator | two |
| --- | ---: | ---: |
| 1 | 4.388 s | **3.657 s** |
| 2 | 1.937 s | **1.855 s** |
| 3 | 1.854 s | **1.801 s** |
| 5 | 1.863 s | **1.829 s** |
| 7 | 1.878 s | **1.856 s** |

**Seventeen per cent at one worker and one at seven**, and the shape is the
one every instruction cut on this side has had: the chain is the wall while
one core is running and the bus is the wall once three are.

**It is refused, and not for the speed.** It moves two digests -- the
twelve-token run from `33f48397f89839f6` to `5abff916f9d83ca6` and the
sixty-four-token one from `3248ac1bb7011de0` to `448c2ed68ec342ee` -- and
both of those are answers this program already gives elsewhere: they are what
`--arith f32` says and what the device says. The two-accumulator sum is
*nearer* the exact one, not further from it.

But it moves only the single-vector kernel, and the batch kernel cannot
follow: `Rows_By_Strips` already holds eighteen accumulators in `ymm8` to
`ymm25`, one for every row and vector of its tile, and doubling them does not
fit in thirty-two registers. The two then sum a row's blocks in different
orders -- **and drafting depends on their agreeing.** A draft proposes a
token at a time and the model checks several at once, so one answer comes
from the strip kernel and the other from the single-vector one. In the
sitting taken with the change in, the drafted twelve-token run printed
`33f48397f89839f6` and the undrafted one `5abff916f9d83ca6`: the guarantee
`### Drafting` opens with, false in a published figure.

**Nothing caught it.** The suite passed 294 of 294, the sweep read 28344
sequences with none outside tolerance, and the test that runs a prompt with
and without a draft did not diverge on its own model. What caught it was the
sitting's own table, printing the two digests one line apart -- a person
reading rather than a check firing, which is the second time on this page
that has been the case.

So the constraint is worth stating, because nothing enforces it and it is not
obvious from either kernel: **`Rows_Singly` and `Rows_By_Strips` must sum a
row's blocks in the same order and the same precision.** They do today
because both were written with one accumulator to a row, and either one
changing alone breaks drafting.


### A lane is not the unit, and the prefetcher was already there

Two more attempts on the two gaps that are left, and both are level.

**The prefetch.** After the page tables and the accumulator, the remaining
guess about the generating side was that the hardware prefetcher cannot keep
eight workers fed and a `prefetcht0` in the row loop would. One instruction
added to an eleven-instruction loop, at two distances:

| | generating |
| --- | ---: |
| as it is | 1.876 s |
| 256 bytes ahead | 1.870 s |
| 512 bytes ahead | 1.871 s |

Level at both, and bit for bit the same answer. A worker walks contiguous
rows; the prefetcher has them already. So the generating gap -- 40 GB/s
against llama.cpp's 46 for identical bytes -- is now three things it is
**not**: not the page tables, at eight tenths of one per cent; not the
accumulator chain, worth seventeen per cent at one worker and one at seven
and unavailable anyway; not the prefetcher.

**The device's combining step, and a piece of reasoning that was wrong.** It
costs seventy-one milliseconds of a 1419-token device prompt and moves about
1.06 gigabytes, which is sixteen gigabytes a second on a part that does
several times that. An invocation read two halves and wrote one -- two bytes
a lane -- and that looked like the reason. Four values to an invocation,
through `f16vec4` and `vec4` aliases of the same bindings with a guard for a
shape that would not line up, and a dispatch a quarter the size:

| | 1419-token device prompt |
| --- | ---: |
| one value an invocation | 0.845 s |
| four | 0.844 s |

**Level**, and the generating row and the short prompt level with it.

The mistake was taking a lane's access width as the unit. A wave is
sixty-four lanes reading consecutive halves, which is a hundred and
twenty-eight contiguous bytes coalesced into two cache lines *whatever the
per-lane width is*. Widening the lane makes fewer, larger requests for
exactly the same bytes, and a kernel with no reuse and nothing to hide behind
them gains nothing. Coalescing happens across the lanes of a wave, not within
a lane, and this page had it the other way round for the length of one
experiment.

Nor is it the unit. Replacing the whole activation with an addition -- a
build that answers wrongly, so a ceiling and not a change -- reads 0.837 s
against 0.844: **seven milliseconds of the seventy-one**, a tenth.

Which leaves the rate unexplained, and it is worth recording as a bound
rather than a bug: `norm` costs sixty-nine milliseconds and moves about the
same bytes, so the two elementwise kernels sit at the same rate. Whatever
holds them is shared between them, is not their arithmetic, and is not how
wide a lane reads.

**And it was a bug after all**, which `### Where the device's gap is now`
below settles: the normalization was running in binary64 on a part that does
double precision at a sixteenth rate, and llama.cpp's does the same fold in
binary32.

**The sixteen is also wrong, which the section below corrects**: it counted
one dispatch of the combining kernel a layer where there are three -- the
gated middle and the two residual joins, which are the same two arms in and
one out on a narrower width and go through the same shader. Counted properly
the rate is nearer twenty-eight gigabytes a second. Still under half of what
this part should do, and no longer the sixth that made it look urgent.


### The memory kind, and the number the item was ranked on

The section above leaves the device's two elementwise kernels running slowly
with the access width and the arithmetic both ruled out, and names the memory
they live in as the thing never tested. This machine offers eleven kinds over
two heaps, and three of them matter:

| | properties | heap |
| --- | --- | --- |
| type 3 | device-local, host-visible, host-coherent | 1, the device's own |
| type 5 | host-visible, host-coherent, host-cached | 0, not the device's own |
| type 0 | device-local and nothing else | 1 |

The engine allocates uploads and scratch out of type 3, results out of type 5
-- deliberately, because the processor reads a result far more often than the
device does -- and **nothing at all out of type 0.** The argument for trying
it: host-coherent is a promise that a processor write is seen without anyone
being told, and the way a driver keeps that promise is to stop the device
caching the memory. A scratch buffer nothing maps would then be read through
to memory on every access, for a guarantee it does not need.

The half-precision buffer is the one to test -- three regions of it, written
and read by the tile product and the combining step, and nothing maps it.
Given a kind of its own, through an `Own` field on the engine beside `Upload`
and `Download`:

| | 1419-token prompt | 64 generated |
| --- | ---: | ---: |
| type 3, as it is | 0.855 s | 1.236 s |
| type 0, its own | 0.847 s | 1.235 s |

**Nine tenths of one per cent and nothing**, which is the noise. Either the
driver is not giving up the cache for coherence, or these kernels were never
waiting on it. Not kept.

**And the item was ranked on a number that is wrong.** The sixteen gigabytes
a second counted one dispatch of the combining kernel a layer. There are
three: the gated middle, and the two residual joins, which are the same two
arms in and one out on a narrower width and go through the same shader.
Counted properly a prompt moves about two gigabytes through it rather than
one, and the rate is nearer twenty-eight gigabytes a second -- still under
half of what this part should do, but not the sixth that put it at the top of
a list.

So four things now do not explain it, and the fourth is that it was never as
far off as it looked.


### A share a worker, decided before any of them started

The list said to stop guessing at the generating gap and read what llama.cpp
actually does. Its Q8_0 dot product turns out to be the same kernel as this
one -- one accumulator, eight lanes, a fused multiply-add a block, `_mm256_
sign_epi8` where this has the bias trick -- and it does not repack Q8_0
weights either. The kernels are not the difference.

**The scheduling is.** `ggml_compute_forward_mul_mat` cuts the output rows
into chunks of sixteen and hands them out through an atomic counter, falling
back to a fixed cut only when there would be fewer than four chunks a thread.
This program cut a product into one contiguous range for every worker, worked
out before any of them started.

That is right when the workers run at the same speed. On a fifteen-watt part
sharing its boost between eight cores, with an operating system on them, they
do not -- and a job is not done until its slowest range is. Every worker that
finished early sat in the spin loop `### The workers are not spinning for
nothing` measures, waiting for one that had not.

So the pool takes its next tile from an atomic counter instead. The grid is
anchored at row zero and a tile is never split, which is what keeps the answer
bit for bit what a fixed cut produced -- the tile a row falls in does not
depend on who computes it, and the note above `Partition` explains why that
mattered enough to be written down once already.

Alternated, three rounds, medians, every reading of one arm below every
reading of the other:

| | 1419-token prompt | 110-token prompt | 64 generated |
| --- | ---: | ---: | ---: |
| a range a worker | 5.412 s | 0.406 s | 1.916 s |
| a tile at a time | **4.796 s** | **0.370 s** | **1.893 s** |

**Eleven per cent of the long prompt, nine of the short one and one of a
generated token** -- the shapes with the most tiles to hand out gain the
most, and a generated token, whose products are one vector wide and already
memory-bound, gains least.

Every digest holds, at one worker, three, four and seven: `33f48397f89839f6`
for twelve tokens whatever the worker count, which is the invariant the fixed
cut was arranged around and the one this had to keep.

**The processor now reads the long prompt faster than llama.cpp does** --
292.3 tokens a second against 268.8, which is 1.09 times -- where it was
level one commit ago, 1.16 behind two ago and 2.7 behind when this work
began. The share-scaling curve moved with it: seven workers against one reads
5.03x where the sitting before read 4.11x.

The tail of this is worth naming. Three of the last five things tried on the
processor were arithmetic -- an instruction here, a chain there -- and all
three were level or refused. This one is not arithmetic at all; it is the
same instructions in the same order, handed out differently. The profile
could not have found it either: it does not appear as a symbol, only as
workers idle in a spin loop that the page above had already decided was
earning its keep.


### Where the device's gap is now, kernel against kernel

`### The tile llama.cpp uses` put eighty-four per cent of the device gap in
the matrix products and measured our kernel at 3.4 teraflops against theirs
at 4.9. That was several changes ago and it is no longer where the gap is.
Taken again -- ours by voiding each shader in turn on the long prompt, theirs
from `GGML_VK_PERF_LOGGER=1` on the same prompt and the same file:

| | here | llama.cpp | behind |
| --- | ---: | ---: | ---: |
| matrix products | 595 ms | ~575 ms | 1.03x |
| attention | 108 ms | 80 ms | 1.35x |
| **the normalization** | **69 ms** | **21 ms** | **3.3x** |
| the gated middle and the joins | 71 ms | 61 ms | 1.16x |
| the rotation | 10 ms | 15 ms | ahead |

**The matrix row has caught up.** Ours now runs at about 4.9 teraflops and
theirs at 5.0, which is where their figure was when this comparison began. So
the tall-tile arguments under `### The tile llama.cpp uses` stand and the
work they were arguing about is done; what is left is elsewhere.

**And the normalization is three times behind, which is not a bound.** The
section above this one recorded that kernel and the combining one at sixteen
gigabytes a second and called it a bound rather than a bug, having ruled out
the access width, the arithmetic and the memory kind. It was a bug, and the
comparison found it in one reading: llama.cpp's `rms_norm.comp` is binary32
and ours was **binary64 the whole way through** -- eight squares a lane,
eight folding steps and eight scaled stores, all in double precision, on a
consumer RDNA3 part that runs double at a sixteenth of single.

The double was deliberate and the comment above the shader argued for it: a
tree fold is a different association from the processor's in-order sum, and
binary64 kept the difference in the last bits. But the error a tree already
carries is a few parts in ten million over two thousand and forty-eight
squares, and the epsilon added to the mean is a thousand times that. Nothing
downstream can see it.

| | 1419-token prompt | 110-token prompt |
| --- | ---: | ---: |
| binary64 | 0.843 s | 0.103 s |
| binary32 | **0.832 s** | **0.101 s** |

One and three tenths per cent of the long prompt and two of the short one --
less than the arithmetic suggested, so the double was not the whole of that
kernel's slowness either. Every digest holds, including `cbf29ce484222325`,
which both backends print for the 110-token prompt and which is the claim
under `### The device backend` that the two read the same text. And the
shader no longer needs `shaderFloat64` at all, which is a device feature it
had been requiring for a sum that never needed it.

The lane count was swept in the same sitting and is already right: two
hundred and fifty-six reads 0.832 s where five hundred and twelve reads 0.837
and a hundred and twenty-eight 0.844.

What is left on that side is now named: **attention at 1.35 times and the
elementwise kernels at 1.16**, with the matrix products level. It is the
first time in this file that the device's gap has not been mostly one row.


### The normalization taken apart, and it is the store

The section above leaves the normalization 2.8 times behind llama.cpp's and
names the eight barriers of its fold as the reason. Both halves of that were
wrong, and the number was stale: fifty-eight milliseconds came from a removal
sweep taken before the binary32 change, and the kernel has been re-measured
since.

Taken apart on the long prompt, each part voided in turn against a
0.830-second baseline:

| | prompt |
| --- | ---: |
| as it is | 0.830 s |
| the sum pass gone, a constant gain | 0.834 s |
| the output pass gone | **0.794 s** |
| neither pass | 0.795 s |

**The kernel is thirty-five milliseconds, not fifty-eight**, against
llama.cpp's twenty-one: 1.7 times behind and fourteen milliseconds of an
830-millisecond prompt. It is not the largest thing left on that side and the
item that ranked it first was ranking a number that had already moved.

**The fold is none of it.** Eight halvings is eight barriers across four
waves, and folded in two turns instead -- thirty-two partials to each of
eight lanes, then those eight -- it reads 0.835 against 0.830. The barriers
were free, which is why the subgroup reduction that item was really proposing
was never built: the cheap version of it already said no.

**The sum pass is free as well**, which the table says plainly: removing the
first read of the row and all the squares makes the kernel no faster. The
second read warms nothing the first did not, or rather the first warms
nothing the second could not do for itself.

Everything is in the output pass -- and inside that pass, **the reads are
free too**. Writing a constant, reading neither the row nor the gain, still
reads 0.832.

So the whole cost of this kernel is its store, and the store is not slow for
its width. A binary32 store of *twice* the bytes reads 0.819, eleven
milliseconds faster than the half-precision one. But that variant writes the
result buffer rather than the half-precision buffer -- and packing two halves
into one four-byte store of the *same* buffer reads 0.838. **It is not the
width of the store. It is which buffer is written.**

Which points somewhere this page has already looked without finding
anything. The result buffer is host-cached memory out of the heap that is not
the device's own; the half-precision buffer is the device's own and
host-coherent. `### The memory kind, and the number the item was ranked on`
above moved the half buffer to a kind that is the device's own and nothing
else and measured nothing -- but it was looking for a faster **read** where
the cost turns out to be a **write**.

So both ends were tried again, for the write. **Host-cached, out of the heap
that is not the device's own** -- the kind that was eleven milliseconds
faster to write -- reads **0.860 s** against 0.830: thirty worse, because the
tile product reads that buffer on every dispatch and a read out of that heap
is what this page already knew to be slow. Fast to write and slow to read is
not a trade a buffer read far more than it is written can take. And **the
device's own and nothing else**, with no coherence to keep and nothing
forcing a write past a cache, reads 0.819, 0.830, 0.823 and 0.836 against
0.832, 0.839, 0.829 and 0.825 -- half a per cent, arms overlapping at both
ends, on four rounds rather than three.

So the eleven milliseconds is not the heap, not the property bits, not the
width of the store and not what is in it. **What is left untried is the one
other thing those two variants differ in.** The half-precision buffer is
written by the normalization, read by the tile product, written by the tile
product and read by the combining step, all inside one submission -- so every
barrier in a layer is a barrier over that buffer. The result buffer, in the
variant that was faster, was touched by nothing else in the sequence. That is
the next question, and it is about barriers rather than about memory.

**Asked, and it bounds itself.** A layer's steps are a chain -- normalize,
three projections, rotate, attend, project out, join, normalize, two arms,
combine, project down, join -- and the engine walks a memory barrier in
wherever a step reads what a step before it wrote: about ten a layer, so
something over six hundred in a 1419-token prompt. Removed altogether, which
answers wrongly and is only a ceiling, the prompt reads **0.809 s against
0.830** and a generated token 1.199 against 1.225.

**Twenty-one milliseconds, two and a half per cent** -- the whole budget for
anything barrier-shaped, and the eleven the section above is chasing is half
of it. It cannot be the count, either: both variants of that experiment issue
the same barriers in the same places.

Split, by asking for a barrier that orders execution and requests no cache
work at all -- not correct, and only a measurement -- the prompt reads
**0.816 s**. So seven milliseconds is the drain, a dispatch waiting for the
one before it to empty, which is what a chain of dependent steps is; and
fourteen is the cache work a shader read after a shader write requires on
this part, because the per-unit vector caches have to be invalidated or one
compute unit may read a line another wrote. It answered correctly without
them in that run, which is luck about which lines collided rather than a
property worth keeping.

Nothing there is removable, and the ceiling is the point: **two and a half
per cent, most of it required.** The eleven milliseconds is still
unexplained, and is now bounded by a number small enough that it is not the
next thing to chase.


### Attention read line by line, and nothing to take from it

Attention is a hundred and eight milliseconds of a device prompt against
llama.cpp's eighty -- 1.35 times, twenty-eight milliseconds, and the largest
named item left on that side. Reading the other runtime's source is what
closed the processor's prompt two commits ago, so `flash_attn_cm1.comp` was
read through rather than sampled, beside this kernel.

**They are the same design, step for step:**

| | both kernels |
| --- | --- |
| the scores | a cooperative matrix product of the queries against a tile of keys, stored to shared memory |
| the softmax | read back into ordinary registers, the running maximum and total kept there, everything accumulated so far rescaled by the exponential of the change in maximum |
| the weighing | a second cooperative matrix product, its result stored to shared memory and added into those same registers |

That last step is the one this page had guessed was theirs alone -- keeping
the output in registers so it can be rescaled, because a cooperative matrix
cannot be. It is not. `coopMatStore` into `pvsh` and `Of[r][d] += pvsh[...]`
is exactly what this kernel does with `pacc` and `ss`. The tile is the same
too: sixteen query rows by sixty-four cached positions, which
`get_fa_tuning_params_coopmat1` gives this device and which this kernel
already used.

The one structural difference is the four subgroups, and `### Attention split
four ways` above already built that: fourteen per cent slower here.

**The one parameter left unswept is the query block, and it is at its peak.**
It must be a multiple of sixteen for the instruction, so there are two
candidates:

| | 1419-token device prompt |
| --- | ---: |
| **sixteen query rows** | **0.830 s** |
| thirty-two | 0.911 s |

Ten per cent worse, which is the answer every taller tile on this device has
given -- the third such reading, after the hundred-and-twenty-eight-row
product tile and the staged operands.

So the twenty-eight milliseconds is not the tile, not the structure, not the
split and not the block. Reading the other runtime's source has twice found
an answer on the processor side and twice now found nothing here, and that is
worth recording as a result about the two sides rather than about attention:
**this program's device kernels are already shaped the way the other
runtime's are, and where they differ it is because this part was measured
against the difference.**


### The share count a generated token was tuned to

A generated token reads every weight once and multiplies each of them once,
so it is the memory path that answers rather than the arithmetic, and that
path saturates before the cores do. This program has known that for a while
and gives a generated token a smaller team than a prompt: four shares where a
prompt takes eight.

**Four was measured against a pool that no longer exists.** Under the fixed
cut, a fifth and a sixth share bought nothing and cost a straggler -- the job
is not done until its slowest range is, and the ranges were decided before
any of them started. `### A share a worker, decided before any of them
started` replaced that with a tile taken from an atomic counter, and the
constant beside it was never asked again.

Swept on the pool that is there now, two rounds of sixty-four tokens:

| shares | generating | processor time |
| --- | ---: | ---: |
| three | 2.047 s | 6.77 s |
| four | 1.872 s | 7.91 s |
| **five** | **1.812 s** | 9.35 s |
| six | 1.794 s | 10.88 s |
| eight | 1.790 s | 14.08 s |

Alternated against four over three rounds, with every reading of one arm
below every reading of the other, **five reads 1.800 s against 1.849 -- two
and seven tenths per cent** -- for 9.29 seconds of processor time against
7.87. Six reads 1.790 against 1.847, three and a tenth, for 10.84; eight is
level with six again for 14.1.

**Five is the one to take.** It has seven eighths of what there is to take
for less than half of what six spends on it, and eight spends fifty per cent
more than five to be indistinguishable from six. That is the same trade the
worker default is chosen on, and this page has already refused hyperthreading
on a worse version of it.

The prompt is untouched -- 5.00 s both ways -- because a batch keeps every
share, and the digest holds at every count.

Generating goes from 34.7 to 34.8 tokens a second in the sitting and the gap
to llama.cpp from 1.18 to **1.12**. It is the fourth thing this program has
found by asking a constant that was right when it was measured and is not
any more, and the pattern is worth naming: **a tuned constant is a
measurement, and a measurement has a date.**


### Three more constants asked, and all three stand

The section above ends by saying a tuned constant is a measurement with a
date. Three more were asked. None of them moves -- and two of the sweeps are
worth keeping anyway, because they say how much the choice matters.

**The chunk grain**, which the pool takes a worker's next piece from, had
never been swept at all: it was set to the row tile because the tiling
requires that as a floor, and the floor was never tested against anything
above it. llama.cpp hands out sixteen rows, and sixty-four for a large
matrix, which is a deliberate two-value choice in
`ggml_compute_forward_mul_mat`. Two rounds, medians of three:

| grain | 1419-token prompt | 64 generated | 110-token prompt |
| --- | ---: | ---: | ---: |
| **one tile, 32 rows** | **4.827 s** | **1.825 s** | **0.366 s** |
| two tiles, 64 | 5.009 s | 1.833 s | 0.385 s |
| three tiles, 96 | 5.264 s | 1.836 s | 0.408 s |
| four tiles, 128 | 5.567 s | 1.873 s | 0.431 s |

One tile is the best of them and the curve is monotone: two costs four per
cent of the long prompt, three eight and four fifteen. **The floor is also
the optimum, which is luck rather than design** -- the grain cannot go below
a tile without splitting one, and splitting one would change which kernel a
row's tile takes and move the answers at different worker counts. The
constant is right, and the reason it is right is not the reason it was
chosen.

**The two thresholds that gate the pool.** A batch below sixteen positions
keeps its elementwise loops on the calling task, which was measured when
three such loops went to the pool and there are five now. Swept over one,
eight, sixteen and sixty-four, generating reads 1.797 to 1.810 seconds and a
drafted run 2.964 to 3.052 -- flat everywhere, which is itself the answer: a
batch of one or five positions has so little elementwise work that neither
sharing it nor keeping it can be seen.

The activation quantizer's floor does matter:

| a run under | 64 generated | processor time |
| --- | ---: | ---: |
| sixty-four blocks | 1.909 s | 10.00 s |
| **two hundred and fifty-six** | **1.801 s** | 9.26 s |
| a thousand and twenty-four | 1.797 s | 9.27 s |

Six per cent worse at sixty-four and level at a thousand. A generated token's
sixty-four blocks are quantized faster than a pool can be told about them,
which is exactly what that constant was put there to say.

**And the batch, five hundred and twelve** -- swept on the device recently
and never on the processor since the prompt path changed three times under
it. From 256 to 1024 the long prompt reads 4.685 to 4.973 seconds and the
device 0.845 to 0.875, two per cent across a fourfold range with the arms
overlapping: the 256 arm holds both the slowest reading and the fastest.
Nothing to choose, and 512 is what the other runtime uses as well.

Three constants asked, three unchanged, and the sweeps cost less than the one
that moved was worth.


### The short device prompt, and the tile table on the other side

The device's 110-token prompt is 1.53 times behind, the widest ratio in this
file, and the reason offered was occupancy: a 110-column batch is one column
tile wide, so a 2048-row product dispatches sixty-four workgroups onto twelve
compute units. A narrower column tile doubles that.

| column tile | 110 tokens | 1419 tokens |
| --- | ---: | ---: |
| a hundred and twenty-eight | **0.101 s** | **0.841 s** |
| sixty-four | 0.103 s | 0.846 s |

Nothing at the short length and slightly worse at the long one, with twice
the workgroups. **That is the fourth independent measurement on this device
to say occupancy is not the constraint**, after the taller product tile, the
staged operands and the four-subgroup attention.

So the other runtime's short prompt was measured rather than reasoned about,
with `GGML_VK_PERF_LOGGER` on the same file and the same length, taking the
warm block:

| | llama.cpp, 110 tokens |
| --- | ---: |
| matrix products | 63.1 ms of 74.0 -- **85 %** |
| the gated middle | 2.70 ms |
| the residual adds | 1.83 ms |
| the normalization | 1.93 ms |
| attention | 1.53 ms |
| the rotation | 1.22 ms |

**Which is the same shape as ours**: eighty-five per cent matrix products
there and eighty-five here, 63.1 milliseconds against our 88 of 104. The
whole of the difference at this length is in the one row -- the row we are
level with at five hundred and twelve columns.

Their rates by shape say where it goes. At a hundred and ten columns they
read 2908, 3765, 575 and 4073 gigaflops for the four products a layer makes,
and at five hundred and twelve 4552, 5581, 2097 and 5002. **They lose between
a quarter and a third going from 512 columns to 110, and we lose
forty-seven per cent** -- 0.80 milliseconds a token against 0.425. The narrow
one, the 256-row key and value projection, is the worst for both: 575
gigaflops, 8.8 of their 63 milliseconds.

And `ggml-vulkan.cpp` keeps **three tile shapes chosen by the matrix's
size** where this program has one -- small `{32 rows, 64 columns, 128 deep}`,
medium `{128, 128, 64}`, large `{128, 256, 64}`. At a hundred and ten columns
it picks the medium, which is *taller* than ours rather than narrower, and
the taller tile is what `### The tile llama.cpp uses` already measured at
thirteen per cent worse on the long prompt.

What is left is the depth: all three of their shapes take sixty-four or a
hundred and twenty-eight columns of the shared dimension at a step where this
takes thirty-two. **Which had already been tried, and the next section is the
correction.**


### The step's depth, which had been done, and the guard I walked round

The section above calls the depth "the one dimension of the tile this program
has never varied" and "the only untried thing left in this kernel". Both are
wrong, and the answer was **two lines under the constant I edited**. The
shader says, of `TILE_R`, `TILE_V` and `KCH`: *the step is one Q8_0 block
deep, which is what makes the decode below a whole number of blocks;
sixty-four and a hundred and twenty-eight were measured and are slower.*

`docs/measured-figures.txt` has it at more length under 2026-08-29. The
staging was rewritten to take any shape, eleven were swept, every one
answered `1a26d24d33b8957b`, and the shape already there won by six per cent
-- step sixty-four read 2.062 s against 1.935 and step a hundred and
twenty-eight 2.122. The rewrite cost one and a half per cent and was taken
out, **and a repository check was added that `TILE_R` and `KCH` are
thirty-two**, so that the next person to turn one gets a failure rather than
a kernel that runs and answers nothing.

That check exists, it names this exact mistake, and it did not fire because I
never ran it: the sweep went through the shader build script and the speed
tool, and the check lives in `tests check`, which I had skipped for being
slow. The guard was written for precisely this and I walked round it.

**What does justify re-asking is the date.** That sweep was taken when the
long device prompt was 1.935 seconds and it is now 0.831 -- the shape was
chosen on a machine doing less than half the work per second it does now. So
it was asked again with a smaller change than the 2026-08-29 rewrite: the
staging keeps its straight-line body and gains one loop over sixteen-value
units, both of whose bounds are compile-time constants, so a step of
thirty-two turns it once.

| | 1419-token device prompt |
| --- | ---: |
| **as it is, no loop** | **0.831 s** |
| the loop, step thirty-two | 0.880 s |
| the loop, step sixty-four | 0.898 s |
| the loop, step a hundred and twenty-eight | 0.888 s |

Two readings come out of that. **The depth is still wrong at both larger
values** -- two per cent worse at sixty-four and one at a hundred and
twenty-eight, measured against the same loop -- a smaller gap than the six
and ten per cent of the old sweep, but the same sign, and the shape stands.

And **the loop costs four and a half per cent** where the earlier, more
general rewrite cost one and a half. It is a smaller change on a baseline
that has more than halved, so the absolute cost is about the same and the
proportion is what moved. Generality that costs four and a half per cent and
unlocks nothing is not kept, for the second time and for the same reason.


### The weights' traffic costs nothing, which takes the bus off the list

Generating reads every weight once a token -- a gigabyte and a sixth -- and
the standing explanation of the gap to llama.cpp on that row has been that
the bus answers rather than the arithmetic. Four hypotheses about that bus
have been refused on this page: the page tables, the accumulator chain, the
prefetcher and the memory kind. **None of them tested the premise.**

So the traffic itself was removed. The insertion's weight cursor is left at
zero, so every block of every row reads the same thirty-two bytes: the same
instructions in the same order, on data that never leaves the nearest cache.
The answers are wrong and finite, which is all a timing needs.

| | generating | processor time |
| --- | ---: | ---: |
| five shares, as it is | 1.800 s | 9.29 s |
| five shares, one block | 1.804 s | 9.32 s |
| one worker, as it is | 4.553 s | |
| one worker, one block | **4.327 s** | |

**A gigabyte and a sixth a token, and taking it away is worth nothing at the
share count this program uses** -- and five per cent at one worker. Whatever
that row is waiting for at five shares, it is not the weights arriving.

It does not say what it is, and the arithmetic does not close either: the
kernel is seventy-nine per cent of the samples and about three hundred and
eighty million instructions a token, which at five cores and this part's
all-core clock is a quarter of the twenty-eight milliseconds a token takes;
the dependent multiply-add chain is another quarter. Something is being
waited for that is neither the weights, nor the issue rate, nor the chain.
What this entry does is take the bus off the list -- four earlier entries
assumed it and none of them checked.

**And the normalization's store, again.** `### The normalization taken apart`
above leaves eleven milliseconds that is not the heap, the property bits, the
store width, the contents or the barriers. Re-run on the build that does the
sum in binary32:

| | 1419-token device prompt |
| --- | ---: |
| writing the half-precision copy | 0.828 s |
| writing the binary32 one | **0.800 s** |

**Thirty-one milliseconds, where the same probe read eleven before** -- the
number grew as the kernel around it shrank, and it is now nearly four per
cent of a device prompt. The probe is not a change, because the tile
product's operand must be half precision.

One thing has not been tried and fits every reading: the half-precision
buffer is three regions of five and four fifths megabytes, **seventeen in
all**, where the result buffer is four and a fifth -- and this part's
second-level cache is two. Which of them a kernel writes changes what is
resident across the dispatches either side of it. That is a size argument
rather than a kind argument, and it is the next thing to ask.


### The size argument, and reading the instruction instead

The section above proposes that the normalization's store is dearer into the
half-precision buffer than into the result buffer because the first is
seventeen megabytes and the second four, against a second-level cache of two.
The batch sets that size -- a region is the widest product's columns times
the batch rounded to a tile -- so the batch was cut to a quarter and the same
probe run at both:

| | 1419-token device prompt |
| --- | ---: |
| batch 512, writing the halves | 0.848 s |
| batch 512, writing binary32 | 0.819 s |
| batch 128, writing the halves | 0.917 s |
| batch 128, writing binary32 | 0.890 s |

Seventeen megabytes against four and a third -- a fourfold cut in the working
set -- and the gap is **twenty-nine milliseconds against twenty-seven**. It
is not the size.

So the instruction was read rather than guessed at. `RADV_DEBUG=asm` prints
every kernel the driver compiles, and the normalization is the short one with
a square root in it:

| the shader writes | the driver emits |
| --- | --- |
| `h[at + c]` | `buffer_store_b16` |
| `y[at + c]` | `buffer_store_b32` |
| `h2[(at + c) / 2]` | `buffer_store_b32` |

Two things follow. **The half store is a real sixteen-bit store**, not a
read-modify-write of the word around it -- which was the last mechanism that
would have explained a per-element penalty. And the pair-packed variant
really did emit the wide store, so when it measured 0.838 against 0.830 it
was a wide store into the half buffer losing to a narrow one into the same
buffer, not a failed compilation.

Which leaves the destination and nothing else. A thirty-two-bit store into
the result buffer is faster than a sixteen-bit store into the half buffer,
and a thirty-two-bit store into the half buffer is slower than either.
**Six things have been tried and none is it**: the memory kind at both ends,
the size of the buffer, the width of the store, what is in it, and the
barriers -- and the barriers are bounded at twenty-one milliseconds for a
whole prompt, which is less than the twenty-nine this costs.

What is left is what else touches the buffer inside a submission. The
half-precision buffer is written by the normalization, read by the tile
product, written by the tile product and read by the combining step; the
result buffer, in the faster variant, is touched by nothing else in the
sequence. That was named a barrier question two sections ago and the barrier
budget rules it out as one -- so whatever it is, this page does not have a
name for it yet.

Recorded as an open question with six doors closed, which is worth more than
a seventh guess.


### The probe was the bug: there is no thirty-one milliseconds

Three sections above have chased a store. The normalization writes its answer
into the half-precision buffer, and writing it into the result buffer instead
reads twenty-nine to thirty-one milliseconds faster; six explanations were
eliminated -- the memory kind at both ends, the size of the buffer, the width
of the store, its contents, the barriers. **The seventh test was of the probe
itself, and it should have been the first.**

**Is the effect general?** The combining step writes the same buffer the same
way. Given the same treatment -- its answer into the result buffer instead --
the long device prompt reads 0.829 s against a baseline of 0.828 to 0.848.
Nothing, where the same change to the normalization is worth twenty-nine
milliseconds.

**What does the write actually cost?** Made to write *both* -- the halves
where they belong and the binary32 copy beside them, which is a correct build
answering `1a26d24d33b8957b` -- it reads 0.838 s. So adding a 4.2-megabyte
binary32 store to that kernel costs about five milliseconds, where removing a
2.1-megabyte half store is supposed to save twenty-nine.

**And here is the answer.** In the probe, nothing writes the normalization's
region of the half buffer at all -- and the three projections and the two
arms read it. So the region was changed to be written once a row: five
hundred and twelve stores of two bytes rather than a million, every page
touched and almost nothing put in it.

| | 1419-token device prompt |
| --- | ---: |
| as it is, the whole region written | 0.838 s |
| one store a row, and the binary32 copy | 0.847 s |
| no store at all, and the binary32 copy | **0.810 s** |

Writing a megabyte into the region and writing a kilobyte into it cost the
same. Writing *nothing* into it is what is cheap. **The twenty-nine
milliseconds is not the store. It is the reads downstream of a region that
has been written, against reads of one that has not** -- the probe replaced a
real dependency with reads of memory nobody had touched, and what it measured
was the normalization's output existing.

That also explains the combining step's result: its region is written by the
tile products as well, so skipping its own write leaves the region dirty and
there is nothing to save.

So there is no thirty-one milliseconds and there never was. The sections
above that call it unexplained were explaining an artefact, and the six doors
they closed were closed on an empty room. What is worth keeping is the rule:
**a probe that removes a write must be asked what reads it**, and a saving
that appears when a buffer stops being written is a saving in the readers.


### What a voided kernel really measures

The rule the section above ends on -- a probe that removes a write must be
asked what reads it -- applies to this page's main instrument. **Every device
budget here was taken by voiding a kernel and reading the whole run, and every
kernel in those budgets writes something another one reads.**

So the normalization was measured three ways rather than two:

| | 1419-token device prompt |
| --- | ---: |
| as it is | 0.833 s |
| one store a row and nothing else | 0.829 s |
| voided entirely | **0.783 s** |

The middle build keeps the kernel's shape and throws away its work: the sum,
the fold, the gain and a million stores become five hundred and twelve stores
of two bytes, one to a row, touching every page of the region and putting
almost nothing in it.

**Four milliseconds is what the normalization does. Forty-six is what its
output costs the five kernels that read it** -- three projections and two
arms -- against reading a region nobody wrote. The removal method charges the
kernel for both and reports fifty.

That is a correction to every figure in `### Where a device prompt goes, every
kernel taken out in turn` and to the budget under `### Where the device's gap
is now`. **Those tables say what removing a kernel saves. They do not say what
the kernel costs**, and for this one the two differ by a factor of twelve.

It also explains a thing recorded here as unexplained. At a 110-token prompt
each of five small kernels appeared to cost about thirty-two milliseconds
alone and all five together thirty-five, which could not be true of any of
them. It is true of none of them: most of each figure is the same downstream
reads becoming cheap, and removing a second kernel cannot make them cheap
twice.

What survives is the two ends of such a table -- everything and nothing, both
real -- and the ordering, which is roughly right because a kernel whose output
is read more has more readers to make cheap. **What does not survive is the
share.**

The middle build is the instrument to use from here: keep the writes, throw
away the work. It is more trouble than an early return, and it is the only one
of the two that measures a kernel.


### The activation quantizer, widened and refused

The processor's two small kernels are a different matter and the same
sentence as the section above. `quantize_blocks` is two per cent of a
processor prompt and its annotation is `addps`, `cmpleps`, `movups` on
**`xmm`** -- a hundred and twenty-eight bits, which is the baseline this
library compiles to. `mat_mul_range_packed` is three and a half per cent and
moves its tile with `movsd` and `movhpd`, sixty-four bits at a time. Neither
is in a unit the project file gives wide lanes to, and that is deliberate:
the wide code is isolated into units chosen at run time so that the binary
runs on a processor that has none of it. What those two want is the same
treatment the row kernels already have -- a wide variant beside the
baseline, chosen when the host says yes -- and the measurement above says to
widen them to two hundred and fifty-six bits and stop there.

So the quantizer was widened, as a probe rather than as a change: the whole
unit compiled for `x86-64-v3`, which is not shippable because the binary
would then fault on a processor without it, but which answers what the
width is worth before four files of plumbing are written to get it safely.

**It is worth seven tenths of one per cent.** The wall clock read 5.809
seconds against about 6.05, which looked like four -- but that column swings
by more than that between sittings, and the profile is the honest measure:
`quantize_blocks` falls from **2.0 per cent of the prompt to 1.27**, and
every other share stands still.

**And it does not answer the same.** The 1419-token prompt comes back
`b8887185cdd328a7` where it has always been `1a26d24d33b8957b`, and reverting
the switch brings it back. Nothing in that unit reduces across lanes -- the
only accumulation in it is an integer total, which is exact in any order --
so what changed is the rounding. `Real'Rounding` is ties away from zero, and
the baseline reaches that by adding and truncating where the vectorised form
reaches for a rounding instruction; a value landing exactly on a half then
goes the other way. Three million activations a batch is enough for that to
show.

Seven tenths of a per cent, four files of plumbing, and an answer that
differs. Not built.

**The tile write-back, the other half of the same item, is bit-exact and
level.** `mat_mul_range_packed` narrows a tile of binary64 accumulators into
binary32 and lays it out the way the target wants it, and unlike the
quantizer's rounding there is no emulation to differ: a double narrowed to a
float is round-to-nearest-even, which is one instruction at any width. The
digest holds -- `1a26d24d33b8957b` throughout -- and the run does not move:
6.266, 6.053 and 6.218 seconds against 5.786, 6.137 and 6.220, ahead in one
round of three.

The profile says why. Its share goes **3.26 per cent to 3.04**, which is
nothing. The loop writes the target contiguously and reads the tile with a
stride, and a wider lane does not help a strided read -- this part's gather
is slow enough that the compiler keeps the paired sixty-four-bit moves
whichever set it is given. One of the two sides has to be strided, and which
one is the subject of `### A tile written the way the target is laid out`
above; widening the lanes does not change that choice, it only makes the
contiguous side wider while the strided side still decides the pace.

**And the reading that started this was noise.** The first measurement of
the widened unit read 5.648 seconds against about 6.05 and looked like six
and a half per cent. Three alternated rounds put it at nothing. The
processor's prompt column swings by five per cent between sittings -- this
file has said so for months, and it is the third time in this session that a
single reading of it has pointed the wrong way.

That is worth setting beside the section above it, because the two are the
same lesson from opposite ends. Widening the blending run was **bit-exact
and slower**. Widening the quantizer is **faster and not bit-exact**. Neither
is what the width was expected to give, and in both the reason is a property
of the instruction rather than of the lane: one is double-pumped, and the
other rounds differently.

And the normalization's six per cent of a device prompt is neither of the
two things it looked like. Its second read of the row was refused last
section for occupancy. Its fold -- two hundred and fifty-six lanes halved
through eight workgroup barriers, which the shader's own comment flags as
the thing a subgroup reduction would replace -- costs nothing either:
removing the halvings entirely reads 0.892 and 0.903 seconds against 0.892
and 0.885. What is left is the streaming and the dispatch, and neither is a
lever.

One correctness trap on the way, worth recording because it was silent on
the run that matters and loud on the one that does not. A run whose products
all take the row shader has no half-precision buffer at all -- the engine
sizes it only when some step uses the tile -- and the binding that would
carry it is then the batch's own. The normalization wrote its copy through
that binding and a generated token came back with a different digest while
the prompt's stayed right. A kernel that trusts a binding rather than the
caller is a kernel that will do this; it takes the count from the caller
now, and zero means there is nothing to write.


### A generated token is one kernel

Everything above is about a prompt. A generated token was priced the same
way -- each kernel voided in turn, sixty-four tokens, two rounds each -- and
it is a different program:

| kernel voided | generating | it costs |
| --- | ---: | ---: |
| nothing | 1.270 s | -- |
| **`row_product`** | **0.181 s** | **1.089 s, 86 %** |
| `attention` | 1.273 s | nothing |
| `combine` | 1.271 s | nothing |
| `norm` | 1.249 s | nothing |
| `rotate` | 1.273 s | nothing |
| `place` | 1.282 s | nothing |

**A generated token is the row product and nothing else.** Attention,
the normalizations, the joins, the rotation and the cache write together
measure zero at a batch of one -- every one of them is a few thousand
operations against a pass over every weight in the model.

Per token: 19.8 milliseconds, of which **17.0 is the row product and 2.8 is
no kernel at all**. llama.cpp's whole token on this device is 17.9. So this
program's one kernel is about as fast as their entire token, and what puts
it behind is the 2.8 milliseconds around it.

**The row product is at the bus, not at its instructions.** It moves 1.17
gigabytes a token in 17.0 milliseconds, which is 69 gigabytes a second of a
part whose peak is about a hundred. And the instruction count was tested
directly: a `Q8_0` block is thirty-four bytes and a row begins on a word, so
half the blocks of every matrix straddle, and the straddling path read both
words of every pair -- sixteen reads for what nine words cover. Carrying the
second word forward reads each once, a quarter off every weight read the
kernel makes. It is bit-exact and it is **level**: 1.276, 1.282 and 1.280
seconds against 1.278, 1.282 and 1.288. A kernel waiting on memory does not
care how few instructions ask for it.

The 2.8 milliseconds is not what it looks like either. It is about
twenty-two submissions -- one a layer -- and the obvious suspect was the
host writing descriptors, four to a step and nine steps to a layer. Writing
every one of them **twice** costs nothing: 1.264 seconds against 1.270. So
the descriptors are free and what is left is the submissions themselves.

**And `--budget` is no help here at all**, which is the sharpest illustration
this file has of what that instrument measures. It puts attending at
**seventy-five per cent** of a generated token and projecting at nineteen,
where removal puts attention at zero and the row product at eighty-six. The
single-position path waits for a layer's fence inside its attending span, so
the whole layer's time lands there. The instrument is not wrong -- it is
answering where the host waits, and this is where the host waits.


### The two and a half milliseconds that are not a kernel

The section above leaves 2.8 milliseconds of a 19.8-millisecond token in no
kernel at all, and names the twenty-two submissions a token makes as what is
left. That was the wrong suspect, and finding out cost three probes and no
code.

**It is not the submissions.** A profile of the run with every kernel voided
-- so that nothing remains but the host and the queue -- puts the top of the
list at a memory copy, and that copy is the model going to the device once,
1.1 gigabytes of it, which the first token pays and the other sixty-three do
not. Under it are the kernel's own wait paths, which is the host correctly
idle while the device works: with a layer carried, nothing it produces is
kept and nothing is borrowed, so the only wait in a token is the last
layer's.

**And it is not the descriptors**, which was the other suspect: the host
writes four of them a step and nine steps a layer, a hundred and ninety-eight
a token. Writing every one of them **twice** costs nothing -- 1.264 seconds
against 1.270.

What the profile does name is a function: **`Sampling.Adjusted`, at six point
eight per cent of a run with the kernels gone.** The repetition penalty is on
by default, over a window of sixty-four tokens, and the question it asks --
is this token in the window? -- was a walk of the window asked once for every
token of the vocabulary. Thirty-two thousand walks of sixty-four entries is
**two million comparisons a token**, and it is pure host arithmetic between
one device submission and the next.

The window is sorted and deduplicated once a token instead, in the one place
the history changes, and the question becomes a binary search: at most six
comparisons rather than sixty-four, and the sort costs a couple of thousand
operations against the two million it removes.

**Worth two and a half per cent of a generated token**, ahead in each of
three alternated rounds -- 1.239, 1.251 and 1.250 seconds against 1.279,
1.282 and 1.283 -- and bit-identical: the same token is chosen, by the same
arithmetic, in a different order of asking. The device generates at **50.6
tokens a second** and the gap to llama.cpp is **1.10**.

**The check did not fire on it**, and that is the part to keep. The sampler
is in no group's source list, so a change that made every generated figure
in this file faster passed the gate in silence. It is in the five groups that
publish a generating figure now -- the same repair `model_runner-llama.ads`
needed two commits ago, and the second time in three days that a file the
figures depend on turned out not to be watched.


### Kernels

Row dot product, nanoseconds per element, release build, every format the
engine supports:

| Format | ns/element | Format | ns/element |
|---|---|---|---|
| F32 | 0.27 | Q4_1 | 0.52 |
| BF16 | 0.33 | IQ4_XS | 0.52 |
| Q4_0 | 0.32 | Q5_0 | 0.57 |
| Q8_0 | 0.40 | F16 | 0.59 |
| Q4_K | 0.41 | Q5_1 | 0.61 |
| Q6_K | 0.41 | IQ4_NL | 0.67 |
| Q5_K | 0.43 | Q2_K | 0.74 |
| Q3_K | 0.51 | | |

Every row of this reading is five to ten per cent above the one before it and
no decoder changed between them: the part had stopped cooling, as this table
requires, but the sitting reached it after two hours of building and
measuring and the machine's load average had not come down. Read the column
against itself, not against the last printing of it.

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
Q4_0 went 0.33, then 0.59, then 0.31, and reads 0.32 now; IQ4_NL went 1.44,
then 0.59, then 0.62, and reads 0.67; IQ4_XS went 0.95, then 0.48, then 0.50,
and reads 0.52; Q2_K went 0.79, then 1.01, then 0.69, and reads 0.74. All
four now move with the rest of the table rather than against it.

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
