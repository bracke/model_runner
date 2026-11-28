# Independent synthetic decoder references

`tiny-f32.tsv` and `tiny-prefix-f32.tsv` are outputs of the pinned independent
llama.cpp reference, not outputs of model_runner. `Tiny_Model.Build_Inkling`
generates their deterministic, synthetic GGUF. The fixture contains no weights
from an external checkpoint. Its SHA-256 is
`c3c1b3cabe3fcf141d74667905e256d7b6210f911381c808bc768c2aa126e586`.

The model has 24 physical layers, three core visits, width 8, four experts
with two active, two query heads, one KV head, four-dimensional heads,
four-tap convolutions, a four-token local window, relative extent four and
global scale floor eight. Its vocabulary has 16 tokens but its embedding and
output tables have 20 rows. All weights are F32. These reduced dimensions
exercise the same operations and state identities as the full model.

Both recordings use llama.cpp b12600 at
`29b52d398b294509746ec0a3f28948a3107c0213` and the checked-in
`reference-capture.patch`, whose SHA-256 is
`2e97e9a28cb74168ad34e8894e4beb741bde8ccfd2e629cb575c0528a4b20462`.
The canonical build disables `GGML_LLAMAFILE`; its remaining settings and
library hashes are in `q4_k_m-cpu-hello/manifest.json`. The same frozen binaries
and libraries generated these recordings.

```sh
INKLING_FIXTURE_DIR="$CAPTURE" llama-eval-callback \
  -m fixtures/tiny-inkling.gguf -p '<s>' -c 32 -b 8 -ub 8 \
  -t 1 -ngl 0 -ctk f32 -ctv f32 -fa off --no-repack
INKLING_FIXTURE_DIR="$PREFIX_CAPTURE" INKLING_STEPWISE=1 llama-eval-callback \
  -m fixtures/tiny-inkling.gguf -p '<s><s><s><s><s><s><s><s><s><s>' \
  -c 32 -b 16 -ub 16 -t 1 -ngl 0 -ctk f32 -ctv f32 -fa off --no-repack
```

The first prompt is exactly token ID 1. The second is ten copies of ID 1;
the incremental capture retains the final token, position 9. It crosses
the local-window, convolution-history, relative-extent and global-scale-floor
boundaries. The reference rounds its allocated context up to 256; the inputs
remain within the fixture's 32-token training context.

Each TSV line is a tensor name, a tab, then its contiguous values separated
by spaces. F32 values use nine significant decimal digits, which round-trip
to the original binary32. Integer expert IDs are retained as integers.
These are direct little-endian raw-dump conversions; no model computation
is performed while packaging them. Each file contains 834 tensors, including
the 336 routing tensors. At eight residual block boundaries `attn_out` is
renamed `ffn_inp`; the other 40 attention outputs retain their own names.

| Recording | Bytes | SHA-256 |
| --- | ---: | --- |
| `tiny-f32.tsv` | 74620 | `e26a99bac26b6223ddf329a25c638e66f785bb95c9993508eb9bb5ec9c548fe8` |
| `tiny-prefix-f32.tsv` | 74618 | `94468e4c57a2f56f81258bb553eba2f992e14a741925572813dd2e3cbedc6df2` |

The AUnit observer compares all 834 tensors, including exact expert IDs,
and 4952 elements in each F32 recording. The initial single-token comparison
measured a maximum absolute difference of `2.53320e-6`; the ten-token prefix
measured `2.92063e-6`. Its acceptance bound is `1e-5` absolute
plus `2e-5` times the reference magnitude. Full-checkpoint and device conformance use their own captures and recorded
results in the verification document. This fixture alone does not establish
those results.

`tiny-q8.tsv` uses the same independent binary with a wider synthetic fixture:
hidden width 32, expert width 64, and Q8_0 projection matrices where block
alignment permits. Depth queries, learned normalization and clipping tables,
convolutions and the router retain F32. Its GGUF SHA-256 is
`ade485d047d54163d32b91e2cdaa533c7663e1996f7e5c44a9183a24195a9486`.
Generate it with `Tiny_Model.Write_Inkling (..., Quantized => True)` and use
the single-token command above with `fixtures/tiny-inkling-q8.gguf` instead.
The recording has 834 tensors, 14000 elements, 187680 bytes and SHA-256
`7b03fcdab823eab54866913d367f23f292aeaa86473e016f509f29f6b6b9b986`.
Its initial native CPU comparison measured maximum absolute error `2.38419e-6`
under the same bound. It verifies the adapter's explicit half-precision Q8
activation scales through both projections and experts; the larger Q4_K_M checkpoint and its K-quantized expert matrices have
separate independent captures.

## Extended state and zero-controller recordings

`tiny-long-prefix-f32.tsv` records position 2199 after 2200 copies of token 1
with a 2304-token synthetic context. Both full-batch and incremental independent
reference execution produced byte-identical final-token dumps for all 834
observed tensors. The native test also rewinds after actual local-cache eviction
and compares an alternative continuation with a fresh run. The provenance JSON
records its model, capture and fixture identities.

`tiny-zero-controls.tsv` records the same single-token synthetic decoder with
all learned gain and forget projections zero. Three core visits still execute;
zero controls must not bypass residual/message ordering or read uninitialized
state. It contains 834 independent tensors and has SHA-256
`7ef0e9aba8c66242ebba61187e07b6d564a9c6eee6ec98dc077b54ffe28a340b`.
Its GGUF SHA-256 is
`9b63be6e6bfcca5738d343c40e7c1ec42cd72b2fab2ae4a631daa5243f882d23`.
Use the single-token capture command above with
`fixtures/tiny-inkling-zero-controls.gguf`; no precision override environment
variable is enabled. Packaging reads the raw F32/int32 files into nine-digit
TSV, without computing model outputs. See `tiny-zero-controls-provenance.json`.

The current AUnit generator writes these reproducible GGUF containers under
`tests/obj/`, consistent with the repository fixture policy. Historical capture
commands above used `tests/fixtures/`; substitute `obj/` when regenerating.
Changing the output path does not change their recorded contents or hashes.
