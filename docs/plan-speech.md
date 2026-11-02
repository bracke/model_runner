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
`added_tokens.json`, `model.safetensors`).

## 3. Audio

`Model_Runner.Fourier` (mixed radix, any length), `Model_Runner.Audio` (WAV,
mixing, resampling), `Model_Runner.Audio.Spectrograms` (log-Mel). Held to
the reference: filters to 1e-8, spectrograms of both fixtures to 1e-4 at a
grid of points and their means to 1e-5.

## 4-7. Encoder, decoder, transcription

To be filled in as built.

## 8. The harness

To be filled in as built.

## 9. The device

To be filled in as built.
