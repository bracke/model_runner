# Speech to text: Whisper beside the conversation

**A plan, written 2026-11-02, and the record of what was built against it.**
The specification it answers is "Native Whisper Speech Recognition" (v1.0,
2 November 2026). What this file adds is what the specification could not
know: where in this program each part goes, what is already here to reuse,
and where the specification and the repository disagree.

The aim: in an interactive session, Ctrl-G records, Ctrl-G again stops,
and what was said appears in the line being typed, to be edited and sent
as any typed line is. The model in the conversation is never touched.
`model_runner transcribe FILE.wav` does the same for a file.

---

## 0. Audit: what is here, what is reused, what is new

Read before anything was written (commit c2a4f26c).

| need | what the repository has | used as |
| --- | --- | --- |
| a model file's container | `GGUF.Containers` (strict, bounded) | as is: Whisper is a GGUF file |
| tensors where they lie | `Tensors.View`, `Tensors.Dequantize_Row` | as is |
| products of many vectors | `Float_Panels` (packed binary32, 6x32 tiles) and `Backend.CPU.Dispatch_Batch` | the encoder's products |
| products of one vector | `Backend.CPU.Dispatch` (every format, integer kernels) | the decoder's products |
| LayerNorm, exact GELU, softmax | `Kernels.Layer_Norm`, `Kernels.Exact_GELU`, `Kernels.Softmax` | as is: the vision encoders use them |
| a byte-pair vocabulary | `Tokenizer` (`gpt2` model, merges, byte decoding) | Whisper's vocabulary, from the GGUF |
| a worker pool | `Backend.CPU.Pool`, `Shares` | Whisper shares the session's pool; it does not open one |
| the device | `Backend.Device` (one queue, process-wide) | phase 9; the vision encoder already shares it with a session |
| a safetensors table | `Safetensors` | the converter reads OpenAI's checkpoint through it |
| a GGUF writer | `Fixtures.Builder` (tests crate) | the converter writes through it |
| the line editor | `CLI.Choosers.Edited_Line` (raw terminal, its own keys) | Ctrl-G added there |
| settings | `Config` (a key is a `run` option without its dashes) | `--speech-model` and the rest; `speech-model = ...` in the file follows |
| messages | `resources/messages/catalog.txt` (en, da, qps) | every new message in all three |
| a library opened by name | `Platform.Video` (FFmpeg by `dlopen`) | the microphone: libpulse-simple by `dlopen` |

Where the specification and the repository part:

1. **"The converter may use Python."** CONTRIBUTING.md: every project-owned
   tool is an Ada program in the tests crate. The converter is
   `tests whisper-convert`, reading OpenAI's `model.safetensors` (as Hugging
   Face publishes it) with `Model_Runner.Safetensors`. The reference used to
   hold the numbers to is a numpy program kept outside the repository (as
   llama.cpp and stable-diffusion.cpp are kept beside it); it is described
   below, not committed.
2. **"`Model_Runner.Llama` rejects cross-attention."** It does, and Whisper
   is not added to it: `Model_Runner.Whisper` is its own package and depends
   on nothing of `Llama`'s.
3. **"`docs/whisper/architecture-audit.md`, `integration-map.md`,
   `baseline-results.md`."** One file, this one, as every plan here is.
4. **"GNATprove under the project's policy", "90% line coverage".** The
   project has neither policy; it has the AUnit suite, `tests check`'s
   static checks, and the stack-frame gate. Those are what is run.
5. **Microphone through PipeWire's C interface.** PipeWire serves the
   PulseAudio protocol, and `libpulse-simple` is three calls --
   open a stream at a rate and channel count the server converts to, read,
   free. Opened by name as FFmpeg is; no headers, no link-time dependency;
   a host without it says so by name.

### Reference

There is no Whisper runtime on this machine and building whisper.cpp was
not permitted in this session. The reference is therefore an independent
numpy implementation of openai/whisper's `audio.py`, `model.py` and the
greedy path of `decoding.py` (timestamp rules, blank and token
suppression), reading the same `model.safetensors`. It reproduces the
published transcript of `jfk.wav` with Whisper tiny exactly -- " And so my
fellow Americans ask not what your country can do for you, ask what you can
do for your country.", 0.00 to 10.50 s -- and its Mel filters match the
reference's own `mel_filters.npz` (read out of whisper.cpp's
`ggml-tiny.bin`) to 1.9e-9.

### Fixtures

| file | source | licence |
| --- | --- | --- |
| `tests/fixtures/speech/jfk.wav` | whisper.cpp `samples/jfk.wav`: J. F. Kennedy's inaugural address, 1961, 11 s | public domain (a US government work) |
| `tests/fixtures/speech/da-short.wav` | LibriVox "Udvalgte Danske Eventyr 001", "Den lille pige med svovlstikkerne", read by Hedvig and Kristoffer Hunsdahl, 34 s to 48 s, 16 kHz mono | public domain (LibriVox) |
| `tests/fixtures/speech/*-mel.expect` | the numpy reference's spectrogram of each, sampled | this project's |

---

## 1. Ownership: two models, one process

`Model_Runner.Whisper` holds a `Model` (weights, immutable once prepared)
and a `Session` (its encoder's output, the cross-attention keys and values,
the decoder's own cache, scratch). Nothing of either is shared with
`Llama.Model` or `Llama.Session`; they share only the worker pool, which is
task-safe, and the device queue, which is serialized by the backend.

`Model_Runner.Speech` is the auxiliary owner: it loads the Whisper model on
first use, keeps it, records, transcribes, and unloads, as a state machine
(Disabled, Unloaded, Loading, Ready, Recording, Transcribing, Failed,
Unloading). It is given the session's pool; it never sees the LLM.

## 2. The file

A GGUF file, `general.architecture = whisper`, written by `tests
whisper-convert` from OpenAI's checkpoint as Hugging Face publishes it
(`config.json`, `generation_config.json`, `vocab.json`, `merges.txt`,
`added_tokens.json`, `model.safetensors`):

    cd tests
    ./bin/tests whisper-convert --from ~/models/whisper/small --out whisper-small-f16.gguf

`--type f32` keeps the matrices binary32; the default, `f16`, halves them.
Norms, biases, the convolutions and the two position tables stay binary32
either way. The same checkpoint makes the same bytes (checked: two runs,
`cmp` equal), and a manifest is written beside the file: profile, tool,
SHA-256 of the checkpoint's weights and of the file.

**Profile 1.** Keys: `whisper.profile.version`; `whisper.encoder.` and
`whisper.decoder.` `context_length`, `embedding_length`,
`feed_forward_length`, `attention.head_count`, `block_count`;
`whisper.attention.layer_norm_epsilon`; `whisper.audio.` `mel_bins`,
`sample_rate`, `window_length`, `hop_length`, `chunk_length`;
`whisper.vocabulary.size`; `whisper.multilingual`; `whisper.languages`
(codes, in token order) and `whisper.token.first_language`;
`whisper.token.` `end_of_text`, `start_of_transcript`, `transcribe`,
`translate`, `start_of_previous`, `start_of_lm`, `no_timestamps`,
`no_speech`, `timestamp_begin`; `whisper.suppress_tokens` and
`whisper.begin_suppress_tokens` (from `generation_config.json`); and the
vocabulary as llama.cpp writes a GPT-2 one (`tokenizer.ggml.model = gpt2`,
`pre = gpt-2`, tokens, types, merges). Tensors, named as llama.cpp names
an encoder-decoder's: `enc.conv1`, `enc.conv2` (weight, bias),
`enc.position_embd.weight`, `enc.blk.N.` `attn_norm`, `attn_q`, `attn_k`
(no bias), `attn_v`, `attn_out`, `ffn_norm`, `ffn_up`, `ffn_down`,
`enc.output_norm`; `dec.token_embd.weight` (the output head too: tied),
`dec.position_embd.weight`, `dec.blk.N.` the same plus `cross_attn_norm`
and `cross_attn_q`/`_k`/`_v`/`_out`, `dec.output_norm`.

Nothing is guessed from a file name: every dimension is read and every
tensor's shape held to it. Whisper tiny is 167 tensors, small 479.

Two defects in jsonlib, found converting: reading a member of a large
object copied the whole node, and building one and refusing a repeated
name walked every member -- each quadratic, minutes for a 50,000-token
vocabulary. Fixed there (jsonlib 9ba48f0, 24a1b18); the conversion takes
1.6 s.

## 3. Audio

`Model_Runner.Fourier` (mixed radix, any length), `Model_Runner.Audio` (WAV,
mixing, resampling), `Model_Runner.Audio.Spectrograms` (log-Mel). Held to
the reference: filters to 1e-8, spectrograms of both fixtures to 1e-4 at a
grid of points and their means to 1e-5.

## 4-7. Encoder, decoder, transcription

`Model_Runner.Whisper` (model, session, transcription) and
`Model_Runner.Whisper.Decoding` (the reference's token rules, pure).

What is reused rather than written again: `Kernels.Layer_Norm`,
`Kernels.Exact_GELU`, `Kernels.Softmax`, `Kernels.Dot`; `Float_Panels` for
every encoder product -- the convolutions as products over their three
taps, the projections, and attention's two products (the keys and the
turned values laid out as weights, read in place by stride); the CPU
backend's `Dispatch_Batch` and `Dispatch` for the decoder's products,
which read F16 and F32 weights where they lie; `Tokenizer` for the
vocabulary. No numerical primitive was missing: what Whisper needed of
"convolution" is a product over gathered taps, of "cross-attention" an
attention whose keys were made once.

The encoder runs once a window and its output stays in the session; each
decoder block's keys and values of it are made then, once a window; the
decoder's own keys and values are a cache of the text context's rows.

Transcription is the reference's `transcribe()` with greedy decoding:
language detected from the first window's 3,000 frames as they are (the
padding's own frames after a short recording), each window after that
padded with zeros past its content, prompted with the text before it
(`<|startofprev|>`, the last 223 tokens, times included), times decoded
with the text, segments cut at consecutive times, the next window
starting at the last time where the window did not end on a single one.
The no-speech probability is read at `<|startoftranscript|>`'s position.

**Held to the reference** (`tests hear --reference DIR`, the numpy
program's dumps for the same recording):

| model | recording | encoder output, worst / largest | first logits, worst / largest | transcript |
| --- | --- | ---: | ---: | --- |
| tiny F32 | jfk.wav, 11 s | 8.9e-5 | 6.3e-7 | identical: tokens, text, 0.00-11.00 s, logprob -0.33127, no-speech 0.06912 |
| tiny F32 | da-long, 45 s, language detected | -- | -- | identical: da, nine segments, their times, the second window at 25.0 s |
| small F32 | da-short, 14 s | 1.5e-5 | 1.0e-6 | identical: "Den lille pi med svovelstikkerne af H.C. Andersen. Det var så grulig koldt. Det snede og det begyndte at blive mørk aften.", logprob -0.42276 |

**Speed, 2026-11-03** (small, 14 s of Danish, eight cores, quiet machine,
third of three rounds): f16 2.47 -> 1.68 s, the decoder 30 -> 10.5 ms a
token. What did it, measured one at a time on 45 s: the decoder's products
with integer activations where a matrix is quantized (the backend's float
path for a raw view decodes a block and dots it, 30 -> 19 ms a token on
Q8_0; f16 and f32 are untouched by it); the cross-attention's keys and
values laid out in panels a head once a window, each token's two products
a head on its own worker (19 -> 8.6 ms); row work of a few rows done on the
calling task. Kept but worth nothing measurable: the encoder's matrices
packed once a session (the encoder is the panels' own arithmetic, about
300 GFLOP/s of the kernel's 573). The binary32 files' transcripts stay the
reference's, token for token.

**Language detection without a second encoder pass.** The reference
detects the language with an encoder pass of its own, over the first 3,000
frames as they are; then decodes the first window zero-padded, a second
pass. `Options.Detect_From_Window` reads the language off the logits at
`<|startoftranscript|>` of the decoded window instead -- the same logits
the no-speech probability is read from -- and the encoder runs once.
Dictation does so; `transcribe` keeps the reference's way. On 14 s of
Danish, small f16, auto: 2.78 -> 1.85 s, the language da either way.

**Q8_0** (`--type q8_0`, ggml's encoding): 270 MB for small against 490
binary16, 1.53 s for the same 14 s. It is not the reference's arithmetic:
the encoder's output stands 0.37 of its largest value from the binary32
reference at its worst element, and on 45 s of Danish the text differs by
a comma and two words; on 14 s it is the same. It is for a machine short of
memory, not a default.

**The temperature fallback** is the reference's `decode_with_fallback`: a
window refused -- compression past 2.4, or an average log probability under
-1 and not silent -- is decoded again at 0.2, 0.4, ... 1, five drawn at
each (`best_of`), the likeliest over its length kept, and the window after
one decoded past 0.5 prompted with nothing. The draws are SplitMix64's from
a seed (`Options.Seed`), not torch's, so a retried window is not the
reference's to the token; every window of the three fixtures is decoded at
nought and is. Tiny made to hear Danish as English tries every temperature
and keeps the last, marked uncertain, as the reference keeps it.

**Word timestamps** (`--speech-word-timestamps`, `Options.Word_Timestamps`)
are the reference's `timing.py` and `add_word_timestamps`: the decoder
over the start of the transcript, `<|notimestamps|>`, the window's text and
the end once more, the alignment heads' scaled scores kept
(`whisper.alignment_heads`, which the converter now writes from
`generation_config.json`; without it, the upper half of the decoder's
heads); a softmax over the frames heard, each frame standardized over the
tokens, a median of seven, the heads averaged (`Whisper.Timing.Weights`);
the reference's warp (`Timing.Warp`, its ties broken as `dtw_cpu` breaks
them); tokens cut into words as `split_tokens_on_spaces` cuts them;
sentence-edge and pause clipping at twice the median; punctuation joined;
the segments' ends moved to their words'; the next window from the last
word's end. Held to a numpy transcription of `timing.py`: every word's
start and end the same to the hundredth on jfk.wav (tiny, 22 words) and the
Danish clip (small, 23 words). Found on the way: GGUFs converted before the
key existed read the default heads, so the six files here were converted
again.

**Translation**: `--speech-translate` puts `<|translate|>` for
`<|transcribe|>`; small on the Danish fixture writes "It was so crudely
cold. It snowed and it started to get dark in the evening."

## 7b. The corpus

`tests speech-corpus --model PATH` hears `tests/fixtures/speech/corpus.txt`
and scores it: word and character error rates against what is said, after
case and punctuation are taken away; the language heard unasked; the
seconds taken; each language's rates over its recordings; and the words
heard in silence. Noise is white, from a fixed seed, mixed in at a stated
signal-to-noise ratio. 2026-11-03, eight cores:

| model | en WER / CER | da WER / CER | words in silence | real-time factor en / da |
| --- | ---: | ---: | ---: | ---: |
| tiny f16 | 7.04 % / 4.73 % | 69.93 % / 36.74 % | 0 | 0.03 / 0.07 |
| small f16 | 0.00 % / 0.00 % | 25.49 % / 8.21 % | 0 | 0.18 / 0.28 |
| small Q8_0 | 0.00 % / 0.00 % | 25.49 % / 8.46 % | 0 | 0.16 / 0.17 |

English is jfk.wav clean, at 10 dB and at 0 dB, and its first 2.4 s; small
writes all four word for word (tiny gives way at 0 dB). Danish is a
LibriVox reading of Andersen in an old-fashioned diction: small's errors
are the reader's archaisms and names ("pi" for "pige", "grulig" for
"grueligt"), which the reference implementation makes too, word for word,
where it was run (da-short, da-long on tiny). That is the release criterion
the specification sets -- no degradation against the same checkpoint and
decoding in the reference -- and it holds: on the binary32 files the
tokens are the reference's.

Wanted and not had: Danish with English technical words, and Ada
identifiers spoken; see docs/fixture-provenance.md.

## 8. The harness

`Model_Runner.Speech` is the auxiliary owner: two tasks of its own (the
microphone, a tenth of a second a read; the model, loaded on first use while
the first recording runs), a protected state between them and the terminal,
the states the specification names. `Hostkit.Microphone` records (moved to
hostkit, where code that differs by host belongs: libpulse-simple opened by
name on Linux, refusals elsewhere). `CLI.Speech_Input` adapts it to the
line editor's `Choosers.Dictation`, and `Choosers.Edited_Line` takes the
shortcut: recording and hearing are shown dimmed after the line; Escape or
Ctrl-C give up; every other key is held and replayed once the transcript is
in, so typing during it neither races the insertion nor is lost (the
reconciliation the specification asks for, by not letting the two edits
overlap). `Choosers.Insert_Spoken` is the insertion policy, tested apart.
`model_runner transcribe FILE.wav` hears a file.

Checked by hand, through a pty and a PulseAudio null sink playing jfk.wav
into the recorded source: dictation after typed text, keys typed while it
was heard landing after it, Enter sending it to the conversation's model;
Escape while recording and while hearing leaving the line as typed.

In the suite: the insertion policy; the recognizer's states, refusals and
recovery (a source that does not exist, so no microphone is opened); the
memory admission; and a conversation's logits the same to the bit with a
Whisper model read, heard with, failed and closed beside it.

Options: `--speech-model`, `--speech-language`, `--speech-device`,
`--speech-max-seconds`, `--[no-]speech-keep-loaded`,
`--speech-initial-prompt`, `--[no-]speech-enabled`, `--speech-shortcut`;
each a settings-file key too. `transcribe` also takes `--speech-timestamps`.

**Undo**: Ctrl-_ (readline's undo key) puts the line back as it was before
the last transcript went in, while the line is still as the insertion left
it.

**In the suite, on a terminal** (`Dictation_In_A_Session`): the program
run under a pseudo-terminal with the tiny fixture conversation model, the
Whisper fixture and `--speech-device file:jfk.wav` -- a WAV file played as
the microphone, at its own pace -- and what was entered read back from the
history the session keeps: dictation after typed text keeps the text and
the key pressed while it was heard lands after it; Escape while recording
leaves the line as typed; Ctrl-_ takes the transcript out. The transcript
is decoded with errors replaced (U+FFFD), as the reference decodes, so a
model's broken bytes still make text that goes in.

Not checked: the shortcut against every terminal's own keys past the
editor's and flow control (tmux passes Ctrl-G through).

## 9. The device

`Backend.Device` is one queue fed from one task -- its own words: "one task
at a time ... makes no attempt to feed it from several" -- and keeps
process-wide state between the calls of a sequence (its cache, its resident
weights, the arithmetic switches). A second engine of Whisper's own on a
second context was looked at and is not safe: the products package's body
keeps unprotected globals (the instance its entry points resolve through,
the tile choice, the prefetch slots) that two engines on two tasks would
race on.

What the first audit missed is when speech is heard: while the line editor
waits, and the editor waits for the transcript (`Is_Done`) before it gives
the line back, even after Escape. `/work` runs from the session's task too
-- lines typed meanwhile queue in the terminal. So while dictation runs
nothing of the conversation's own runs, except the warming evaluation a
session starts with. That makes the lock a turn, not a scheduler in the
hot path: `Backend.Device.Lend_Turn` / `Take_Turn` / `Borrow_Turn` /
`Return_Turn`, a protected flag pair. The session lends the turn while a
line is waited for, once its model is warm (at the line's start, or when
warming ends during it), and takes it back before the line is answered --
waiting for a borrower to give it back. Whisper borrows it per encode where
the device is open and `Room_Beside` holds its weights, and runs on the
processor where the turn is not lent: it never waits for the conversation.
Outside a session the turn starts lent, so `transcribe` and `tests hear
--device` simply have the device.

On the device go the encoder's products (`Dispatch_Batch`, the file's own
weights, any shape the tile takes whole: Whisper's widths are multiples of
128 and its rows of 32; the first convolution's 240 columns stay on the
processor) and its attention both ways (`Attend` with `Causal => False`,
the keys and values put in the device's cache past the conversation's,
as the vision encoder does it). The
device knows a matrix by where its bytes lie, so a session's Whisper gives
its matrices back at the end of each encode while it still has the turn:
kept past it, a model read again at the same address would be answered
with stale weights. That costs 0.13 s a dictation on small. `transcribe`
keeps them and closes the device after.

Measured on this machine, small f16, 11 s of speech: encoder 2.35 s on the
processor, 1.25 s with the device (two encodes, as the language is
detected on the padded spectrogram); a session's dictation 0.4 s sooner
with the conversation on the device. Tiny and small f16 transcribe to the
same text on both; small Q8_0 differs by two commas on da-long (a near
tie, the f16 file's own text). Held by `speech : the encoder on the device
hears what the processor does` (the encoder's output within half
precision, products on the device, matrices given back, nothing asked of
the device without the turn) and `speech : the device's turn is lent`.

The decoder followed. Its products sent one at a time lost -- 2.8 s of
decoder became 4.7 on da-long, each a submission of its own at some 80 us
before any work, seventy a token -- so a token is recorded as the language
model's are: a sequence a block (`Feed_On_Device`), 26 steps of the 40 a
sequence holds -- the shifted norm with its bias (`Add_Norm`, `Shift`),
products and biases, the position's keys and values put in the block's
part of the cache (`Add_Place`) and attended to causally, the cross-
attention over what Encode put in the cache (`Causal => False`), the
joins, and GELU in its erf form (combine.comp's unit 10, the error
function by Abramowitz and Stegun's 7.1.26, within 1.5e-7; the tanh form
of unit 5 moved tiny's Danish by three points of word error, the erf form
scores as the processor does). The activation is carried from block
to block on the device (`Carry_Out`/`Carry_In`), and a last sequence
normalizes and, for one token, makes the logits; a prompt of more brings
its rows home and the pool makes the last one's logits. The cross-
attention reads the cache's half-precision copy (`Attend_In_Halves`, the
conversation's own choice put back with the turn): 170 us a block became
86. A small f16 token is 12 x 528 us and 1.24 ms of logits, about 7.6 ms
against 12 on the processor; da-long's decoder 2.7 -> 1.7 s, the whole
5.3 -> 3.3 s. The turn is now held for a whole transcription (`Hold`,
`Let_Go`, nested by who took it), the cache laid out as each block's
heard keys and values, then its own, then the encoder's scratch. Where a
step is refused or a run fails the pool goes on from the same place, the
positions' keys and values brought home first (`Bring_Home`); word
timing's pass, which needs the alignment heads' scores on the host,
decodes on the processor. Biases and norms are given back with the
matrices, as the device knows them by address too. Held by the device
test transcribing the wide fixture on both and getting the same text with
every position on the device (`Statistics.Device_Positions`), and by
`tests speech-corpus --device`: small f16 and Q8_0 score as on the
processor; tiny's Danish 73.2 % of words against 69.9.

Then three more. A window decoded again drew its five candidates one
after another, each through the whole decoder: 5 s of noise heard as
Nynorsk, every temperature tried, took 52 s. The reference draws them as a
batch, and so does this now (`Decode_Candidates`): the prompt fed once, its
keys and values given to each candidate, then a step at a time every
unfinished candidate's token fed in one pass over the weights, each
attending to its own keys and values (`Candidate_K`, `_V`) and every row's
logits made from one read of the table. A step of five costs what a token
did, 12.9 ms; the noise takes 25 s. The candidates run on the processor:
the device's attention reads one cache for a batch's rows. The draws come
from the same seeded stream in another order, a step at a time.
And a block's keys and values, the values' bias added and both placed in
the cache, are one heads step now where they were three (`Add_Heads` took
no head without a turn; a head with nothing turned now reads no table and
passes as it is): 1.5 % of the decoder, measured over six alternated
rounds, the text the same.

Then the cross-attention's and the projection down's biases were added to
the residual rather than to the product, so that each join folds into its
product's store: two dispatches a block fewer. On jfk that was right at
once; on da-long the down join's fold went wrong -- the text changed and a
round took 27 s. Found by placing the same bias step two ways: right
after the join it extends it was right, between the GELU and the
projection down it was not, and a bias step there with its answer unused
was right too. The fault was Products': a tiled product judged whether the
half-precision copy held its operand by the latest step it reads at all,
which for a product with a join folded into it is the join's residual.
Where that residual was made after the operand, the copy was taken not to
hold it and the operand converted again from its binary32 form -- which a
step written only as halves, the GELU here, never writes. The product's
operand (`Operand`: the step it names, the one before where it is
chained, or the activation) is what is asked now, and `cpu backend : a
join folded over a residual made after the product's operand reads that
operand's halves` holds it, failing without the fix (4.8e-2 off a largest
of 0.77) and passing with it. No language model's layer makes a residual
after its operand, so none answered wrongly. With it, Whisper folds both:
the decoder on da-long 1.683 -> 1.622 s over three alternated pairs (3.6
%), the six recordings' text the processor's.

And the projections' own biases into their products' stores, with no
kernel changed: a row kernel's store adds a folded join's residual at
`rj[out_at]`, and for one position `out_at` is the row, so the bias bound
there is added row for row (`Add_Bias`'s `Fold`). Products refuses a
folded bias over more than one position, where the residual is read a
position at a time, and on a device whose storage alignment (now read:
`Platform.Device.Storage_Alignment`, minStorageBufferOffsetAlignment, 4
on the 780M) the bias's offset does not keep; Whisper names the token
again without folds then, and stops asking. The queries', the cross
queries', the up projection's and the first output projection's biases
fold: decoder on da-long 1.636 -> 1.553 s over three alternated pairs (5
%), the six recordings' text the processor's; held by `cpu backend : a
bias folded into its product says what the bias step says, and refuses
two positions`. Left as dispatches of their own: the first join, whose
residual is the block's carried activation and no step a bias can be
added to, and the three norms.

And the candidates on the device. The device's attention reads one cache
for a batch's rows, where each candidate has its own keys and values; so
the candidates are made heads of one position (`Add_Attention`'s
`Rows_As_Heads`): their keys and values lie in a row of five widths a
position (`Wide_Keys_At`), candidate c's in its c-th, placed there by the
heads step's row stride, and the attention takes one position of five
times twelve heads, head c * 12 + h reading candidate c's columns -- the
rows of a batch lie in memory as that one row does. Only the token kernel
takes it, which is the one a single position takes; Products refuses it
anywhere else. The products and the attention to what was heard are an
ordinary batch of five; every candidate is fed each step, one that ended
a dummy whose answer goes unread, so that row c stays candidate c; the
prompt's keys and values are put in every candidate's columns once a
round. 5 s of noise tried at every temperature: 24.1 s on the processor,
13.5 s with the device; the corpus scores as before (small identical,
tiny's Danish 67.3 % -> 68.0 % of words: a noisy window's candidates draw
from probabilities a device rounds otherwise). Room for the candidates'
rows is taken with the turn, and left out where the cache has none.

Found while measuring it: every transcription on the device put
Whisper's part of the cache past what the cache last held -- its own
part from the turn before among it -- so the cache grew by a part each
time, and in a session by one each dictation; the corpus's ninth
recording, silence, took 0.82 s on the device for 0.22 on the processor,
copying the eight before it to reserve its own. A turn now puts it past
what the conversation's sessions have reserved (`Hold`,
`Backend.Device.Cache_Claimed`; Whisper's own reservation is `Scratch`
and does not move it). The vision encoder had the same fault, a
picture's worth of cache each picture, and the same fix; both are held
by their device tests transcribing or encoding twice and finding the
cache as the first left it. The first fix, where the last turn's part
went wherever the cache had not grown since, was found unsafe in review:
a conversation's pages grow into the room a reservation leaves past what
it asked without the cache growing, and the next dictation would have
written over them. The speech device test claims that room as a
conversation would and finds the next transcription put past it.

What is left of a token's small steps on the device is the first join
and the three norms. Two of the three joins are inside their products'
stores already, so the norms cannot go: what a fused join-and-norm would
save is the first join, about 1.5 % of the decoder, and the norm kernel
adds a residual after normalizing where Whisper needs it before -- a step
that writes two answers, the sum and its norm, which nothing here has.
Not built.

Also found here: a recording of thirty seconds or more had its first
window encoded twice, once for the language and once to transcribe, though
the two windows are the same frames. The language's encode now stands for
it (`First_Heard`); a shorter recording's language is still read from the
padded spectrogram by an encode of its own, as the reference reads it.
