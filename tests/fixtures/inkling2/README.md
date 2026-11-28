# Inkling source fixtures

These include source-audit inputs, independently executed tokenizer/template
recordings and independently executed reference activations. Native CPU and Vulkan
conformance is recorded in [verification](../../../docs/inkling2-verification.md).

`q4_k_m-int8-prefix/manifest.json` is the directly addressable canonical
byte-activation cached-prefix capture: all 834 final-token tensors agree
byte-for-byte between independent prefill and decode. Native CPU integer
execution now matches every captured value exactly for both this prefix and
Hello, including grouped expert execution, with row-major weights on the
recorded AVX-512 host. Native and interleaved integer products now pass the
independent fixtures, and the full interleaved checkpoint matches all 834
captured tensors exactly. The native Vulkan reference integer path now passes
five-format operator comparisons and both full-model captures exactly; its
bounded throughput trial did not finish. The
new tile test repeats/permutates independent golden rows and vectors to cover
odd rows, five-vector tails, offset spans and cached native header scales.
Paired gathering, activation packing and capacity reuse use the independent
Q5_0 golden products. See `docs/inkling2-integer-eight-evidence.json`.
See [integer evidence](../../../docs/inkling2-integer-native-evidence.json).
The older `q4_k_m-cpu-prefix/manifest.json` is a multi-mode comparison summary
and must not be passed directly to the optional tensor-comparison test.

The full 18658096192-byte Q4_K_M file is downloaded in the normal models store.
Both native `Hub.Fetch` and independent GNU `sha256sum` verified
`ed38ac618a24ee65142c27073783a80aa3b100546a21212d59690c9081945a9b`.
Native full-file inspection matches every captured tensor descriptor and
accepts the fixed-loop structural contract.

`q4_k_m-cpu-hello/manifest.json` identifies 834 independently captured
tensors for token 32269 (`Hello`), using the canonical CPU build with
`GGML_LLAMAFILE=OFF`, including all 48 layer outputs, 48
eight-expert selections, 24 cross-loop messages, 96 controller outputs and
200058 unpadded logits. Nine F32/I32 bundles preserve every captured value
without storing weights. Offsets, dimensions, byte lengths and per-tensor
hashes make every slice addressable; dimension zero is fastest. Each bundle
is below 2 MiB. All floating values are finite, and each expert selection
contains eight distinct IDs in 0-127. The greedy next ID is 11. These are
reference goldens, not passing native comparisons; tolerances remain unset.

`q4_k_m-cpu-prefix/manifest.json` records the five-token English prefix in
five reference modes across two explicitly identified builds. Each stores final logits/norm, final-token layer
outputs, router logits, biased routing scores and selected IDs. Prefill at
microbatch eight differs from incremental decode: maximum logit difference
0.4003310203552246, RMS difference 0.09638334313653585. Both choose next ID
152717. Prefill at microbatch one is byte-identical to incremental decode
for every stored value; all raw F32 captures also agree exactly.

A controlled rebuild changed only `GGML_LLAMAFILE` from on to off. With
it off, prefill at microbatch eight and incremental decode match exactly
for all 834 final-token F32/I32 tensors. That is the initial conformance
reference. The optimized build's discrepant outputs are retained separately;
no native tolerance is inferred from them. The manifests record both sets
of binary hashes, the single CMake change and all comparison values.

The external capture code is licensed under the upstream MIT terms in
`REFERENCE-LICENSE.txt`. Build and capture reproduction are documented in
[the reference document](../../../docs/inkling2-reference.md). To reproduce
the bundles, retain each callback's raw little-endian payload and `.shape`;
concatenate payloads in the manifest's file/offset order and verify their
individual and bundle hashes. Prefix layer/router bundles retain only the
final token column, in the listed logical execution order; their manifest
retains parent shapes. Final outputs are copied without numerical conversion.

`chat-template-cases.json` records six independent renders using the pinned
Transformers template compiler with Jinja2 3.1.6 and MarkupSafe 2.1.5. It
contains exact inputs, expected text/errors, compiler source hash and template
hash. Cases cover the default effort, generation-prompt flag, no reasoning,
medium effort, a tool round trip and an invalid effort. The compiler factories
were extracted as unmodified AST nodes from the official utility module;
no native renderer supplied the expected text. The selected GGUF contains
the same template bytes as this snapshot. The template itself does not append
an assistant prefix when `add_generation_prompt` is true.

`reference-capture.patch` instruments the external llama.cpp b12600 source
for finite F32 activation and I32 expert-ID capture. It is reference-only test material, never
part of the native build. See the reference document for application, build
flags and capture commands. It has been exercised on TinyLlama and the
verified Inkling GGUF above.

The four `tokenizer-*.expect` files are independently executed tokenizer
goldens. They were captured with llama.cpp b12600, commit
`29b52d398b294509746ec0a3f28948a3107c0213`, using `llama-tokenize --no-escape --ids`.
The vocabulary was loaded from the pinned 32 MiB header in a sparse file of
the published full length. This reference tool sets `vocab_only=true`; no
weight payload was read. Native `tests tokenize --special` matches all four
lists exactly. All four captures were subsequently repeated against the
fully hashed download; reference and native IDs remain identical. This
qualifies these tokenizer inputs, not the model's inference engine.

The reference reports that EOS is not initially in its EOG set, then adds
it; its vocabulary-only context also reports a zero training context. These
warnings are retained in the capture logs and are not evidence of decoder
execution. Token IDs do not depend on the zero-filled weight region.

Inputs are the literal `prompt` directives in each recording. Special-token
parsing is the reference default; the official metadata declines BOS/EOS
insertion. There are no greedy or logit directives in these recordings.

`q4_k_m.gguf.pointer` pins the initial Bartowski Q4_K_M file's published
SHA-256 and byte length at revision `ad66863fd3b7f3236c0b7a0862412c9e00f78a6e`.
`q4_k_m-tensors.tsv` contains all 704 descriptors read by native inspection
from a 32 MiB range capture; columns are name, dimensions and tensor type.
`q4_k_m-metadata.txt` summarizes architecture and tokenizer metadata, with
array counts only. The full GGUF hash and header correspondence are now verified.
These are structural observations, not numerical expected outputs.

`q4_k_m-architecture-metadata.json` additionally records all 36 architecture
keys with exact scalar types, F32 values and complete head/window arrays.
These were extracted with the pinned reference's official gguf C API using
`no_alloc=true` and no tensor context, from the same header-only sparse
inspection file. No weight payload was read. Query each `inkling2_loop.*`
key with `gguf_get_kv_type` and its matching typed accessor; for arrays use
`gguf_get_arr_type`, `gguf_get_arr_n` and `gguf_get_arr_data`. Boolean arrays
use one byte per entry, as specified by that API.

`q4_k_m-layout.json` and `q4_k_m-imatrix.pointer` are publisher provenance
captured byte-for-byte at the same revision. The layout's absolute paths are
the publisher's build paths, not paths to artifacts in this workspace.

```text
6b11eb5f86f2311ee96322ae90490d233580dde0c593d2d7cc49e21acff6d88a  q4_k_m-metadata.txt
d7386c4d9290d68238cee3ba0d6ccdec666b539f768cbf598ee3f6bc9094f861  q4_k_m-tensors.tsv
b8b513af6dc311376519980ac88aa81a135e4165c9a4b2e607968bb3cd71ed8b  q4_k_m.gguf.pointer
119aa40844b99d0e7a4e4b871c0798e414f577fa076047665029af71cd728ec7  q4_k_m-layout.json
276bca39a78d34c62ae27f19388c5f3fefcbfce06554b2983a4b21dddfd6671a  q4_k_m-imatrix.pointer
```

See [the reference document](../../../docs/inkling2-reference.md) for the
selected artifact, header hash and inspection-only sparse-file procedure.

`config.json` and `chat_template.jinja` were retrieved on 2026-11-24 from:

- Repository: https://huggingface.co/thinkingmachines/Inkling-2-Mini
- Immutable revision: `7a67ae2314b44ef05c87fd1d4d311c58aaeb18f6`

The official model API declares Apache-2.0 and Transformers. Initial main-branch
snapshots were subsequently retrieved at this immutable revision and verified
byte-for-byte by SHA-256. The same revision supplies `tokenizer_config.json`,
`generation_config.json`, `hf_quant_config.json` and `processor_config.json`.
All six snapshots preserve original bytes. Official weights are not vendored
or downloaded; the selected GGUF is the quantized inference reference.

```text
a7a349601f0984c4abf999c480ef775d8567d21f5f84b4e8a3e035b44f288dc2  config.json
53a9035f3255945704b5857657cfb00c1165090c0641c4f782a0cbf268cc16dc  chat_template.jinja
001d5c7f03d19f353774ef9cdb99319f3b671327bdc1cc612728c605ace58a18  schedule.txt
bf09342d285139fd37ce10c70878af1d52cb390e9901e10248654293a80ee636  tokenizer_config.json
a08737c07a65a8fdf69f7cf086576210e5aad4b241437090b26d7b0c4f7905f7  generation_config.json
7c656207d3ce37879c7be209a036b0dde43bf01f78159bff06880b868ed57143  hf_quant_config.json
d7350adce18c8be4b607f261c8f0f7eabbf720bb7aaf648a43d4f8372bbacc2d  processor_config.json
86f30cceaddc46d151496e27797f8efcb3d44e2c3bb81591376bc39d400160e8  q4_k_m-architecture-metadata.json
19ac91f1f24c4f09ba710058fe4a55e1a051ee90bd79333543c474ad4e60a5b3  chat-template-cases.json
2e97e9a28cb74168ad34e8894e4beb741bde8ccfd2e629cb575c0528a4b20462  reference-capture.patch
```

`schedule.txt` has 48 literal rows, four columns: zero-based logical position,
zero-based physical layer, one-based visit and zero-based cache/history slot.
It was transcribed manually from the independent Transformers loop ranges and
`cache_offset` expression, then checked against llama.cpp's loop graph and
`layer_phys`. It was not emitted by the native schedule builder. Reproduce it
by tracing prelude 0-5, core 6-17 three times and epilogue 18-23, retaining
physical state IDs for first visits and appending later core slots at 24/36.

Reference identities:

| Source | Inspected Git blob |
| --- | --- |
| llama.cpp `src/models/inkling2-loop.cpp` | `8366a1191f253c0d6e5cc1c611979eca33e462dc` |
| llama.cpp `src/models/inkling2.cpp` | `45477a69e35e13bfe638aa3617486edea26fb78d` |
| Transformers `modeling_inkling2_loop.py` | `78498834e2806e83a1bb96eea5cf5447d9b1531f` |

The loop source commit is `690b87d88151dbd775bb6eff5581663688785928`;
the Transformers source commit is `046bdb8cc2cee29d233964bb77fe6fd37cfe4aa3`.
The base `inkling2.cpp` source was fetched from master and is identified by its blob above.

SHA-256 of the inspected source text, retrieved through the GitHub connector
and saved with a final newline (sources are not vendored):

```text
635948697cb841c7db6a940ed4868800e0b5f4d4d8ef24ccb5df44cd83c47121  inkling2-loop.cpp
971dedc098a1e4f8cae45643dbec7f1bdc6b80192426b4480f5b4a94840a73e3  inkling2.cpp
1c8e65b45a11c13ecad86c088105acd5e4567123ef6599844a95912d242e9f28  modeling_inkling2_loop.py
8dfd9d28cbac6ee1e5e8804c83b06f752acebce304b5587346813ecee869ec07  llama-arch.cpp
```

Run the schedule comparison through the existing AUnit suite from `tests/`:

```text
alr build
./bin/tests test --only "execution schedules"
```

More operation-level/lifecycle fixtures, resolution of the batched reference
discrepancy and target-machine baselines remain missing. Do not derive expected numeric
outputs from model_runner or relax tolerances to claim conformance. See
[the capture protocol](../../../docs/inkling2-reference.md) and INK-002/006.
See [precision profiles](precision-profiles.md) for the independent reference
overrides, exact input IDs, unchanged F32 tolerances and the separate F16-cache
precision envelope.


The `q8-dot-reference`, `f32-dot-reference`, `q4k-dot-reference`,
`q5k-dot-reference`, `q6k-dot-reference` and `q50-dot-reference` files
independently exercise the native integer profile's activation packing and
binary32 reductions. Their producers are an external-runtime patch,
`reference-integer-fixture-producers.patch`, applied to the pinned llama.cpp
checkout and compiled outside model_runner. The native repository remains Ada-only;
no reference executor is linked into model_runner. Adjacent JSON
files record exact producer, library, input and output hashes. The
`q8-attention-*` fixture preserves an independently captured 3072-coordinate
attention input whose Q8 scale reproduces the smallest binary16-subnormal
rounding bug. The original 834 checkpoint captures were verified byte-identical
before using the expanded independent diagnostic capture.

To reproduce the independent operator fixtures, apply the producer patch with
`patch -p1` in a separate checkout of the pinned llama.cpp revision. The patch
adds `examples/inkling2-fixtures/{q8-dot-reference,f32-dot-reference,quantized-dot-reference}.c`
to that external checkout. Compile those files there with the commands and
pinned library recorded in the adjacent JSON files; the original capture
commands and source hashes remain preserved. Write reproduced outputs to a
temporary directory and compare their hashes to the committed binary fixtures.


The streaming integer qualification adds one-through-nine-vector native and
direct-panel comparisons, with and without the compact coefficient cache. All
five formats retain independent golden outputs. A 2304-coordinate differential
case checks the previously qualified reference FMA lanes, specifically catching
a misplaced Q6 bias that short fixtures did not expose. SIMD reference packing
also checks nearest-even ties, signed first maxima, block sums, half scales and
nonfinite rejection. The measured activation callback is checked against the
independent Q5_0 products. No golden fixture bytes are regenerated or relaxed.
See `docs/inkling2-integer-stream-eight-evidence.json`.

The joint-product qualification extends the long-row differential case through
17 vectors, checks two matrices with permuted rows, odd output-row tails,
nonzero output origins and untouched sentinels. Truncated partners and aliased
outputs are refused before writes. Q8_0/Q5_0 tests additionally inject -128
activation bytes against a separate scalar signed-integer calculation using
nonzero independent fixture scales and the reference binary32 lane fold.
The older sign-negating helper is not a valid oracle for that byte value.
Existing golden files, provenance and tolerances remain byte-identical.
See `docs/inkling2-integer-pair-eight-evidence.json`.

The next quantized-path qualification covers five output rows and 1 through 17
vectors across all five native formats, direct cached coefficients and
permuted destination slots with untouched guards. Batched Q4T rotations are
bit-exact against scalar transforms. Four-query attention passes the existing
independent full-checkpoint attention and cache lifecycle checks. The optional
native Vulkan operator case uses 2304-column repeated independent fixture
blocks, exact reference-lane checks and refusal of an unpadded final word.
Existing golden files, provenance and tolerance envelopes are unchanged.
See `docs/inkling2-quantized-next-eight-evidence.json`.

The GPU checkpoint comparisons use F32 KV storage. The extended GPU integer
Q4T lifecycle case did not finish within 600 seconds and is not qualified.

The following evaluation checks indexed packed inputs with repeated and
permuted sources, nonzero array origins, one source serving many outputs and
rejection before writes for invalid maps. Wider Q4T value updates preserve
per-channel binary32 decoding and binary64 accumulation order. Native Vulkan
groups cover one through 17 vectors, separate input slices, five mixed
quantization formats and rejection of mixed reference/non-reference groups.
The private 4 GiB profile passes full-checkpoint Q4T attention, cancellation
and rewind. The earlier shared-host timeout remains unqualified. The optional
block layout and test-only vector math replacement were rejected. Golden
files and tolerance envelopes are unchanged. See
`docs/inkling2-quantized-followup-eight-evidence.json`.

A final regression rejects an unaligned stride for a single indexed packed
input before writes, while preserving the ordinary single-vector path where
stride is unused. The regression failed before the guard and passes after it.


The reference SiTU fixtures contain 65,536 gate/up pairs with zero, tiny,
saturation, sigmoid-overflow and reduction-boundary inputs. The checked-in
`reference-situ-generator.patch` extracts a test-only C generator using
scalar glibc 2.39 `tanhf`/`expf`, explicit
binary32 stages and disabled contraction. `reference-situ.json` records hashes
and reproduction commands. Apply the patch under `/tmp`, then run the generator in a separate directory and
compare hashes before replacing any fixture. Production inference does not
execute this generator or link another model runtime. The optional Vulkan
SiTU test requires exact output bits, and the resident mixture test verifies
one through eight experts and ordered weighted accumulation. Set
`MODEL_RUNNER_INKLING_REFERENCE_GPU=1` for these operator tests, and
`MODEL_RUNNER_INKLING_CHAIN_GPU=1` with the actual-model Q4T test to require
that the existing 256 MiB expert-cache reserve executes resident sequences.


The K-format follow-up keeps eight-token tiles and checks streamed rows through
33 tokens against the qualified scalar lane oracle. Shared transformed input
packing is checked serially and with the existing CPU pool for all five native
integer formats, including non-finite rejection without exposing partial rows.
The model comparison exercises block-fused K-format SiTU packing and gate/up/down
metadata inside the unchanged 128 MiB coefficient budget.

`reference-sigmoid-native.f32` contains 32 independent scalar glibc 2.39 sigmoid
results. The producer is preserved as `reference-sigmoid-generator.patch`; its
source and output hashes and reproduction commands are in
`reference-sigmoid.json`. All earlier fixture bytes remain unchanged. The native
Vulkan mixture test now checks gathered expert batches at 1, 2, 4, 17 and 128
rows, malformed counts, and exact reference gating, projection, fused
convolution history and residual addition. Dyadic test coefficients make the
host binary64 convolution oracle exact before each binary32 rounding. The
actual-checkpoint cache test requires resident expert execution during batched
prefill when `MODEL_RUNNER_INKLING_CHAIN_GPU=1` is set.

The `dspark-q8_0-metadata.json` fixture records the pinned 58-tensor Q8 DSpark compatibility audit, tokenizer fingerprints and logical feature contract. It contains no weights and is not a native execution golden. See `docs/inkling2-dspark-compatibility.md`; native DSpark execution remains unsupported.


`dspark-tiny/` and `dspark-long/` hold independently executed dense-block and
context fixtures, with independently computed BF16-input Markov correction.
The long case injects 1,030 positions and shares the anchor's sliding window
across all noise queries. `dspark-bf16/` comes directly from the pinned
`ggml_vec_dot_bf16` source, including conversion ties and independent row/vector
bounds. Each manifest pins its bytes and method. Synthetic tensor payloads are kept as
`weights.bin`; the existing Tiny_Model fixture builder reconstructs their GGUF
framing into obj, so clean checkouts need no ignored model file. Full checkpoint outputs and
initial mismatches are retained under the DSpark evidence artifacts. The old
`dspark-q8_0-metadata.json` is a historical compatibility audit. Reproduction
sources are supplied as reference-only patches, never as native dependencies.
See [native validation](../../../docs/inkling2-dspark-native.md).
