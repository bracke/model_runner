# Mellum learning data selection

This refines the [learning protocol](mellum-learning-protocol.md) before fitting or held-out evaluation.
The existing Add, Times and Subtract fixture families and their old captures remain excluded from training.

Each fresh teaching attempt is retained, including failures. A supervised source must have a native
independent passing grade and a complete exact-token capture from the declared Mellum base. The current
curator handles root-only episodes; linked helper episodes are refused rather than partially interpreted.
Capture hashes and independent-result artifact hashes are recorded in every selected frame.

A successful episode can contain earlier incorrect edits. Those edits are not positive labels. The curator
selects only the last successful source mutation, the last successful check, and the final generation.
Generations with multiple mutating calls are excluded conservatively. Only naturally completed generations
are eligible. Reasoning before the last closing think tag is masked, as are prompt, environment and forced
tokens. The actual selected terminal token is retained. No response is rewritten or labeled model-generated
after a human repair.

Within each eligible visible response, up to 32 token positions are selected uniformly by index, independent
of token likelihood. Their exact input tokens, response tokens, generation and one-based loss positions
are retained. Each family has a 256-position cap. Frames longer than 16,384 tokens are not fitted.
The four training families therefore contribute at most 1,024 positions; calendar validation contributes
at most 256. A family with no qualifying positions refuses dataset construction.

Frozen normalized states and base logits are extracted once by teacher forcing. The default extractor uses
the declared Mellum identity, device execution, seven workers, q4t keys, q4 values and a 16,384-position
capacity. Input batches are capped at 64. Only batches containing selected predecessors request every
position's state and logits. The CPU path is used for independent numerical controls.

Feature artifacts use a bounded little-endian format with explicit width, vocabulary, row count, token
target and binary32 arrays. Their manifest binds the base, source datasets and feature hashes. Fitting
refuses changed features, wrong model identities, incomplete sizes and nonfinite values. A numerical
control compares extracted rows against an independent evaluation of the selected token's prefix.

The fitted update is `B * A * h` on the output projection, with alpha equal to rank. The transformer is
frozen. Independent finite differences check both factor gradients. Zero-update merging preserves every
model byte; nonzero F32 and quantized merges are checked against an independent low-rank product.
The applied GGUF retains its original head quantization and copies all other bytes unchanged. Merge
artifacts record quantization error; held-out workflows evaluate the actual converted weights.

The numerical unit-test data is synthetic and is never included in the real training corpus. The learning
curve and native workflow comparison, not passing infrastructure tests, determine the experiment's result.
