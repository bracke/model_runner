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

What is not done: the reference's temperature fallback (decoding again,
sampled, when a window repeats itself or is unsure). A window that would
have been retried is marked uncertain and kept; nothing is sampled.

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

Not done: an undo of the insertion (the editor has none to extend); the
shortcut's conflicts beyond the editor's own keys and terminal flow control
(tmux passes Ctrl-G through).

## 9. The device

To be filled in as built.
