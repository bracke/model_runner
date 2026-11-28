# Reference-only DSpark fixture reproduction

Apply each patch in a temporary directory (`patch -p0 < FILE.patch`); no reference
program belongs to the production build. Scripts use `/tmp/inkling-dspark-*`
paths, recorded literally to make their inputs clear. NumPy is needed only by
the independent small Markov calculation.

Pin ggml-org/llama.cpp at `4c7344447cb1727f1e2f982febc99a8f88dcb77f` under
`/tmp/inkling-dspark-native-reference`. Configure Release with `GGML_NATIVE=ON`,
`GGML_LLAMAFILE=OFF`, `GGML_VULKAN=OFF`, `LLAMA_CURL=OFF`,
`LLAMA_BUILD_SERVER=OFF`, and `LLAMA_BUILD_TESTS=OFF`, then build.
Compile `inkling-dspark-reference.cpp` with that checkout's `include` and
`ggml/include`, link `llama`, `ggml`, `ggml-base`, `ggml-cpu` from `build/bin`,
and set the runtime library search path to that directory.

Run `inkling-dspark-make-tiny.py`. The native AUnit tiny-model cases also create
`tests/obj/tiny-inkling-q8.gguf` through the existing `Tiny_Model.Build_Inkling`
helper; this supplies only target embedding/output weights to the independent
reference. Create `/tmp/inkling-dspark-tiny/reference`, then run the reference:

```
inkling-dspark-reference tests/obj/tiny-inkling-q8.gguf /tmp/inkling-dspark-tiny/tiny-dspark.gguf /tmp/inkling-dspark-tiny/features.f32 /tmp/inkling-dspark-tiny/reference 32 16 3
python3 inkling-dspark-tiny-golden.py
```

For the window fixture, create `/tmp/inkling-dspark-long`, copy the tiny drafter
there, and write 1,030 * 128 little-endian binary32 values from
`math.cos(i * 0.067) * 0.3`. Run the reference with those features, output in
that directory, the same target, H=32, V=16, anchor=3, and final argument 1030.
Run `inkling-dspark-long-golden.py`. Run the reference-only `inkling-dspark-package.py` after both captures. Copy
its independent raw `weights.bin`, packaged manifests and numerical arrays to
the fixture directories. Model GGUF files stay outside Git; `Tiny_Model` builds
their framing into `obj` during every test. The generated GGUF hash is the same
as the original independent synthetic model.
The small reference omits the upstream packed draw output, which requires a
larger hidden dimension; the independently calculated NumPy recurrence provides
all seven corrected rows and token IDs instead.

For full-checkpoint capture use the external Q4_K_M target and Q8_0 drafter
pinned in `docs/inkling2-dspark-compatibility.md`, feature argument `@target`,
H=2304, V=200058, anchor=0. This captures newer-reference features and every
small graph node alongside raw/corrected logits. It does not establish target
conformance across upstream versions. Native target taps use the original
`q4_k_m-int8-prefix` fixtures: final-token `l_out-4`, `l_out-28`, `l_out-46`,
`result_norm` rows concatenated in that order, representing taps 5/23/41/48.
The target input is [371,151451,149879,151194,149884]. The component test reads
these separately from the newer drafter fixtures.

Compile `inkling-dspark-bf16-fixture.cpp` with the pinned checkout's CPU
`vec.cpp`, its normal include paths and `-O3 -march=native`; link the CPU/base
GGML libraries. The single argument is an existing output directory. It calls
the independent `ggml_vec_dot_bf16`, including nearest-even conversion ties.
The fixture manifests pin all binary input/output hashes. Initial build/tap
mismatches remain in the evidence artifacts; no old fixture or numeric bound
was changed to accommodate them.
