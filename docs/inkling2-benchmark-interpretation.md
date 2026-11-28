# Benchmark operation-count correction

The premeasurement protocols are preserved unchanged for provenance. Their
operation-count assumptions were incorrect; the commands, retained samples,
output checks and measured times remain valid and unchanged.

In the existing non-drafting generator, `L.Evaluate` commits every sampled token
to the session before the output-token limit is checked. See
`src/library/model_runner-generation.adb:3687` and `:3806`.

- The five-prompt/sixteen-output CPU case performs five prompt evaluations and
  sixteen decoder evaluations, including evaluation of the last output token.
  The raw acquisition metadata assumed fifteen and its derived fifteen-step
  rate is withdrawn. The correct decoder-evaluation rate equals the native
  sixteen-token generation rate, median 1.786 evaluations/s.
- The one-prompt/one-output case performs two network evaluations: one prompt
  evaluation and one decoder evaluation. The raw field `sampling_seconds`
  contains decode time including that network evaluation. The earlier
  sampling-only interpretation is withdrawn.
- The private-GPU short-case timeline records four output-head products: two
  from its untimed warmup and two from its measured pass. The timeline option
  then runs another complete campaign without recording its GPU timeline.
  The captured GPU work therefore covers the first campaign, including its
  warmup; it covers neither the measured pass alone nor the whole process.

The [corrected report](inkling2-native-benchmark-evidence.json) supplies explicit
counts and field mappings. Original raw evidence and premeasurement protocol
hashes remain intact. No sample was retried, excluded or replaced.
