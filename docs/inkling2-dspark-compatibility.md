# Inkling 2 Mini DSpark compatibility audit

Status: the compatibility audit led to a native CPU adapter for the fixed
58-tensor DSpark variant. See the [native execution contract](inkling2-dspark-native.md)
and [qualification/throughput evidence](inkling2-dspark-native-evidence.json).
The metadata fixture preserves the historical audit status; it is not an
execution-support declaration. The earlier rejected depth fusion remains
rejected. DSpark is an optional drafter, with default selection determined by
measured results.

## Pinned artifacts

The drafter is `Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf_file` from
`unsloth/Inkling-2-Mini-GGUF` at revision
`8078d149286eec7193795413b9e0643da6d11fa1`. Its 503,889,952 bytes have SHA-256
`3da00cf7c31bbe5662b3c0d373ecf782d74d32ef43990acc158ce60c2add72e0`.
The verified download is retained outside Git as
`/home/bent/models/Inkling-2-Mini-dspark-Q8_0.gguf`.

The target remains the Bartowski Q4_K_M checkpoint pinned in
[the reference contract](inkling2-reference.md). Its weights, tokenizer and
Q4T cache policy are unchanged. No additional target weights were downloaded.

The audited primary implementation is ggml-org/llama.cpp revision
`4c7344447cb1727f1e2f982febc99a8f88dcb77f`, specifically
[`dflash.cpp`](https://github.com/ggml-org/llama.cpp/blob/4c7344447cb1727f1e2f982febc99a8f88dcb77f/src/models/dflash.cpp),
[`dspark.cpp`](https://github.com/ggml-org/llama.cpp/blob/4c7344447cb1727f1e2f982febc99a8f88dcb77f/src/models/dspark.cpp),
[`inkling2-loop.cpp`](https://github.com/ggml-org/llama.cpp/blob/4c7344447cb1727f1e2f982febc99a8f88dcb77f/src/models/inkling2-loop.cpp)
and `common/speculative.cpp`. Reference code is used for auditing and testing,
never as an inference dependency of model_runner.

## Verified format and target agreement

The native GGUF inspector parses the complete file: GGUF v3, 39 metadata
entries, 58 tensors, and 368,489,482 stored parameters in Q8_0, BF16 and F32.
The independent header audit compares the complete vocabulary, token types,
424,413 merges, special token settings and chat template against the target.
All shared tokenizer entries agree exactly. The drafter additionally declares
mask token zero; learned mask embeddings supply the noise positions.

| Property | Audited contract |
| --- | --- |
| Architecture | `dflash` with DSpark Markov context head |
| Hidden width | 2304, matching the target |
| Decoder blocks | 3 dense blocks, feed-forward width 9216 |
| Attention | 24 query heads, 8 KV heads, head width 128 |
| Positional encoding | RoPE width 128, base 1,000,000 |
| Local/global pattern | Local, global, local; local window 1025 |
| Trained block size | 8: one accepted anchor plus at most 7 proposals |
| Vocabulary | 200,058 real tokens; target storage pads to 201,024 |
| Markov rank | 256 |
| Context input | Four logical target feature taps |
| Embedding/output ownership | Borrow target embeddings and output weights |
| Final softcap | 30, applied after the Markov correction |

Q8_0 stores the attention and feed-forward projections. The two large Markov
matrices and joint projection use BF16 in this published quantized checkpoint;
this does not require expanding the target weights or changing its cache.
The file omits token embeddings and an output projection, so it cannot serve
as an independent text model.

## Logical feature identity

| Tap | Physical layer | Visit | State |
| ---: | ---: | ---: | --- |
| 5 | 5 | 1 | Input to the logical layer |
| 23 | 11 | 2 | Input to the logical layer |
| 41 | 17 | 3 | Input to the logical layer |
| 48 | Output | After all 48 applications | Final depth mix and output normalization |

The last tap is the normalized state supplied to the target's output head,
not the raw output of its last transformer layer. Physical layer numbers alone
cannot identify the other taps. Treating 23 as physical layer 23 is incorrect.

Each draft layer mixes the four target features using its own `ctx_mix`,
normalizes the result, projects separate context keys and values, normalizes
keys per head and applies RoPE. The Markov head has a separate context mix and
normalization. The exported four-element mix coefficients already sum to one
within their F32 rounding; applying another softmax changes the model.

## Execution requirements

The existing ordinary draft-model driver is insufficient:

1. Selectively capture the target's logical inputs and normalized final state
   during prefill and verification. Capture must preserve batching and existing
   fast paths. Installing the general tensor watcher would disable several of
   them and is unsuitable as the normal DSpark data path.
2. Borrow immutable target embedding/output views with their established model
   lifetime. Validate all token identities and the padded output extent before
   creating dependent state.
3. Inject context KV derived from accepted target features. The three draft
   blocks have their own state; the local blocks and global block retain their
   distinct reach.
4. Evaluate the anchor and learned noise rows as a block. The attention mask is
   defined for the whole block and uses the anchor's local window; the ordinary
   causal `Evaluate_Batch` semantics cannot be substituted.
5. Run the Markov recurrence from the previous proposed token, draft hidden
   state and accepted-token context mix. Apply its vocabulary bias before the
   final softcap. The anchor itself is not a prediction slot.
6. Verify proposals through the existing target generation path. Commit only
   accepted target features, and make reset, rewind, cancellation and failure
   recovery transactional for all draft state.
7. Generate independent encoder, attention, Markov, proposal and rollback
   fixtures before advertising execution support. Qualify sampled verification
   separately from the initial greedy path.

These steps should extend the existing model adapter, session/cache and
generation mechanisms. They do not require a second runtime or executable.
The audit established the pairing. The subsequent native adapter and its
component-pinned conformance are documented in [the execution contract](inkling2-dspark-native.md).

## Evidence and reproduction

[Metadata fixture](../tests/fixtures/inkling2/dspark-q8_0-metadata.json) records
all tensor names, shapes, formats and offsets, tokenizer fingerprints, context
mix payloads, source revisions and artifact hashes. No drafter weights are
stored in Git. Detailed evidence and the native inspector's explicit refusal
are retained under `artifacts/inkling2/obj/dspark-depth-mix/`.

Reproduce the header/compatibility audit against the immutable artifact above
and the pinned target. Do not infer format identity from the filename: the
publisher also provides an older padded-vocabulary variant with different
tensors. This audit applies to the 58-tensor artifact identified by its hash.

Published DSpark gains on other GPUs do not predict a gain on the Ryzen 7
7840U. The [native trial](inkling2-dspark-native-evidence.json) retains Q4T and
the existing memory limits and records proposals, acceptance and complete-model
tok/s.
