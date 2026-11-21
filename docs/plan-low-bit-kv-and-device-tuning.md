# A better low-bit KV cache, then device tuning

`model_runner` already has the five mechanisms highlighted by llamAmpere's
speed work: a model's own next-token block, a 65,536-row draft head, exact
`p/q` speculative sampling, attention over a cache kept packed, and shader
shapes selected for the work they do. Two things remain worth taking from that
work rather than reproducing it: a low-bit cache whose codec preserves more of
the model than the present uniform Q4 blocks do, and launch choices measured
for the device actually running them rather than fixed from the device on which
this backend was written.

This plan builds them in that order. The cache codec comes first because it can
be proved useful and correct on the processor before a shader changes. Device
tuning comes second and initially only records an explicit measurement; an
ordinary run may consume a valid profile automatically, but it does not perform
an unasked benchmark until that workflow has proved stable.

**Status: implemented through automatic profile use (2026-11-20).** Stages one
through six and eight through ten are implemented. Stage seven remains the
optional, separately gated lower-bit experiment it was defined as; bounded
first-use benchmarking remains deferred until profiles have been replayed on
two materially different devices.
The stage-one instrument lets one prepared model compare two key/value cache
storages and reports both
perplexities, mean and worst-position KL, top-token agreement, planned KV bytes
and per-arm time. Its focused test and a Q4-versus-F16 tiny-fixture run pass.
The four-family quality baseline and the quiet-host q4t-versus-Q4 timing are
recorded in `cache-quality-baseline.md`. The result narrows stage two:
preserve keys first, because Q8 keys/Q4 values beat the inverse pairing by
55–94% mean KL at identical bytes. Stage two's standalone codec and independent
direct-matrix reference are specified in `cache-codec-q4t-spec.md`; their
focused test passes. Stage three now exposes `q4t`, retains Q4's byte budget,
stores transformed keys with ordinary Q4 values, and runs token, batch, shift,
window, mixed-value, snapshot and adoption paths on the host. Its focused
session test passes.
Arbitrary head widths remain deliberately excluded. The independent reference
covers key scoring and value coding.
The first four-model stage-four run is also recorded: q4t lowers aggregate mean
KL by 66.8% from Q4 at identical bytes and improves top-token agreement on all
four models. Gemma 3 has one worse tail outlier despite its better mean; an
eight-chunk follow-up confirms the mean win and records that outlier for the
long-context gate.
The 1,024-token Gemma depth run also favors q4t: 58.3% lower mean KL, 6.4
percentage points more top-token agreement, and a lower worst KL than Q4.
The completed eight-chunk sweep strengthens the decision: aggregate mean KL is
75.7% below Q4 and average top-token agreement is 12.5 percentage points
higher, with every model's mean improved. Stage four's quality gate therefore
passes. Its quiet-host, order-balanced timing is now recorded: q4t costs
12.2--21.7% more arm time than Q4 by model, and 14.1% over the combined arm
times. This host cost is accepted for the 2026-11-20 default because the
completed quality sweep and device generation gate pass; CPU-only runs retain
the measured cost.
Stage five passes an explicit cache-codec identity through the pack/unpack push
ABI. The q4t pack shader matches the host encoder byte for byte and scale for
scale at full and partial groups, through subgroup and plain paths; the unpack
shader is checked through exact matrix attention over its half copy. Blocked
and paged placement, page-boundary addressing, raw read-back and reconstruction
all pass their focused test.
Stage six rotates the query inside `attention_packed.comp` and the specialized
token kernel, preserves the ordinary Q4 value path, and passes direct,
sliced-and-merged, windowed and sink attention against the exact decoded cache.
The subgroup packer distributes a transform group over thirty-two lanes; its
plain fallback retains the scalar reference operation.
A real paged q4t session now keeps whole layers on the device, with no attention
handoff, and agrees with its host session within the established device-logit
tolerance. With automatic drafting disabled so different cache answers cannot
change the work done, Gemma 3 4B generates at 23.35 versus Q4's 23.51 tokens/s
at 1,328 positions, and 21.11 versus 21.21 at 17,187. Those 0.7% and 0.5% gaps
are level at the measurement's resolution and clear the device speed gate.
Nothing in this plan changes a default until its own quality, correctness, speed and
fallback gates have passed. The two projects are independently shippable:
stopping after the cache work leaves no unfinished tuner, and rejecting the
cache at its quality gate still leaves device tuning worth doing.

## The baseline already here

The cache can be exact (`f32`), halved (`f16`), signed bytes with one scale per
row (`q8`), nibbles with one scale per block of thirty-two (`q4`), or OCP E4M3.
Keys and values may use different packed precisions. Packed blocks and packed
pages share the same region-major layout; the host can attend from the packed
bytes, the device can pack and attend them in place, a prompt can unpack them
into the half-precision matrix-attention copy, and snapshots preserve the
numbers the bytes represent. The conformance sweep checks those paths against
an independent implementation of their rounding.

That proves implementation fidelity, not model quality. In particular, the Q4
check compares the engine with an independent computation of the same Q4
rounding. It does not say how much information Q4 loses against F16. The
perplexity tool already computes KL divergence between two model files, but it
cannot yet compare two cache modes of the same file. That missing measurement
is the first deliverable.

The device backend likewise already has specialization constants and several
measured kernel choices. Some policy is still a build-time constant. The clearest
case is `Want_Workgroups := 256`, measured on a twelve-compute-unit part; the
comment beside it says another part would want its own number. Vulkan exposes
enough stable identity to remember a measurement even where it exposes no
portable compute-unit count.

## Decisions made before implementation

**Measure cache quality against F16 from the same model file.** Weight
quantization must be held constant. Comparing a Q8 model file with a Q4 model
file would mix the cost of the weights into the cost of the cache.

**Begin with one transformed four-bit body.** `q4t` is the working name, not a
promised command-line spelling. It targets roughly the present Q4 footprint and
isolates whether transforming or otherwise shaping a thirty-two-element block
improves quality. Three-bit bodies, trellis coding and a recent F16 window are
separate gates after that result. Starting with all three would make a bad
quality result impossible to attribute and would force a general bitstream
layout into the device before the codec earned one.

**Define a codec contract, not a collection of branches on a new enum.** Keys
and values do not necessarily use the same operations. A rotated key may
require the query to be rotated before its dot product; a rotated value may
require the blended result to be turned back. The host-facing contract therefore
names `Encode_Key`, `Score_Key`, `Encode_Value`, `Accumulate_Value` and
`Finish_Value`, plus its byte and auxiliary-data geometry. Uniform Q8 and Q4
can be described by that contract too, but are not rewritten in the first
stage.

**Append snapshot precision codes.** New `Cache_Precision` and
`Value_Precision` values go at the end. Existing snapshots keep their meaning.
The snapshot version changes only if the new codec needs metadata that the
precision code and model shape do not determine.

**Do not copy an algorithm from a name.** Before code is ported, the precise
codec specification, golden vectors, license and provenance are recorded. A
Walsh-Hadamard/TurboQuant-like experiment may be written independently from
the published rule; an SJ-KVaRN port is taken only from its licensed source and
credited. The experiment and a port are different changes.

**A tuning profile may choose only tested alternatives.** It cannot inject a
workgroup size, tile or slice count outside a bounded list compiled into the
program. An absent, stale, corrupt or slower profile means the current constants.
The profile is an optimization hint, never a condition for running.

**Tune launch policy before generation policy.** The first tuner does not
change temperature, draft depth or context semantics. It chooses equivalent
kernel paths. Draft depth and prompt batch size may be reported as recommendations
later, because changing either also changes latency, cancellation grain or the
sequence of sampled draws.

## Part one: prove the codec

### 1. A same-model cache-quality instrument (two to four days)

Extend `tests perplexity` so one model file can be read into two sessions with
different cache storage:

```
tests perplexity --model MODEL --kv-cache q4 --against-kv-cache f16 ...
```

Both arms use the same prepared weights, tokenizer, text, context, rope settings,
arithmetic and backend. They evaluate the same chunks and compare every scored
distribution. The report carries:

- mean KL divergence from F16;
- worst-position KL and its token position;
- top-token agreement;
- perplexity for each arm;
- cache bytes and seconds for each arm;
- the number of positions actually compared.

The command refuses two arms that silently differ in anything other than cache
storage. Tests cover a flat distribution, a known differing pair, a cache mode
that changes no row, and a deliberately mismatched arm. A run that scores zero
positions fails as every other measurement command does.

Take the baseline before adding a codec: F16, Q8, Q4, Q8 keys/Q4 values and Q4
keys/Q8 values on at least one dense model, one grouped-query model, one
sliding-window model and one attention-sink model. Use a short corpus for the
gate and one long-context prompt for depth. Record the command, model digest,
context, backend and host load in `docs/measured-figures.txt`.

### 2. The codec and its independent reference (four to seven days)

Add a small pure package for the candidate codec. Its public operations consume
and produce ordinary real rows and a bounded byte/auxiliary buffer. It allocates
nothing, accepts a block whose width is not a multiple of its group size, and
defines zero, NaN and overflow behavior.

Write the production encoder/decoder and a deliberately plain reference from
the specification, not by calling the production routines. Golden-vector tests
cover:

- all zeros, one outlier, alternating signs and the representable extremes;
- half-way rounding cases;
- partial final blocks;
- keys and values independently;
- encode/decode stability and the published vectors, where the chosen codec
  supplies them;
- the transform's dot-product or inverse-transform identity before quantization.

No `Cache_Precision` value and no CLI name exists yet. This stage answers only
whether the codec is correctly understood.

### 3. A host-first experimental cache mode (four to six days)

Append the experimental precision and thread its geometry through the engine:

- byte and auxiliary counts, alignment, `Cache_Name`, option parsing and memory
  accounting;
- block and page layouts;
- `Open`, placement, attention, rewind, shift and close;
- snapshots and adoption;
- distinct key/value storage where the codec permits it;
- `inspect` and statistics.

The processor attends through the codec contract. The reference backend decodes
through its independent implementation. At this stage the device backend
explicitly declined the mode and kept attention on the host while its products
remained on the device. That fallback was reported; no shader interpreted the
new bytes as Q4. Stages five and six subsequently added the explicit device
codec path described below.

Tests mirror every existing packed-cache test: a token and a batch, a window,
a context shift, a snapshot round trip, a page boundary, a page turned out and
read back, mixed key/value storage, and refusal of an invalid pairing. The engine
and reference backend agree over the values the candidate bytes stand for.

### 4. The quality gate (three to five days of runs)

Run the instrument from stage one with F16 as the baseline. A candidate proceeds
only when all of these are true on the recorded model set:

1. Its bytes per cached position are no greater than the present Q4 mode, or
   any increase is stated and compared at the same byte budget.
2. Mean KL improves by at least twenty per cent over Q4 on the aggregate.
3. No model's mean KL is more than ten per cent worse than Q4, and the worst
   position is inspected rather than hidden by the mean.
4. Top-token agreement is no worse on every model, apart from a recorded tie
   whose F16 logit gap is below the existing near-tie threshold.
5. Attention-sink and sliding-window cases pass separately; a result on dense
   Llama alone is insufficient.
6. Encoding and host attention costs are reported. A codec that wins quality
   but is slower is not rejected automatically, but cannot become the default.

The percentages are an initial decision boundary, not a claim about a codec not
yet measured. If Q4 is already too close to F16 on the small fixtures for the
ratio to be meaningful, use the long corpus's absolute KL and record why the
gate changed.

If the candidate fails, remove the experimental engine mode and keep the quality
instrument and golden-vector experiment. Do not build its shaders.

## Part two: put a winning codec on the device

### 5. Device layout and pack/unpack kernels (one to two weeks)

**Done.** The codec identity is append-only in every device shape. Both shader
variants produce the host encoder's bytes and scales, unpack into the half copy,
and read back blocked and paged rows across page boundaries.

Give the winning codec an explicit device layout. Keep packed pages region-major
unless measurement proves a different access pattern necessary. Extend the
packed shape passed to the backend with a codec identifier and the offsets of
all auxiliary regions; do not overload `K_Bits`/`V_Bits` with a value that makes
an old kernel guess the codec.

Implement and independently test:

- `pack.comp`: encode a position where its cache is made;
- `unpack.comp`: reconstruct a layer into the half-precision copy for prompt
  matrix attention;
- read-back into the host's snapshot representation;
- paged and blocked addressing at shift zero and past two pages.

First compare device bytes and auxiliary data with the host encoder bit for bit.
Only then use them for attention. Regenerate the embedded shaders and update
their source digests through the repository's shader workflow.

### 6. Direct packed attention (one to two weeks)

**Done.** Direct and sliced packed attention,
including merge, windows, sinks, mixed q4t-key/Q4-value storage and a paged
full-session route, pass. The short and deep acceptance measurements are
recorded in `cache-quality-baseline.md`.

Extend `attention_packed.comp` or add a separate shader when the new codec's
inner loop is materially different. A separate shader is preferred over a
per-element codec branch. Preserve:

- bundled grouped-query heads;
- sliced long-context attention and merge;
- attention sinks;
- mixed key/value codecs;
- packed pages;
- the plain shared-memory reduction for devices without subgroup arithmetic.

The check has three levels:

1. The device agrees with host attention over the decoded candidate values.
2. Device packing agrees bit for bit with host packing.
3. Full-model logits stay within the codec tolerance established at the quality
   gate on both evaluation paths.

Measure short and long contexts separately. The acceptance target is no more
than five per cent slower than current Q4 at 1,419 positions and no slower at
16K or deeper, at the same or smaller memory. The device result met this gate
and, with the completed quality sweep, made q4t the unnamed default on
2026-11-20. `--kv-cache fit` remains the separate explicit f16/q8 policy.

### 7. Lower bits and a recent window (optional, separately gated)

Only after transformed Q4 ships, try one change at a time:

1. Three-bit values with four-bit keys.
2. Three-bit keys and values.
3. A bounded F16 recent window in front of a low-bit body.

Three-bit storage needs a general bitstream geometry rather than pretending to
be bytes or nibbles. The recent window needs two physical regions and explicit
rules for commit, rewind, shift, snapshot and page eviction; it is not represented
as a codec flag. Each variant repeats the quality gate at its own byte budget.

## Part three: describe and tune the device

### 8. A stable device fingerprint and tuning record (two to three days)

**Done.** An open context now reports one bounded `Device_Identity`: numeric
vendor, device and driver IDs, the sixteen-byte pipeline-cache UUID, the name
for display, and the matrix, subgroup, sized-subgroup and integer-dot
capabilities used by the backend. The POSIX Vulkan body reads those values from
the same properties structure it already queried; closed, unsupported and
currently unsupported Windows contexts return no identity. The localized name
is deliberately absent from the matching key.

`Model_Runner.Platform.Device.Tuning` builds an exact bounded key from that
identity, tuning schema, shader stamp and executable stamp, and maps it beneath
the cache home's `tuning` directory. Its 4 KiB record carries only the safe
launch choices listed below. It is replaced through a uniquely named sibling,
with file and directory syncs. A missing field, unknown or duplicate field,
non-canonical or out-of-range value, oversized file, invalid key or key mismatch
turns the whole read into the existing safe defaults. The focused tests exercise
the real device identity where one is available, a record round trip and each
strict rejection. Stage ten now consumes this record on an ordinary device
open; the storage package itself still only validates and returns choices.

Expose the Vulkan properties already adjacent to the fields the platform body
reads:

- vendor ID and device ID;
- driver version;
- pipeline-cache UUID, or device UUID where the supported properties call
  provides one;
- device name for reporting only;
- subgroup and cooperative-matrix capabilities already recorded.

The POSIX and Windows bodies return the same bounded `Device_Identity`; the
unsupported body returns none. Names are not identity because drivers localize
and revise them.

Add a versioned, bounded tuning record under the cache directory. Its key covers
the device identity, driver, shader digest/program stamp and tuning-schema
version. It is written to a sibling temporary file and renamed, as the other
caches are. Unknown fields, duplicate fields, out-of-range values and a mismatched
key cause the whole record to be ignored. There is no partial application.

The first record contains only launch choices that already have safe defaults:

- attention's target workgroups and slice thresholds;
- row-product workgroup specialization selected from compiled variants;
- packed-attention bundle/slice policy;
- matrix-versus-row crossover where both kernels support the shape.

### 9. An explicit tuning campaign (four to six days)

**Done.** The product engine now owns one complete `Launch_Choices`
value and accepts only the fixed candidate values whose pipelines and scratch
geometry this build already carries. Application is atomic: one unsupported
field leaves the previous policy unchanged, reopening restores the established
defaults, and no ordinary run selects a candidate yet. The selectable paths
now include packed-attention workgroup, slice and bundle policy, the compiled
128/256-lane row-product variants, and the matrix-versus-row crossover. A
focused device test runs the non-default 128-lane row product and checks its
answer before restoring the default.

`tests device-tune` now warms and alternates every fixed candidate against the
defaults and prints wall and device-timestamp medians. Its correctness gate
covers F32, Q8 and Q4 narrow, verification, prefill and feed-forward products;
exact attention at 128, 1,419 and 16,384 cached positions and at 2, 4, 8, 16
and 32 queries; and Q8, Q4 and q4t packed attention at decode, verification,
prefill and long-context shapes. It scores decode/verification/prefill/packed
long attention at 40/30/20/10, requires a one-percent median win, assembles
the independently winning choices, and replays that combined policy over the
whole shape set before it may write anything. `--write` stores the exact-keyed
proposal atomically and `--check PROFILE` reloads and replays it. A profile
field may contain only the compiled whitelist: the packed-round switch has no
dispatch that can presently distinguish it, so its non-default value is
rejected rather than presented as a measured choice.

Add `tests device-tune` before adding any first-run behavior. It opens one device,
warms each candidate, alternates candidates to reduce thermal bias, and records
median device timestamps as well as wall time. Candidates are a fixed list.

Every timing sample also checks an output mark or tolerance against the current
default. A candidate that is faster and wrong is rejected, not ranked. Device
loss, timeout, non-finite output or cancellation leaves no profile.

The campaign covers at least these shapes:

- one generated token at short, 1,419 and long cache depths;
- verification batches of two, four and eight rows;
- prompt batches at the narrow and matrix-attention crossovers;
- Q8, Q4 and the new codec if it passed part two;
- a narrow projection and a feed-forward projection.

Selection uses a weighted score published in the output, initially forty per
cent single-token decode, thirty per cent drafted verification, twenty per cent
prefill and ten per cent packed long-context attention. The raw measurements
are printed so another policy can be applied without rerunning them.

The tool writes a proposed profile only with `--write`. `--check PROFILE`
replays its selected candidates against the defaults and is the regression path.

### 10. Automatic use, then bounded first-use tuning (three to five days)

**Done for automatic use; first-use measurement remains deliberately
deferred.** The backend derives the same shader stamp as the explicit tuner and
loads the exact cache path when a device opens. A valid profile is applied as
one complete policy and its path is reported. An absent, corrupt or stale
automatic profile is a cache miss and keeps the compiled defaults.
The separate tests executable keys the record to the sibling production
`bin/model_runner`; otherwise its own executable stamp would make every
profile stale before an ordinary run could read it.
`--device-tuning none` disables lookup; `--device-tuning PATH` makes an invalid
or mismatched record a typed error. The option is shared by run, embed, image
and transcribe, and the embedded inference API carries the same request.
Focused tests cover exact application, disablement, strict refusal, parser/help
plumbing and localized diagnostics.

Only one device identity has produced and replayed a profile during this work,
so no unannounced first-use screen has been added. That preserves the following
gate rather than treating one machine as evidence for a portable campaign.

An ordinary run automatically loads an exact-match profile and reports that it
did. `--device-tuning none` ignores one; `--device-tuning PATH` names one and
turns a mismatch into an error rather than a silent fallback. No profile means
today's constants.

After profiles have been produced and replayed on at least two materially
different devices, consider first-use tuning. It is admitted only if the full
campaign can be bounded to a documented time and interrupted safely. The first
version should therefore be one of:

- an explicit `model_runner tune` command whose result later runs use
  automatically; or
- a short first-use screen followed by the full explicit campaign for uncertain
  choices.

Do not put a multi-second unannounced benchmark in model loading merely to call
the result automatic. Automatic application of an explicit, durable profile is
already useful and reproducible.

## Verification and evidence

Each implementation stage ends with the smallest relevant checks, then the
repository gate:

1. Codec golden vectors and cache unit cases.
2. Inference cases for token, batch, window, shift, snapshot and pages.
3. Device attention and shader-generation cases where shaders changed.
4. The conformance sweep, with compared counts for every new mode so a silent
   fallback reads as zero.
5. CLI option, help, settings and invalid-profile cases.
6. `tests perplexity` cache-quality runs and `tests speed` timing runs outside
   the default gate, recorded with their model and environment.
7. `tools/bin/check_all` after each independently shippable part.

The evidence table for each cache mode records bytes per position, mean and
worst KL from F16, top-token agreement, prompt rate and decode rate at shallow
and deep context. The tuning table records the fingerprint, driver, candidates,
raw medians, output checks and chosen values. A headline never combines results
from different devices or models.

## What is not in this plan

**CUDA or SM86 kernels.** The useful idea is specializing for the work and the
device. This backend remains Vulkan and selects among Vulkan kernels its device
can run.

**Card-memory presets.** The run already accounts for weights, context, host
sharing and a margin, and chooses a backend, split and cache fit. A preset for
"12 GB" would discard information the planner already has.

**A new prompt cache.** The automatic prefill cache is already keyed by model,
resolved settings and build, keeps several prompt prefixes, and maps a hit
directly. Device tuning may be stored beside it but does not replace it.

**Changing the default cache to the experimental codec.** Shipping a named
mode and choosing it under `fit` are separate decisions. The latter needs
quality evidence on the models `fit` may encounter, not only the models used to
develop the codec.

**Tuning draft depth in the launch profile.** Acceptance is prompt- and
model-dependent, while launch shape is device-dependent. A later speculative
benchmark may recommend a depth, but the device profile does not silently
change sampling work.

## Order and estimate

Stages 1 through 4 are the first project: about two to three weeks including
measurements. They end in a hard gate. If the codec wins, stages 5 and 6 take
roughly two to four more weeks; stage 7 is optional.

Stages 8 through 10 are the second project and can begin after the host codec's
quality gate, while device kernels are still being built: about two weeks for
the explicit, cached-profile workflow, plus a later bounded first-use screen if
the evidence supports it.

The likely whole is five to eight weeks, dominated by the new codec's device
attention and by measurements rather than enum wiring. The first useful artifact
arrives much earlier: the same-model cache-quality instrument in the first week.
