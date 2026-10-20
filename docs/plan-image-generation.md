# Text to image: Qwen-Image 2.1

**A plan, written 2026-10-20. Nothing of it is built yet.** The reference is
stable-diffusion.cpp, which supports this model (`docs/qwen_image_2.1.md`).

What this program does today with pictures is read them: a projector turns
a picture into rows a text model attends to. This plan is the other way
round -- a prompt in, a picture out -- for one model, Qwen-Image 2.1, whose
three files are in the model store:

| part | file | size | what it is |
| --- | --- | ---: | --- |
| denoiser | `qwen-image-2.1-Q8_0.gguf` | 7.6 GB | the image transformer, unsloth's Q8_0 |
| text encoder | `Qwen3-VL-8B-Instruct-Q8_0.gguf` | 8.7 GB | Qwen3-VL-8B, its text half used |
| VAE | `qwen_image_2.1_vae_bf16.safetensors` | 0.7 GB | latent to pixels |

The aim is `model_runner image --prompt "..." --out picture.png`, on the
780M first and the processor as well, its picture matching a reference
implementation's for the same noise. Not in this plan: editing a picture
(the `ti2i` template and condition images), LoRAs, the Turbo distillation,
video. Each is a step after this one and is named where it touches it.

Every step is held the way the log holds the engine's: a number predicted,
built, measured against the reference, kept or refused, written down.

---

## What the files hold

Read from the files and from the reference implementation (diffusers
`QwenImage21Transformer2DModel`, `AutoencoderKLQwenImage21`,
`QwenImage21Pipeline`, `main` of 2026-10-20).

**The denoiser** is a single-stream transformer: 32 blocks, width 4096, 32
heads of 128, a SwiGLU feed-forward three times the width (`gate_up` fused,
24576 wide, its **first half the gate** that takes the SiLU, its second
the up, then `out`), no biases anywhere. 7.1 billion parameters, 265
tensors, and **no metadata at all** -- no architecture key, no shapes said:
the file is known by its tensor names (`model.diffusion_model.img_in`,
`txt_in`, `time_text_embed`, `modulation.1`, `transformer_blocks.N.*`,
`norm_out`, `proj_out`) and its shapes are the configuration.

- The latent is 64 channels at a sixteenth of the picture, patch size 1:
  a 1024x1024 picture is 64x64 = 4096 image tokens, each 64 wide in and out.
- The prompt's rows come in 4096 wide (`context_in_dim`) through `txt_in`:
  a zero-centred RMS norm (scale `weight + 1`), a linear, a tanh GELU, a
  linear.
- The time is a 256-wide sinusoid (cosines first, the time times 1000),
  through two linears with a SiLU between.
- Modulation is not per block: one linear (`modulation.1`) of the SiLU'd
  time embedding, 4 x 4096 wide, cut into four in order -- attention's
  scale, attention's gate, feed-forward's scale, feed-forward's gate --
  which **every block** reads (stable-diffusion.cpp `qwen_image_2_1.hpp`
  at b13a48219d passes the same four to all 32).
- `causal_condition`: the time is embedded twice, the step's and 0, so
  each of the four has two rows: image tokens take the step's row, text
  tokens the time-0 row. Scales are applied as `1 + scale`, gates as
  `tanh (gate)`. The output norm's scale is `norm_out.linear` of the
  step's row alone.
- A block: LayerNorm without affine, times `1 + scale`; attention (q, k, v,
  an RMS norm on each head's q and k, a three-axis rotation 16/56/56 at
  theta 10000), its output through `tanh (gate)` added back; the same again
  for the feed-forward. The last norm is scale-only, then `proj_out`.
- The attention is **block-causal**: text tokens attend causally among
  themselves and see no image; the image's tokens attend to all the text
  and to each other both ways.
- Positions, as the reference lays them out: the prompt's tokens (the
  system turn already dropped) at `(p, p, p)` for p = 0, 1, ...; the image
  at frame `n`, the prompt's length, row `h - (H - H/2)` and column
  `w - (W - W/2)` -- a 64x64 latent from -32 to 31. The rotation pairs
  **neighbouring** elements (2i, 2i+1), its 128 split 16/56/56 over frame,
  row and column. The GELU in `txt_in` is ggml's tanh form.

**What the denoiser file holds** (unsloth's Q8_0, read 2026-10-20): every
block's products Q8_0; `img_in`, `txt_in`'s two linears and its norm
BF16; `norm_out.linear` and the q/k norms F32; no biases at all, the time
embedder's two linears included. BF16 the GGUF reader takes already.

**The text encoder** is Qwen3-VL-8B's language model -- Qwen3 dense, 36
layers, 4096 wide, grouped attention 32/8, the multimodal rotation
interleaved 24/20/20 at theta 5,000,000. The file's architecture key is
`qwen3vl`, which this build refuses by name today (`MR-ARCH-0002`). For a
prompt of text alone the multimodal rotation reads as the plain one. What
the denoiser is given is the **last layer's output before the final norm**,
for every token of the prompt, the system turn's tokens dropped -- the
reference asks for layer 36's output (`out_layers = {num_layers}`) and
counts the dropped tokens by tokenizing the system turn alone. The prompt
is a raw template, not the chat template:

    <|im_start|>system
    Comprehend and analyze the provided prompt.<|im_end|>
    <|im_start|>user
    {prompt}<|im_end|>
    <|im_start|>assistant

**The VAE** is Wan 2.2's shape, used for one frame: 64 latent channels, a
sixteenth spatially; a decoder of base width 144 through 1, 2, 4, 8, 8
times, two residual blocks a level, a mid block with one attention, a
channel RMS norm, SiLU, and duplicating up-samplers (repeat and pixel
shuffle). Its "causal 3-D" convolutions are written as 2-D convolutions,
so a picture needs only 3x3 convolutions. The latent is unnormalized
before decoding with 64 means and 64 deviations from its config. bf16,
safetensors -- a format this program does not read yet.

Two traps the reference knows of:

- The decoder writes **four channels: red, green, blue and alpha**. The
  model decides from the prompt whether a picture is transparent ("This is
  an RGBA image with transparency. ..."); the PNG is written RGBA.
- The up-samplers keep Wan's temporal factors (`true, true, true, false`)
  even for one frame: they change how channels are grouped when
  duplicated, so a 2-D reading that drops them reorders channels silently.
  The reference also scales every convolution by 1/128 to keep the
  activations within binary16 -- a sign of their range, which matters for
  a binary16 device path.


**The sampler** is flow matching, Euler: `x <- x + (sigma_next - sigma) *
v`. The sigmas, as the reference's `FluxScheduler` works them out for this
model: `mu` linear in the image's token count, 0.5 at 256 and 0.9 at 8192;
for `t = 1 - i/n`, `sigma = e^mu / (e^mu + 1/t - 1)`; then every sigma
but the last stretched, `1 - (1 - sigma) / k`, so the last one the model is
run at is 0.02; the last is 0. The model's time is the sigma times 1000.
The pipeline's default is 40 steps. Guidance (a negative prompt, the
reference's `--cfg-scale`, 6 in its example) is optional and doubles a
step.

---

## Steps, in order

### 0. A reference to hold every step to

There is none on this machine: no stable-diffusion.cpp, no torch. Build
stable-diffusion.cpp at a pinned commit, CPU and Vulkan, as llama.cpp is
built beside this program -- unsloth's card runs these three files with it.

- A small harness that writes, for one prompt and one seed: the encoder's
  rows, the denoiser's velocity at step 1, the latent after N steps, and the
  decoded picture.
- The **same noise on both sides by seed**: the reference's generators are
  small -- `--rng cuda`, its default, is Philox in 96 lines
  (`src/core/rng_philox.hpp`); `cpu` is torch's MT19937 with Box-Muller
  (`rng_mt19937.hpp`) -- and one ported here gives the same latent from the
  same seed, held to the reference's first values in a unit test. Done
  for Philox: `Philox_Noise` (in `examples/mr_reference/ada` of the clone,
  waiting for step 4) matches it **bit for bit** -- seeds 0, 42, 2^64-1
  and 123456789012, up to 262,144 values, three draws running -- once its
  logarithm, root and sine are taken in binary64 as the C++ overloads do;
  in binary32 they differ by up to 3 ulp. Seed 42 begins 0.19401887,
  2.1613739, -0.1720506, 0.8490601 -- torch's CUDA randn. The
  command line has no noise or tensor dump of its own, so the harness is a
  small program against its library that writes them out: written,
  `examples/mr_reference` in the clone (`mr-reference`, not yet built). Its
  eval callback dumps every graph tensor whose name or op matches `--dump`
  as raw f32 and lists them in `index.tsv`; with no `--dump` it lists what
  the graphs compute; the picture is written as a PAM. Graph cutting is
  turned off so each graph is seen whole, and the callback is ignored under
  the backend scheduler, so the reference runs on one backend -- the CPU
  for the numbers held to.
- Cloned at b13a48219d into `~/stable-diffusion.cpp`, beside `~/llama.cpp`.
- The tensor layout questions, answered from its source (b13a48219d)
  before any build and written above: `gate_up` is gate first; modulation
  is shared by all blocks; the VAE's four channels are RGBA.

Done when the harness writes all four for a 512x512 prompt.

### 1. Reading the files

- **The denoiser without metadata**: known by its tensor names, its
  configuration read off the shapes (layers counted, width from `img_in`,
  head width from `norm_q`, feed-forward from `out`), and refused by name
  where a shape is not this model's. It is no text model and goes nowhere
  near `Llama.Prepare`; it gets a package of its own.
- **Qwen3-VL's text half**: `qwen3vl` taken by the Qwen3 dense path, the
  rotation's sections read from `rope.dimension_sections` as Qwen3.5's are.
  Its vision tower (deepstack) is not needed for text to image and stays
  refused.
- **safetensors**: an eight-byte header length, a JSON header, raw bf16
  tensors -- read mapped, the way GGUF files are. Small, and needed by any
  diffusion VAE, which is rarely published as GGUF.

### 2. The prompt's rows

A new output of the engine: every token's state after the last layer,
before the final norm, rather than logits. The template above, tokenized by
the file's own vocabulary; the system turn's tokens dropped (their count
found by tokenizing the system turn alone, as the reference does).

Held to the reference's rows at a cosine of 0.9999 a row on the Q8_0 file.
The encoder runs once a picture: about 0.2 s of prefill on the device.

### 3. One step of the denoiser

Every piece above, in binary32 on the host first, held to a binary64
computation of the same network in the suite -- a denoiser written small (2
blocks, width 64) by a fixture encoder, as the vision encoders are tested.

- **The prompt's keys and values once a picture.** Text attends only to
  text, causally, and takes the time-0 modulation, so its keys and values
  are the same at every step: computed once, kept per block as a cache, and
  each step runs **only the image's tokens**. The reference does this too
  (`QwenImage21KVCache`). With a few hundred prompt tokens against 4096
  image tokens it saves little compute, but it is what keeps a step to one
  pass over the image rows.
- Image rows attend to the cached text keys and to each other both ways --
  what `Evaluate_Batch` already does for a picture's rows in a text model.

Held to the reference's velocity at step 1: a cosine of 0.999 over the
latent on the real file, the rest being Q8_0.

### 4. The sampler and the picture's latent

The sigmas worked out as the scheduler does, held to its values to 1e-6 in
a unit test. Euler steps. Gaussian noise from a seed through the reference's
own generator, ported, so a seed gives its picture on both. Guidance
with a negative prompt, where asked: two passes a step, each with its own
cached prompt.

Held to the reference's latent after 40 steps from the same noise.

### 5. The VAE decoder

New kernels: a 3x3 convolution (lowered to the matrix product the engine
already has -- the input's neighbourhoods gathered into rows), the channel
RMS norm, the duplicating up-sampler. The mid block's attention is 4096
positions at width 1152 -- the encoder's attention, told that no position
comes before another. Decoded in tiles of 256 with a 64-pixel overlap, as
the reference tiles, so a 1024x1024 picture never holds its full-size
activations at once (144 channels at full size are 600 MB a tensor).

Held to the reference's picture from the same latent: 40 dB PSNR.

### 6. The command

`model_runner image --prompt TEXT [--negative TEXT --cfg SCALE] [--size
WxH] [--steps N] [--seed N] --out FILE.png`, the three files found in the
model store by name or given by `--model`, `--text-encoder` and `--vae`. A
line a step with its time; Ctrl-C stops between steps. Sizes are multiples
of 32; 1024x1024 by default. A PNG written through the zlib crate, which
already compresses. The suite's own PNG reader reads the result back.

The text encoder is loaded, used and **let go before the denoiser loads**:
the two together are 16 GB, and this box has 30.

### 7. The device, and speed

Measured before it is promised; what the arithmetic predicts:

| | per step | 40 steps |
| --- | ---: | ---: |
| 1024x1024 (4096 image tokens) | about 62 TFLOP | |
| on the 780M at the 4-5 TFLOP/s a prompt batch runs at | 12-15 s | 8-10 min |
| 512x512 (1024 image tokens) | about 15 TFLOP, 3-4 s | 2-2.5 min |
| on eight cores | about ten times slower | |

The linear products are a prompt batch's -- 4096 rows against Q8_0 weights
-- which is the device's fastest path already (the 64-row tile). Attention
over 4096 image tokens is the deep-attention kernel's work. The step is the
same shape forty times, so command buffers can be recorded once and
replayed. Turbo, a distilled model taking a few steps, is the large lever
on time, and needs no new code once this works.

### 8. Done

- `image` writes a picture for a prompt on the device and on the processor.
- Its latent and its picture agree with the reference's from the same
  noise: cosine 0.999 on the latent, 40 dB on the picture.
- The suite holds each part to a binary64 computation on small fixtures,
  and the real model to `tests image --expect` with the reference's numbers
  recorded, as `tests see` holds the vision encoders.
- The support matrix, the changelog and the measured figures say what was
  built and what it costs.

---

## Risks and open questions

1. **The reference's support.** stable-diffusion.cpp runs this model and
   these three files by name, prompt-prefix cache included; what is left is
   building it here and checking its CPU picture against its Vulkan one.
2. **The layout questions in step 0** are answered from the reference's
   source; each still gets held to the reference's numbers, since a
   misread is a silent wrong picture.
3. **Memory.** 7.6 GB of denoiser on the device is within its budget; the
   encoder must be gone first. The VAE at full size is held in by tiling.
4. **Time.** A 1024x1024 picture at 40 steps is minutes on this machine.
   That is the model's arithmetic, not a defect to chase -- the levers are
   fewer steps (Turbo) and smaller pictures.

## The order of the work

| step | what | about |
| --- | --- | --- |
| 0 | reference built, harness, layout questions answered | 1 session |
| 1 | the three files read | 1-2 |
| 2 | the prompt's rows | 1 |
| 3 | one denoiser step, host, against binary64 and the reference | 2-3 |
| 4 | sampler, noise, guidance | 1 |
| 5 | VAE decoder and its kernels | 2-3 |
| 6 | the command and the PNG | 1 |
| 7 | the device path, measured | 2-4 |
