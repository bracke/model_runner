# Transformed four-bit cache experiment

`Model_Runner.Cache_Codecs.Transformed_Four_Bit` began as the stage-two codec
experiment from `plan-low-bit-kv-and-device-tuning.md`. Stage three now exposes
it as the experimental `q4t` session precision. Its purpose remains to answer
one question before any default changes: does an orthonormal
transform make four-bit keys materially closer to F16 at the same bytes?

The session mode appends its precision code, so existing snapshot codes retain
their meaning. `Same_As_Keys` means ordinary Q4 values for this asymmetric
mode. Device shapes, pack/unpack and packed-attention push ABIs carry an explicit
q4t codec identity. The packer and half-copy unpacker recognize it; packed
attention rotates queries before reading transformed keys. Blocked and paged
device caches are supported. The token-specialized kernel performs the same
transform with subgroup shuffles, and the packer distributes each transform
group over thirty-two lanes. Every attention head must currently be a multiple of 32
coordinates. Planning and opening refuse other widths rather than mixing two
heads in one transform group.

## Provenance

The mathematical motivation is TurboQuant's rotate-then-quantize construction:

- Amir Zandieh, Majid Daliri, Mojtaba Hadian and Vahab Mirrokni,
  *TurboQuant: Online Vector Quantization with Near-optimal Distortion Rate*,
  ICLR 2026: <https://openreview.net/pdf/86df3c70aa9b7035c407e886e8238951a5d6ec23.pdf>
- Inesh Chakrabarti et al., *UltraQuant: 4-bit KV Caching for Context-Heavy
  Agents*, especially its Walsh-Hadamard, asymmetric K/V and per-block-scale
  ablations: <https://arxiv.org/abs/2606.20474>

No implementation source from TurboQuant, llamAmpere, vLLM or UltraQuant was
copied or translated. The production butterfly and the test's direct-matrix
reference were written independently from the algorithms in those papers. The
fixed sign mask is original to this experiment. Consequently there is no
third-party code license to carry; the files have this repository's license.

This is intentionally not full TurboQuant. It has no learned or Lloyd-Max
codebook, QJL residual, per-token norm, calibration data or boundary-layer
exception. Those would prevent attributing a quality change to the transform
and would change the byte budget being compared.

## Format

The stored key is divided into groups of at most 32 coordinates. A complete
group is transformed by

`R = H32 D / sqrt(32)`

where `H32` is the Sylvester Walsh-Hadamard matrix and `D` is the diagonal sign
matrix whose bits are `0xD6E8FEB8`, least-significant bit first. A zero bit is
`+1`; a one bit is `-1`. The same `R` is applied to the query, so
`dot(Rq, Rk) = dot(q, k)` before quantization and a stored key need not be
inverse-transformed during attention.

A final group shorter than 32 is partitioned greedily into power-of-two spans.
For example, 29 coordinates use transforms of widths 16, 8, 4 and 1. Each span
has its own orthonormal normalization, while the whole final group still shares
one Q4 scale. This keeps exactly one code per input coordinate: no padding is
stored and arbitrary widths are accepted.

The transformed coordinates use the existing cache Q4 rule, one scale per 32:

1. Find the first coordinate with the largest absolute magnitude, retaining
   its sign as `largest`.
2. Store `scale = largest / -8`.
3. For each coordinate `x`, compute
   `level = floor(x / scale + 8.5)`, clamped to 0 through 15. If the scale is
   zero, the reciprocal is zero.
4. Store the first level in the low nibble and the second in the high nibble.
5. Decode as `(level - 8) * scale`.

Values use this Q4 body without rotation. The baseline in
`cache-quality-baseline.md` is why: at identical bytes, Q8 keys/Q4 values had
55–94% less mean KL than Q4 keys/Q8 values. The first experiment spends its
new mechanism on the fragile side and leaves the tolerant side unchanged.

Storage is therefore identical to current Q4: `ceil(n/2)` code bytes and
`ceil(n/32)` binary32 scales, about five bits per element for complete groups.

## Contract and exceptional values

The package allocates nothing. Callers provide exact-sized bounded arrays.
`Encode_Key`, `Score_Key`, `Encode_Value`, `Accumulate_Value` and
`Finish_Value` are the operations the eventual session codec needs;
`Rotate_Key`, `Restore_Key` and `Decode_Key` make the experiment independently
testable and support the session's shift and snapshot paths.

- A zero group stores scale zero and code `0x88` for each pair.
- Finite input is required. NaN and infinity are refused with `Valid = False`.
- A finite input whose transformed or accumulated value cannot be represented
  in binary32 is likewise refused, rather than saturated.
- A short or oversized caller buffer is refused.
- `Finish_Value` is the identity for this asymmetric first experiment and
  verifies that the accumulated row remains finite.

The independent test reference forms every Hadamard coefficient from the
parity of its row/column indices; it shares neither the production butterfly
nor its decoding and scoring operations. Tests cover zeros, one outlier,
alternating signs, midpoint rounding, a partial final group, dot-product
identity, key scoring, value accumulation, decode/re-encode stability, NaN and
overflow refusal. The papers provide algorithms and distributions rather than
a serialized WHT-Q4 golden byte vector, so the exact zero and midpoint vectors
above are this format's initial golden vectors.
